-- Permission gating: render the request inline and bind one-shot key handlers.

local tool_policy = require("zeroxzero.chat.tool_policy")
local util = require("zeroxzero.chat.util")

local M = {}

---@param options table[]
---@param wanted_kind string
---@return string|nil option_id, string|nil option_name
local function find_option(options, wanted_kind)
  for _, option in ipairs(options or {}) do
    if option.kind == wanted_kind then
      return option.optionId, option.name
    end
  end
end

---Drain the next queued permission, if any.
function M:_pump_permission_queue()
  if not self.permission_queue or #self.permission_queue == 0 then
    return
  end
  if self.widget.permission_pending then
    return
  end
  local next_entry = table.remove(self.permission_queue, 1)
  self:_present_permission(next_entry.request, next_entry.respond)
end

function M:_handle_permission(request, respond)
  vim.schedule(function()
    self.permission_queue = self.permission_queue or {}
    if self.widget.permission_pending then
      self.permission_queue[#self.permission_queue + 1] = { request = request, respond = respond }
      if self.in_flight then
        local depth = #self.permission_queue
        self:_set_turn_activity("waiting", ("Waiting for user input (%d queued)"):format(depth))
      end
      return
    end
    self:_present_permission(request, respond)
  end)
end

function M:_present_permission(request, respond)
  local tool_call = request.toolCall or {}
  local tool_call_id = tool_call.toolCallId or tostring(vim.loop.hrtime())
  local kind, title = util.describe_tool(tool_call)
  local options = request.options or {}

  local class = tool_policy.classify(tool_call)
  if tool_policy.decide(tool_call, class) then
    local opt_id = find_option(options, "allow_once") or find_option(options, "allow_always")
    if opt_id then
      respond(opt_id)
      self:_pump_permission_queue()
      return
    end
    -- Fall through to the gated path if no allow option was offered.
  end

  if self.in_flight then
    self:_set_turn_activity("waiting", "Waiting for user input")
  end
  self.history:add({
    type = "permission",
    tool_call_id = tool_call_id,
    kind = kind,
    description = title,
    options = options,
    tool_class = class,
    raw_input = tool_call.rawInput,
    tool_content = tool_call.content,
  })
  self.widget:render()
  util.emit_user("ZeroChatPermission")
  self.widget:bind_permission_keys(tool_call_id, request.options or {}, function(option_id, option_name)
    self.history:set_permission_decision(tool_call_id, option_name or option_id or "rejected")
    if self.in_flight then
      self:_set_turn_activity("waiting", "Working")
    end
    self.widget:render()
    respond(option_id)
    self:_pump_permission_queue()
  end)
end

return M
