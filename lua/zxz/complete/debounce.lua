--- Debounce timer utility for completion triggers.

local M = {}

---@type uv_timer_t?
local _timer = nil

--- Start or restart a debounced timer.
---@param ms integer Delay in milliseconds
---@param callback fun() Function to call after delay
function M.start(ms, callback)
  M.stop()
  _timer = vim.uv.new_timer()
  _timer:start(ms, 0, vim.schedule_wrap(callback))
end

--- Stop the debounce timer.
function M.stop()
  if _timer then
    if not _timer:is_closing() then
      _timer:stop()
      _timer:close()
    end
    _timer = nil
  end
end

--- Check if a timer is currently running.
---@return boolean
function M.is_pending()
  return _timer ~= nil and _timer:is_active()
end

return M
