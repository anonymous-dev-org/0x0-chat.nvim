local config = require("zeroxzero.config")

local M = {}

---Percent-encode a string for use in URL query parameters
---@param str string
---@return string
local function url_encode(str)
  return str:gsub("([^%w%-%.%_%~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

---@type vim.SystemObj?
M._process = nil
---@type table<string, fun(properties: table)[]>
M._handlers = {}
---@type boolean
M._connected = false
---@type uv_timer_t?
M._reconnect_timer = nil
---@type number
M._reconnect_delay = 1000
---@type number
M._max_reconnect_delay = 30000
---@type uv_timer_t?
M._heartbeat_timer = nil
---@type number heartbeat timeout in ms
M._heartbeat_timeout = 65000

---Register a handler for an SSE event type
---@param event_type string
---@param handler fun(properties: table)
function M.on(event_type, handler)
  if not M._handlers[event_type] then
    M._handlers[event_type] = {}
  end
  table.insert(M._handlers[event_type], handler)
end

---Remove a specific handler for an SSE event type
---@param event_type string
---@param handler fun(properties: table)
function M.off(event_type, handler)
  local handlers = M._handlers[event_type]
  if not handlers then
    return
  end
  for i = #handlers, 1, -1 do
    if handlers[i] == handler then
      table.remove(handlers, i)
      return
    end
  end
end

---Dispatch an event to registered handlers
---@param event_type string
---@param properties table
local function dispatch(event_type, properties)
  local handlers = M._handlers[event_type]
  if handlers then
    for _, handler in ipairs(handlers) do
      handler(properties)
    end
  end

  local wildcard = M._handlers["*"]
  if wildcard then
    for _, handler in ipairs(wildcard) do
      handler({ type = event_type, properties = properties })
    end
  end
end

local function reset_heartbeat()
  if M._heartbeat_timer then
    M._heartbeat_timer:stop()
    M._heartbeat_timer:close()
    M._heartbeat_timer = nil
  end

  M._heartbeat_timer = vim.uv.new_timer()
  M._heartbeat_timer:start(M._heartbeat_timeout, 0, function()
    vim.schedule(function()
      M.disconnect()
      M.connect()
    end)
  end)
end

---@type string
local _buffer = ""

local function on_stdout(_, data)
  if not data then
    return
  end

  vim.schedule(function()
    _buffer = _buffer .. data

    while true do
      local newline_pos = _buffer:find("\n")
      if not newline_pos then
        break
      end

      local line = _buffer:sub(1, newline_pos - 1):gsub("\r$", "")
      _buffer = _buffer:sub(newline_pos + 1)

      if line:sub(1, 6) == "data: " then
        local json_str = line:sub(7)
        local ok, event = pcall(vim.json.decode, json_str)
        if ok and event then
          reset_heartbeat()
          dispatch(event.type, event.properties or {})
        end
      end
    end
  end)
end

function M.connect()
  if M._process then
    return
  end

  local cfg = config.current
  local cwd = vim.fn.getcwd()
  local url = string.format("http://%s:%d/event?directory=%s", cfg.hostname, cfg.port, url_encode(cwd))

  local cmd = { "curl", "-s", "-N" }

  if cfg.auth then
    table.insert(cmd, "-u")
    table.insert(cmd, cfg.auth.username .. ":" .. cfg.auth.password)
  end

  table.insert(cmd, url)

  _buffer = ""
  M._connected = false
  M._reconnect_delay = 1000

  M._process = vim.system(cmd, {
    text = true,
    stdout = on_stdout,
  }, function()
    vim.schedule(function()
      M._process = nil
      M._connected = false

      if M._heartbeat_timer then
        M._heartbeat_timer:stop()
        M._heartbeat_timer:close()
        M._heartbeat_timer = nil
      end

      -- Auto-reconnect with exponential backoff
      local server = require("zeroxzero.server")
      if server.connected then
        M._reconnect_timer = vim.uv.new_timer()
        M._reconnect_timer:start(M._reconnect_delay, 0, function()
          vim.schedule(function()
            if M._reconnect_timer then
              M._reconnect_timer:stop()
              M._reconnect_timer:close()
              M._reconnect_timer = nil
            end
            M._reconnect_delay = math.min(M._reconnect_delay * 2, M._max_reconnect_delay)
            M.connect()
          end)
        end)
      end
    end)
  end)

  M._register_builtin_handlers()
  reset_heartbeat()
end

function M.disconnect()
  if M._reconnect_timer then
    M._reconnect_timer:stop()
    M._reconnect_timer:close()
    M._reconnect_timer = nil
  end

  if M._heartbeat_timer then
    M._heartbeat_timer:stop()
    M._heartbeat_timer:close()
    M._heartbeat_timer = nil
  end

  if M._process then
    M._process:kill("sigterm")
    M._process = nil
  end

  M._connected = false
  _buffer = ""
end

local _builtin_registered = false

function M._register_builtin_handlers()
  if _builtin_registered then
    return
  end
  _builtin_registered = true

  M.on("server.connected", function()
    M._connected = true
    M._reconnect_delay = 1000
  end)

  -- Permission requests
  M.on("permission.asked", function(props)
    local ok, permission = pcall(require, "zeroxzero.permission")
    if ok then
      permission.handle(props)
    end
  end)

  -- Question requests
  M.on("question.asked", function(props)
    local ok, question = pcall(require, "zeroxzero.question")
    if ok then
      question.handle(props)
    end
  end)

  -- File edits — auto-reload buffers
  M.on("file.edited", function(props)
    if props.file then
      local bufnr = vim.fn.bufnr(props.file)
      if bufnr ~= -1 then
        vim.cmd("checktime " .. bufnr)
      end
    end
  end)

  M.on("file.watcher.updated", function(props)
    if props.file then
      local bufnr = vim.fn.bufnr(props.file)
      if bufnr ~= -1 then
        vim.cmd("checktime " .. bufnr)
      end
    end
  end)

  -- Toast notifications
  M.on("tui.toast.show", function(props)
    local ok, notification = pcall(require, "zeroxzero.ui.notification")
    if ok then
      notification.handle(props)
    end
  end)

end

return M
