local acp_client = require("zeroxzero.acp_client")
local config = require("zeroxzero.config")

local M = {}

local function configured_title_model(provider_name)
  local title_model = config.current.title_model
  if type(title_model) == "table" then
    return title_model[provider_name]
  end
  return title_model
end

local function model_option_has_value(options, value)
  if not options or not value or value == "" then
    return false
  end
  for _, option in ipairs(options) do
    if option.category == "model" and option.options then
      for _, item in ipairs(option.options) do
        if item.value == value then
          return true
        end
      end
    end
  end
  return false
end

local function clean_title(text)
  text = vim.trim((text or ""):gsub("\r", ""):gsub("\n", " "))
  text = text:gsub("^#+%s*", "")
  text = text:gsub('^["“”]+', ""):gsub('["“”]+$', "")
  text = text:gsub("%s+", " ")
  if #text > 80 then
    text = text:sub(1, 80):gsub("%s+%S*$", "")
  end
  return text ~= "" and text or nil
end

local function stop_client(client, session_id)
  if session_id then
    pcall(function()
      client:cancel(session_id)
    end)
    pcall(function()
      client:unsubscribe(session_id)
    end)
  end
  pcall(function()
    client:stop()
  end)
end

---@param provider_name string
---@param cwd string
---@param first_prompt string
---@param callback fun(title: string|nil, err: table|nil)
function M.generate(provider_name, cwd, first_prompt, callback)
  local provider, perr = config.resolve_provider(provider_name)
  if not provider then
    callback(nil, { message = perr })
    return
  end

  local model = configured_title_model(provider_name)
  local client = acp_client.new(provider, { host_fs = false })
  local chunks = {}

  client:start(function(c, cerr)
    if cerr or not c then
      callback(nil, cerr or { message = "title client unavailable" })
      return
    end

    c:new_session(cwd, function(result, serr)
      if serr or not result or not result.sessionId then
        stop_client(c)
        callback(nil, serr or { message = "title session failed" })
        return
      end

      local session_id = result.sessionId

      local function prompt_for_title()
        c:subscribe(session_id, {
          on_update = function(update)
            if update.sessionUpdate == "agent_message_chunk" then
              local text = update.content and update.content.text or ""
              if text ~= "" then
                chunks[#chunks + 1] = text
              end
            end
          end,
        })

        local prompt = table.concat({
          "Create a concise title for this agent chat.",
          "Return only the title, with no quotes, labels, or punctuation.",
          "Use 2 to 6 words.",
          "",
          "User request:",
          first_prompt,
        }, "\n")

        c:prompt(session_id, { { type = "text", text = prompt } }, function(_, perr2)
          stop_client(c, session_id)
          callback(clean_title(table.concat(chunks, "")), perr2)
        end)
      end

      if model and model ~= "" then
        if model_option_has_value(result.configOptions, model) then
          c:set_config_option(session_id, "model", model, function(_, merr)
            if merr then
              stop_client(c, session_id)
              callback(nil, merr)
              return
            end
            prompt_for_title()
          end)
        else
          c:set_model(session_id, model, function(_, merr)
            if merr then
              stop_client(c, session_id)
              callback(nil, merr)
              return
            end
            prompt_for_title()
          end)
        end
      else
        prompt_for_title()
      end
    end)
  end)
end

return M
