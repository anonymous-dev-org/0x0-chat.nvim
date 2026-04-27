---@class zeroxzero.history.UserMessage
---@field type "user"
---@field text string

---@class zeroxzero.history.AgentMessage
---@field type "agent"|"thought"
---@field text string

---@class zeroxzero.history.ToolCall
---@field type "tool_call"
---@field tool_call_id string
---@field kind string
---@field title string
---@field status string

---@class zeroxzero.history.Permission
---@field type "permission"
---@field tool_call_id string
---@field description string
---@field options table[]
---@field decision? string

---@alias zeroxzero.history.Message
---| zeroxzero.history.UserMessage
---| zeroxzero.history.AgentMessage
---| zeroxzero.history.ToolCall
---| zeroxzero.history.Permission

---@class zeroxzero.History
---@field messages zeroxzero.history.Message[]
local History = {}
History.__index = History

---@return zeroxzero.History
function History.new()
  return setmetatable({ messages = {} }, History)
end

---@param msg zeroxzero.history.Message
function History:add(msg)
  table.insert(self.messages, msg)
end

---@param kind "agent"|"thought"
---@param text string
function History:add_agent_chunk(kind, text)
  table.insert(self.messages, { type = kind, text = text })
end

---@param tool_call_id string
---@param patch table
function History:update_tool_call(tool_call_id, patch)
  for i = #self.messages, 1, -1 do
    local msg = self.messages[i]
    if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
      self.messages[i] = vim.tbl_deep_extend("force", msg, patch)
      return
    end
  end
end

---@param tool_call_id string
---@param decision string
function History:set_permission_decision(tool_call_id, decision)
  for i = #self.messages, 1, -1 do
    local msg = self.messages[i]
    if msg.type == "permission" and msg.tool_call_id == tool_call_id then
      msg.decision = decision
      return
    end
  end
end

function History:clear()
  self.messages = {}
end

return History
