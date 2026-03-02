local api = require("zeroxzero.api")
local server = require("zeroxzero.server")

local M = {}

---Pick a session or create a new one
function M.session_picker()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.get_sessions(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local chat = require("zeroxzero.chat")
      local sessions = response and response.body or {}

      if type(sessions) ~= "table" or #sessions == 0 then
        chat.new_session(function() chat.open() end)
        return
      end

      local items = {}
      table.insert(items, { title = "+ New session", id = nil })
      for _, session in ipairs(sessions) do
        local title = session.title or session.id or "untitled"
        local id = session.id
        table.insert(items, { title = title, id = id })
      end

      vim.ui.select(items, {
        prompt = "Sessions",
        format_item = function(item)
          return item.title
        end,
      }, function(choice)
        if not choice then
          return
        end
        if choice.id == nil then
          chat.new_session(function() chat.open() end)
        else
          chat.switch_session(choice.id)
          chat.open()
        end
      end)
    end)
  end)
end

---Pick a model from available providers
function M.model_picker()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.get_providers(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local providers = response and response.body or {}
      if type(providers) ~= "table" or #providers == 0 then
        vim.notify("0x0: no providers found", vim.log.levels.INFO)
        return
      end

      -- Build flat list of provider + model combos
      local items = {}
      for _, provider in ipairs(providers) do
        local models = provider.models or {}
        for _, model in ipairs(models) do
          table.insert(items, {
            providerID = provider.id,
            modelID = model.id or model,
            label = (provider.id or "?") .. "/" .. (model.id or model),
          })
        end
      end

      if #items == 0 then
        vim.notify("0x0: no models found", vim.log.levels.INFO)
        return
      end

      vim.ui.select(items, {
        prompt = "Models",
        format_item = function(item)
          return item.label
        end,
      }, function(choice)
        if not choice then
          return
        end
        local chat = require("zeroxzero.chat")
        chat.set_model({ providerID = choice.providerID, modelID = choice.modelID })
        vim.notify("0x0: model set to " .. choice.label, vim.log.levels.INFO)
      end)
    end)
  end)
end

return M
