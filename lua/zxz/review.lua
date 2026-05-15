---Review the agent's worktree through the user's git UI.
---
---We run `git merge --no-ff --no-commit <agent-branch>` in the user's main
---worktree. That stages every committed turn from the agent branch as a real
---git merge state — index populated, MERGE_HEAD set, conflict markers inserted
---where needed — and then we open a dedicated full-tab Fugitive review layout:
---changed files on the left, side-by-side diff for the selected file on the
---right.
---
---Closing with `q` aborts the temporary merge if it is still in progress, so
---the main worktree is free for future reviews or normal merge work.

local Worktree = require("zxz.worktree")

local M = {}

---@class zxz.review.File
---@field status string
---@field path string

---@param wt zxz.Worktree
---@return boolean ok
---@return string? err
local function stage_branch(wt)
  local out = vim.fn.system({
    "git",
    "-C",
    wt.repo,
    "merge",
    "--no-ff",
    "--no-commit",
    wt.branch,
  })
  if vim.v.shell_error ~= 0 then
    -- Conflicts produce a non-zero exit but DO leave the index populated and
    -- MERGE_HEAD set; surface that as a soft notice so the user can resolve
    -- in their git UI normally.
    if out:match("CONFLICT") then
      vim.notify("zxz.review: merge has conflicts — resolve in your git UI", vim.log.levels.WARN)
      return true, nil
    end
    return false, out
  end
  return true, nil
end

