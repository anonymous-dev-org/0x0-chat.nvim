---Human review workflow for an agent worktree.
---
---Review never mutates the main worktree until the user presses `m`. 0x0
---creates a review worktree/branch from the agent branch's base commit and
---uses it as a staging area for accepted hunks/files. The final merge brings
---only accepted review-branch commits into main.

local Chat = require("zxz.chat")
local Worktree = require("zxz.worktree")

local M = {}

---@class zxz.review.File
---@field status string
---@field path string

---@class zxz.review.State
---@field repo string
---@field worktree zxz.Worktree
---@field review_branch string
---@field review_path string
---@field files zxz.review.File[]
---@field selected integer
---@field tab integer?
---@field list_win integer?
---@field list_buf integer?
---@field diff_win integer?
---@field diff_buf integer?
---@field diff_lines string[]

---@param cmd string[]
---@return string? out
---@return string? err
local function run(cmd)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, out
  end
  return out, nil
end

---@param cmd string[]
---@return string[]
---@return string? err
local function run_lines(cmd)
  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    return {}, table.concat(lines, "\n")
  end
  return lines, nil
end

---@param repo string
---@param branch string
---@return boolean
local function branch_exists(repo, branch)
  run({ "git", "-C", repo, "rev-parse", "--verify", "--quiet", branch })
  return vim.v.shell_error == 0
end

---@param repo string
---@param branch string
---@return string?
local function branch_worktree_path(repo, branch)
  local out = run({ "git", "-C", repo, "worktree", "list", "--porcelain" }) or ""
  local current_path
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      current_path = nil
    else
      local key, value = line:match("^(%S+)%s+(.+)$")
      if key == "worktree" then
        current_path = value
      elseif key == "branch" and value:gsub("^refs/heads/", "") == branch then
        return current_path
      end
    end
  end
  return nil
end

---@param repo string
---@param branch string
---@param path string
---@param base_ref string
---@return boolean ok
---@return string? err
local function ensure_review_worktree(repo, branch, path, base_ref)
  local existing = branch_worktree_path(repo, branch)
  if existing then
    return true, nil
  end

  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  if branch_exists(repo, branch) then
    local _, err = run({ "git", "-C", repo, "worktree", "add", path, branch })
    return err == nil, err
  end

  local _, err = run({ "git", "-C", repo, "worktree", "add", "-b", branch, path, base_ref })
  return err == nil, err
end

