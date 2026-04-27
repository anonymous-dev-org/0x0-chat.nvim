local M = {}

local cache = {
  cwd = nil,
  files = nil,
}

local function list_files()
  local cwd = vim.fn.getcwd()
  if cache.cwd == cwd and cache.files then
    return cache.files
  end

  local files = {}
  local output = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!**/.git/**" })
  if vim.v.shell_error == 0 then
    files = output
  else
    output = vim.fn.systemlist({ "find", ".", "-type", "f", "-not", "-path", "*/.git/*" })
    for _, path in ipairs(output) do
      table.insert(files, path:gsub("^%./", ""))
    end
  end

  table.sort(files)
  cache.cwd = cwd
  cache.files = files
  return files
end

local function current_mention_prefix()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local start_col, token = before:match(".*()@([^%s`]*)$")
  if not start_col then
    return nil, nil
  end
  return start_col, token
end

function M.completefunc(findstart, base)
  local start_col, token = current_mention_prefix()
  if findstart == 1 then
    if not start_col then
      return -2
    end
    return start_col - 1
  end

  base = token or base or ""
  local matches = {}
  for _, file in ipairs(list_files()) do
    if file:find(base, 1, true) or file:lower():find(base:lower(), 1, true) then
      table.insert(matches, {
        word = "@" .. file,
        abbr = "@" .. file,
        menu = "file",
        kind = "f",
      })
      if #matches >= 100 then
        break
      end
    end
  end
  return matches
end

function M.trigger()
  local start_col = current_mention_prefix()
  if not start_col then
    return
  end
  vim.bo.completefunc = "v:lua.require'zeroxzero.file_completion'.completefunc"
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-u>", true, false, true), "n", false)
end

return M
