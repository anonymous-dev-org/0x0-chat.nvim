local config = require("zeroxzero.config")
local api = require("zeroxzero.api")
local render = require("zeroxzero.render")
local server = require("zeroxzero.server")

local M = {}

---@type integer? chat buffer number
M._buf = nil
---@type integer? chat window id
M._win = nil
---@type string? active session id
M._session_id = nil
---@type zeroxzero.RenderState?
M._state = nil
---@type table<string, boolean> message IDs we're tracking (sent via prompt_async)
M._tracked_messages = {}
---@type boolean whether the user has scrolled up (disables auto-scroll)
M._user_scrolled = false
---@type {providerID: string, modelID: string}? override model for next prompt
M._model = nil
---@type string? override agent for next prompt
M._agent = nil
---@type table[]? cached agent list from server
M._agents = nil
---@type integer agent cycle index (0 = default, 1..N = specific agent)
M._agent_idx = 0
---@type string[]? context files to include in next prompt
M._context_files = nil

---Create the chat buffer if it doesn't exist
---@return integer buf
local function ensure_buf()
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    return M._buf
  end

  M._buf = vim.api.nvim_create_buf(false, true)
  vim.bo[M._buf].buftype = "nofile"
  vim.bo[M._buf].bufhidden = "hide"
  vim.bo[M._buf].swapfile = false
  vim.bo[M._buf].modifiable = true

  M._state = render.new_state(M._buf)

  -- Buffer-local keymaps
  local buf = M._buf
  vim.keymap.set("n", "q", function() M.close() end, { buffer = buf, desc = "Close chat" })
  vim.keymap.set("n", "<CR>", function() M.prompt() end, { buffer = buf, desc = "New prompt" })
  vim.keymap.set("n", "<C-c>", function() M.interrupt() end, { buffer = buf, desc = "Interrupt" })
  vim.keymap.set("n", "<Tab>", function() M._cycle_agent(1) end, { buffer = buf, desc = "Next agent" })
  vim.keymap.set("n", "<S-Tab>", function() M._cycle_agent(-1) end, { buffer = buf, desc = "Previous agent" })

  -- Track scroll position for auto-scroll
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if not M._win or not vim.api.nvim_win_is_valid(M._win) then
        return
      end
      local total = vim.api.nvim_buf_line_count(buf)
      local cursor = vim.api.nvim_win_get_cursor(M._win)
      M._user_scrolled = cursor[1] < total - 2
    end,
  })

  return buf
end

---Open the floating chat window
local function open_window()
  local buf = ensure_buf()
  local chat = config.current.chat
  local ui = vim.api.nvim_list_uis()[1] or { width = 80, height = 24 }

  local w = chat.width < 1 and math.floor(ui.width * chat.width) or math.floor(chat.width)
  local h = chat.height < 1 and math.floor(ui.height * chat.height) or math.floor(chat.height)
  local row = math.floor((ui.height - h) / 2)
  local col = math.floor((ui.width - w) / 2)

  M._win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = w,
    height = h,
    row = row,
    col = col,
    style = "minimal",
    border = chat.border,
    title = M._session_title(),
    title_pos = "center",
  })

  vim.wo[M._win].wrap = true
  vim.wo[M._win].linebreak = true
  vim.wo[M._win].cursorline = true
  render.setup_folds(buf)

  -- Go to end
  local total = vim.api.nvim_buf_line_count(buf)
  vim.api.nvim_win_set_cursor(M._win, { total, 0 })
  M._user_scrolled = false
end

---Get the window title
---@return string
function M._session_title()
  local title = " 0x0 "
  if M._session_id then
    title = title .. "| " .. M._session_id:sub(1, 12) .. " "
  end
  if M._agent then
    title = title .. "| " .. M._agent .. " "
  end
  return title
end

---Update the window title to reflect current state
local function refresh_title()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_set_config(M._win, { title = M._session_title(), title_pos = "center" })
  end
end

---Cycle through agents
---@param direction integer 1 for next, -1 for previous
function M._cycle_agent(direction)
  local function do_cycle()
    if not M._agents or #M._agents == 0 then
      vim.notify("0x0: no agents available", vim.log.levels.WARN)
      return
    end

    local count = #M._agents
    M._agent_idx = (M._agent_idx + direction) % (count + 1)

    if M._agent_idx == 0 then
      M._agent = nil
      vim.notify("0x0: agent: default", vim.log.levels.INFO)
    else
      local agent = M._agents[M._agent_idx]
      M._agent = agent.name
      vim.notify("0x0: agent: " .. (agent.displayName or agent.name), vim.log.levels.INFO)
    end

    refresh_title()
  end

  if M._agents then
    do_cycle()
    return
  end

  api.get_agents(function(err, response)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    local agents = response and response.body or {}
    M._agents = {}
    for _, agent in ipairs(agents) do
      if not agent.hidden then
        table.insert(M._agents, agent)
      end
    end
    do_cycle()
  end)
