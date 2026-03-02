local M = {}

---Get relative path of a buffer from the working directory
---@param bufnr? integer
---@return string?
local function relative_path(bufnr)
  bufnr = bufnr or 0
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then
    return nil
  end
  local cwd = vim.fn.getcwd()
  if path:sub(1, #cwd) == cwd then
    return path:sub(#cwd + 2) -- +2 to skip the trailing /
  end
  return vim.fn.fnamemodify(path, ":~:.")
end

---Build a file reference string like @path.ts or @path.ts#L5-L10
---@param bufnr? integer
---@param opts? {include_selection?: boolean}
---@return string?
function M.file_ref(bufnr, opts)
  bufnr = bufnr or 0
  opts = opts or {}
  local rel = relative_path(bufnr)
  if not rel then
    return nil
  end

  local ref = "@" .. rel

  -- Check for visual selection
  local start_line, end_line = M.selection_range(bufnr, opts.include_selection)
  if start_line and end_line then
    if start_line == end_line then
      ref = ref .. "#L" .. start_line
    else
      ref = ref .. "#L" .. start_line .. "-" .. end_line
    end
  end

  return ref
end

---Get visual selection line range (1-based)
---@param bufnr? integer
---@param include_marks? boolean when true, check '</'> marks even outside visual mode
---@return integer? start_line
---@return integer? end_line
function M.selection_range(bufnr, include_marks)
  bufnr = bufnr or 0
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local start_pos = vim.fn.getpos("v")
    local end_pos = vim.fn.getpos(".")
    local start_line = start_pos[2]
    local end_line = end_pos[2]
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    return start_line, end_line
  end

  -- Only check marks from last visual selection when explicitly requested
  if include_marks then
    local start_pos = vim.api.nvim_buf_get_mark(bufnr, "<")
    local end_pos = vim.api.nvim_buf_get_mark(bufnr, ">")
    if start_pos[1] > 0 and end_pos[1] > 0 then
      return start_pos[1], end_pos[1]
    end
  end

  return nil, nil
end

---Get visual selection text
---@param bufnr? integer
---@return string?
function M.selection_text(bufnr)
  bufnr = bufnr or 0
  local start_line, end_line = M.selection_range(bufnr, true)
  if not start_line or not end_line then
    return nil
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return table.concat(lines, "\n")
end

---Get diagnostics for a buffer formatted as text
---@param bufnr? integer
---@return string
function M.diagnostics(bufnr)
  bufnr = bufnr or 0
  local diags = vim.diagnostic.get(bufnr)
  if #diags == 0 then
    return ""
  end

  local rel = relative_path(bufnr) or vim.api.nvim_buf_get_name(bufnr)
  local severity_map = { "ERROR", "WARN", "INFO", "HINT" }
  local lines = {}
  for _, d in ipairs(diags) do
    local sev = severity_map[d.severity] or "UNKNOWN"
    table.insert(lines, string.format(
      "%s:%d: [%s] %s",
      rel,
      (d.lnum or 0) + 1,
      sev,
      d.message
    ))
  end
  return table.concat(lines, "\n")
end

return M
