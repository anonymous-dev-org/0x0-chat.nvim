---@class zxz.history.UserMessage
---@field type "user"
---@field id string
---@field text string
---@field status? "active"|"queued"
---@field context_summary? string[]

---@class zxz.history.AgentMessage
---@field type "agent"|"thought"
---@field text string

---@class zxz.history.ToolCall
---@field type "tool_call"
---@field tool_call_id string
---@field kind string
---@field title string
---@field status string
---@field raw_input? table
---@field content? table[]
---@field locations? table[]
---@field expanded? boolean
---@field edit_events? table[]

---@class zxz.history.Permission
---@field type "permission"
---@field tool_call_id string
---@field description string
---@field options table[]
---@field decision? string
---@field tool_class? "read"|"write"|"shell"|"unknown"
---@field raw_input? table
---@field tool_content? table[]

---@class zxz.history.Activity
---@field type "activity"
---@field text string
---@field status? "pending"|"in_progress"|"completed"|"failed"

---@alias zxz.history.Message
---| zxz.history.UserMessage
---| zxz.history.AgentMessage
---| zxz.history.ToolCall
---| zxz.history.Permission
---| zxz.history.Activity

---@class zxz.History
---@field messages zxz.history.Message[]
---@field next_id integer
local History = {}
History.__index = History

---@return zxz.History
function History.new()
  return setmetatable({ messages = {}, next_id = 1 }, History)
end

---@param msg zxz.history.Message
function History:add(msg)
  table.insert(self.messages, msg)
end

---@param text string
---@param status? "active"|"queued"
---@param context_summary? string[]
---@return string id
function History:add_user(text, status, context_summary)
  local id = tostring(self.next_id)
  self.next_id = self.next_id + 1
  self:add({ type = "user", id = id, text = text, status = status or "active", context_summary = context_summary })
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
---@param event table
---@return boolean
function History:append_tool_edit_event(tool_call_id, event)
  if not tool_call_id or not event then
    return false
  end
  for i = #self.messages, 1, -1 do
    local msg = self.messages[i]
    if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
      msg.edit_events = msg.edit_events or {}
      msg.edit_events[#msg.edit_events + 1] = event
      return true
    end
  end
  return false
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
