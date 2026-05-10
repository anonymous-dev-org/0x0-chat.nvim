local transport_mod = require("zeroxzero.acp_transport")
local config = require("zeroxzero.config")
local log = require("zeroxzero.log")

local M = {}

-- Some requests are inherently long-running (a streaming model turn) and
-- should not be timed out by the per-request watchdog.
local NON_TIMED_METHODS = {
  ["session/prompt"] = true,
}

local Client = {}
Client.__index = Client

---@param provider { command: string, args?: string[], env?: table<string, string>, name?: string }
---@param opts? { host_fs?: boolean }
function M.new(provider, opts)
  opts = opts or {}
  local self = setmetatable({
    provider = provider,
    state = "disconnected",
    id_counter = 0,
    callbacks = {},
    notification_handlers = {},
    ready_listeners = {},
    subscribers = {},
    agent_info = nil,
    agent_capabilities = nil,
    protocol_version = 1,
    host_fs = opts.host_fs and true or false,
  }, Client)

  self.transport = transport_mod.create(provider, {
    on_state = function(state)
      self:_on_state(state)
    end,
    on_message = function(msg)
      self:_on_message(msg)
    end,
    on_exit = function(code, stderr_lines)
      if code ~= 0 then
        local stderr_blob = table.concat(stderr_lines, "\n")
        log.error(("acp[%s]: exited with code %d\n%s"):format(provider.name or provider.command, code, stderr_blob))
        vim.notify(
          ("acp[%s]: exited with code %d (see :ZeroChatLog for details)"):format(
            provider.name or provider.command,
            code
          ),
          vim.log.levels.ERROR
        )
      end
    end,
    on_idle = function(ms)
      log.error(("acp[%s]: idle for %d ms — provider considered hung"):format(provider.name or provider.command, ms))
      self:_fail_all_pending({ code = -32001, message = "provider hung (no I/O)" })
    end,
  }, { idle_kill_ms = config.current.idle_kill_ms or 0 })

  return self
end

function Client:_on_state(state)
  self.state = state
  if state == "disconnected" or state == "error" then
    self:_fail_all_pending({ code = -32000, message = "transport " .. state })
    local listeners = self.ready_listeners
    self.ready_listeners = {}
    for _, listener in ipairs(listeners) do
      vim.schedule(function()
        pcall(listener, nil, { code = -32000, message = "transport " .. state })
      end)
    end
  end
end

---Reject every pending callback with err. Used by transport disconnects and
---the idle watchdog so callers aren't left hanging.
---@param err table
function Client:_fail_all_pending(err)
  local pending = self.callbacks
  self.callbacks = {}
  for id, entry in pairs(pending) do
    if entry.timer then
      pcall(function()
        entry.timer:stop()
        entry.timer:close()
      end)
    end
    vim.schedule(function()
      pcall(entry.cb, nil, err)
    end)
  end
  if self.transport and self.transport.set_idle_armed then
    self.transport:set_idle_armed(false)
  end
end

function Client:_next_id()
  self.id_counter = self.id_counter + 1
  return self.id_counter
end

---@param method string
---@param params table|nil
---@param callback fun(result: table|nil, err: table|nil)
function Client:request(method, params, callback)
  local id = self:_next_id()
  local entry = { cb = callback, method = method }
  self.callbacks[id] = entry

  local timeout = config.current.request_timeout_ms or 0
  if timeout > 0 and not NON_TIMED_METHODS[method] then
    local timer = vim.uv.new_timer()
    entry.timer = timer
    timer:start(
      timeout,
      0,
      vim.schedule_wrap(function()
        local pending = self.callbacks[id]
        if not pending then
          return
        end
        self.callbacks[id] = nil
        if pending.timer then
          pcall(function()
            pending.timer:stop()
            pending.timer:close()
          end)
        end
        log.warn(("acp: request '%s' (id=%d) timed out after %d ms"):format(method, id, timeout))
        pcall(pending.cb, nil, { code = -32001, message = "request timed out", data = { method = method } })
      end)
    )
  end

  if self.transport and self.transport.set_idle_armed then
    self.transport:set_idle_armed(true)
  end

  local data = vim.json.encode({ jsonrpc = "2.0", id = id, method = method, params = params or vim.empty_dict() })
  self.transport:send(data)
