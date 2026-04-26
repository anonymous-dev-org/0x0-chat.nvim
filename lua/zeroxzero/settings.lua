local config = require("zeroxzero.config")
local util = require("zeroxzero.util")

local M = {}

local function notify_setting(name, value)
  util.notify(name .. " set to " .. tostring(value))
end

local function providers_url()
  return (config.current.server_url or ""):gsub("/$", "") .. "/providers"
end

local function fetch_providers(callback)
  local function handle_output(code, stdout, stderr)
    vim.schedule(function()
      if code ~= 0 then
        util.notify("Could not load providers: " .. (stderr or "curl failed"), vim.log.levels.ERROR)
        callback(nil)
        return
      end

      local ok, decoded = pcall(vim.json.decode, stdout or "")
      if not ok or type(decoded) ~= "table" or type(decoded.providers) ~= "table" then
        util.notify("Could not parse provider list", vim.log.levels.ERROR)
        callback(nil)
        return
      end

      callback(decoded.providers)
    end)
  end

  if vim.system then
    vim.system({ "curl", "-fsS", providers_url() }, { text = true }, function(result)
      handle_output(result.code, result.stdout, result.stderr)
    end)
    return
  end

  local output = vim.fn.system({ "curl", "-fsS", providers_url() })
  handle_output(vim.v.shell_error, output, output)
end

local function choose_provider()
  fetch_providers(function(providers)
    if not providers or #providers == 0 then
      return
    end

    vim.ui.select(providers, {
      prompt = "0x0 chat provider",
      format_item = function(provider)
        local suffix = provider.configured == false and " unavailable" or ""
        return string.format("%s (%s)%s", provider.label or provider.id, provider.id, suffix)
      end,
    }, function(provider)
      if not provider then
        return
      end
      if provider.configured == false then
        util.notify((provider.label or provider.id) .. " is unavailable", vim.log.levels.WARN)
        return
      end

      vim.ui.select(provider.models or {}, {
        prompt = "0x0 chat model",
        format_item = function(model)
          if model == provider.defaultModel then
            return model .. " (default)"
          end
          return model
        end,
      }, function(model)
        if not model then
          return
        end
        config.current.provider = provider.id
        config.current.model = model
        notify_setting("model", provider.id .. " / " .. model)
      end)
    end)
  end)
end

local function choose_effort()
  local efforts = { "minimal", "low", "medium", "high", "xhigh" }
  vim.ui.select(efforts, { prompt = "0x0 chat effort" }, function(effort)
    if not effort then
      return
    end
    config.current.effort = effort
    notify_setting("effort", effort)
  end)
end

function M.open()
  local actions = {
    {
      label = "Provider / model: " .. tostring(config.current.provider or "server default") .. " / " .. tostring(
        config.current.model or "default"
      ),
      run = choose_provider,
    },
    {
      label = "Effort: " .. tostring(config.current.effort or "server default"),
      run = choose_effort,
    },
  }

  vim.ui.select(actions, {
    prompt = "0x0 chat settings",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
      action.run()
    end
  end)
end

return M
