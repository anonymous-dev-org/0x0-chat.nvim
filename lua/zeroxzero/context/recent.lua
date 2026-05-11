-- Recent-files ring buffer. Pushed onto via a BufWritePost autocmd
-- installed in init.lua. Most-recent first.

local M = {}

local MAX = 10
local ring = {}

local function path_for(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" then
    return nil
  end
  local bt = vim.bo[bufnr].buftype
  if bt ~= "" and bt ~= "acwrite" then
    return nil
  end
  local cwd = vim.fn.getcwd()
  if name:sub(1, #cwd + 1) == cwd .. "/" then
    return name:sub(#cwd + 2)
  end
  return vim.fn.fnamemodify(name, ":~:.")
end

---Called from BufWritePost.
---@param bufnr integer
function M.push(bufnr)
  local path = path_for(bufnr)
  if not path then
    return
  end
  for i, existing in ipairs(ring) do
    if existing == path then
      table.remove(ring, i)
      break
    end
  end
  table.insert(ring, 1, path)
  while #ring > MAX do
    table.remove(ring)
  end
end

---@param n integer|nil
---@return string[]
function M.list(n)
  if not n or n <= 0 or n > #ring then
    n = #ring
  end
  local out = {}
  for i = 1, n do
    out[i] = ring[i]
  end
  return out
end

function M.clear()
  ring = {}
end

return M