end

---@param method string
---@param params table|nil
function Client:notify(method, params)
  local data = vim.json.encode({ jsonrpc = "2.0", method = method, params = params or vim.empty_dict() })
  self.transport:send(data)
end

---@param id integer
---@param result table|nil
function Client:respond(id, result)
  local data = vim.json.encode({ jsonrpc = "2.0", id = id, result = result or vim.empty_dict() })
  self.transport:send(data)
end

---@param id integer
---@param code integer
---@param message string
---@param data? table
function Client:respond_error(id, code, message, data)
  local err = { code = code, message = message }
  if data then
    err.data = data
  end
  local payload = vim.json.encode({ jsonrpc = "2.0", id = id, error = err })
  self.transport:send(payload)
end

---@param method string
---@param handler fun(params: table, message_id: integer|nil)
function Client:on_notification(method, handler)
  self.notification_handlers[method] = handler
end

function Client:_on_message(message)
  if message.method and message.result == nil and message.error == nil then
    local handler = self.notification_handlers[message.method]
    if handler then
      vim.schedule(function()
        handler(message.params or {}, message.id)
      end)
    else
      vim.schedule(function()
        vim.notify("acp: unhandled notification " .. message.method, vim.log.levels.DEBUG)
      end)
    end
    return
  end

  if message.id ~= nil and (message.result ~= nil or message.error ~= nil) then
    local entry = self.callbacks[message.id]
    if entry then
      self.callbacks[message.id] = nil
      if entry.timer then
        pcall(function()
          entry.timer:stop()
          entry.timer:close()
        end)
      end
      if not next(self.callbacks) and self.transport and self.transport.set_idle_armed then
        self.transport:set_idle_armed(false)
      end
      vim.schedule(function()
        entry.cb(message.result, message.error)
      end)
    end
    return
  end

  vim.schedule(function()
    vim.notify("acp: unknown message shape: " .. vim.inspect(message), vim.log.levels.WARN)
  end)
end

