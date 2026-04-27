local config = require("zeroxzero.config")
local acp_client = require("zeroxzero.acp_client")
local permission = require("zeroxzero.permission")

local M = {}
local api = vim.api

local USER_HEADING = "## User"
local ASSISTANT_HEADING_PREFIX = "## Assistant"
local BUFFER_NAME = "[0x0 Chat]"

---@class zeroxzero.ChatState
---@field bufnr integer|nil
---@field winid integer|nil
---@field client table|nil
---@field session_id string|nil
---@field provider_name string|nil
---@field model string|nil
---@field mode string|nil
---@field config_options table<string, table>
---@field assistant_line integer|nil  -- 0-indexed line currently being streamed
---@field in_flight boolean
---@field pending_permission table|nil
---@field tool_calls table<string, { mark: integer, kind: string, title: string, status: string }>
local state = {
  bufnr = nil,
  winid = nil,
  client = nil,
  session_id = nil,
  provider_name = nil,
  model = nil,
  mode = nil,
  config_options = {},
  assistant_line = nil,
  in_flight = false,
  pending_permission = nil,
  tool_calls = {},
}

local NS = api.nvim_create_namespace("zeroxzero_chat_tools")

local STATUS_ICONS = {
  pending = "·",
  in_progress = "⠋",
  completed = "✓",
  failed = "✗",
}

local function buf_valid()
  return state.bufnr and api.nvim_buf_is_valid(state.bufnr)
end

local function set_modifiable(value)
  if buf_valid() then
    vim.bo[state.bufnr].modifiable = value
  end
end

local function append_lines(lines)
  if not buf_valid() then
    return
  end
  set_modifiable(true)
  local last = api.nvim_buf_line_count(state.bufnr)
  api.nvim_buf_set_lines(state.bufnr, last, last, false, lines)
  set_modifiable(false)
end

local function find_window_for_buffer()
  if not buf_valid() then
    return nil
  end
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == state.bufnr then
      return win
    end
  end
  return nil
end

local function ensure_buffer()
  if buf_valid() then
    return state.bufnr
  end

  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, BUFFER_NAME)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  state.bufnr = bufnr

  api.nvim_buf_set_lines(bufnr, 0, -1, false, { USER_HEADING, "" })
  set_modifiable(true)

  vim.keymap.set("n", "<CR>", function()
    M.submit()
  end, { buffer = bufnr, desc = "Submit chat prompt" })
  vim.keymap.set("n", "<localleader>c", function()
    M.cancel()
  end, { buffer = bufnr, desc = "Cancel chat run" })

  return bufnr
end

local function ensure_window()
  local win = find_window_for_buffer()
  if win and api.nvim_win_is_valid(win) then
    state.winid = win
    return win
  end
  vim.cmd("botright vsplit")
  win = api.nvim_get_current_win()
  api.nvim_win_set_buf(win, ensure_buffer())
  api.nvim_win_set_width(win, math.max(60, math.floor(vim.o.columns * (config.current.width or 0.4))))
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  state.winid = win
  return win
end

