local transport_mod = require("zxz.core.acp_transport")
local config = require("zxz.core.config")
local log = require("zxz.core.log")

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
          ("acp[%s]: exited with code %d (see :ZxzChatLog for details)"):format(provider.name or provider.command, code),
          vim.log.levels.ERROR
        )
      end
    end,
    on_idle = function(ms)
      log.error(("acp[%s]: idle for %d ms — provider considered hung"):format(provider.name or provider.command, ms))
      self:_fail_all_pending({
        code = -32001,
        message = "provider hung (no I/O)",
      })
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
---@return integer id
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
        pcall(pending.cb, nil, {
          code = -32001,
          message = "request timed out",
          data = { method = method },
        })
      end)
    )
  end

  if self.transport and self.transport.set_idle_armed then
    self.transport:set_idle_armed(true)
  end

  local data = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    method = method,
    params = params or vim.empty_dict(),
  })
  self.transport:send(data)
  return id
end

---@param id integer|nil
function Client:forget_request(id)
  if not id then
    return
  end
  local entry = self.callbacks[id]
  if not entry then
    return
  end
  self.callbacks[id] = nil
  if entry.timer then
    pcall(function()
      entry.timer:stop()
      entry.timer:close()
    end)
  end
  if not next(self.callbacks) and self.transport and self.transport.set_idle_armed then
    self.transport:set_idle_armed(false)
  end
end

---@param method string
---@param params table|nil
function Client:notify(method, params)
  local data = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  })
  self.transport:send(data)
end

---@param id integer
---@param result table|nil
function Client:respond(id, result)
  local data = vim.json.encode({
    jsonrpc = "2.0",
    id = id,
    result = result or vim.empty_dict(),
  })
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
    clientInfo = { name = "0x0.nvim", version = "0.1.0" },
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
  return self:request("session/new", { cwd = cwd, mcpServers = {} }, callback)
end

---@param session_id string
---@param prompt_blocks table[]
---@param callback fun(result: table|nil, err: table|nil)
function Client:prompt(session_id, prompt_blocks, callback)
  return self:request("session/prompt", { sessionId = session_id, prompt = prompt_blocks }, callback)
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
  return self:request("session/set_model", { sessionId = session_id, modelId = model_id }, callback)
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
  return self:request(
    "session/set_config_option",
    { sessionId = session_id, configId = config_id, value = value },
    callback
  )
end

function Client:is_ready()
  return self.state == "ready"
end

function Client:stop()
  self.subscribers = {}
  self.transport:stop()
end

-- ---------------------------------------------------------------------------
-- Inline completion: lightweight wrapper around new()/start()/new_session()
-- for ghost-text completion. Differs from a chat session in two ways:
--   1. Permission requests are auto-approved (silent ghost text UX).
--   2. The client is a per-provider singleton, separate from chat clients.
-- ---------------------------------------------------------------------------

local _completion_clients = {}

local function _completion_key(provider)
  return tostring(provider.command) .. "\0" .. table.concat(provider.args or {}, "\1")
end

local function _flush_completion_waiters(entry, client, err)
  local waiters = entry.ready_waiters
  entry.ready_waiters = {}
  for _, fn in ipairs(waiters) do
    vim.schedule(function()
      fn(client, err)
    end)
  end
end

