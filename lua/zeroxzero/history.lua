---@class zeroxzero.history.UserMessage
---@field type "user"
---@field id string
---@field text string
---@field status? "active"|"queued"

---@class zeroxzero.history.AgentMessage
---@field type "agent"|"thought"
---@field text string

---@class zeroxzero.history.ToolCall
---@field type "tool_call"
---@field tool_call_id string
---@field kind string
---@field title string
---@field status string
---@field raw_input? table
---@field content? table[]
---@field locations? table[]
---@field expanded? boolean

---@class zeroxzero.history.Permission
---@field type "permission"
---@field tool_call_id string
---@field description string
---@field options table[]
---@field decision? string
---@field tool_class? "read"|"write"|"shell"|"unknown"
---@field raw_input? table
---@field tool_content? table[]

---@class zeroxzero.history.Activity
---@field type "activity"
---@field text string
---@field status? "pending"|"in_progress"|"completed"|"failed"

---@alias zeroxzero.history.Message
---| zeroxzero.history.UserMessage
---| zeroxzero.history.AgentMessage
---| zeroxzero.history.ToolCall
---| zeroxzero.history.Permission
---| zeroxzero.history.Activity

---@class zeroxzero.History
---@field messages zeroxzero.history.Message[]
---@field next_id integer
local History = {}
History.__index = History

---@return zeroxzero.History
function History.new()
  return setmetatable({ messages = {}, next_id = 1 }, History)
end

---@param msg zeroxzero.history.Message
function History:add(msg)
  table.insert(self.messages, msg)
end

---@param text string
---@param status? "active"|"queued"
---@return string id
function History:add_user(text, status)
  local id = tostring(self.next_id)
  self.next_id = self.next_id + 1
  self:add({ type = "user", id = id, text = text, status = status or "active" })
  return id
end

---@param id string
---@param status "active"|"queued"
function History:set_user_status(id, status)
  for i = #self.messages, 1, -1 do
    local msg = self.messages[i]
    if msg.type == "user" and msg.id == id then
      msg.status = status
      return
    end
  end
end

---@param kind "agent"|"thought"
---@param text string
function History:add_agent_chunk(kind, text)
  table.insert(self.messages, { type = kind, text = text })
end

---@param text string
---@param status? "pending"|"in_progress"|"completed"|"failed"
function History:add_activity(text, status)
  self:add({ type = "activity", text = text, status = status or "completed" })
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
  self.next_id = 1
end

return History