---@param state zxz.review.State
---@param args string[]
---@return string
---@return string? err
local function diff(state, args)
  local cmd = {
    "git",
    "-C",
    state.repo,
    "diff",
    "--no-ext-diff",
    "--unified=3",
    state.review_branch .. ".." .. state.worktree.branch,
  }
  for _, arg in ipairs(args or {}) do
    cmd[#cmd + 1] = arg
  end
  local out, err = run(cmd)
  return out or "", err
end

---@param state zxz.review.State
---@return zxz.review.File[]? files
---@return string? err
local function proposal_files(state)
  local lines, err = run_lines({
    "git",
    "-C",
    state.repo,
    "diff",
    "--name-status",
    state.worktree.base_ref .. ".." .. state.worktree.branch,
  })
  if err then
    return nil, err
  end

  local files = {}
  for _, line in ipairs(lines) do
    local parts = vim.split(line, "\t", { plain = true })
    local status = parts[1] or ""
    local path = parts[#parts] or ""
    if path ~= "" then
      files[#files + 1] = { status = status, path = path }
    end
  end
  return files, nil
end

---@param state zxz.review.State
---@param rev string
---@param path string
---@return string
local function blob(state, rev, path)
  local out = vim.fn.system({ "git", "-C", state.repo, "show", rev .. ":" .. path })
  if vim.v.shell_error ~= 0 then
    return "__ZXZ_MISSING__"
  end
  return out
end

---@param state zxz.review.State
---@param file zxz.review.File
---@return string
local function file_mark(state, file)
  local base = blob(state, state.worktree.base_ref, file.path)
  local review = blob(state, state.review_branch, file.path)
  local agent = blob(state, state.worktree.branch, file.path)
  if review == agent then
    return "[x]"
  end
  if review == base then
    return "[ ]"
  end
  return "[~]"
end

---@param state zxz.review.State
---@return zxz.review.File?
local function selected_file(state)
  return state.files[state.selected]
end

---@param state zxz.review.State
local function render_list(state)
  if not state.list_buf or not vim.api.nvim_buf_is_valid(state.list_buf) then
    return
  end

  vim.bo[state.list_buf].modifiable = true
  local lines = {
    "0x0 Review",
    state.worktree.branch,
    "A all  a accept  m merge  f feedback  q close",
    "",
  }
  for i, file in ipairs(state.files) do
    local cursor = i == state.selected and ">" or " "
    lines[#lines + 1] = ("%s %s %s  %s"):format(cursor, file_mark(state, file), file.status, file.path)
  end
  if #state.files == 0 then
    lines[#lines + 1] = "No remaining changes"
  end
  vim.api.nvim_buf_set_lines(state.list_buf, 0, -1, false, lines)
  vim.bo[state.list_buf].modifiable = false
end

---@param state zxz.review.State
local function render_diff(state)
  if not state.diff_buf or not vim.api.nvim_buf_is_valid(state.diff_buf) then
    return
  end

  local file = selected_file(state)
  local lines = {}
  if file then
    local out = diff(state, { "--", file.path })
    state.diff_lines = vim.split(out, "\n", { plain = true })
    if #state.diff_lines == 1 and state.diff_lines[1] == "" then
      lines = { "No remaining changes for " .. file.path }
    else
      lines = state.diff_lines
    end
  else
    state.diff_lines = {}
    lines = { "No file selected" }
  end

  vim.bo[state.diff_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.diff_buf, 0, -1, false, lines)
  vim.bo[state.diff_buf].modifiable = false
  vim.bo[state.diff_buf].filetype = "diff"
end

---@param state zxz.review.State
local function refresh(state)
  local files, err = proposal_files(state)
  if not files then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  state.files = files
  if state.selected > #state.files then
    state.selected = math.max(#state.files, 1)
  end
  render_list(state)
  render_diff(state)
end

---@param state zxz.review.State
---@param patch string
---@return boolean ok
---@return string? err
local function apply_patch_to_review(state, patch)
  if patch == "" then
    return true, nil
  end
  local patch_file = vim.fn.tempname()
  local f = assert(io.open(patch_file, "wb"))
  f:write(patch)
  f:close()
  local _, err = run({ "git", "-C", state.review_path, "apply", "--index", patch_file })
  vim.fn.delete(patch_file)
  if err then
    return false, err
  end
  return true, nil
end

---@param state zxz.review.State
---@param message string
---@return boolean ok
---@return string? err
local function commit_review(state, message)
  local status = vim.fn.system({ "git", "-C", state.review_path, "status", "--porcelain" })
  if vim.v.shell_error ~= 0 then
    return false, status
  end
  if status == "" then
    return true, nil
  end
  local _, err = run({ "git", "-C", state.review_path, "commit", "-m", message })
  if err then
    return false, err
  end
  return true, nil
end

---@param state zxz.review.State
---@param message string
---@param patch string
local function accept_patch(state, message, patch)
  local ok, err = apply_patch_to_review(state, patch)
  if not ok then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  ok, err = commit_review(state, message)
  if not ok then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  refresh(state)
end

---@param state zxz.review.State
function M.accept_all(state)
  local patch, err = diff(state, {})
  if err then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  accept_patch(state, "zxz: accept all reviewed changes", patch)
end

---@param state zxz.review.State
---@param file? zxz.review.File
function M.accept_file(state, file)
  file = file or selected_file(state)
  if not file then
    return
  end
  local patch, err = diff(state, { "--", file.path })
  if err then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  accept_patch(state, "zxz: accept " .. file.path, patch)
end

---@param state zxz.review.State
---@return string?
local function current_hunk_patch(state)
  if not state.diff_win or not vim.api.nvim_win_is_valid(state.diff_win) then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(state.diff_win)[1]
  local lines = state.diff_lines or {}
  local hunk_start
  for i = math.min(row, #lines), 1, -1 do
    if lines[i]:match("^@@") then
      hunk_start = i
      break
    end
  end
  if not hunk_start then
    return nil
  end
  local hunk_end = #lines
  for i = hunk_start + 1, #lines do
    if lines[i]:match("^@@") or lines[i]:match("^diff %-%-git ") then
      hunk_end = i - 1
      break
    end
  end

  local first_hunk = hunk_start
  for i = 1, hunk_start do
    if lines[i]:match("^@@") then
      first_hunk = i
      break
    end
  end

  local header = {}
  for i = 1, first_hunk - 1 do
    header[#header + 1] = lines[i]
  end
  local patch = vim.list_extend(header, vim.list_slice(lines, hunk_start, hunk_end))
  return table.concat(patch, "\n") .. "\n"
end

---@param state zxz.review.State
function M.accept_hunk(state)
  local patch = current_hunk_patch(state)
  if not patch then
    vim.notify("zxz.review: cursor is not on a diff hunk", vim.log.levels.WARN)
    return
  end
  local file = selected_file(state)
  accept_patch(state, "zxz: accept hunk from " .. (file and file.path or "review"), patch)
end

---@param state zxz.review.State
function M.merge(state)
  local no_accepted = vim.fn.system({
    "git",
    "-C",
    state.repo,
    "diff",
    "--quiet",
    state.worktree.base_ref .. ".." .. state.review_branch,
  })
  if vim.v.shell_error == 0 then
    vim.notify("zxz.review: no accepted changes to merge", vim.log.levels.WARN)
    return
  end

  local out = vim.fn.system({
    "git",
    "-C",
    state.repo,
    "merge",
    "--no-ff",
    "-m",
    "zxz: merge accepted review changes",
    state.review_branch,
  })
  if vim.v.shell_error ~= 0 then
    pcall(vim.fn.system, { "git", "-C", state.repo, "merge", "--abort" })
    vim.notify("zxz.review: merge failed and was aborted: " .. tostring(out), vim.log.levels.ERROR)
    return
  end
  vim.notify("zxz.review: merged accepted changes", vim.log.levels.INFO)
  pcall(vim.fn.system, { "git", "-C", state.repo, "worktree", "remove", "--force", state.review_path })
  pcall(vim.fn.system, { "git", "-C", state.repo, "branch", "-D", state.review_branch })
end

---@param state zxz.review.State
---@return string
local function current_context_patch(state)
  if state.diff_win and vim.api.nvim_get_current_win() == state.diff_win then
    return current_hunk_patch(state) or table.concat(state.diff_lines or {}, "\n")
  end
  local file = selected_file(state)
  if not file then
    return ""
  end
  return diff(state, { "--", file.path })
end

---@param state zxz.review.State
---@param general? boolean
function M.feedback(state, general)
  vim.ui.input({ prompt = general and "Review feedback: " or "Feedback for selection: " }, function(input)
    if not input or input == "" then
      return
    end
    local file = selected_file(state)
    local lines = {
      "Review feedback for your branch.",
      "",
    }
    if file then
      lines[#lines + 1] = "File: " .. file.path
      lines[#lines + 1] = ""
    end
    lines[#lines + 1] = "Selected diff:"
    lines[#lines + 1] = "```diff"
    lines[#lines + 1] = general and "" or current_context_patch(state)
    lines[#lines + 1] = "```"
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Feedback:"
    lines[#lines + 1] = input
    local prompt = table.concat(lines, "\n")
    Chat.open_existing(state.worktree, { prompt = prompt })
  end)
end

---@param state zxz.review.State
local function close(state)
  if state.tab and vim.api.nvim_tabpage_is_valid(state.tab) then
    vim.api.nvim_set_current_tabpage(state.tab)
    vim.cmd("tabclose")
  end
end

---@param state zxz.review.State
local function map_keys(state)
  local function map(buf, lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, { buffer = buf, nowait = true, silent = true, desc = desc })
  end

  map(state.list_buf, "j", function()
    state.selected = math.min(state.selected + 1, #state.files)
    render_list(state)
    render_diff(state)
  end, "Next review file")
  map(state.list_buf, "k", function()
    state.selected = math.max(state.selected - 1, 1)
    render_list(state)
    render_diff(state)
  end, "Previous review file")
  map(state.list_buf, "<CR>", function()
    render_diff(state)
  end, "Open review diff")
  map(state.list_buf, "a", function()
    M.accept_file(state)
  end, "Accept review file")
  map(state.list_buf, "A", function()
    M.accept_all(state)
  end, "Accept all review changes")
  map(state.list_buf, "m", function()
    M.merge(state)
  end, "Merge accepted changes")
  map(state.list_buf, "f", function()
    M.feedback(state, false)
  end, "Send review feedback")
  map(state.list_buf, "F", function()
    M.feedback(state, true)
  end, "Send general review feedback")
  map(state.list_buf, "r", function()
    refresh(state)
  end, "Refresh review")
  map(state.list_buf, "q", function()
    close(state)
  end, "Close review")

  map(state.diff_buf, "a", function()
    M.accept_hunk(state)
  end, "Accept review hunk")
  map(state.diff_buf, "A", function()
    M.accept_all(state)
  end, "Accept all review changes")
  map(state.diff_buf, "m", function()
    M.merge(state)
  end, "Merge accepted changes")
  map(state.diff_buf, "f", function()
    M.feedback(state, false)
  end, "Send hunk feedback")
  map(state.diff_buf, "F", function()
    M.feedback(state, true)
  end, "Send general review feedback")
  map(state.diff_buf, "q", function()
    close(state)
  end, "Close review")
end

---@param wt zxz.Worktree
---@return zxz.review.State? state
---@return string? err
function M.create_state(wt)
  local dirty, dirty_err = Worktree.is_dirty(wt)
  if dirty_err then
    return nil, dirty_err
  end
  if dirty then
    return nil, "agent worktree has uncommitted changes; wait for the turn commit before review"
  end

  local branch = "zxz/review-" .. wt.id
  local path = wt.repo .. "/.git/zxz/review-" .. wt.id
  local ok, err = ensure_review_worktree(wt.repo, branch, path, wt.base_ref)
  if not ok then
    return nil, err
  end

  local state = {
    repo = wt.repo,
    worktree = wt,
    review_branch = branch,
    review_path = path,
    files = {},
    selected = 1,
    diff_lines = {},
  }
  state.files, err = proposal_files(state)
  if not state.files then
    return nil, err
  end
  return state, nil
end

---@param state zxz.review.State
function M.open_state(state)
  vim.cmd("tabnew")
  state.tab = vim.api.nvim_get_current_tabpage()
  state.list_win = vim.api.nvim_get_current_win()
  state.list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.list_win, state.list_buf)
  vim.bo[state.list_buf].buftype = "nofile"
  vim.bo[state.list_buf].bufhidden = "wipe"
  vim.bo[state.list_buf].filetype = "zxzreview"
  vim.bo[state.list_buf].modifiable = false
  vim.api.nvim_win_set_width(state.list_win, 42)

  vim.cmd("rightbelow vertical new")
  state.diff_win = vim.api.nvim_get_current_win()
  state.diff_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(state.diff_win, state.diff_buf)
  vim.bo[state.diff_buf].buftype = "nofile"
  vim.bo[state.diff_buf].bufhidden = "wipe"
  vim.bo[state.diff_buf].modifiable = false

  map_keys(state)
  refresh(state)
  vim.api.nvim_set_current_win(state.list_win)
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
---@return zxz.review.State?
function M._open_for(wt)
  local state, err = M.create_state(wt)
  if not state then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return nil
  end
  M.open_state(state)
  return state
end

function M.open_current()
  M.open()
end

return M
