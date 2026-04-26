local M = {}

local api = vim.api

function M.repo_root(bufnr)
  bufnr = bufnr or 0
  local name = api.nvim_buf_get_name(bufnr)
  local start = name ~= "" and vim.fs.dirname(name) or vim.uv.cwd()
  return vim.fs.root(start, { ".git" }) or vim.uv.cwd()
end

function M.relative_path(bufnr, root)
  bufnr = bufnr or 0
  local name = api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  root = root or M.repo_root(bufnr)
  return vim.fs.relpath(root, name) or name
end

local function split_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines > 1 and lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

M.split_lines = split_lines

function M.range_from_command(opts)
  local bufnr = api.nvim_get_current_buf()
  local start_line = opts and opts.line1 or vim.fn.line(".")
  local end_line = opts and opts.line2 or start_line

  if not opts or opts.range == 0 then
    start_line = vim.fn.line(".")
    end_line = start_line
  end

  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end

  local lines = api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local last = lines[#lines] or ""

  return {
    bufnr = bufnr,
    start_line = start_line,
    end_line = end_line,
    text = table.concat(lines, "\n"),
    range = {
      startLine = start_line,
      startColumn = 1,
      endLine = end_line,
      endColumn = #last + 1,
    },
  }
end

function M.replace_line_range(bufnr, start_line, end_line, replacement)
  api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, split_lines(replacement))
end

function M.append_lines(bufnr, lines)
  if type(lines) == "string" then
    lines = split_lines(lines)
  end
  api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)
end

function M.notify(message, level)
  vim.notify("0x0: " .. message, level or vim.log.levels.INFO)
end

function M.file_candidates(arglead)
  local root = M.repo_root(0)
  local prefix = (arglead or ""):gsub("^@", "")
  local found = vim.fn.globpath(root, prefix .. "*", false, true)
  if #found == 0 and not prefix:find("/", 1, true) then
    found = vim.fn.globpath(root, "**/" .. prefix .. "*", false, true)
  end
  local results = {}

  for _, path in ipairs(found) do
    if vim.fn.isdirectory(path) == 0 then
      local rel = vim.fs.relpath(root, path)
      if rel then
        table.insert(results, "@" .. rel)
      end
    end
  end

  table.sort(results)
  return results
end

return M
