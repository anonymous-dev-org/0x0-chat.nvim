local config = require("zeroxzero.config")
local api = require("zeroxzero.api")

local M = {}

---@type boolean
M.connected = false
---@type vim.SystemObj?
M._process = nil
---@type boolean true if we spawned the server (so we can stop it on exit)
M._owned = false

---Check if the server is reachable
---@param callback fun(ok: boolean)
local function health_check(callback)
  api.health(function(err)
    callback(not err)
  end)
end

---Start the server as a background process
---@param callback fun(err?: string)
local function start_server(callback)
  local cfg = config.current
  local cmd = cfg.cmd
  if vim.fn.executable(cmd) ~= 1 then
    -- Fall back to "0x0 serve"
    if vim.fn.executable("0x0") == 1 then
      cmd = "0x0"
    else
      callback(cmd .. " not found in PATH")
      return
    end
  end

  local args = { cmd }
  if cmd == "0x0" then
    table.insert(args, "serve")
  end
  table.insert(args, "--port")
  table.insert(args, tostring(cfg.port))

  local child_env = vim.fn.environ()
  child_env.ZEROXZERO_CALLER = "neovim"

  M._process = vim.system(args, {
    detach = true,
    text = true,
    env = child_env,
  }, function()
    vim.schedule(function()
      M._process = nil
      M._owned = false
      M.connected = false
    end)
  end)

  M._owned = true

  -- Poll for readiness
  local tries = 0
  local max_tries = 20
  local done = false
  local timer = vim.uv.new_timer()
  timer:start(250, 250, function()
    if done then
      return
    end
    tries = tries + 1
    vim.schedule(function()
      if done then
        return
      end
      health_check(function(ok)
        if done then
          return
        end
        if ok then
          done = true
          timer:stop()
          timer:close()
          M.connected = true
          callback(nil)
        elseif tries >= max_tries then
          done = true
          timer:stop()
          timer:close()
          callback("server failed to start after " .. max_tries .. " attempts")
        end
      end)
    end)
  end)
end

---Ensure the server is running and connected. Starts it if needed.
---@param callback fun(err?: string)
function M.ensure(callback)
  callback = callback or function() end

  if M.connected then
    callback(nil)
    return
  end

  -- Check if server is already running (e.g. started by another tool)
  health_check(function(ok)
    if ok then
      M.connected = true
      -- Start SSE listener
      local sse = require("zeroxzero.sse")
      sse.connect()
      callback(nil)
      return
    end

    if not config.current.auto_start then
      callback("server not running (auto_start disabled)")
      return
    end

    start_server(function(err)
      if err then
        callback(err)
        return
      end
      -- Start SSE listener
      local sse = require("zeroxzero.sse")
      sse.connect()
      callback(nil)
    end)
  end)
end

---Stop the server if we own it
function M.stop()
  local ok, sse = pcall(require, "zeroxzero.sse")
  if ok then
    sse.disconnect()
  end

  if M._process and M._owned then
    M._process:kill("sigterm")
    M._process = nil
  end

  M._owned = false
  M.connected = false
end

return M
