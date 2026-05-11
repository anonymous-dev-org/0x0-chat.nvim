-- Shared helpers used across chat/* submodules. File-local utilities only;
-- nothing here touches Chat state directly.

local config = require("zxz.core.config")
local notify = require("zxz.core.notify")

local M = {}

---Ring the user via autocmd, optional sound, and a TTY bell.
---@param pattern string the autocmd User pattern to fire
function M.notify_user(pattern)
  notify.notify(config.current.sound, pattern)
end

---@param pattern string the autocmd User pattern to fire without sound
function M.emit_user(pattern)
  notify.notify(false, pattern)
end

---@param err any
---@return string
function M.error_message(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

function M.is_transport_disconnected(err)
  local message = M.error_message(err)
  return message == "transport disconnected" or message == "transport error"
end

function M.is_session_missing(err)
  return M.error_message(err) == "Resource not found"
end

function M.is_cancel_result(result)
  return result and result.stopReason == "cancelled"
end

---@param tool_call table
---@return string kind, string title
function M.describe_tool(tool_call)
  local kind = tool_call.kind or "tool"
  local title = tool_call.title
  if not title or title == "" then
    title = tool_call.toolCallId or "?"
  end
  return kind, title
end

---@param update table
---@return table patch
function M.tool_patch(update)
  local patch = {}
  if update.status then
    patch.status = update.status
  end
  if update.title and update.title ~= "" then
    patch.title = update.title
  end
  if update.kind then
    patch.kind = update.kind
  end
  if update.rawInput ~= nil then
    patch.raw_input = update.rawInput
  end
  if update.content ~= nil then
    patch.content = update.content
  end
  if update.locations ~= nil then
    patch.locations = update.locations
  end
  return patch
end

return M
