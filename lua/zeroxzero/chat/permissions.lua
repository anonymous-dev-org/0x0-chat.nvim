-- Permission gating: render the request inline and bind one-shot key handlers.

local util = require("zeroxzero.chat.util")

local M = {}

function M:_handle_permission(request, respond)
  vim.schedule(function()
    if self.widget.permission_pending then
      respond("reject_once")
      return
    end
    if self.in_flight then
      self:_set_turn_activity("waiting", "Waiting for user input")
    end
    local tool_call = request.toolCall or {}
    local tool_call_id = tool_call.toolCallId or tostring(vim.loop.hrtime())
    local kind, title = util.describe_tool(tool_call)
    self.history:add({
      type = "permission",
      tool_call_id = tool_call_id,
      kind = kind,
      description = title,
      options = request.options or {},
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
    end)
  end)
end

return M
