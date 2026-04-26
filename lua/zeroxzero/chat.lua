local client = require("zeroxzero.client")
local config = require("zeroxzero.config")
local util = require("zeroxzero.util")

local M = {}

local api = vim.api
local USER_HEADING = "## User"
local QUEUE_HEADING = "## Next message"
local LEGACY_QUEUE_HEADING = "## User (queued)"
local WORKING_LINE = "_Working... type below to queue another message._"

---@class zeroxzero.ChatMessage
---@field role "user"|"assistant"
---@field content string

---@class zeroxzero.Session
---@field id string
---@field repoRoot string
---@field provider string
---@field model string
---@field createdAt string
---@field messages zeroxzero.ChatMessage[]

---@class zeroxzero.ChangedFile
---@field path string
---@field status "added"|"modified"|"deleted"|"renamed"

---@class zeroxzero.Changes
---@field files zeroxzero.ChangedFile[]
---@field baseRef string|nil
---@field agentRef string|nil

---@class zeroxzero.ChatState
---@field bufnr integer|nil
---@field session zeroxzero.Session|nil
---@field changes zeroxzero.Changes|nil
---@field active_request string|nil
---@field queued_requests table<string, boolean>
---@field assistant_line integer|nil

---@type zeroxzero.ChatState
local state = {
  bufnr = nil,
  session = nil,
  changes = nil,
  active_request = nil,
  queued_requests = {},
  assistant_line = nil,
}

local function is_chat_buf(bufnr)
  return bufnr and api.nvim_buf_is_valid(bufnr)
end

local function set_modifiable(bufnr, value)
  vim.bo[bufnr].modifiable = value
end

local function chat_win(bufnr)
  for _, win in ipairs(api.nvim_list_wins()) do
    if api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function move_cursor_to_end(bufnr)
  local win = chat_win(bufnr)
  if win then
    api.nvim_win_set_cursor(win, { api.nvim_buf_line_count(bufnr), 0 })
  end
end

local function append(bufnr, lines)
  set_modifiable(bufnr, true)
  util.append_lines(bufnr, lines)
  move_cursor_to_end(bufnr)
end

local function set_lines(bufnr, lines)
  set_modifiable(bufnr, true)
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function assistant_heading()
  if state.session then
    return string.format("## Model: %s/%s", state.session.provider or "provider", state.session.model or "model")
  end
  return "## Model"
end

local function split_command()
  local position = config.current.chat_position or "bottom"
  if position == "top" then
    return "topleft split"
  end
  if position == "left" then
    return "topleft vertical split"
  end
  if position == "right" then
    return "botright vertical split"
  end
  return "botright split"
end

local function size_chat_window()
  local position = config.current.chat_position or "bottom"
  if position == "left" or position == "right" then
    api.nvim_win_set_width(0, math.max(40, math.floor(vim.o.columns * 0.35)))
  else
    api.nvim_win_set_height(0, math.max(12, math.floor(vim.o.lines * 0.35)))
  end
end

local function is_model_heading(line)
  return line == "## Assistant" or line == "## Model" or line:match("^## Model:") ~= nil
end

local function is_user_heading(line)
  return line == USER_HEADING or line == QUEUE_HEADING or line == LEGACY_QUEUE_HEADING
end

local function is_empty_input_heading(line)
  return line == USER_HEADING or line == QUEUE_HEADING or line == LEGACY_QUEUE_HEADING
end

