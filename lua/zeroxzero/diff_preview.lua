local M = {}

local state = {
  bufnr = nil,
  winid = nil,
  worktree = nil,
}

local function ensure_buffer()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "[0x0 Chat Review]")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "diff"
  state.bufnr = bufnr
  return bufnr
end

local function current_file()
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
  for i = #lines, 1, -1 do
    local _, file = lines[i]:match("^diff %-%-git a/(.-) b/(.+)$")
    if file and file ~= "dev/null" then
      return file
    end
  end
  return nil
end

local function current_hunk_patch()
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local diff_start
  for i = row, 1, -1 do
    if lines[i]:match("^diff %-%-git ") then
      diff_start = i
      break
    end
  end
  if not diff_start then
    return nil
  end

  local header_end
  local hunk_start
  for i = diff_start + 1, #lines do
    if lines[i]:match("^diff %-%-git ") then
      break
    end
    if lines[i]:match("^@@ ") then
      if i <= row then
        hunk_start = i
      else
        break
      end
    elseif hunk_start == nil and lines[i]:match("^%+%+%+ ") then
      header_end = i
    end
  end
  if not hunk_start or not header_end then
    return nil
  end

  local hunk_end = #lines
  for i = hunk_start + 1, #lines do
    if lines[i]:match("^@@ ") or lines[i]:match("^diff %-%-git ") then
      hunk_end = i - 1
      break
    end
  end

  local patch = {}
  for i = diff_start, header_end do
    table.insert(patch, lines[i])
  end
  for i = hunk_start, hunk_end do
    table.insert(patch, lines[i])
  end
  table.insert(patch, "")

  return table.concat(patch, "\n")
end

local function render(lines)
  local bufnr = ensure_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  return bufnr
end

local function refresh(opts)
  opts = opts or {}
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return false
  end

  local lines = state.worktree:diff()
  if #lines == 0 then
    render({ "No changes in chat worktree." })
    return false
  end

  local previous_win = vim.api.nvim_get_current_win()
  local bufnr = render(lines)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    vim.cmd("botright split")
    state.winid = vim.api.nvim_get_current_win()
  end
  vim.api.nvim_win_set_buf(state.winid, bufnr)
  vim.api.nvim_win_set_height(state.winid, math.max(10, math.floor(vim.o.lines * 0.35)))
  if not opts.focus and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end
  return true
end

local function setup_keymaps(bufnr)
  local opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set("n", "a", function()
    M.accept_current_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0 accept current file" }))
  vim.keymap.set("n", "h", function()
    M.accept_current_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0 accept current hunk" }))
  vim.keymap.set("n", "A", function()
    M.accept_all()
  end, vim.tbl_extend("force", opts, { desc = "0x0 accept all chat changes" }))
  vim.keymap.set("n", "D", function()
    M.discard_all()
  end, vim.tbl_extend("force", opts, { desc = "0x0 discard all chat changes" }))
  vim.keymap.set("n", "R", function()
    M.refresh({ focus = true })
  end, vim.tbl_extend("force", opts, { desc = "0x0 refresh chat diff" }))
end

function M.show_worktree(worktree, opts)
  state.worktree = worktree or state.worktree
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return false
  end
  local bufnr = ensure_buffer()
  setup_keymaps(bufnr)
  return refresh(opts)
end

function M.refresh(opts)
  return refresh(opts)
end

function M.accept_current_hunk()
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return
  end
  local patch = current_hunk_patch()
  if not patch then
    vim.notify("0x0: place cursor inside a diff hunk", vim.log.levels.WARN)
    return
  end
  local ok, err = state.worktree:accept_patch(patch)
  if not ok then
    vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    return
  end
  ok, err = state.worktree:mark_patch_accepted(patch)
  if not ok then
    vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    return
  end
  vim.cmd.checktime()
  refresh({ focus = true })
end

function M.accept_current_file()
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return
  end
  local file = current_file()
  if not file then
    vim.notify("0x0: place cursor inside a file diff", vim.log.levels.WARN)
    return
  end
  local ok, err = state.worktree:accept_files({ file })
  if not ok then
    vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    return
  end
  state.worktree:mark_accepted({ file })
  vim.cmd.checktime()
  refresh({ focus = true })
end

function M.accept_all()
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return
  end
  local ok, err = state.worktree:accept_all()
  if not ok then
    vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    return
  end
  state.worktree:discard()
  state.worktree = nil
  vim.cmd.checktime()
  render({ "Accepted all chat changes." })
  return true
end

function M.discard_all()
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return
  end
  state.worktree:discard()
  state.worktree = nil
  render({ "Discarded all chat changes." })
  return true
end

return M