local function assistant_heading()
  local label = state.provider_name or "assistant"
  local details = {}
  if state.mode then
    details[#details + 1] = "mode: " .. state.mode
  end
  if state.model then
    details[#details + 1] = "model: " .. state.model
  end
  if #details > 0 then
    label = label .. " | " .. table.concat(details, " | ")
  end
  return ("%s (%s)"):format(ASSISTANT_HEADING_PREFIX, label)
end

local function read_pending_prompt()
  if not buf_valid() then
    return ""
  end
  local lines = api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
  local user_line = nil
  for i = #lines, 1, -1 do
    if lines[i] == USER_HEADING then
      user_line = i
      break
    end
  end
  if not user_line then
    return ""
  end
  local prompt_lines = {}
  for i = user_line + 1, #lines do
    prompt_lines[#prompt_lines + 1] = lines[i]
  end
  return vim.trim(table.concat(prompt_lines, "\n"))
end

---@param call { kind: string, title: string, status: string }
local function format_tool_line(call)
  local icon = STATUS_ICONS[call.status] or "·"
  local title = call.title ~= "" and call.title or "(no title)"
  return ("%s %s — %s"):format(icon, call.kind, title)
end

---@param update table
local function render_tool_call(update)
  if not buf_valid() then
    return
  end
  local id = update.toolCallId
  if not id then
    return
  end

  local existing = state.tool_calls[id]
  if existing then
    existing.status = update.status or existing.status
    if update.title and update.title ~= "" then
      existing.title = update.title
    end
    if update.kind then
      existing.kind = update.kind
    end
    local pos = api.nvim_buf_get_extmark_by_id(state.bufnr, NS, existing.mark, {})
    if not pos[1] then
      return
    end
    set_modifiable(true)
    api.nvim_buf_set_lines(state.bufnr, pos[1], pos[1] + 1, false, { format_tool_line(existing) })
    set_modifiable(false)
    return
  end

  local last = api.nvim_buf_line_count(state.bufnr)
  local call = {
    kind = update.kind or "tool",
    title = update.title or "",
    status = update.status or "pending",
    mark = 0,
  }
  set_modifiable(true)
  api.nvim_buf_set_lines(state.bufnr, last, last, false, { format_tool_line(call) })
  set_modifiable(false)
  call.mark = api.nvim_buf_set_extmark(state.bufnr, NS, last, 0, {})
  state.tool_calls[id] = call
  state.assistant_line = nil
end

---@param text string
local function append_chunk(text)
  if not buf_valid() then
    return
  end
  set_modifiable(true)
  if not state.assistant_line then
    local last = api.nvim_buf_line_count(state.bufnr)
    api.nvim_buf_set_lines(state.bufnr, last, last, false, { "" })
    state.assistant_line = last
  end
  local line = state.assistant_line
  local current = api.nvim_buf_get_lines(state.bufnr, line, line + 1, false)[1] or ""
  local pieces = vim.split(text, "\n", { plain = true })
  pieces[1] = current .. pieces[1]
  api.nvim_buf_set_lines(state.bufnr, line, line + 1, false, pieces)
  state.assistant_line = line + #pieces - 1
  set_modifiable(false)
end

local function open_for_next_prompt()
  append_lines({ "", USER_HEADING, "" })
  state.assistant_line = nil
  state.in_flight = false
end

local function reset_session()
  if state.pending_permission then
    pcall(state.pending_permission.unmap)
    state.pending_permission = nil
  end
  if state.client and state.session_id then
    state.client:cancel(state.session_id)
    state.client:unsubscribe(state.session_id)
  end
  if state.client then
    state.client:stop()
  end
  state.client = nil
  state.session_id = nil
  state.assistant_line = nil
  state.in_flight = false
  state.tool_calls = {}
  state.config_options = {}
end

local function set_config_options(options)
  state.config_options = {}
  if type(options) ~= "table" then
    return
  end

  for _, option in ipairs(options) do
    local category = type(option.category) == "string" and option.category or ""
    if category == "mode" or category == "model" then
      state.config_options[category] = option
      if category == "mode" then
        state.mode = option.currentValue or state.mode
      elseif category == "model" then
        state.model = option.currentValue or state.model
      end
    end
  end
end

local function set_session_options(result)
  if type(result) ~= "table" then
    set_config_options(nil)
    return
  end

  set_config_options(result.configOptions)
end

local function option_has_value(option, value)
  if not option or not option.options then
    return false
  end
  for _, item in ipairs(option.options) do
    if item.value == value then
      return true
    end
  end
  return false
end

local function set_config_value(category, value)
  if category == "mode" then
    state.mode = value
  elseif category == "model" then
    state.model = value
  end

  local option = state.config_options[category]
  if option then
    option.currentValue = value
  end
end

local function apply_config_option(category, value, callback)
  if not state.client or not state.session_id then
    callback(false)
    return
  end

  local session_id = state.session_id
  local option = state.config_options[category]
  if option and option_has_value(option, value) then
    state.client:set_config_option(session_id, category, value, function(result, err)
      if state.session_id ~= session_id then
        return
      end
      if err then
        vim.notify(("acp: set %s failed: %s"):format(category, err.message or vim.inspect(err)), vim.log.levels.ERROR)
        callback(false)
        return
      end
      if result and result.configOptions then
        set_config_options(result.configOptions)
      end
      set_config_value(category, value)
      callback(true)
    end)
    return
  end

  if category == "model" and not state.config_options.model then
    state.client:set_model(session_id, value, function(result, err)
      if state.session_id ~= session_id then
        return
      end
      if err then
        vim.notify("acp: set model failed: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
        callback(false)
        return
      end
      if result and result.configOptions then
        set_config_options(result.configOptions)
      end
      state.model = value
      callback(true)
    end)
    return
  end

  vim.notify("acp: " .. category .. " is not available for this provider/session", vim.log.levels.WARN)
  callback(false)
end

local function apply_initial_session_config(client, session_id, desired, done)
  local function set_model()
    if desired.model then
      apply_config_option("model", desired.model, function()
        done(client, session_id)
      end)
    else
      done(client, session_id)
    end
  end

  if desired.mode and option_has_value(state.config_options.mode, desired.mode) then
    apply_config_option("mode", desired.mode, set_model)
  else
    set_model()
  end
end

---@param on_ready fun(client: table|nil, err: table|nil)
local function ensure_client(on_ready)
  local provider_name = state.provider_name or config.current.provider
  if state.client and state.provider_name == provider_name and state.client:is_ready() then
    on_ready(state.client, nil)
    return
  end

  local provider, perr = config.resolve_provider(provider_name)
  if not provider then
    vim.notify(perr, vim.log.levels.ERROR)
    on_ready(nil, { message = perr })
    return
  end

  if state.client then
    state.client:stop()
  end
  state.provider_name = provider_name
  state.client = acp_client.new(provider)
  state.client:start(function(c, err)
    on_ready(c, err)
  end)
end

---@param on_session fun(client: table|nil, session_id: string|nil, err: table|nil)
local function ensure_session(on_session)
  ensure_client(function(client, cerr)
    if cerr or not client then
      on_session(nil, nil, cerr or { message = "client unavailable" })
      return
    end
    if state.session_id then
      on_session(client, state.session_id, nil)
      return
    end
    local desired = {
      mode = state.mode,
      model = state.model,
    }
    client:new_session(vim.fn.getcwd(), function(result, err)
      if state.client ~= client then
        on_session(nil, nil, { message = "client replaced" })
        return
      end
      if err or not result or not result.sessionId then
        vim.notify("acp: session/new failed: " .. vim.inspect(err), vim.log.levels.ERROR)
        on_session(nil, nil, err or { message = "session/new failed" })
        return
      end
      state.session_id = result.sessionId
      set_session_options(result)

      client:subscribe(result.sessionId, {
        on_update = function(update)
          local kind = update.sessionUpdate
          if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
            local text = update.content and update.content.text or ""
            if text ~= "" then
              vim.schedule(function()
                append_chunk(text)
              end)
            end
          elseif kind == "tool_call" or kind == "tool_call_update" then
            vim.schedule(function()
              render_tool_call(update)
            end)
          elseif kind == "config_option_update" then
            vim.schedule(function()
              set_config_options(update.configOptions)
            end)
          end
        end,
        on_request_permission = function(request, respond)
          vim.schedule(function()
            if state.pending_permission then
              respond("reject_once")
              return
            end
            local pending = permission.render(state.bufnr, request, function(option_id)
              state.pending_permission = nil
              respond(option_id)
            end)
            if pending then
              state.pending_permission = pending
              state.assistant_line = nil
            else
              respond("reject_once")
            end
          end)
        end,
      })

      apply_initial_session_config(client, result.sessionId, desired, function(c, sid)
        on_session(c, sid, nil)
      end)
    end)
  end)
end

function M.open()
  ensure_buffer()
  ensure_window()
end

function M.new()
  reset_session()
  if buf_valid() then
    set_modifiable(true)
    api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { USER_HEADING, "" })
    set_modifiable(false)
  end
  M.open()
end

function M.submit()
  ensure_buffer()
  if state.in_flight then
    vim.notify("acp: prompt already in flight", vim.log.levels.WARN)
    return
  end
  local prompt = read_pending_prompt()
  if prompt == "" then
    vim.notify("acp: empty prompt", vim.log.levels.WARN)
    return
  end

  state.in_flight = true
  append_lines({ "", assistant_heading(), "" })
  state.assistant_line = api.nvim_buf_line_count(state.bufnr) - 1

  ensure_session(function(client, session_id, sess_err)
    if sess_err or not client or not session_id then
      vim.schedule(function()
        local msg = sess_err and (sess_err.message or vim.inspect(sess_err)) or "failed to start session"
        append_lines({ "", "_error: " .. msg .. "_" })
        open_for_next_prompt()
      end)
      return
    end
    client:prompt(session_id, { { type = "text", text = prompt } }, function(result, err)
      vim.schedule(function()
        if err then
          local msg = type(err) == "table" and (err.message or vim.inspect(err)) or tostring(err)
          append_lines({ "", "_error: " .. msg .. "_" })
        elseif result and result.stopReason and result.stopReason ~= "end_turn" then
          append_lines({ "", "_stopped: " .. tostring(result.stopReason) .. "_" })
        end
        open_for_next_prompt()
      end)
    end)
  end)
end

function M.cancel()
  if state.client and state.session_id and state.in_flight then
    state.client:cancel(state.session_id)
  end
end

function M.stop()
  reset_session()
  state.assistant_line = nil
end

---@return { provider: string, model: string|nil }
function M.current_settings()
  return {
    provider = state.provider_name or config.current.provider,
    model = state.model,
    mode = state.mode,
    config_options = state.config_options,
  }
end

---@param name string
function M.set_provider(name)
  reset_session()
  state.provider_name = name
  state.model = nil
  state.mode = nil
end

---@param model string|nil
function M.set_model(model)
  state.model = model
  if state.client and state.session_id then
    apply_config_option("model", model, function() end)
  end
end

---@param mode string|nil
function M.set_mode(mode)
  state.mode = mode
  if state.client and state.session_id then
    apply_config_option("mode", mode, function() end)
  end
end

function M.discover_options(callback)
  ensure_session(function()
    if callback then
      callback(M.current_settings())
    end
  end)
end

function M.option_items(category)
  local items = {}
  local option = state.config_options[category]
  if option and option.options then
    for _, item in ipairs(option.options) do
      items[#items + 1] = {
        value = item.value,
        name = item.name or item.value,
        description = item.description,
        current = item.value == option.currentValue,
      }
    end
    return items
  end

  return items
end

function M.has_config_option(category)
  return state.config_options[category] ~= nil
end

return M
