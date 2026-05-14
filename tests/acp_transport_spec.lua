local function fake_pipe()
  return {
    closed = false,
    read_start = function(self, cb)
      self.read_cb = cb
    end,
    write = function(self, data)
      self.last_write = data
    end,
    is_closing = function(self)
      return self.closed
    end,
    close = function(self)
      self.closed = true
    end,
  }
end

local function fake_handle(command)
  return {
    command = command,
    closed = false,
    killed = {},
    is_closing = function(self)
      return self.closed
    end,
    close = function(self)
      self.closed = true
    end,
    kill = function(self, signal)
      self.killed[#self.killed + 1] = signal
    end,
  }
end

local function with_fake_processes(fn)
  local saved_uv = vim.uv
  local saved_has = vim.fn.has
  local saved_executable = vim.fn.executable
  local saved_transport = package.loaded["zxz.core.acp_transport"]
  local spawns = {}
  local next_pid = 4242

  vim.uv = setmetatable({
    new_pipe = function()
      return fake_pipe()
    end,
    spawn = function(command, opts, on_exit)
      local handle = fake_handle(command)
      local pid = next_pid
      next_pid = next_pid + 1
      spawns[#spawns + 1] = {
        command = command,
        opts = opts or {},
        on_exit = on_exit,
        handle = handle,
        pid = pid,
      }
      return handle, pid
    end,
  }, { __index = saved_uv })
  vim.fn.has = function(feature)
    if feature == "mac" then
      return 1
    end
    return saved_has(feature)
  end
  vim.fn.executable = function(command)
    if command == "caffeinate" then
      return 1
    end
    return saved_executable(command)
  end
  package.loaded["zxz.core.acp_transport"] = nil

  local ok, err = pcall(fn, spawns)

  vim.uv = saved_uv
  vim.fn.has = saved_has
  vim.fn.executable = saved_executable
  package.loaded["zxz.core.acp_transport"] = saved_transport

  if not ok then
    error(err)
  end
end

describe("acp_transport", function()
  it("keeps provider subprocesses awake with caffeinate on macOS", function()
    with_fake_processes(function(spawns)
      local Transport = require("zxz.core.acp_transport")
      local states = {}
      local transport = Transport.create({
        name = "fake",
        command = "fake-acp",
        args = { "--stdio" },
      }, {
        on_state = function(state)
          states[#states + 1] = state
        end,
        on_message = function() end,
      })

      transport:start()

      assert.are.equal(1, #spawns)
      assert.are.equal("fake-acp", spawns[1].command)
      assert.are.same({ "--stdio" }, spawns[1].opts.args)
      assert.are.same({ "connecting", "connected" }, states)

      transport:set_idle_armed(true)
      assert.are.equal(2, #spawns)
      assert.are.equal("caffeinate", spawns[2].command)
      assert.are.same({ "-i", "-w", "4242" }, spawns[2].opts.args)

      transport:set_idle_armed(false)
      assert.are.same({ 15 }, spawns[2].handle.killed)

      transport:stop()
      assert.are.same({ 15, 9 }, spawns[1].handle.killed)
      assert.are.same({ 15 }, spawns[2].handle.killed)
    end)
  end)
end)
