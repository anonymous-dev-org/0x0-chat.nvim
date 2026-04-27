local config = require("zeroxzero.config")

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

function M.open()
  local chat = require("zeroxzero.chat")
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