---@param repo string
---@return zxz.review.File[]? files
---@return string? err
local function changed_files(repo)
  local lines = vim.fn.systemlist({
    "git",
    "-C",
    repo,
    "status",
    "--porcelain=v1",
  })
  if vim.v.shell_error ~= 0 then
    return nil, table.concat(lines, "\n")
  end

  local files = {}
  for _, line in ipairs(lines) do
    local status = line:sub(1, 2)
    local path = line:sub(4):gsub("^.* %-> ", "")
    if status ~= "??" and path ~= "" then
      files[#files + 1] = { status = status, path = path }
    end
  end
  return files, nil
end

---@param repo string
---@return boolean
local function merge_in_progress(repo)
  vim.fn.system({
    "git",
    "-C",
    repo,
    "rev-parse",
    "-q",
    "--verify",
    "MERGE_HEAD",
  })
  return vim.v.shell_error == 0
end

---@param repo string
---@return boolean ok
---@return string? err
local function abort_merge(repo)
  if not merge_in_progress(repo) then
    return true, nil
  end
  local out = vim.fn.system({
    "git",
    "-C",
    repo,
    "merge",
    "--abort",
  })
  if vim.v.shell_error ~= 0 then
    return false, out
  end
  return true, nil
end

---@param buf integer
---@param state table
local function map_close(buf, state)
  vim.keymap.set("n", "q", function()
    local ok, err = abort_merge(state.repo)
    if not ok then
      vim.notify("zxz.review: could not abort merge: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if vim.api.nvim_tabpage_is_valid(state.tab) then
      vim.api.nvim_set_current_tabpage(state.tab)
      vim.cmd("tabclose")
    end
  end, { buffer = buf, nowait = true, silent = true, desc = "Close zxz review" })
end

---@param state table
local function close_diff_windows(state)
  if not vim.api.nvim_tabpage_is_valid(state.tab) then
    return
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    if win ~= state.list_win and vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

---@param state table
---@param file zxz.review.File
local function open_file_diff(state, file)
  if not file then
    return
  end

  vim.api.nvim_set_current_tabpage(state.tab)
  close_diff_windows(state)
  vim.api.nvim_set_current_win(state.list_win)
  vim.cmd("rightbelow vertical new")
  local file_win = vim.api.nvim_get_current_win()
  local abs = state.repo .. "/" .. file.path
  vim.cmd("noswapfile edit " .. vim.fn.fnameescape(abs))
  map_close(vim.api.nvim_get_current_buf(), state)

  local diff_cmd = file.status:match("U") and "Gvdiffsplit!" or "Gvdiffsplit HEAD"
  local ok = pcall(vim.cmd, diff_cmd)
  if not ok then
    pcall(vim.cmd, "Gvdiffsplit")
  end

  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(state.tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    map_close(buf, state)
  end
  vim.api.nvim_set_current_win(file_win)
end

---@param state table
local function select_current_file(state)
  local row = vim.api.nvim_win_get_cursor(state.list_win)[1] - state.header_lines
  open_file_diff(state, state.files[row])
end

---@param repo string
---@param wt zxz.Worktree
---@return boolean ok
---@return string? err
local function open_review_tab(repo, wt)
  if vim.fn.exists(":Gvdiffsplit") ~= 2 then
    return false, "vim-fugitive is required for the review diff layout"
  end

  local files, err = changed_files(repo)
  if not files then
    return false, err
  end

  vim.cmd("tabnew")
  vim.cmd("lcd " .. vim.fn.fnameescape(repo))
  local state = {
    repo = repo,
    worktree = wt,
    files = files,
    header_lines = 4,
    tab = vim.api.nvim_get_current_tabpage(),
    list_win = vim.api.nvim_get_current_win(),
  }

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.list_win, buf)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "zxzreview"
  vim.bo[buf].modifiable = true

  local lines = {
    "0x0 Review",
    wt.branch .. " -> " .. repo,
    "q close  <CR> diff file",
    "",
  }
  for _, file in ipairs(files) do
    lines[#lines + 1] = ("%s  %s"):format(file.status, file.path)
  end
  if #files == 0 then
    lines[#lines + 1] = "No changed files"
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.wo[state.list_win].number = false
  vim.wo[state.list_win].relativenumber = false
  vim.wo[state.list_win].signcolumn = "no"
  vim.wo[state.list_win].wrap = false
  vim.api.nvim_win_set_width(state.list_win, 36)

  map_close(buf, state)
  vim.keymap.set("n", "<CR>", function()
    select_current_file(state)
  end, { buffer = buf, nowait = true, silent = true, desc = "Open zxz review diff" })
  vim.keymap.set("n", "o", function()
    select_current_file(state)
  end, { buffer = buf, nowait = true, silent = true, desc = "Open zxz review diff" })

  if #files > 0 then
    vim.api.nvim_win_set_cursor(state.list_win, { state.header_lines + 1, 0 })
    open_file_diff(state, files[1])
  end

  return true, nil
end

---Pick a worktree to review. Prompts via `vim.ui.select` over live agent
---worktrees. Calls `cb(wt)` with the choice, or nothing if the user cancelled
---or nothing exists to review.
---@param cb fun(wt: zxz.Worktree)
function M.pick(cb)
  local wts = Worktree.list()
  if #wts == 0 then
    vim.notify("zxz.review: no agent worktrees — :ZxzChat first", vim.log.levels.WARN)
    return
  end
  if #wts == 1 then
    return cb(wts[1])
  end
  vim.ui.select(wts, {
    prompt = "Review which agent worktree?",
    format_item = function(wt)
      return wt.branch .. "  -  " .. wt.path
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

---Stage the chosen agent worktree's branch into the user's main worktree and
---hand control to their git UI for review.
---@param opts? { worktree?: zxz.Worktree }
function M.open(opts)
  opts = opts or {}
  if opts.worktree then
    return M._open_for(opts.worktree)
  end
  M.pick(function(wt)
    M._open_for(wt)
  end)
end

---@param wt zxz.Worktree
function M._open_for(wt)
  local dirty, dirty_err = Worktree.is_dirty(wt)
  if dirty_err then
    vim.notify("zxz.review: " .. tostring(dirty_err), vim.log.levels.ERROR)
    return
  end
  if dirty then
    vim.notify(
      "zxz.review: agent worktree has uncommitted changes; wait for the turn commit before review",
      vim.log.levels.ERROR
    )
    return
  end

  local ok, err = stage_branch(wt)
  if not ok then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  ok, err = open_review_tab(wt.repo, wt)
  if not ok then
    vim.notify("zxz.review: agent changes staged, but review UI failed: " .. tostring(err), vim.log.levels.ERROR)
  end
end

---Convenience: kept so commands.lua (and any external callers) don't need
---to change.
function M.open_current()
  M.open()
end

return M
