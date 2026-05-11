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

--- Strip control characters and unwrap markdown code fences. The provider
--- occasionally streams ASCII control bytes (which render as `^N` etc. in
--- inline virtual text) or wraps the completion in ``` fences.
---@param text string
---@return string
local function sanitize(text)
  text = text:gsub("^%s*```[%w_-]*\n?", ""):gsub("\n?```%s*$", "")
  text = text:gsub("[%z\1-\8\11\12\14-\31\127]", "")
  return text
end

--- Show ghost text at the current cursor position.
---@param bufnr integer
---@param row integer 0-based
---@param col integer 0-based
---@param text string The completion text to display
function M.show(bufnr, row, col, text)
  text = sanitize(text)
  if text == "" then
    return
  end

  setup_highlights()
  M.clear()

  local first_line = vim.split(text, "\n", { plain = true })[1] or ""
  if first_line == "" then
    return
  end

  _state = {
    bufnr = bufnr,
    row = row,
    col = col,
    text = first_line,
    extmark_ids = {},
  }

  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, col, {
    virt_text = { { first_line, "ZxzCompleteGhost" } },
    virt_text_pos = "inline",
    priority = 1000,
  })
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

  vim.api.nvim_buf_set_text(bufnr, row, col, row, col, { text })
  vim.api.nvim_win_set_cursor(0, { row + 1, col + #text })

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