end

---Auto-scroll to bottom if the user hasn't scrolled up
function M._auto_scroll()
  if M._user_scrolled then
    return
  end
  if not M._win or not vim.api.nvim_win_is_valid(M._win) then
    return
  end
  if not M._buf or not vim.api.nvim_buf_is_valid(M._buf) then
    return
  end
  local total = vim.api.nvim_buf_line_count(M._buf)
  vim.api.nvim_win_set_cursor(M._win, { total, 0 })
end

-- Public API

function M.open()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    render.setup_highlights()
    if not M._session_id then
      M._create_session(function()
        open_window()
      end)
    else
      open_window()
    end
  end)
end

function M.close()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    vim.api.nvim_win_close(M._win, false)
    M._win = nil
  end
end

function M.toggle()
  if M._win and vim.api.nvim_win_is_valid(M._win) then
    M.close()
  else
    M.open()
  end
end

---Open prompt input via vim.ui.input
---@param opts? {default?: string}
function M.prompt(opts)
  opts = opts or {}
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    vim.ui.input({
      prompt = "0x0> ",
      default = opts.default or "",
    }, function(input)
      if not input or input == "" then
        return
      end
      M.send(input)
    end)
  end)
end

---Send a message to the current session
---@param text string
function M.send(text)
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    if not M._session_id then
      M._create_session(function()
        M._send_impl(text)
      end)
    else
      M._send_impl(text)
    end
  end)
end

---@param text string
function M._send_impl(text)
  render.setup_highlights()
  local state = M._state
  if not state then
    ensure_buf()
    state = M._state
  end

  -- Render user message in buffer
  render.user_header(state)
  render.user_text(state, text)
  M._auto_scroll()

  -- Build parts
  local parts = {}

  -- Add context files if any
  if M._context_files then
    for _, ref in ipairs(M._context_files) do
      table.insert(parts, { type = "text", text = ref })
    end
    M._context_files = nil
  end

  table.insert(parts, { type = "text", text = text })

  -- Build opts
  local prompt_opts = {}
  if M._model then
    prompt_opts.model = M._model
    M._model = nil
  end
  if M._agent then
    prompt_opts.agent = M._agent
    M._agent = nil
    M._agent_idx = 0
    refresh_title()
  end

  api.prompt_async(M._session_id, parts, prompt_opts, function(send_err)
    if send_err then
      render.error_message(state, send_err)
      M._auto_scroll()
    end
  end)
end

---Interrupt the current session
function M.interrupt()
  if not M._session_id then
    return
  end
  api.abort_session(M._session_id, function(err)
    if err then
      vim.notify("0x0: abort failed: " .. err, vim.log.levels.ERROR)
    end
  end)
end

---Create a new session
---@param callback? fun()
function M._create_session(callback)
  api.create_session(function(err, session_id)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    M._session_id = session_id
    if callback then
      callback()
    end
  end)
end

---Switch to a different session and load its history
---@param session_id string
function M.switch_session(session_id)
  M._session_id = session_id
  M._tracked_messages = {}

  -- Reset buffer
  if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
    vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, { "" })
    M._state = render.new_state(M._buf)
  end

  -- Load history
  api.get_messages(session_id, function(err, messages)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    local state = M._state
    if not state then
      return
    end

    render.setup_highlights()

    for _, msg in ipairs(messages or {}) do
      local info = msg.info
      local msg_parts = msg.parts or {}

      if info.role == "user" then
        render.user_header(state)
        for _, p in ipairs(msg_parts) do
          if p.type == "text" then
            render.user_text(state, p.text or "")
          end
        end
      elseif info.role == "assistant" then
        render.assistant_header(state, info.id, info.modelID)
        for _, p in ipairs(msg_parts) do
          if p.type == "text" then
            render.text_delta(state, p, nil)
          elseif p.type == "tool" then
            render.tool_update(state, p)
          elseif p.type == "reasoning" then
            render.reasoning_delta(state, p, nil)
          end
        end
        if info.error then
          local error_msg = info.error.properties and info.error.properties.message or info.error.name or "unknown error"
          render.error_message(state, error_msg)
        end
      end
    end

    -- Fold completed tools
    if config.current.chat.fold_tools and M._win and vim.api.nvim_win_is_valid(M._win) then
      vim.api.nvim_win_call(M._win, function()
        pcall(vim.cmd, "normal! zM")
      end)
    end

    M._auto_scroll()

    -- Update window title
    if M._win and vim.api.nvim_win_is_valid(M._win) then
      vim.api.nvim_win_set_config(M._win, { title = M._session_title(), title_pos = "center" })
    end
  end)
