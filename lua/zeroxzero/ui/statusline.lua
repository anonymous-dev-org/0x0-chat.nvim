local M = {}

---@type string
M._status = ""

---@type string?
M._session_title = nil

local _frames = { "\u{280b}", "\u{2819}", "\u{2839}", "\u{2838}", "\u{283c}", "\u{2834}", "\u{2826}", "\u{2827}", "\u{2807}", "\u{280f}" }

---@type table<string, true>
local _busy = {}

---@type table<string, string>
local _phase = {}

---@type integer
local _frame = 1

---@type uv_timer_t?
local _timer = nil

---Update status from SSE events
function M._setup()
  local ok, sse = pcall(require, "zeroxzero.sse")
  if not ok then
    return
  end

  sse.on("server.connected", function()
    M._status = "connected"
  end)

  sse.on("session.updated", function(props)
    if props and props.info and props.info.title then
      M._session_title = props.info.title
    end
  end)

  sse.on("session.status", function(props)
    if not props or not props.sessionID or not props.status then
      return
    end

    local session_id = props.sessionID
    local status = props.status

    if status.type == "busy" then
      _busy[session_id] = true
      _phase[session_id] = status.phase or "thinking"

      if not _timer then
        _timer = vim.uv.new_timer()
        _timer:start(80, 80, function()
          vim.schedule(function()
            _frame = (_frame % #_frames) + 1
            vim.cmd("redrawstatus")
          end)
        end)
      end
    else
      _busy[session_id] = nil
      _phase[session_id] = nil

      if not next(_busy) and _timer then
        _timer:stop()
        _timer:close()
        _timer = nil
        vim.schedule(function()
          vim.cmd("redrawstatus")
        end)
      end
    end
  end)
end

---Get statusline string
---@return string
function M.get()
  local server = require("zeroxzero.server")
  if not server.connected then
    return ""
  end

  local parts = { "0x0" }

  -- Show busy status for any active session
  if next(_busy) then
    local session_id = next(_busy)
    local phase = _phase[session_id] or "thinking"
    table.insert(parts, _frames[_frame] .. " " .. phase)
  elseif M._status ~= "" then
    table.insert(parts, M._status)
  end

  if M._session_title then
    table.insert(parts, M._session_title)
  end

  return table.concat(parts, " | ")
end

return M
