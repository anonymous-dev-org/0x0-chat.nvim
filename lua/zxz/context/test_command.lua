-- Test-command detection and execution for the @test-output mention.
-- Per-project; auto-detects when config.test_command is nil.

local M = {}

---@param root string
---@return string|nil
local function detect_test_command(root)
  -- Order of probes, from most to least specific.
  local pkg_json = root .. "/package.json"
  if vim.fn.filereadable(pkg_json) == 1 then
    local content = vim.fn.readfile(pkg_json)
    local joined = table.concat(content, "\n")
    if joined:find('"test"%s*:%s*"') then
      return "bun run test"
    end
  end
  if vim.fn.filereadable(root .. "/Makefile") == 1 then
    local mk = vim.fn.readfile(root .. "/Makefile")
    for _, line in ipairs(mk) do
      if line:match("^test%s*:") then
        return "make test"
      end
    end
  end
  if vim.fn.filereadable(root .. "/Cargo.toml") == 1 then
    return "cargo test --quiet"
  end
  if vim.fn.filereadable(root .. "/pyproject.toml") == 1 or vim.fn.filereadable(root .. "/setup.py") == 1 then
    if vim.fn.executable("pytest") == 1 then
      return "pytest -q"
    end
  end
  if vim.fn.filereadable(root .. "/go.mod") == 1 then
    return "go test ./..."
  end
  return nil
end

---@param root string
---@return string|nil
function M.resolve(root)
  local config = require("zxz.core.config")
  if config.current.test_command and config.current.test_command ~= "" then
    return config.current.test_command
  end
  return detect_test_command(root)
end

---@param root string
---@param timeout_ms integer|nil
---@return string command, integer|nil exit_code, string|nil stdout, string|nil stderr
function M.run(root, timeout_ms)
  local cmd = M.resolve(root)
  if not cmd then
    return "", nil, nil, "no test command detected"
  end
  local config = require("zxz.core.config")
  local timeout = timeout_ms or config.current.test_command_timeout_ms or 5000 -- T2.1: 5s default
  local handle = vim.system({ "sh", "-c", cmd }, {
    cwd = root,
    text = true,
  })
  local ok, result = pcall(handle.wait, handle, timeout)
  if not ok or not result then
    pcall(handle.kill, handle, 15) -- T2.7: SIGTERM on timeout
    return cmd, nil, nil, ("test command timed out after %dms"):format(timeout)
  end
  -- vim.system's :wait returns code=nil when the timeout fires; kill explicitly.
  if result.code == nil and result.signal == nil then
    pcall(handle.kill, handle, 15)
    return cmd, nil, result.stdout, ("test command timed out after %dms"):format(timeout)
  end
  return cmd, result.code, result.stdout, result.stderr
end

return M
