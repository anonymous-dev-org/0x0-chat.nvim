-- Shared test helpers: set up scratch git repos in vim.fn.tempname() roots.

local M = {}

local function system(cmd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, "command failed: " .. vim.inspect(cmd) .. "\n" .. out)
  return out
end

---@param files? table<string, string> initial files (relative path -> content)
---@return string root
function M.make_repo(files)
  local root = vim.fn.tempname()
  vim.fn.mkdir(root, "p")
  system({ "git", "-C", root, "init", "-q", "-b", "main" })
  system({ "git", "-C", root, "config", "user.email", "test@example.com" })
  system({ "git", "-C", root, "config", "user.name", "Test" })
  system({ "git", "-C", root, "config", "commit.gpgsign", "false" })
  for path, content in pairs(files or {}) do
    M.write_file(root .. "/" .. path, content)
  end
  if files and next(files) then
    system({ "git", "-C", root, "add", "-A" })
    system({ "git", "-C", root, "commit", "-q", "-m", "initial" })
  else
    system({ "git", "-C", root, "commit", "--allow-empty", "-q", "-m", "initial" })
  end
  return root
end

---@param path string absolute
---@param content string
function M.write_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
end

---@param path string absolute
---@return string|nil
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

function M.cleanup(root)
  if root and root ~= "" then
    vim.fn.delete(root, "rf")
  end
end

return M