---@param on_ready fun(self: table)|nil
function Client:start(on_ready)
  if on_ready then
    self.ready_listeners[#self.ready_listeners + 1] = on_ready
  end

  self:on_notification("session/update", function(params)
    local sub = self.subscribers[params.sessionId]
    if sub and sub.on_update then
      sub.on_update(params.update or {})
    end
  end)

  self:on_notification("session/request_permission", function(params, message_id)
    local sub = self.subscribers[params.sessionId]
    if not sub or not sub.on_request_permission then
      self:respond(message_id, { outcome = { outcome = "cancelled" } })
      return
    end
    if self.transport and self.transport.set_idle_armed then
      self.transport:set_idle_armed(false)
    end
    sub.on_request_permission(params, function(option_id)
      if not option_id or option_id == "" then
        self:respond(message_id, { outcome = { outcome = "cancelled" } })
        if next(self.callbacks) and self.transport and self.transport.set_idle_armed then
          self.transport:set_idle_armed(true)
        end
        return
      end
      self:respond(message_id, { outcome = { outcome = "selected", optionId = option_id } })
      if next(self.callbacks) and self.transport and self.transport.set_idle_armed then
        self.transport:set_idle_armed(true)
      end
    end)
  end)

  self:on_notification("fs/read_text_file", function(params, message_id)
    if message_id == nil then
      return
    end
    local sub = self.subscribers[params.sessionId]
    if not sub or not sub.on_fs_read_text_file then
      self:respond_error(message_id, -32601, "fs/read_text_file not handled")
      return
    end
    sub.on_fs_read_text_file(params, function(content, err)
      if err then
        local code = err.code or -32000
        self:respond_error(message_id, code, err.message or tostring(err), err.data)
        return
      end
      self:respond(message_id, { content = content or "" })
    end)
  end)

  self:on_notification("fs/write_text_file", function(params, message_id)
    if message_id == nil then
      return
    end
    local sub = self.subscribers[params.sessionId]
    if not sub or not sub.on_fs_write_text_file then
      self:respond_error(message_id, -32601, "fs/write_text_file not handled")
      return
    end
    sub.on_fs_write_text_file(params, function(err)
      if err then
        local code = err.code or -32000
        self:respond_error(message_id, code, err.message or tostring(err), err.data)
        return
      end
      self:respond(message_id, vim.empty_dict())
    end)
  end)

  self.transport:start()
  self.state = "initializing"
  self:_initialize_with_retry(0)
end

local INITIALIZE_BACKOFF_MS = { 250, 500, 1000 }

function Client:_initialize_with_retry(attempt)
  local max = config.current.initialize_retries or 3
  self:request("initialize", {
    protocolVersion = self.protocol_version,
    clientInfo = { name = "0x0-chat-nvim", version = "0.1.0" },
    clientCapabilities = {
      fs = {
        readTextFile = self.host_fs,
        writeTextFile = self.host_fs,
      },
      terminal = false,
    },
  }, function(result, err)
    if err or not result then
      if attempt + 1 < max then
        local delay = INITIALIZE_BACKOFF_MS[attempt + 1] or 1000
        log.warn(
          ("acp: initialize failed (attempt %d/%d), retrying in %d ms: %s"):format(
            attempt + 1,
            max,
            delay,
            vim.inspect(err)
          )
        )
        vim.defer_fn(function()
          if self.state ~= "initializing" then
            return
          end
          self:_initialize_with_retry(attempt + 1)
        end, delay)
        return
      end
      log.error("acp: initialize failed after retries: " .. vim.inspect(err))
      vim.notify("acp: initialize failed: " .. vim.inspect(err), vim.log.levels.ERROR)
      self:_on_state("error")
      return
    end
    self.protocol_version = result.protocolVersion or self.protocol_version
    self.agent_info = result.agentInfo
    self.agent_capabilities = result.agentCapabilities
    self.state = "ready"
    local listeners = self.ready_listeners
    self.ready_listeners = {}
    for _, listener in ipairs(listeners) do
      pcall(listener, self)
    end
  end)
end

---@param session_id string
---@param handlers { on_update: fun(update: table), on_request_permission?: fun(request: table, respond: fun(option_id: string)) }
function Client:subscribe(session_id, handlers)
  self.subscribers[session_id] = handlers
end

---@param session_id string
function Client:unsubscribe(session_id)
  self.subscribers[session_id] = nil
end

---@param cwd string
---@param callback fun(result: table|nil, err: table|nil)
function Client:new_session(cwd, callback)
  self:request("session/new", { cwd = cwd, mcpServers = {} }, callback)
end

---@param session_id string
---@param prompt_blocks table[]
---@param callback fun(result: table|nil, err: table|nil)
function Client:prompt(session_id, prompt_blocks, callback)
  self:request("session/prompt", { sessionId = session_id, prompt = prompt_blocks }, callback)
end

---@param session_id string
function Client:cancel(session_id)
  if not session_id then
    return
  end
  self:notify("session/cancel", { sessionId = session_id })
end

---@param session_id string
---@param model_id string|nil
---@param callback fun(result: table|nil, err: table|nil)
function Client:set_model(session_id, model_id, callback)
  if not session_id or not model_id or model_id == "" then
    callback(nil, nil)
    return
  end
  self:request("session/set_model", { sessionId = session_id, modelId = model_id }, callback)
end

---@param session_id string
---@param config_id string|nil
---@param value string|nil
---@param callback fun(result: table|nil, err: table|nil)
function Client:set_config_option(session_id, config_id, value, callback)
  if not session_id or not config_id or config_id == "" or not value or value == "" then
    callback(nil, nil)
    return
  end
  self:request("session/set_config_option", { sessionId = session_id, configId = config_id, value = value }, callback)
end

function Client:is_ready()
  return self.state == "ready"
end

function Client:stop()
  self.subscribers = {}
  self.transport:stop()
end

return M