end

---Create a new session and clear the buffer
---@param callback? fun()
function M.new_session(callback)
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    M._create_session(function()
      if M._buf and vim.api.nvim_buf_is_valid(M._buf) then
        vim.api.nvim_buf_set_lines(M._buf, 0, -1, false, { "" })
        M._state = render.new_state(M._buf)
      end
      if M._win and vim.api.nvim_win_is_valid(M._win) then
        vim.api.nvim_win_set_config(M._win, { title = M._session_title(), title_pos = "center" })
      end
      if callback then
        callback()
      end
    end)
  end)
end

---Add a file reference to the next prompt context
---@param ref string file reference like @path.ts#L5-L10
function M.add_context(ref)
  if not M._context_files then
    M._context_files = {}
  end
  table.insert(M._context_files, ref)
  vim.notify("0x0: added " .. ref, vim.log.levels.INFO)
end

---Set model for next prompt
---@param model {providerID: string, modelID: string}
function M.set_model(model)
  M._model = model
end

---Set agent for next prompt
---@param agent string
function M.set_agent(agent)
  M._agent = agent
end

-- SSE event handlers (called from sse.lua)

---@param props table {part: MessageV2.Part, delta?: string}
function M._on_part_updated(props)
  local part = props.part
  if not part then
    return
  end

  -- Only handle events for our active session
  if part.sessionID and part.sessionID ~= M._session_id then
    return
  end

  local state = M._state
  if not state or not vim.api.nvim_buf_is_valid(state.buf) then
    return
  end

  -- If we see a message we haven't rendered a header for, add one
  if part.messageID and not state.message_lines[part.messageID] then
    render.assistant_header(state, part.messageID, nil)
  end

  if part.type == "text" then
    render.text_delta(state, part, props.delta)
  elseif part.type == "tool" then
    render.tool_update(state, part)
  elseif part.type == "reasoning" then
    render.reasoning_delta(state, part, props.delta)
  end

  M._auto_scroll()
end

---@param props table {info: MessageV2.Info}
function M._on_message_updated(props)
  local info = props.info
  if not info then
    return
  end

  if info.sessionID and info.sessionID ~= M._session_id then
    return
  end

  -- Update assistant header with model info if we have it now
  if info.role == "assistant" and info.modelID and M._state and vim.api.nvim_buf_is_valid(M._state.buf) then
    local header_line = M._state.message_lines[info.id]
    if header_line then
      local label = " Assistant (" .. info.modelID .. ")"
      local sep = string.rep("\u{2500}", 50)
      -- The header is: sep, label, sep — label is at header_line - 2 (0-indexed)
      local label_idx = header_line - 3
      if label_idx >= 0 then
        vim.api.nvim_buf_set_lines(M._buf, label_idx, label_idx + 1, false, { label })
        vim.api.nvim_buf_add_highlight(
          M._buf,
          vim.api.nvim_create_namespace("zeroxzero_chat"),
          "ZeroChatAssistant",
          label_idx,
          0,
          -1
        )
      end
    end
  end

  -- Handle errors
  if info.error then
    local state = M._state
    if state and vim.api.nvim_buf_is_valid(state.buf) then
      local error_msg = info.error.properties and info.error.properties.message or info.error.name or "unknown error"
      render.error_message(state, error_msg)
      M._auto_scroll()
    end
  end

  -- Fold completed tools when message finishes
  if info.role == "assistant" and info.time and info.time.completed then
    if config.current.chat.fold_tools and M._win and vim.api.nvim_win_is_valid(M._win) then
      vim.schedule(function()
        if M._win and vim.api.nvim_win_is_valid(M._win) then
          vim.api.nvim_win_call(M._win, function()
            pcall(vim.cmd, "normal! zM")
          end)
        end
      end)
    end
  end
end

---@param props table {sessionID?: string, error: MessageV2.Error}
function M._on_session_error(props)
  if props.sessionID and props.sessionID ~= M._session_id then
    return
  end
  local state = M._state
  if not state then
    return
  end
  local error_obj = props.error or {}
  local message = (error_obj.properties and error_obj.properties.message) or error_obj.name or "unknown error"
  render.error_message(state, message)
  M._auto_scroll()
end

return M
