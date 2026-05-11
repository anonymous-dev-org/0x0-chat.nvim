--- Buffer context gathering for code completion.
--- Extracts prefix (before cursor) and suffix (after cursor) from the current buffer.

local M = {}

--- Maximum lines to include in prefix/suffix.
local MAX_PREFIX_LINES = 1500
local MAX_SUFFIX_LINES = 500

--- Gather context from the current buffer at the cursor position.
---@return { prefix: string, suffix: string, language: string, filepath: string }
function M.gather()
  local bufnr = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] -- 1-indexed
  local col = cursor[2] -- 0-indexed

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local total = #lines

  -- Current line split at cursor position
  local current_line = lines[row] or ""
  local before_cursor = current_line:sub(1, col)
  local after_cursor = current_line:sub(col + 1)

  -- Build prefix: lines before current + current line up to cursor
  local prefix_start = math.max(1, row - MAX_PREFIX_LINES)
  local prefix_parts = {}
  for i = prefix_start, row - 1 do
    table.insert(prefix_parts, lines[i])
  end
  table.insert(prefix_parts, before_cursor)
  local prefix = table.concat(prefix_parts, "\n")

  -- Build suffix: rest of current line + lines after cursor
  local suffix_end = math.min(total, row + MAX_SUFFIX_LINES)
  local suffix_parts = { after_cursor }
  for i = row + 1, suffix_end do
    table.insert(suffix_parts, lines[i])
  end
  local suffix = table.concat(suffix_parts, "\n")

  return {
    prefix = prefix,
    suffix = suffix,
    language = vim.bo[bufnr].filetype,
    filepath = vim.api.nvim_buf_get_name(bufnr),
  }
end

return M
