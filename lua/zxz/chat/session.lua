-- ACP client + session lifecycle: bring up the provider subprocess, open a
-- session, mirror config options (mode/model), and tear them down.

local config = require("zxz.core.config")
local acp_client = require("zxz.core.acp_client")

local M = {}

function M:_set_config_options(options)
  self.config_options = {}
  if type(options) ~= "table" then
    return
  end
  for _, option in ipairs(options) do
    local category = type(option.category) == "string" and option.category or ""
    if category ~= "" then
      self.config_options[category] = option
      if category == "mode" then
        self.mode = option.currentValue or self.mode
      elseif category == "model" then
        self.model = option.currentValue or self.model
      else
        self.config_values = self.config_values or {}
        self.config_values[category] = option.currentValue or self.config_values[category]
      end
    end
  end
end

local function option_has_value(option, value)
  if not option or not option.options then
    return false
  end
  for _, item in ipairs(option.options) do
    if item.value == value then
      return true
    end
  end
  return false
end

function M:_apply_config_option(category, value, callback)
  callback = callback or function() end
  if value == nil or value == "" then
    self.config_values = self.config_values or {}
    self.config_values[category] = nil
    if category == "mode" then
      self.mode = nil
    elseif category == "model" then
      self.model = nil
    end
    callback(true)
    return
  end
  if not self.client or not self.session_id then
    callback(false)
    return
  end
  local session_id = self.session_id
  local option = self.config_options[category]
  if option and option_has_value(option, value) then
    self.client:set_config_option(session_id, category, value, function(result, err)
      if self.session_id ~= session_id then
        return
      end
      if err then
        vim.notify(("acp: set %s failed: %s"):format(category, err.message or vim.inspect(err)), vim.log.levels.ERROR)
        callback(false)
        return
      end
      if result and result.configOptions then
        self:_set_config_options(result.configOptions)
      end
      if category == "mode" then
        self.mode = value
      elseif category == "model" then
        self.model = value
      else
        self.config_values = self.config_values or {}
        self.config_values[category] = value
      end
      if option then
        option.currentValue = value
      end
      callback(true)
    end)
    return
  end
  if category == "model" and not self.config_options.model then
    self.client:set_model(session_id, value, function(result, err)
      if self.session_id ~= session_id then
        return
      end
      if err then
        vim.notify("acp: set model failed: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
        callback(false)
        return
      end
      if result and result.configOptions then
        self:_set_config_options(result.configOptions)
      end
      self.model = value
      callback(true)
    end)
    return
  end
  vim.notify("acp: " .. category .. " is not available for this provider/session", vim.log.levels.WARN)
  callback(false)
end

function M:_apply_initial_session_config(desired, done)
  local pending = {}
  if desired.mode then
    pending[#pending + 1] = { "mode", desired.mode }
  end
  if desired.model then
    pending[#pending + 1] = { "model", desired.model }
  end
  for category, value in pairs(desired.config_values or {}) do
    if value ~= nil and category ~= "mode" and category ~= "model" then
      pending[#pending + 1] = { category, value }
    end
  end

  local i = 1
  local function next_option()
    local item = pending[i]
    i = i + 1
    if not item then
      done()
      return
    end
    self:_apply_config_option(item[1], item[2], next_option)
  end
  next_option()
end

function M:_ensure_client(on_ready)
  local provider_name = self.provider_name or config.current.provider
  if self.client and self.provider_name == provider_name and self.client:is_ready() then
    on_ready(self.client, nil)
    return
  end
  local provider, perr = config.resolve_provider(provider_name)
  if not provider then
    vim.notify(perr, vim.log.levels.ERROR)
    on_ready(nil, { message = perr })
    return
  end
  if self.client then
    self.client:stop()
  end
  self.provider_name = provider_name
  self.client = acp_client.new(provider, { host_fs = true })
  self.client:start(function(c, err)
    on_ready(c, err)
  end)
end

function M:_ensure_session(on_session)
  local function start_session(cwd)
    self:_ensure_client(function(client, cerr)
      if cerr or not client then
        on_session(nil, nil, cerr or { message = "client unavailable" })
        return
      end
      if self.session_id then
        on_session(client, self.session_id, nil)
        return
      end
      local desired = { mode = self.mode, model = self.model, config_values = vim.deepcopy(self.config_values or {}) }
      client:new_session(cwd, function(result, err)
        if self.client ~= client then
          on_session(nil, nil, { message = "client replaced" })
          return
        end
        if err or not result or not result.sessionId then
          vim.notify("acp: session/new failed: " .. vim.inspect(err), vim.log.levels.ERROR)
          on_session(nil, nil, err or { message = "session/new failed" })
          return
        end
        self.session_id = result.sessionId
        self:_set_config_options(result.configOptions)
        client:subscribe(result.sessionId, {
          on_update = function(update)
            self:_handle_update(update)
          end,
          on_request_permission = function(request, respond)
            self:_handle_permission(request, respond)
          end,
          on_fs_read_text_file = function(params, respond)
            self:_handle_fs_read(params, respond)
          end,
          on_fs_write_text_file = function(params, respond)
            self:_handle_fs_write(params, respond)
          end,
        })
        self:_apply_initial_session_config(desired, function()
          on_session(client, result.sessionId, nil)
        end)
      end)
    end)
  end

  self:_ensure_checkpoint(function(checkpoint, cerr)
    if cerr or not checkpoint then
      on_session(nil, nil, cerr or { message = "checkpoint unavailable" })
      return
    end
    start_session(checkpoint.root)
  end)
end

---@return { provider: string, model: string|nil, mode: string|nil, profile: string, config_options: table, config_values: table }
function M:current_settings()
  return {
    provider = self.provider_name or config.current.provider,
    model = self.model,
    mode = self.mode,
    profile = config.current.profile or config.current.default_profile,
    config_options = self.config_options,
    config_values = self.config_values or {},
  }
end

function M:set_provider(name)
  self:_reset_session()
  self.provider_name = name
  self.model = nil
  self.mode = nil
  self.config_values = {}
end

function M:set_model(model)
  self.model = model
  if self.client and self.session_id then
    self:_apply_config_option("model", model, function() end)
  end
end

function M:set_mode(mode)
  self.mode = mode
  if self.client and self.session_id then
    self:_apply_config_option("mode", mode, function() end)
  end
end

function M:set_config_option(category, value)
  self.config_values = self.config_values or {}
  self.config_values[category] = value
  if category == "mode" then
    self:set_mode(value)
    return
  elseif category == "model" then
    self:set_model(value)
    return
  end
  if self.client and self.session_id then
    self:_apply_config_option(category, value, function() end)
  end
end

function M:discover_options(callback)
  self:_ensure_client(function(client, cerr)
    if cerr or not client then
      local msg = cerr and (cerr.message or vim.inspect(cerr)) or "client unavailable"
      vim.notify("acp: option discovery failed: " .. msg, vim.log.levels.ERROR)
      if callback then
        callback(self:current_settings())
      end
      return
    end
    client:new_session(vim.fn.getcwd(), function(result, err)
      if self.client ~= client then
        return
      end
      if err or not result or not result.sessionId then
        vim.notify("acp: option discovery failed: " .. vim.inspect(err), vim.log.levels.ERROR)
        if callback then
          callback(self:current_settings())
        end
        return
      end
      local session_id = result.sessionId
      self:_set_config_options(result.configOptions)
      client:cancel(session_id)
      client:unsubscribe(session_id)
      if callback then
        callback(self:current_settings())
      end
    end)
  end)
end

function M:option_items(category)
  local items = {}
  local option = self.config_options[category]
  if option and option.options then
    for _, item in ipairs(option.options) do
      items[#items + 1] = {
        value = item.value,
        name = item.name or item.value,
        description = item.description,
        current = item.value == option.currentValue,
      }
    end
  end
  return items
end

function M:has_config_option(category)
  return self.config_options[category] ~= nil
end

return M
