local config = require("zeroxzero.config")

local M = {}

local uv = vim.uv or vim.loop
local bitlib = bit or bit32

local socket = nil
local connected = false
local connecting = false
local read_buffer = ""
local write_queue = {}
local pending = {}
local subscribers = {}
local request_seq = 0

local function websocket_url(server_url)
  local scheme, rest = server_url:match("^(https?)://(.+)$")
  if not scheme then
    return server_url
  end

  local ws_scheme = scheme == "https" and "wss" or "ws"
  return ws_scheme .. "://" .. rest:gsub("/$", "") .. "/ws"
end

local function parse_url(url)
  local scheme, host, port, path = url:match("^(wss?)://([^:/]+):?(%d*)(/.*)$")
  if not scheme then
    error("Invalid WebSocket URL: " .. url)
  end
  if scheme == "wss" then
    error("wss is not supported by the local TCP client")
  end

  -- luv's raw TCP connect expects an IP address in some Neovim builds.
  if host == "localhost" then
    host = "127.0.0.1"
  end

  return host, tonumber(port) or 80, path
end

local function b64(data)
  local alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  return (
    (data:gsub(".", function(char)
      local byte = char:byte()
      local bits = ""
      for i = 7, 0, -1 do
        bits = bits .. (bitlib.band(byte, bitlib.lshift(1, i)) ~= 0 and "1" or "0")
      end
      return bits
    end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(bits)
      if #bits < 6 then
        return ""
      end

      local value = 0
      for i = 1, 6 do
        if bits:sub(i, i) == "1" then
          value = value + 2 ^ (6 - i)
        end
      end
      return alphabet:sub(value + 1, value + 1)
    end) .. ({ "", "==", "=" })[#data % 3 + 1]
  )
end

local function random_bytes(len)
  local bytes = {}
  for i = 1, len do
    bytes[i] = string.char(math.random(0, 255))
  end
  return table.concat(bytes)
end

local function close_socket()
  connected = false
  connecting = false
  read_buffer = ""
  write_queue = {}

  if socket and not socket:is_closing() then
    socket:read_stop()
    socket:close()
  end
  socket = nil
end

local function notify_error(err)
  vim.schedule(function()
    vim.notify("0x0: " .. tostring(err), vim.log.levels.ERROR)
  end)
end

local function fail_pending(err)
  local requests = pending
  pending = {}

  for _, callbacks in pairs(requests) do
    if callbacks.on_error then
      vim.schedule(function()
        callbacks.on_error(err)
      end)
    end
  end
end

local function encode_frame(payload)
  local payload_len = #payload
  local parts = { string.char(0x81) }

  if payload_len < 126 then
    table.insert(parts, string.char(0x80 + payload_len))
  elseif payload_len <= 0xffff then
    table.insert(parts, string.char(0x80 + 126, math.floor(payload_len / 256), payload_len % 256))
  else
    local bytes = {}
    local remaining = payload_len
    for i = 8, 1, -1 do
      bytes[i] = remaining % 256
      remaining = math.floor(remaining / 256)
    end
    table.insert(parts, string.char(0x80 + 127, unpack(bytes)))
  end

  local mask = random_bytes(4)
  table.insert(parts, mask)

  local masked = {}
  for i = 1, payload_len do
    local key = mask:byte(((i - 1) % 4) + 1)
    masked[i] = string.char(bitlib.bxor(payload:byte(i), key))
  end
  table.insert(parts, table.concat(masked))

  return table.concat(parts)
end

local function send_json(message)
  local payload = vim.json.encode(message)
  if not connected or not socket then
    table.insert(write_queue, payload)
    return
  end
  socket:write(encode_frame(payload))
end

local function flush_queue()
  local queued = write_queue
  write_queue = {}
  for _, payload in ipairs(queued) do
    socket:write(encode_frame(payload))
  end
end

function M._handle_message(message)
  for _, subscriber in ipairs(subscribers) do
    vim.schedule(function()
      subscriber(message)
    end)
  end

  if message.type == "error" then
    local callbacks = message.id and pending[message.id] or nil
    if callbacks and callbacks.on_error then
      pending[message.id] = nil
      vim.schedule(function()
        callbacks.on_error(message.error or "unknown error")
      end)
    else
      notify_error(message.error or "unknown error")
    end
    return
  end

  if not message.id then
    return
  end

  local callbacks = pending[message.id]
  if not callbacks then
    return
  end

  if callbacks[message.type] then
    vim.schedule(function()
      callbacks[message.type](message)
    end)
  elseif callbacks.on_message then
    vim.schedule(function()
      callbacks.on_message(message)
    end)
  end

  if message.type == "changes.updated" and callbacks.close_on_changes then
    pending[message.id] = nil
  end

  if
    message.type == "assistant.done"
    or message.type == "inline.result"
    or message.type == "session.created"
    or message.type == "user.queued"
  then
    if callbacks.on_done then
      vim.schedule(function()
        callbacks.on_done(message)
      end)
    end
    if callbacks.keep and callbacks.done_grace_ms then
      local timer = uv.new_timer()
      timer:start(callbacks.done_grace_ms, 0, function()
        timer:stop()
        timer:close()
        pending[message.id] = nil
      end)
    elseif not callbacks.keep then
      pending[message.id] = nil
    end
  end
end

local function decode_frames()
  while true do
    if #read_buffer < 2 then
      return
    end

    local b1 = read_buffer:byte(1)
    local b2 = read_buffer:byte(2)
    local opcode = bitlib.band(b1, 0x0f)
    local masked = bitlib.band(b2, 0x80) ~= 0
    local len = bitlib.band(b2, 0x7f)
    local offset = 3

    if len == 126 then
      if #read_buffer < 4 then
        return
      end
      len = read_buffer:byte(3) * 256 + read_buffer:byte(4)
      offset = 5
    elseif len == 127 then
      if #read_buffer < 10 then
        return
      end
      len = 0
      for i = 3, 10 do
        len = len * 256 + read_buffer:byte(i)
      end
      offset = 11
    end

    local mask
    if masked then
      if #read_buffer < offset + 3 then
        return
      end
      mask = read_buffer:sub(offset, offset + 3)
      offset = offset + 4
    end

    if #read_buffer < offset + len - 1 then
      return
    end

    local payload = read_buffer:sub(offset, offset + len - 1)
    read_buffer = read_buffer:sub(offset + len)

    if masked and mask then
      local unmasked = {}
      for i = 1, #payload do
        local key = mask:byte(((i - 1) % 4) + 1)
        unmasked[i] = string.char(bitlib.bxor(payload:byte(i), key))
      end
      payload = table.concat(unmasked)
    end

    if opcode == 0x1 then
      local ok, message = pcall(vim.json.decode, payload)
      if ok and type(message) == "table" then
        M._handle_message(message)
      end
    elseif opcode == 0x8 then
      close_socket()
      fail_pending("WebSocket closed")
      return
    end
  end
end

function M.connect()
  if connected or connecting then
    return
  end

  connecting = true

  local ok, host, port, path = pcall(function()
    return parse_url(websocket_url(config.current.server_url))
  end)

  if not ok then
    connecting = false
    fail_pending(host)
    notify_error(host)
    return
  end

  local tcp = uv.new_tcp()
  socket = tcp

  tcp:connect(host, port, function(err)
    if err then
      close_socket()
      fail_pending(err)
      return
    end

    local key = b64(random_bytes(16))
    tcp:write(table.concat({
      "GET " .. path .. " HTTP/1.1",
      "Host: " .. host .. ":" .. port,
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Key: " .. key,
      "Sec-WebSocket-Version: 13",
      "",
      "",
    }, "\r\n"))

    tcp:read_start(function(read_err, chunk)
      if read_err then
        close_socket()
        fail_pending(read_err)
        return
      end
      if not chunk then
        close_socket()
        fail_pending("WebSocket closed")
        return
      end

      read_buffer = read_buffer .. chunk

      if not connected then
        local header_end = read_buffer:find("\r\n\r\n", 1, true)
        if not header_end then
          return
        end

        local header = read_buffer:sub(1, header_end + 3)
        read_buffer = read_buffer:sub(header_end + 4)
        if not header:match("^HTTP/1%.1 101") then
          close_socket()
          fail_pending("WebSocket upgrade failed")
          return
        end

        connected = true
        connecting = false
        flush_queue()
      end

      decode_frames()
    end)
  end)
end

---@param message table
---@param handlers? table
---@return string id
function M.request(message, handlers)
  request_seq = request_seq + 1
  local id = message.id or ("nvim-" .. request_seq)
  message.id = id
  pending[id] = handlers or {}
  send_json(message)
  M.connect()
  return id
end

---@param message table
function M.notify(message)
  send_json(message)
  M.connect()
end

---@param callback fun(message: table)
---@return fun()
function M.subscribe(callback)
  table.insert(subscribers, callback)
  return function()
    for index, subscriber in ipairs(subscribers) do
      if subscriber == callback then
        table.remove(subscribers, index)
        return
      end
    end
  end
end

function M.close()
  close_socket()
  fail_pending("WebSocket closed")
end

return M