local function ensure_buffer()
  if is_chat_buf(state.bufnr) then
    return state.bufnr
  end

  local bufnr = api.nvim_create_buf(false, true)
  state.bufnr = bufnr
  api.nvim_buf_set_name(bufnr, config.current.chat_buffer_name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "zeroxzero-chat"

  api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "# 0x0 Chat",
    "",
    USER_HEADING,
    "",
  })

  local submit_keys = config.current.keymaps and config.current.keymaps.submit
  if submit_keys ~= false then
    if type(submit_keys) == "string" then
      submit_keys = { submit_keys }
    end
    for _, key in ipairs(submit_keys or {}) do
      vim.keymap.set("n", key, M.submit, { buffer = bufnr, silent = true, desc = "0x0 submit chat turn" })
    end
  end
  vim.keymap.set("i", "<C-x><C-f>", function()
    local line = api.nvim_get_current_line()
    local col = api.nvim_win_get_cursor(0)[2]
    local prefix = line:sub(1, col):match("@[%w%._%-%/%~]*$")
    if not prefix then
      return
    end
    vim.fn.complete(col - #prefix + 1, util.file_candidates(prefix))
  end, { buffer = bufnr, silent = true, desc = "0x0 complete file reference" })

  return bufnr
end

local function render_session(bufnr)
  local lines = {
    "# 0x0 Chat",
    "",
  }

  if state.session then
    table.insert(
      lines,
      string.format(
        "_Session %s (%s/%s)._",
        state.session.id,
        state.session.provider or "provider",
        state.session.model or "model"
      )
    )
    table.insert(lines, "")
  end

  local messages = state.session and state.session.messages or {}
  for _, message in ipairs(messages) do
    if message.role == "user" then
      table.insert(lines, USER_HEADING)
    else
      table.insert(lines, assistant_heading())
    end
    table.insert(lines, "")
    for _, line in ipairs(util.split_lines(message.content or "")) do
      table.insert(lines, line)
    end
    table.insert(lines, "")
  end

  table.insert(lines, USER_HEADING)
  table.insert(lines, "")
  set_lines(bufnr, lines)
end

local function remove_existing_change_summary(bufnr)
  local existing = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index = #existing, 1, -1 do
    if existing[index] == "## Changes" then
      local start = index
      if existing[index - 1] == "" then
        start = index - 1
      end
      set_modifiable(bufnr, true)
      api.nvim_buf_set_lines(bufnr, start - 1, #existing, false, {})
      return
    end
  end
end

local function remove_empty_trailing_input(bufnr)
  local existing = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local heading = nil
  if is_empty_input_heading(existing[#existing - 1]) and existing[#existing] == "" then
    heading = #existing - 1
  elseif is_empty_input_heading(existing[#existing]) then
    heading = #existing
  end
  if not heading then
    return false
  end

  local start = heading
  if existing[heading - 1] == "" and existing[heading - 2] == WORKING_LINE and existing[heading - 3] == "" then
    start = heading - 3
  end

  set_modifiable(bufnr, true)
  api.nvim_buf_set_lines(bufnr, start - 1, #existing, false, {})
  return true
end

local function append_user_prompt(bufnr)
  append(bufnr, { "", USER_HEADING, "" })
end

local function append_working_prompt(bufnr)
  append(bufnr, { "", WORKING_LINE, "", QUEUE_HEADING, "" })
end

local function current_prompt(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start = nil

  for i = #lines, 1, -1 do
    if is_user_heading(lines[i]) then
      start = i + 1
      break
    end
    if is_model_heading(lines[i]) then
      break
    end
  end

  if not start then
    return nil
  end

  local prompt_lines = {}
  for i = start, #lines do
    table.insert(prompt_lines, lines[i])
  end

  local prompt = table.concat(prompt_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" then
    return nil
  end
  return prompt
end

local function append_change_summary(message)
  state.changes = {
    files = message.files or {},
    baseRef = message.baseRef,
    agentRef = message.agentRef,
  }

  if not is_chat_buf(state.bufnr) then
    return
  end

  remove_existing_change_summary(state.bufnr)
  remove_empty_trailing_input(state.bufnr)

  local lines = { "", "## Changes" }
  if #state.changes.files == 0 then
    table.insert(lines, "No file changes.")
  else
    for _, file in ipairs(state.changes.files) do
      table.insert(lines, string.format("- %s %s", file.status or "modified", file.path or ""))
    end
    table.insert(lines, "")
    table.insert(lines, "Actions: :ZeroReview, :ZeroAcceptAll, :ZeroDiscardAll")
  end
  table.insert(lines, "")
  append(state.bufnr, lines)

  if state.active_request or next(state.queued_requests) ~= nil then
    append_working_prompt(state.bufnr)
  else
    append_user_prompt(state.bufnr)
  end
end

local function ensure_next_prompt(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, math.max(1, #lines - 3), -1 do
    if is_user_heading(lines[i]) then
      return
    end
  end
  append_user_prompt(bufnr)
end

local function clear_empty_trailing_prompt(bufnr)
  remove_empty_trailing_input(bufnr)
end

local function has_queued_requests()
  return next(state.queued_requests) ~= nil
end

local function begin_assistant_response(bufnr, request_id)
  clear_empty_trailing_prompt(bufnr)
  append(bufnr, { "", assistant_heading(), "" })
  state.active_request = request_id
  state.assistant_line = api.nvim_buf_line_count(bufnr)
  append_working_prompt(bufnr)
end

local function normalize_queued_prompt(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index = #lines, 1, -1 do
    if lines[index] == QUEUE_HEADING or lines[index] == LEGACY_QUEUE_HEADING then
      local prompt = table.concat(vim.list_slice(lines, index + 1), "\n"):gsub("^%s+", ""):gsub("%s+$", "")
      if prompt == "" then
        remove_empty_trailing_input(bufnr)
        ensure_next_prompt(bufnr)
        return
      end

      set_modifiable(bufnr, true)
      if lines[index - 1] == "" and lines[index - 2] == WORKING_LINE and lines[index - 3] == "" then
        api.nvim_buf_set_lines(bufnr, index - 4, index, false, { USER_HEADING })
      else
        api.nvim_buf_set_lines(bufnr, index - 1, index, false, { USER_HEADING })
      end
      return
    end
    if lines[index] == USER_HEADING or is_model_heading(lines[index]) then
      return
    end
  end
end

local function mark_latest_queued_prompt_submitted(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for index = #lines, 1, -1 do
    if lines[index] == QUEUE_HEADING or lines[index] == LEGACY_QUEUE_HEADING then
      set_modifiable(bufnr, true)
      api.nvim_buf_set_lines(bufnr, index - 1, index, false, { USER_HEADING })
      append_working_prompt(bufnr)
      return
    end
  end
end

local function send_turn(prompt)
  local bufnr = ensure_buffer()

  local request_id = nil
  begin_assistant_response(bufnr, request_id)

  request_id = client.request({
    type = "chat.turn",
    sessionId = state.session.id,
    prompt = prompt,
  }, {
    keep = true,
    done_grace_ms = 5000,
    close_on_changes = true,
    ["assistant.delta"] = function(message)
      if not is_chat_buf(bufnr) then
        return
      end
      set_modifiable(bufnr, true)
      local line = state.assistant_line or api.nvim_buf_line_count(bufnr)
      local current = api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
      local chunks = util.split_lines(message.text or "")
      if #chunks == 0 then
        return
      end
      chunks[1] = current .. chunks[1]
      api.nvim_buf_set_lines(bufnr, line - 1, line, false, chunks)
      state.assistant_line = line + #chunks - 1
      move_cursor_to_end(bufnr)
    end,
    ["assistant.done"] = function(message)
      state.active_request = nil
      state.assistant_line = nil
      if state.session then
        state.session.messages = message.messages or state.session.messages
      end
      if message.summary and message.summary ~= "" then
        append(bufnr, { "", "_Summary: " .. message.summary .. "_" })
      end
      vim.defer_fn(function()
        if is_chat_buf(bufnr) then
          if not has_queued_requests() then
            normalize_queued_prompt(bufnr)
            ensure_next_prompt(bufnr)
          end
        end
      end, 100)
    end,
    ["user.queued"] = function(message)
      if state.session then
        state.session.messages = message.messages or state.session.messages
      end
      mark_latest_queued_prompt_submitted(bufnr)
    end,
    ["changes.updated"] = append_change_summary,
    ["cancelled"] = function()
      state.active_request = nil
      state.assistant_line = nil
      normalize_queued_prompt(bufnr)
      ensure_next_prompt(bufnr)
    end,
    ["run.status"] = function(message)
      vim.b[bufnr].zeroxzero_status = message.status
    end,
    on_error = function(err)
      state.active_request = nil
      state.assistant_line = nil
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
  state.active_request = request_id
end

local function send_queued_turn(prompt)
  local bufnr = ensure_buffer()
  local started = false
  local request_id = nil

  local function ensure_started()
    if started or not is_chat_buf(bufnr) then
      return
    end
    started = true
    state.queued_requests[request_id] = nil
    begin_assistant_response(bufnr, request_id)
  end

  request_id = client.request({
    type = "chat.turn",
    sessionId = state.session.id,
    prompt = prompt,
  }, {
    keep = true,
    done_grace_ms = 5000,
    close_on_changes = true,
    ["user.queued"] = function(message)
      state.queued_requests[request_id] = true
      if state.session then
        state.session.messages = message.messages or state.session.messages
      end
      mark_latest_queued_prompt_submitted(bufnr)
    end,
    ["assistant.delta"] = function(message)
      ensure_started()
      if not is_chat_buf(bufnr) then
        return
      end
      set_modifiable(bufnr, true)
      local line = state.assistant_line or api.nvim_buf_line_count(bufnr)
      local current = api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
      local chunks = util.split_lines(message.text or "")
      if #chunks == 0 then
        return
      end
      chunks[1] = current .. chunks[1]
      api.nvim_buf_set_lines(bufnr, line - 1, line, false, chunks)
      state.assistant_line = line + #chunks - 1
      move_cursor_to_end(bufnr)
    end,
    ["assistant.done"] = function(message)
      ensure_started()
      state.active_request = nil
      state.assistant_line = nil
      state.queued_requests[request_id] = nil
      if state.session then
        state.session.messages = message.messages or state.session.messages
      end
      if message.summary and message.summary ~= "" then
        append(bufnr, { "", "_Summary: " .. message.summary .. "_" })
      end
      vim.defer_fn(function()
        if is_chat_buf(bufnr) and not has_queued_requests() then
          normalize_queued_prompt(bufnr)
          ensure_next_prompt(bufnr)
        end
      end, 100)
    end,
    ["changes.updated"] = append_change_summary,
    ["cancelled"] = function()
      state.active_request = nil
      state.assistant_line = nil
      state.queued_requests[request_id] = nil
      normalize_queued_prompt(bufnr)
      ensure_next_prompt(bufnr)
    end,
    ["run.status"] = function(message)
      vim.b[bufnr].zeroxzero_status = message.status
    end,
    on_error = function(err)
      state.queued_requests[request_id] = nil
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
  state.queued_requests[request_id] = true
end

local function create_session(prompt)
  local root = util.repo_root(0)
  state.active_request = client.request({
    type = "session.create",
    repoRoot = root,
    provider = config.current.provider,
    model = config.current.model,
    effort = config.current.effort,
  }, {
    ["session.created"] = function(message)
      state.session = message.session
      state.active_request = nil
      send_turn(prompt)
    end,
    on_error = function(err)
      state.active_request = nil
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

function M.open()
  local bufnr = ensure_buffer()
  local existing = chat_win(bufnr)
  if existing then
    api.nvim_set_current_win(existing)
  else
    vim.cmd(split_command())
    api.nvim_win_set_buf(0, bufnr)
    size_chat_window()
  end
  api.nvim_buf_call(bufnr, function()
    vim.cmd("normal! G")
  end)
end

function M.move(position)
  if position ~= "bottom" and position ~= "top" and position ~= "left" and position ~= "right" then
    util.notify("Chat position must be one of: bottom, top, left, right", vim.log.levels.WARN)
    return
  end

  config.current.chat_position = position
  local bufnr = ensure_buffer()
  local win = chat_win(bufnr)
  if not win then
    M.open()
    return
  end

  api.nvim_set_current_win(win)
  local command = ({ bottom = "wincmd J", top = "wincmd K", left = "wincmd H", right = "wincmd L" })[position]
  vim.cmd(command)
  size_chat_window()
end

function M.new()
  if state.session and state.active_request then
    client.notify({
      type = "run.cancel",
      id = state.active_request,
      sessionId = state.session.id,
    })
  end
  state.session = nil
  state.changes = nil
  state.active_request = nil
  state.queued_requests = {}
  state.assistant_line = nil
  if is_chat_buf(state.bufnr) then
    api.nvim_buf_delete(state.bufnr, { force = true })
  end
  state.bufnr = nil
  M.open()
end

function M.open_session(session_id)
  if not session_id or session_id == "" then
    util.notify("Pass a session id to :ZeroChatOpen", vim.log.levels.WARN)
    return
  end

  client.request({
    type = "session.open",
    sessionId = session_id,
  }, {
    keep = true,
    done_grace_ms = 5000,
    close_on_changes = true,
    ["session.created"] = function(message)
      state.session = message.session
      local bufnr = ensure_buffer()
      render_session(bufnr)
      M.open()
    end,
    ["changes.updated"] = append_change_summary,
    on_error = function(err)
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

function M.submit()
  local bufnr = ensure_buffer()

  local prompt = current_prompt(bufnr)
  if not prompt then
    util.notify("Write a prompt under the last ## User heading first", vim.log.levels.WARN)
    return
  end

  if state.session and (state.active_request or has_queued_requests()) then
    send_queued_turn(prompt)
  elseif state.session then
    send_turn(prompt)
  else
    create_session(prompt)
  end
end

function M.cancel()
  if not state.session or not state.active_request then
    return
  end
  client.notify({
    type = "run.cancel",
    id = state.active_request,
    sessionId = state.session.id,
  })
end

---@return zeroxzero.Session|nil
function M.session()
  return state.session
end

---@return zeroxzero.Changes|nil
function M.changes()
  return state.changes
end

---@param changes zeroxzero.Changes|nil
function M.set_changes(changes)
  state.changes = changes
end

return M
