local config = require("zeroxzero.config")

local M = {}

---@param method string
---@param path string
---@param opts? {body?: table, timeout?: number}
---@param callback fun(err?: string, response?: {status: number, body: any})
function M.request(method, path, opts, callback)
  opts = opts or {}
  local cfg = config.current
  local url = string.format("http://%s:%d%s", cfg.hostname, cfg.port, path)

  local cmd = { "curl", "-s", "-w", "\n%{http_code}", "-X", method }

  table.insert(cmd, "-H")
  table.insert(cmd, "x-zeroxzero-directory: " .. vim.fn.getcwd())

  if cfg.auth then
    table.insert(cmd, "-u")
    table.insert(cmd, cfg.auth.username .. ":" .. cfg.auth.password)
  end

  if opts.body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    table.insert(cmd, vim.json.encode(opts.body))
  end

  if opts.timeout then
    table.insert(cmd, "--max-time")
    table.insert(cmd, tostring(opts.timeout))
  end

  table.insert(cmd, url)

  vim.system(cmd, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback("curl failed (exit " .. result.code .. "): " .. (result.stderr or ""))
        return
      end

      local output = result.stdout or ""
      local lines = vim.split(output, "\n", { trimempty = true })
      if #lines == 0 then
        callback("empty response")
        return
      end

      local status_code = tonumber(lines[#lines])
      table.remove(lines, #lines)
      local body_str = table.concat(lines, "\n")

      local body
      if body_str ~= "" then
        local ok, decoded = pcall(vim.json.decode, body_str)
        body = ok and decoded or body_str
      end

      callback(nil, { status = status_code or 0, body = body })
    end)
  end)
end

---@param method string
---@param path string
---@param opts? {body?: table, timeout?: number}
---@return string? err
---@return {status: number, body: any}? response
function M.request_sync(method, path, opts)
  opts = opts or {}
  local cfg = config.current
  local url = string.format("http://%s:%d%s", cfg.hostname, cfg.port, path)

  local cmd = { "curl", "-s", "-w", "\n%{http_code}", "-X", method }

  table.insert(cmd, "-H")
  table.insert(cmd, "x-zeroxzero-directory: " .. vim.fn.getcwd())

  if cfg.auth then
    table.insert(cmd, "-u")
    table.insert(cmd, cfg.auth.username .. ":" .. cfg.auth.password)
  end

  if opts.body then
    table.insert(cmd, "-H")
    table.insert(cmd, "Content-Type: application/json")
    table.insert(cmd, "-d")
    table.insert(cmd, vim.json.encode(opts.body))
  end

  if opts.timeout then
    table.insert(cmd, "--max-time")
    table.insert(cmd, tostring(opts.timeout))
  end

  table.insert(cmd, url)

  local result = vim.system(cmd, { text = true }):wait()

  if result.code ~= 0 then
    return "curl failed (exit " .. result.code .. "): " .. (result.stderr or "")
  end

  local output = result.stdout or ""
  local lines = vim.split(output, "\n", { trimempty = true })
  if #lines == 0 then
    return "empty response"
  end

  local status_code = tonumber(lines[#lines])
  table.remove(lines, #lines)
  local body_str = table.concat(lines, "\n")

  local body
  if body_str ~= "" then
    local ok, decoded = pcall(vim.json.decode, body_str)
    body = ok and decoded or body_str
  end

  return nil, { status = status_code or 0, body = body }
end

-- Convenience wrappers

function M.get(path, callback)
  M.request("GET", path, nil, callback)
end

function M.post(path, body, callback)
  M.request("POST", path, { body = body }, callback)
end

function M.patch(path, body, callback)
  M.request("PATCH", path, { body = body }, callback)
end

function M.delete(path, callback)
  M.request("DELETE", path, nil, callback)
end

-- Domain-specific wrappers

function M.health(callback)
  M.request("GET", "/global/health", { timeout = 2 }, callback)
end

function M.get_sessions(callback)
  M.get("/session", callback)
end

function M.get_session(session_id, callback)
  M.get("/session/" .. session_id, callback)
end

---Create a new session
---@param opts? {title?: string}
---@param callback fun(err?: string, session_id?: string)
function M.create_session(opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  M.request("POST", "/session", { body = opts }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 or not response.body or not response.body.id then
      callback("unexpected response from /session: " .. vim.inspect(response))
      return
    end
    callback(nil, response.body.id)
  end)
end

---@param session_id string
function M.delete_session(session_id)
  M.request("DELETE", "/session/" .. session_id, nil, function() end)
end

---Send a prompt asynchronously (returns 204, results stream via SSE)
---@param session_id string
---@param parts table[] array of PromptInput parts ({type:"text", text:...}, etc.)
---@param opts? {model?: {providerID: string, modelID: string}, agent?: string}
---@param callback fun(err?: string)
function M.prompt_async(session_id, parts, opts, callback)
  if type(opts) == "function" then
    callback = opts
    opts = nil
  end
  local body = { parts = parts }
  if opts then
    if opts.model then body.model = opts.model end
    if opts.agent then body.agent = opts.agent end
  end
  M.request("POST", "/session/" .. session_id .. "/prompt_async", { body = body }, function(err, response)
    if err then
      callback(err)
      return
    end
    if response and response.status ~= 204 and response.status ~= 200 then
      callback("unexpected status " .. tostring(response.status))
      return
    end
    callback(nil)
  end)
end

---Send a blocking message (waits for full response)
---@param session_id string
---@param text string
---@param callback fun(err?: string)
function M.send_message(session_id, text, callback)
  M.request(
    "POST",
    "/session/" .. session_id .. "/message",
    { body = { parts = { { type = "text", text = text } } }, timeout = 120 },
    function(err, response)
      if err then
        callback(err)
        return
      end
      if not response or (response.status ~= 200 and response.status ~= 204) then
        callback("unexpected status " .. tostring(response and response.status))
        return
      end
      callback(nil)
    end
  )
end

---Get messages for a session
---@param session_id string
---@param callback fun(err?: string, messages?: table[])
function M.get_messages(session_id, callback)
  M.get("/session/" .. session_id .. "/message?limit=100", function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("unexpected status " .. tostring(response and response.status))
      return
    end
    callback(nil, response.body or {})
  end)
end

---Abort a running session
---@param session_id string
---@param callback fun(err?: string)
function M.abort_session(session_id, callback)
  M.post("/session/" .. session_id .. "/abort", nil, function(err)
    if err then
      callback(err)
      return
    end
    callback(nil)
  end)
end

function M.reply_permission(request_id, reply, callback)
  M.post("/permission/" .. request_id .. "/reply", { reply = reply }, callback)
end

function M.reply_question(request_id, answers, callback)
  M.post("/question/" .. request_id .. "/reply", { answers = answers }, callback)
end

function M.reject_question(request_id, callback)
  M.post("/question/" .. request_id .. "/reject", nil, callback)
end

function M.get_commands(callback)
  M.get("/command", callback)
end

function M.get_agents(callback)
  M.get("/agent", callback)
end

function M.get_skills(callback)
  M.get("/skill", callback)
end

function M.get_providers(callback)
  M.get("/provider", callback)
end

-- TUI bridge endpoints

---@param text string
---@param callback fun(err?: string)
function M.append_prompt(text, callback)
  M.post("/tui/append-prompt", { text = text }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil)
  end)
end

---@param session_id string
---@param callback fun(err?: string)
function M.select_session(session_id, callback)
  M.post("/tui/select-session", { sessionID = session_id }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil)
  end)
end

---@param command string
---@param callback fun(err?: string)
function M.execute_command(command, callback)
  M.post("/tui/execute-command", { command = command }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil)
  end)
end

-- Revert endpoints

---Revert a session to a specific message
---@param session_id string
---@param message_id string
---@param callback fun(err?: string, session?: table)
function M.revert_session(session_id, message_id, callback)
  M.post("/session/" .. session_id .. "/revert", { messageID = message_id }, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil, response.body)
  end)
end

---Unrevert a session (restore reverted changes on disk)
---@param session_id string
---@param callback fun(err?: string, session?: table)
function M.unrevert_session(session_id, callback)
  M.post("/session/" .. session_id .. "/unrevert", nil, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil, response.body)
  end)
end

-- Diff endpoint

---@param session_id string
---@param message_id string
---@param callback fun(err?: string, diffs?: table[])
function M.get_diff(session_id, message_id, callback)
  M.get("/session/" .. session_id .. "/diff?messageID=" .. message_id, function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status ~= 200 then
      callback("server error: " .. tostring(response and response.status))
      return
    end
    callback(nil, response.body or {})
  end)
end

---Get branch info for a session
---@param session_id string
---@param callback fun(err?: string, branch?: {name: string, base: string, worktree: string})
function M.get_branch(session_id, callback)
  M.get("/session/" .. session_id .. "/branch", function(err, response)
    if err then
      callback(err)
      return
    end
    if not response or response.status == 404 then
      callback(nil, nil)
      return
    end
    if response.status ~= 200 then
      callback("unexpected status " .. tostring(response.status))
      return
    end
    callback(nil, response.body)
  end)
end

return M
