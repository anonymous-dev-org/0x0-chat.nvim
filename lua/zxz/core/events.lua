local M = { _subs = {} }

function M.on(event, fn)
  M._subs[event] = M._subs[event] or {}
  table.insert(M._subs[event], fn)
  return function()
    M.off(event, fn)
  end
end

function M.off(event, fn)
  local subs = M._subs[event]
  if not subs then
    return
  end
  for i, f in ipairs(subs) do
    if f == fn then
      table.remove(subs, i)
      return
    end
  end
end

function M.emit(event, ...)
  for _, fn in ipairs(M._subs[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then
      local log_ok, log = pcall(require, "zxz.core.log")
      if log_ok then
        log.error("event " .. tostring(event) .. ": " .. tostring(err))
      end
    end
  end
end

function M._reset()
  M._subs = {}
end

return M
