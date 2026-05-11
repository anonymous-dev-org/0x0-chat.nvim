-- Validate ACP client timeout + retry behavior using a fake stdio transport.
-- We monkey-patch zxz.acp_transport.create() so the real subprocess
-- machinery never runs; the fake transport just buffers outbound JSON-RPC
-- lines for inspection and replays whatever the test wants on inbound.

local function fake_transport(state)
  return {
    set_idle_armed = function(_, armed)
      state.idle_armed = armed
    end,
    send = function(_, data)
      state.sent[#state.sent + 1] = data
      return true
    end,
    start = function()
      state.callbacks.on_state("connected")
    end,
    stop = function()
      state.callbacks.on_state("disconnected")
    end,
  }
end

local function with_fake_transport(fn)
  local transport_mod = require("zxz.core.acp_transport")
  local saved = transport_mod.create
  local state = { sent = {} }
  transport_mod.create = function(_, callbacks)
    state.callbacks = callbacks
    return fake_transport(state)
  end
  local ok, err = pcall(fn, state)
  transport_mod.create = saved
  if not ok then
    error(err)
  end
end

local function reload_client()
  package.loaded["zxz.core.acp_client"] = nil
  return require("zxz.core.acp_client")
end

local function decode_last(state)
  local last = state.sent[#state.sent]
  return vim.json.decode(last)
end

---Reply to whichever request is currently pending the initialize handshake
---so subsequent requests aren't cascaded into a transport-error failure.
local function ack_initialize(state)
  for _, raw in ipairs(state.sent) do
    local msg = vim.json.decode(raw)
    if msg.method == "initialize" then
      state.callbacks.on_message({
        jsonrpc = "2.0",
        id = msg.id,
        result = { protocolVersion = 1, agentInfo = { name = "fake" } },
      })
      return
    end
  end
end

describe("acp_client", function()
  local config

  before_each(function()
    config = require("zxz.core.config")
    config.setup()
  end)

  it("times out a request when no response arrives", function()
    config.current.request_timeout_ms = 50
    config.current.initialize_retries = 1
    with_fake_transport(function(state)
      local M = reload_client()
      local client = M.new({ name = "fake", command = "echo" })
      client:start()
      ack_initialize(state)
      local got
      client:request("foo/bar", { x = 1 }, function(result, err)
        got = { result = result, err = err }
      end)
      local sent = decode_last(state)
      assert.are.equal("foo/bar", sent.method)
      -- Wait past the timeout deadline.
      vim.wait(200, function()
        return got ~= nil
      end)
      assert.is_truthy(got, "callback never fired")
      assert.is_nil(got.result)
      assert.is_truthy(got.err)
      assert.are.equal(-32001, got.err.code)
      assert.is_truthy(got.err.message:find("timed out"))
    end)
  end)

  it("does not time out session/prompt (long-lived streaming)", function()
    config.current.request_timeout_ms = 50
    config.current.initialize_retries = 1
    with_fake_transport(function(state)
      local M = reload_client()
      local client = M.new({ name = "fake", command = "echo" })
      client:start()
      ack_initialize(state)
      local got
      client:prompt("sess-1", { { type = "text", text = "hi" } }, function(result, err)
        got = { result = result, err = err }
      end)
      vim.wait(150)
      assert.is_nil(got, "prompt should still be in flight")
      -- Manually deliver a response to satisfy the request.
      local prompt_msg = decode_last(state)
      state.callbacks.on_message({ jsonrpc = "2.0", id = prompt_msg.id, result = { stopReason = "end_turn" } })
      vim.wait(50, function()
        return got ~= nil
      end)
      assert.is_truthy(got)
      assert.are.equal("end_turn", got.result.stopReason)
    end)
  end)

  it("pauses the provider idle watchdog while permission is pending", function()
    config.current.request_timeout_ms = 50
    config.current.initialize_retries = 1
    with_fake_transport(function(state)
      local M = reload_client()
      local client = M.new({ name = "fake", command = "echo" })
      client:start()
      ack_initialize(state)

      local permission_respond
      client:subscribe("sess-1", {
        on_update = function() end,
        on_request_permission = function(_, respond)
          permission_respond = respond
        end,
      })
      client:prompt("sess-1", { { type = "text", text = "hi" } }, function() end)
      assert.is_true(state.idle_armed)

      state.callbacks.on_message({
        jsonrpc = "2.0",
        id = 99,
        method = "session/request_permission",
        params = {
          sessionId = "sess-1",
          toolCall = { toolCallId = "tool-1", kind = "edit" },
          options = { { kind = "allow_once", optionId = "allow-1" } },
        },
      })
      vim.wait(50, function()
        return permission_respond ~= nil
      end)
      assert.is_function(permission_respond)
      assert.is_false(state.idle_armed)

      permission_respond("allow-1")
      local response = decode_last(state)
      assert.are.equal(99, response.id)
      assert.are.same({ outcome = { outcome = "selected", optionId = "allow-1" } }, response.result)
      assert.is_true(state.idle_armed)
    end)
  end)

  it("clears the timeout when the response arrives in time", function()
    config.current.request_timeout_ms = 200
    config.current.initialize_retries = 1
    with_fake_transport(function(state)
      local M = reload_client()
      local client = M.new({ name = "fake", command = "echo" })
      client:start()
      ack_initialize(state)
      local got
      client:request("ping", {}, function(result, err)
        got = { result = result, err = err }
      end)
      local req = decode_last(state)
      state.callbacks.on_message({ jsonrpc = "2.0", id = req.id, result = { ok = true } })
      vim.wait(50, function()
        return got ~= nil
      end)
      assert.is_truthy(got)
      assert.are.same({ ok = true }, got.result)
      -- Wait past the original deadline; no second callback should fire.
      vim.wait(250)
    end)
  end)

  it("retries initialize on failure up to the configured count", function()
    config.current.request_timeout_ms = 0
    config.current.initialize_retries = 3
    with_fake_transport(function(state)
      local M = reload_client()
      local client = M.new({ name = "fake", command = "echo" })
      local ready_listener_called = false
      client:start(function()
        ready_listener_called = true
      end)
      -- Reject the first two initialize attempts; succeed on the third.
      local function respond_error(idx)
        local raw = state.sent[idx]
        if not raw then
          return false
        end
        local msg = vim.json.decode(raw)
        state.callbacks.on_message({ jsonrpc = "2.0", id = msg.id, error = { code = -32603, message = "boom" } })
        return true
      end
      respond_error(1)
      vim.wait(400, function()
        return state.sent[2] ~= nil
      end)
      respond_error(2)
      vim.wait(800, function()
        return state.sent[3] ~= nil
      end)
      -- Third attempt: accept.
      local third = vim.json.decode(state.sent[3])
      state.callbacks.on_message({
        jsonrpc = "2.0",
        id = third.id,
        result = { protocolVersion = 1, agentInfo = { name = "fake" } },
      })
      vim.wait(50, function()
        return ready_listener_called
      end)
      assert.is_true(ready_listener_called)
      assert.is_true(client:is_ready())
    end)
  end)
end)
