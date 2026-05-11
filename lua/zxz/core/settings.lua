local config = require("zxz.core.config")

local M = {}

local function notify(text)
  vim.notify("0x0-chat: " .. text, vim.log.levels.INFO)
end

local function pick_provider(chat)
  local ids = {}
  for id in pairs(config.current.providers) do
    ids[#ids + 1] = id
  end
  table.sort(ids)

  vim.ui.select(ids, {
    prompt = "0x0 chat provider",
    format_item = function(id)
      local p = config.current.providers[id]
      return ("%s (%s)"):format(p.name or id, id)
    end,
  }, function(choice)
    if not choice then
      return
    end
    chat.set_provider(choice)
    notify("provider: " .. choice)
  end)
end

local function pick_model(chat)
  chat.discover_options(function()
    local current = chat.current_settings()
    local provider = config.current.providers[current.provider] or {}
    local discovered = chat.option_items("model")
    local models = {}
    for _, item in ipairs(discovered) do
      models[#models + 1] = item
    end
    if #models == 0 then
      for _, model in ipairs(provider.models or {}) do
        models[#models + 1] = { value = model, name = model, current = model == current.model }
      end
    end

    local choices = vim.deepcopy(models)
    if not chat.has_config_option("model") then
      choices[#choices + 1] = { value = "(custom...)", name = "(custom...)" }
      choices[#choices + 1] = { value = "(clear)", name = "(clear)" }
    end

    vim.ui.select(choices, {
      prompt = ("0x0 model for %s"):format(current.provider),
      format_item = function(item)
        local prefix = item.current and "● " or "  "
        local text = prefix .. item.name
        if item.description and item.description ~= "" then
          text = text .. ": " .. item.description
        end
        return text
      end,
    }, function(choice)
      if not choice then
        return
      end
      if choice.value == "(clear)" then
        chat.set_model(nil)
        notify("model cleared")
        return
      end
      if choice.value == "(custom...)" then
        vim.ui.input({ prompt = "model id", default = current.model or "" }, function(value)
          if not value or value == "" then
            return
          end
          chat.set_model(value)
          notify("model: " .. value)
        end)
        return
      end
      chat.set_model(choice.value)
      notify("model: " .. choice.value)
    end)
  end)
end

local function pick_config_option(chat, category, label, setter)
  chat.discover_options(function()
    local choices = chat.option_items(category)
    if #choices == 0 then
      notify(label .. " is not available for this provider")
      return
    end

    vim.ui.select(choices, {
      prompt = "0x0 " .. label,
      format_item = function(item)
        local prefix = item.current and "● " or "  "
        local text = prefix .. item.name
        if item.description and item.description ~= "" then
          text = text .. ": " .. item.description
        end
        return text
      end,
    }, function(choice)
      if not choice then
        return
      end
      setter(choice.value)
      notify(label .. ": " .. choice.value)
    end)
  end)
end

local function pick_favorite_model(chat)
  local favorites = config.current.favorite_models or {}
  if #favorites == 0 then
    notify("no favorite models configured")
    return
  end
  local current = chat.current_settings()
  vim.ui.select(favorites, {
    prompt = "0x0 favorite model",
    format_item = function(item)
      local provider = item.provider or current.provider
      local model = item.model or item
      local prefix = provider == current.provider and model == current.model and "● " or "  "
      return ("%s%s / %s"):format(prefix, provider, model)
    end,
  }, function(choice)
    if not choice then
      return
    end
    if type(choice) == "table" and choice.provider and choice.provider ~= current.provider then
      chat.set_provider(choice.provider)
    end
    local model = type(choice) == "table" and choice.model or choice
    if model then
      chat.set_model(model)
      notify("model: " .. tostring(model))
    end
  end)
end

function M.open()
  local chat = require("zxz.chat.chat")
  local current = chat.current_settings()

  local actions = {
    {
      label = "Provider: " .. tostring(current.provider),
      run = function()
        pick_provider(chat)
      end,
    },
    {
      label = "Model: " .. tostring(current.model or "provider default"),
      run = function()
        pick_model(chat)
      end,
    },
    {
      label = "Mode: " .. tostring(current.mode or "provider default"),
      run = function()
        pick_config_option(chat, "mode", "mode", chat.set_mode)
      end,
    },
    {
      label = "Thinking: " .. tostring((current.config_values or {}).thinking or "provider default"),
      run = function()
        pick_config_option(chat, "thinking", "thinking", function(value)
          chat.set_config_option("thinking", value)
        end)
      end,
    },
    {
      label = "Effort: " .. tostring((current.config_values or {}).effort or "provider default"),
      run = function()
        pick_config_option(chat, "effort", "effort", function(value)
          chat.set_config_option("effort", value)
        end)
      end,
    },
    {
      label = "Favorite model",
      run = function()
        pick_favorite_model(chat)
      end,
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

function M.provider()
  pick_provider(require("zxz.chat.chat"))
end

function M.model()
  pick_model(require("zxz.chat.chat"))
end

function M.mode()
  pick_config_option(require("zxz.chat.chat"), "mode", "mode", require("zxz.chat.chat").set_mode)
end

function M.option(category, label)
  local chat = require("zxz.chat.chat")
  pick_config_option(chat, category, label or category, function(value)
    chat.set_config_option(category, value)
  end)
end

function M.favorite_model()
  pick_favorite_model(require("zxz.chat.chat"))
end

return M