local function _get_completion_client(provider, on_ready)
  local key = _completion_key(provider)
  local entry = _completion_clients[key]
  if entry and entry.client and entry.client.state ~= "disconnected" and entry.client.state ~= "error" then
    if entry.authenticated and entry.client:is_ready() then
      vim.schedule(function()
        on_ready(entry.client, nil)
      end)
    else
      entry.ready_waiters[#entry.ready_waiters + 1] = on_ready
    end
    return entry.client
  end

  local client = M.new(provider, { host_fs = false })
  entry = {
    client = client,
    ready_waiters = { on_ready },
    authenticated = false,
  }
  _completion_clients[key] = entry

  client:start(function(c)
    if not c then
      _completion_clients[key] = nil
      _flush_completion_waiters(entry, nil, { message = "completion client unavailable" })
      return
    end
    if provider.auth_method and provider.auth_method ~= "" then
      c:request("authenticate", { methodId = provider.auth_method }, function(_, err)
        if err then
          log.error("acp[completion]: authenticate failed: " .. vim.inspect(err))
          _completion_clients[key] = nil
          _flush_completion_waiters(entry, nil, err)
          return
        end
        entry.authenticated = true
        _flush_completion_waiters(entry, c, nil)
      end)
    else
      entry.authenticated = true
      _flush_completion_waiters(entry, c, nil)
    end
  end)
  return client
end

local COMPLETION_SAFE_TOOL_KINDS = {
  read = true,
  search = true,
  list = true,
  inspect = true,
}

local function _choose_completion_permission(params)
  params = params or {}
  local tool_call = params and params.toolCall or {}
  local kind = tostring(tool_call.kind or params.kind or ""):lower()
  if not COMPLETION_SAFE_TOOL_KINDS[kind] then
    return nil
  end
  for _, kind in ipairs({ "allow_once", "allow_always" }) do
    for _, opt in ipairs(params.options or {}) do
      if opt.kind == kind then
        return opt.optionId
      end
    end
  end
end

local function _completion_prompt(request)
  return table.concat({
    "You are an inline code completion engine.",
    "Predict the short fragment the user is most likely to type next at the cursor,",
    "inferring intent from the surrounding code in <prefix> and <suffix>.",
    "",
    "Rules:",
    "- Return ONLY the raw text to insert at the cursor. No prose, no explanations.",
    "- No markdown fences, no language tags, no comments about the code.",
    "- Do not repeat any text from <prefix> or <suffix>.",
    "- Prefer a single line. Stop at the end of the current phrase, expression,",
    "  statement, or call — whichever ends first. Output the shortest useful completion.",
    "- If the cursor is mid-identifier, complete that identifier only.",
    "- If nothing useful can be added, return an empty string.",
    "",
    "File: " .. tostring(request.filepath or ""),
    "Language: " .. tostring(request.language or ""),
    "",
    "<prefix>",
    request.prefix or "",
    "</prefix>",
    "<suffix>",
    request.suffix or "",
    "</suffix>",
  }, "\n")
end

---Stream an inline completion. Completion sessions are read-only: they do not
---expose host fs and only select harmless read-style permission options.
---@param provider { command: string, args?: string[], auth_method?: string, name?: string }
---@param request { prefix: string, suffix: string, language?: string, filepath?: string, model?: string }
---@param on_chunk fun(text: string)
---@param on_done fun(err?: any)
---@return fun() abort
function M.stream_completion(provider, request, on_chunk, on_done)
  local active = true
  local done = false
  local session_id = nil
  local client_ref = nil
  local pending_requests = {}

  local function track_request(id)
    if id then
      pending_requests[id] = true
    end
    return id
  end

  local function untrack_request(id)
    pending_requests[id] = nil
  end

  local function forget_pending_requests()
    if client_ref then
      for id in pairs(pending_requests) do
        client_ref:forget_request(id)
      end
    end
    pending_requests = {}
  end

  local function finish(err)
    if done then
      return
    end
    done = true
    active = false
    if session_id and client_ref then
      client_ref:unsubscribe(session_id)
    end
    pending_requests = {}
    vim.schedule(function()
      on_done(err)
    end)
  end

  _get_completion_client(provider, function(client, ready_err)
    if not active then
      return
    end
    if ready_err or not client then
      finish(ready_err or { message = "completion client unavailable" })
      return
    end
    client_ref = client
    local new_session_request_id
    new_session_request_id = track_request(client:new_session(request.cwd or vim.fn.getcwd(), function(result, err)
      untrack_request(new_session_request_id)
      if not active then
        return
      end
      if err or not result or not result.sessionId then
        finish(err or "session/new returned no sessionId")
        return
      end
      session_id = result.sessionId

      client:subscribe(session_id, {
        on_update = function(update)
          if not active then
            return
          end
          if update.sessionUpdate ~= "agent_message_chunk" then
            return
          end
          local content = update.content
          if type(content) == "table" and content.type == "text" and content.text then
            vim.schedule(function()
              if active then
                on_chunk(content.text)
              end
            end)
          end
        end,
        on_request_permission = function(params, respond)
          respond(_choose_completion_permission(params) or "")
        end,
      })

      local function send_prompt()
        local prompt_request_id
        prompt_request_id = track_request(client:prompt(session_id, {
          { type = "text", text = _completion_prompt(request) },
        }, function(_, prompt_err)
          untrack_request(prompt_request_id)
          finish(prompt_err)
        end))
      end

      if request.model and request.model ~= "" then
        local model_request_id
        model_request_id = track_request(client:set_model(session_id, request.model, function(_, model_err)
          untrack_request(model_request_id)
          if model_err then
            finish(model_err)
            return
          end
          send_prompt()
        end))
      else
        send_prompt()
      end
    end))
  end)

  return function()
    if done or not active then
      return
    end
    done = true
    active = false
    if session_id and client_ref then
      client_ref:cancel(session_id)
      client_ref:unsubscribe(session_id)
    end
    forget_pending_requests()
  end
end

return M
