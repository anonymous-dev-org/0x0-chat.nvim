local M = {}

local TERMINAL_TOOL_STATUS = {
  cancelled = true,
  completed = true,
  failed = true,
}

local EXPLICIT_ID_PATHS = {
  { "toolCallId" },
  { "tool_call_id" },
  { "toolUseId" },
  { "tool_use_id" },
  { "toolCall", "toolCallId" },
  { "toolCall", "id" },
  { "tool_call", "tool_call_id" },
  { "tool_call", "id" },
  { "metadata", "toolCallId" },
  { "metadata", "tool_call_id" },
  { "meta", "toolCallId" },
  { "meta", "tool_call_id" },
}

local function string_value(value)
  if type(value) ~= "string" then
    return nil
  end
  if value == "" then
    return nil
  end
  return value
end

local function path_value(params, path)
  local value = params
  for _, key in ipairs(path) do
    if type(value) ~= "table" then
      return nil
    end
    value = value[key]
  end
  return string_value(value)
end

local function explicit_tool_id(params)
  for _, path in ipairs(EXPLICIT_ID_PATHS) do
    local value = path_value(params, path)
    if value then
      return value, "protocol:" .. table.concat(path, ".")
    end
  end
  return nil, nil
end

local function non_terminal_tools(run)
  local tools = {}
  for _, tool in ipairs((run and run.tool_calls) or {}) do
    local id = string_value(tool.tool_call_id)
    if id and not TERMINAL_TOOL_STATUS[tool.status] then
      tools[#tools + 1] = id
    end
  end
  return tools
end

---@param params table|nil
---@param active_tool_call_id string|nil
---@param run table|nil
---@return string|nil tool_call_id
---@return string source
function M.resolve(params, active_tool_call_id, run)
  local explicit, source = explicit_tool_id(params or {})
  if explicit then
    return explicit, source
  end
  local live_tools = non_terminal_tools(run)
  if #live_tools == 0 then
    return nil, "unattributed"
  end
  if #live_tools > 1 then
    return nil, "ambiguous_active"
  end
  if active_tool_call_id == live_tools[1] then
    return active_tool_call_id, "active"
  end
  return nil, "unattributed"
end

function M._explicit_tool_id(params)
  return explicit_tool_id(params or {})
end

return M
