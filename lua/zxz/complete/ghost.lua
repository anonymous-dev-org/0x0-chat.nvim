--- Ghost text rendering using Neovim extmarks.
--- Displays completion suggestions as gray inline virtual text.

local M = {}

local ns = vim.api.nvim_create_namespace("zxz_complete")

---@class zxz.complete.GhostState
---@field bufnr integer
---@field row integer 0-based
---@field col integer 0-based
---@field text string Full completion text
---@field extmark_ids integer[]

---@type zxz.complete.GhostState?
local _state = nil

--- Set up highlight groups.
local function setup_highlights()
  vim.api.nvim_set_hl(0, "ZxzCompleteGhost", { link = "Comment", default = true })
end

--- Show ghost text at the current cursor position.
---@param bufnr integer
---@param row integer 0-based
---@param col integer 0-based
---@param text string The completion text to display
function M.show(bufnr, row, col, text)
  if text == "" then
    return
  end

  setup_highlights()
  M.clear()

  local lines = vim.split(text, "\n", { plain = true })
  if #lines == 0 then
    return
  end

  _state = {
    bufnr = bufnr,
    row = row,
    col = col,
    text = text,
    extmark_ids = {},
  }

  -- First line: inline virtual text after cursor
  local first_line = lines[1]
  local virt_text = { { first_line, "ZxzCompleteGhost" } }

  -- Multi-line: remaining lines as virt_lines below
  local virt_lines = nil
  if #lines > 1 then
    virt_lines = {}
    for i = 2, #lines do
      table.insert(virt_lines, { { lines[i], "ZxzCompleteGhost" } })
    end
  end

  local extmark_opts = {
    virt_text = virt_text,
    virt_text_pos = "inline",
    priority = 1000,
  }
  if virt_lines then
    extmark_opts.virt_lines = virt_lines
  end

  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, extmark_opts)
  if ok then
    table.insert(_state.extmark_ids, id)
  end
end

--- Update the ghost text with new content (for streaming updates).
---@param text string
function M.update(text)
  if not _state then
    return
  end
  M.show(_state.bufnr, _state.row, _state.col, text)
end

--- Clear all ghost text.
function M.clear()
  if _state then
    vim.api.nvim_buf_clear_namespace(_state.bufnr, ns, 0, -1)
    _state = nil
  end
end

--- Accept the ghost text — insert it into the buffer.
---@return boolean true if text was accepted
function M.accept()
  if not _state then
    return false
  end

  local bufnr = _state.bufnr
  local row = _state.row
  local col = _state.col
  local text = _state.text

  M.clear()

  local lines = vim.split(text, "\n", { plain = true })
  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, lines)

  -- Move cursor to end of inserted text
  local new_row = row + #lines - 1
  local new_col
  if #lines == 1 then
    new_col = col + #lines[1]
  else
    new_col = #lines[#lines]
  end
  vim.api.nvim_win_set_cursor(0, { new_row + 1, new_col })

  return true
end

--- Accept only the first line of the ghost text.
---@return boolean true if text was accepted
function M.accept_line()
  if not _state then
    return false
  end

  local bufnr = _state.bufnr
  local row = _state.row
  local col = _state.col
  local text = _state.text

  local lines = vim.split(text, "\n", { plain = true })
  local first_line = lines[1] or ""

  M.clear()

  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { first_line })
  vim.api.nvim_win_set_cursor(0, { row + 1, col + #first_line })

  return true
end

--- Check if ghost text is currently visible.
---@return boolean
function M.is_visible()
  return _state ~= nil
end

--- Get the current ghost text.
---@return string?
function M.get_text()
  return _state and _state.text
end

return M
