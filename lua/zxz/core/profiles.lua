local config = require("zxz.core.config")

local M = {}

local function notify(text)
  vim.notify("0x0: " .. text, vim.log.levels.INFO)
end

---@return string[]
local function profile_ids()
  local ids = {}
  for id in pairs(config.current.profiles or {}) do
    ids[#ids + 1] = id
  end
  table.sort(ids)
  return ids
end

---@param id string
---@return boolean, string|nil
function M.set(id)
  local profile = config.current.profiles and config.current.profiles[id]
  if not profile then
    return false, "unknown profile: " .. tostring(id)
  end
  config.current.profile = id
  if profile.tool_policy then
    config.current.tool_policy = vim.tbl_deep_extend("force", {}, profile.tool_policy)
  end

  local chat = require("zxz.chat.chat")
  if profile.provider then
    chat.set_provider(profile.provider)
  end
  if profile.model then
    chat.set_model(profile.model)
  end
  for category, value in pairs(profile.config_options or {}) do
    chat.set_config_option(category, value)
  end
  return true, nil
end

function M.current()
  local id = config.current.profile or config.current.default_profile
  return id, config.current.profiles and config.current.profiles[id] or nil
end

function M.open()
  local ids = profile_ids()
  if #ids == 0 then
    notify("no profiles configured")
    return
  end
  local current = config.current.profile or config.current.default_profile
  vim.ui.select(ids, {
    prompt = "0x0 profile",
    format_item = function(id)
      local profile = config.current.profiles[id] or {}
      local prefix = id == current and "● " or "  "
      local label = profile.name or id
      if profile.description and profile.description ~= "" then
        label = label .. ": " .. profile.description
      end
      return prefix .. label
    end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, err = M.set(choice)
    if not ok then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    notify("profile: " .. choice)
  end)
end

return M
