local uv = vim.uv or vim.loop

local M = {}

local IGNORE_STDERR_PATTERNS = {
  "Session not found",
  "session/prompt",
  "Spawning Claude Code",
  "does not appear in the file:",
  "Experiments loaded",
  "No onPostToolUseHook found",
  "[PreToolUseHook]",
}

local function should_ignore_stderr(line)
  for _, pattern in ipairs(IGNORE_STDERR_PATTERNS) do
    if line:match(pattern) then
      return true
    end
  end
  return false
end

local function build_env(overrides)
  local env_map = {}
  for k, v in pairs(vim.fn.environ()) do
    env_map[k] = v
  end
  env_map.NODE_NO_WARNINGS = "1"
  env_map.IS_AI_TERMINAL = "1"
  if overrides then
    for k, v in pairs(overrides) do
      env_map[k] = v
    end
  end
  local list = {}
  for k, v in pairs(env_map) do
    list[#list + 1] = k .. "=" .. v
  end
  return list
end

---@param config { command: string, args?: string[], env?: table<string, string> }
---@param callbacks { on_state: fun(state: string), on_message: fun(msg: table), on_exit?: fun(code: integer, stderr: string[]) }
function M.create(config, callbacks)
  local self = { stdin = nil, stdout = nil, process = nil }

  function self:send(data)
    if self.stdin and not self.stdin:is_closing() then
      self.stdin:write(data .. "\n")
      return true
    end
    return false
  end

  function self:start()
    callbacks.on_state("connecting")

    local stdin = uv.new_pipe(false)
    local stdout = uv.new_pipe(false)
    local stderr = uv.new_pipe(false)
    if not stdin or not stdout or not stderr then
      callbacks.on_state("error")
      error("acp: failed to create pipes")
    end

    local stderr_buffer = {}
    local args = vim.deepcopy(config.args or {})

    local ok, handle, pid_or_err = pcall(uv.spawn, config.command, {
      args = args,
      env = build_env(config.env),
      stdio = { stdin, stdout, stderr },
      detached = false,
    }, function(code, _signal)
      if callbacks.on_exit then
        vim.schedule(function()
          callbacks.on_exit(code, stderr_buffer)
        end)
      end
      callbacks.on_state("disconnected")
      if self.process then
        self.process:close()
        self.process = nil
      end
    end)

    if not ok or not handle then
      stdin:close()
      stdout:close()
      stderr:close()
      callbacks.on_state("error")
      vim.schedule(function()
        vim.notify(
          ("acp: failed to spawn '%s': %s"):format(config.command, tostring(handle or pid_or_err)),
          vim.log.levels.ERROR
        )
      end)
      return
    end

    self.process = handle
    self.stdin = stdin
    self.stdout = stdout

    callbacks.on_state("connected")

    local buffered = ""
    stdout:read_start(function(err, data)
      if err then
        vim.schedule(function()
          vim.notify("acp stdout error: " .. err, vim.log.levels.ERROR)
        end)
        callbacks.on_state("error")
        return
      end
      if not data then
        return
      end
      buffered = buffered .. data
      local lines = vim.split(buffered, "\n", { plain = true })
      buffered = lines[#lines]
      for i = 1, #lines - 1 do
        local line = vim.trim(lines[i])
        if line ~= "" then
          local ok, message = pcall(vim.json.decode, line)
          if ok then
            callbacks.on_message(message)
          else
            vim.schedule(function()
              vim.notify("acp: failed to decode JSON line: " .. line, vim.log.levels.WARN)
            end)
          end
        end
      end
    end)

    stderr:read_start(function(_, data)
      if not data then
        return
      end
      local trimmed = vim.trim(data)
      if trimmed == "" then
        return
      end
      stderr_buffer[#stderr_buffer + 1] = trimmed
      if not should_ignore_stderr(data) then
        vim.schedule(function()
          vim.notify("acp stderr: " .. trimmed, vim.log.levels.DEBUG)
        end)
      end
    end)
  end

  function self:stop()
    if self.process and not self.process:is_closing() then
      local p = self.process
      self.process = nil
      pcall(function()
        p:kill(15)
      end)
      pcall(function()
        p:kill(9)
      end)
      p:close()
    end
    if self.stdin then
      self.stdin:close()
      self.stdin = nil
    end
    if self.stdout then
      self.stdout:close()
      self.stdout = nil
    end
    callbacks.on_state("disconnected")
  end

  return self
end

return M
