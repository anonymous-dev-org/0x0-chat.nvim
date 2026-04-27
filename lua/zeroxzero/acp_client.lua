local transport_mod = require("zeroxzero.acp_transport")

local M = {}

local Client = {}
Client.__index = Client

---@param provider { command: string, args?: string[], env?: table<string, string>, name?: string }
function M.new(provider)
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
        vim.notify(
          ("acp[%s]: exited with code %d\n%s"):format(
            provider.name or provider.command,
            code,
            table.concat(stderr_lines, "\n")
          ),
          vim.log.levels.ERROR
        )
      end
    end,
  })

  return self
end

function Client:_on_state(state)
  self.state = state
  if state == "disconnected" or state == "error" then
    local err = { code = -32000, message = "transport " .. state }
    local pending = self.callbacks
    self.callbacks = {}
    for _, cb in pairs(pending) do
      vim.schedule(function()
        pcall(cb, nil, err)
      end)
    end
    local listeners = self.ready_listeners
    self.ready_listeners = {}
    for _, listener in ipairs(listeners) do
      vim.schedule(function()
        pcall(listener, nil, err)
      end)
    end
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
  self.callbacks[id] = callback
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
    local cb = self.callbacks[message.id]
    if cb then
      self.callbacks[message.id] = nil
      vim.schedule(function()
        cb(message.result, message.error)
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
    sub.on_request_permission(params, function(option_id)
      if not option_id or option_id == "" then
        self:respond(message_id, { outcome = { outcome = "cancelled" } })
        return
      end
      self:respond(message_id, { outcome = { outcome = "selected", optionId = option_id } })
    end)
  end)

  self.transport:start()
  self.state = "initializing"

  self:request("initialize", {
    protocolVersion = self.protocol_version,
    clientInfo = { name = "0x0-chat-nvim", version = "0.1.0" },
    clientCapabilities = {
      fs = { readTextFile = false, writeTextFile = false },
      terminal = false,
    },
  }, function(result, err)
    if err or not result then
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
