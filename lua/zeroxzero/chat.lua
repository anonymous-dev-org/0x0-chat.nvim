local config = require("zeroxzero.config")
local acp_client = require("zeroxzero.acp_client")
local History = require("zeroxzero.history")
local HistoryStore = require("zeroxzero.history_store")
local ChatWidget = require("zeroxzero.chat_widget")
local ReferenceMentions = require("zeroxzero.reference_mentions")
local Checkpoint = require("zeroxzero.checkpoint")
local InlineDiff = require("zeroxzero.inline_diff")
local Reconcile = require("zeroxzero.reconcile")

local api = vim.api

local function notify_user(pattern)
  pcall(api.nvim_exec_autocmds, "User", { pattern = pattern })
  local sound = config.current.sound
  if type(sound) == "string" and sound ~= "" and vim.fn.executable("afplay") == 1 then
    pcall(vim.fn.jobstart, { "afplay", sound }, { detach = true })
  end
  pcall(function()
    local f = io.open("/dev/tty", "w")
    if f then
      f:write("\a")
      f:close()
    end
  end)
end

---@class zeroxzero.Chat
---@field tab_page_id integer
---@field client table|nil
---@field session_id string|nil
---@field provider_name string|nil
---@field model string|nil
---@field mode string|nil
---@field config_options table<string, table>
---@field history zeroxzero.History
---@field widget zeroxzero.ChatWidget
---@field in_flight boolean
---@field response_started boolean
---@field queued_prompts table[]
---@field cancel_requested boolean
---@field checkpoint table|nil
---@field repo_root string|nil
---@field reconcile zeroxzero.Reconcile|nil
local Chat = {}
Chat.__index = Chat

---@param tab_page_id integer
---@return zeroxzero.Chat
function Chat.new(tab_page_id)
  local self = setmetatable({
    tab_page_id = tab_page_id,
    client = nil,
    session_id = nil,
    provider_name = nil,
    model = nil,
    mode = nil,
    config_options = {},
    history = History.new(),
    in_flight = false,
    response_started = false,
    queued_prompts = {},
    cancel_requested = false,
    checkpoint = nil,
    repo_root = nil,
    reconcile = nil,
    persist_id = HistoryStore.new_id(),
    persist_created_at = os.time(),
    persist_timer = nil,
  }, Chat)
  self.widget = ChatWidget.new(tab_page_id, self.history, function()
    self:submit()
  end, function()
    self:cancel()
  end, function()
    return {
      provider = self.provider_name or config.current.provider,
      model = self.model,
      mode = self.mode,
    }
  end)
  return self
end

---@param state string|nil
---@param label string|nil
function Chat:_set_activity(state, label)
  self.widget:set_activity(state, label)
end

---@param label string|nil
function Chat:_mark_responding(label)
  if not self.in_flight then
    return
  end
  self.response_started = true
  self:_set_turn_activity("responding", label or "Model responding")
end

function Chat:_render()
  vim.schedule(function()
    self.widget:render()
    self:_schedule_persist()
  end)
end

function Chat:_schedule_persist()
  if self.persist_timer then
    self.persist_timer:stop()
    self.persist_timer:close()
  end
  self.persist_timer = vim.defer_fn(function()
    self.persist_timer = nil
    self:_persist_now()
  end, 1000)
end

function Chat:_persist_now()
  HistoryStore.save({
    id = self.persist_id,
    created_at = self.persist_created_at,
    messages = self.history.messages,
    settings = {
      provider = self.provider_name,
      model = self.model,
      mode = self.mode,
    },
  })
end

---@param id string
function Chat:load_thread(id)
  local entry = HistoryStore.load(id)
  if not entry then
    vim.notify("0x0: chat history entry not found", vim.log.levels.WARN)
    return
  end
  self:_reset_session()
  self.history:clear()
  self.history.messages = entry.messages or {}
  for _, msg in ipairs(self.history.messages) do
    if msg.type == "user" and msg.id then
      self.history.next_id = math.max(self.history.next_id, (tonumber(msg.id) or 0) + 1)
    end
  end
  self.persist_id = entry.id
  self.persist_created_at = entry.created_at or os.time()
  if entry.settings then
    self.provider_name = entry.settings.provider or self.provider_name
    self.model = entry.settings.model
    self.mode = entry.settings.mode
  end
  self.widget:reset()
  self:open()
  self.widget:render()
end

---@return integer
function Chat:_queued_count()
  return #self.queued_prompts
end

---@param state string|nil
---@param label string|nil
function Chat:_set_turn_activity(state, label)
  local queued = self:_queued_count()
  if label then
    label = label:gsub("%s%(%d+ queued%)$", "")
  end
  if state and queued > 0 then
    label = ("%s (%d queued)"):format(label or "Working", queued)
  end
  self:_set_activity(state, label)
end

local function describe_tool(tool_call)
  local kind = tool_call.kind or "tool"
  local title = tool_call.title
  if not title or title == "" then
    title = tool_call.toolCallId or "?"
  end
  return kind, title
end

local function tool_patch(update)
  local patch = {}
  if update.status then
    patch.status = update.status
  end
  if update.title and update.title ~= "" then
    patch.title = update.title
  end
  if update.kind then
    patch.kind = update.kind
  end

  return patch
end

local function error_message(err)
  if type(err) == "table" then
    return err.message or vim.inspect(err)
  end
  return tostring(err)
end

local function is_transport_disconnected(err)
  local message = error_message(err)
  return message == "transport disconnected" or message == "transport error"
end

local function is_session_missing(err)
  return error_message(err) == "Resource not found"
end

local function is_cancel_result(result)
  return result and result.stopReason == "cancelled"
end

function Chat:_handle_update(update)
  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
    local text = update.content and update.content.text or ""
    if text == "" then
      return
    end
    self:_mark_responding(kind == "agent_thought_chunk" and "Model thinking" or "Model responding")
    local msg_kind = kind == "agent_thought_chunk" and "thought" or "agent"
    self.history:add_agent_chunk(msg_kind, text)
    self:_render()
  elseif kind == "tool_call" then
    if not update.toolCallId then
      return
    end
    if self.in_flight then
      self:_set_turn_activity("waiting", "Running tool")
    end
    self.history:add({
      type = "tool_call",
      tool_call_id = update.toolCallId,
      kind = update.kind or "tool",
      title = update.title or "",
      status = update.status or "pending",
    })
    self:_render()
  elseif kind == "tool_call_update" then
    if not update.toolCallId then
      return
    end
    if self.in_flight then
      if update.status == "completed" or update.status == "failed" then
        self:_set_turn_activity("waiting", "Waiting for model")
      else
        self:_set_turn_activity("waiting", "Running tool")
      end
    end
    local patch = tool_patch(update)
    self.history:update_tool_call(update.toolCallId, patch)
    if update.status == "completed" and self.checkpoint then
      vim.schedule(function()
        InlineDiff.refresh_all(self.checkpoint)
      end)
    end
    self:_render()
  elseif kind == "config_option_update" then
    self:_set_config_options(update.configOptions)
  end
end

function Chat:_handle_permission(request, respond)
  vim.schedule(function()
    if self.widget.permission_pending then
      respond("reject_once")
      return
    end
    if self.in_flight then
      self:_set_turn_activity("waiting", "Waiting for permission")
    end
    local tool_call = request.toolCall or {}
    local tool_call_id = tool_call.toolCallId or tostring(vim.loop.hrtime())
    local kind, title = describe_tool(tool_call)
    self.history:add({
      type = "permission",
      tool_call_id = tool_call_id,
      kind = kind,
      description = title,
      options = request.options or {},
    })
    self.widget:render()
    notify_user("ZeroChatPermission")
    self.widget:bind_permission_keys(tool_call_id, request.options or {}, function(option_id, option_name)
      self.history:set_permission_decision(tool_call_id, option_name or option_id or "rejected")
      if self.in_flight then
        self:_set_turn_activity("waiting", "Waiting for model")
      end
      self.widget:render()
      respond(option_id)
    end)
  end)
end

---Resolve an ACP-supplied path to an absolute filesystem path. ACP paths are
---meant to be absolute, but be defensive: relative paths are joined onto the
---repo root so we never read/write something outside the project.
---@param path string
---@return string|nil
function Chat:_resolve_acp_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  if self.repo_root then
    return self.repo_root .. "/" .. path
  end
  return nil
end

function Chat:_handle_fs_read(params, respond)
  vim.schedule(function()
    if not self.reconcile then
      respond(nil, { code = -32000, message = "no active reconcile session" })
      return
    end
    local abs = self:_resolve_acp_path(params.path)
    if not abs then
      respond(nil, { code = -32602, message = "invalid path" })
      return
    end
    local content, err = self.reconcile:read_for_agent(abs, params.line, params.limit)
    if err then
      respond(nil, { code = -32000, message = err })
      return
    end
    respond(content, nil)
  end)
end

function Chat:_handle_fs_write(params, respond)
  vim.schedule(function()
    if not self.reconcile then
      respond({ code = -32000, message = "no active reconcile session" })
      return
    end
    local abs = self:_resolve_acp_path(params.path)
    if not abs then
      respond({ code = -32602, message = "invalid path" })
      return
    end
    local ok, werr = self.reconcile:write_for_agent(abs, params.content or "")
    if not ok then
      respond({ code = -32000, message = werr or "write rejected" })
      return
    end
    if self.repo_root and Checkpoint.is_ignored(self.repo_root, abs) then
      local rel = vim.fn.fnamemodify(abs, ":~:.")
      self.history:add({
        type = "activity",
        status = "failed",
        text = ("wrote `%s` — outside checkpoint, no rewind available"):format(rel),
      })
      self:_render()
    end
    if self.checkpoint then
      InlineDiff.refresh_path(self.checkpoint, abs)
    end
    respond(nil)
  end)
end

function Chat:_set_config_options(options)
  self.config_options = {}
  if type(options) ~= "table" then
    return
  end
  for _, option in ipairs(options) do
    local category = type(option.category) == "string" and option.category or ""
    if category == "mode" or category == "model" then
      self.config_options[category] = option
      if category == "mode" then
        self.mode = option.currentValue or self.mode
      elseif category == "model" then
        self.model = option.currentValue or self.model
      end
    end
  end
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

function Chat:_apply_config_option(category, value, callback)
  if not self.client or not self.session_id then
    callback(false)
    return
  end
  local session_id = self.session_id
  local option = self.config_options[category]
  if option and option_has_value(option, value) then
    self.client:set_config_option(session_id, category, value, function(result, err)
      if self.session_id ~= session_id then
        return
      end
      if err then
        vim.notify(("acp: set %s failed: %s"):format(category, err.message or vim.inspect(err)), vim.log.levels.ERROR)
        callback(false)
        return
      end
      if result and result.configOptions then
        self:_set_config_options(result.configOptions)
      end
      if category == "mode" then
        self.mode = value
      elseif category == "model" then
        self.model = value
      end
      if option then
        option.currentValue = value
      end
      callback(true)
    end)
    return
  end
  if category == "model" and not self.config_options.model then
    self.client:set_model(session_id, value, function(result, err)
      if self.session_id ~= session_id then
        return
      end
      if err then
        vim.notify("acp: set model failed: " .. (err.message or vim.inspect(err)), vim.log.levels.ERROR)
        callback(false)
        return
      end
      if result and result.configOptions then
        self:_set_config_options(result.configOptions)
      end
      self.model = value
      callback(true)
    end)
    return
  end
  vim.notify("acp: " .. category .. " is not available for this provider/session", vim.log.levels.WARN)
  callback(false)
end

function Chat:_apply_initial_session_config(desired, done)
  local function set_model()
    if desired.model then
      self:_apply_config_option("model", desired.model, function()
        done()
      end)
    else
      done()
    end
  end
  if desired.mode and option_has_value(self.config_options.mode, desired.mode) then
    self:_apply_config_option("mode", desired.mode, set_model)
  else
    set_model()
  end
end

function Chat:_ensure_client(on_ready)
  local provider_name = self.provider_name or config.current.provider
  if self.client and self.provider_name == provider_name and self.client:is_ready() then
    on_ready(self.client, nil)
    return
  end
  local provider, perr = config.resolve_provider(provider_name)
  if not provider then
    vim.notify(perr, vim.log.levels.ERROR)
    on_ready(nil, { message = perr })
    return
  end
  if self.client then
    self.client:stop()
  end
  self.provider_name = provider_name
  self.client = acp_client.new(provider, { host_fs = true })
  self.client:start(function(c, err)
    on_ready(c, err)
  end)
end

---Take a fresh checkpoint snapshot at the start of every turn so the diff
---baseline always reflects the working tree as the user just submitted it.
---@param on_ready fun(checkpoint: table|nil, err: table|nil)
function Chat:_ensure_checkpoint(on_ready)
  local root = self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
  if not root then
    on_ready(nil, {
      message = "0x0: not in a git repository — run `git init` first.\n"
        .. "Inline diff requires a git tree as the rewind / review baseline.",
    })
    return
  end
  self.repo_root = root
  local cp, err = Checkpoint.snapshot(root)
  if not cp then
    on_ready(nil, { message = err or "checkpoint snapshot failed" })
    return
  end
  self.checkpoint = cp
  if self.reconcile then
    self.reconcile:set_checkpoint(cp)
    self.reconcile:set_mode(config.current.reconcile or "strict")
  else
    self.reconcile = Reconcile.new({ checkpoint = cp, mode = config.current.reconcile or "strict" })
  end
  InlineDiff.set_active(cp)
  on_ready(cp, nil)
end

function Chat:_ensure_session(on_session)
  local function start_session(cwd)
    self:_ensure_client(function(client, cerr)
      if cerr or not client then
        on_session(nil, nil, cerr or { message = "client unavailable" })
        return
      end
      if self.session_id then
        on_session(client, self.session_id, nil)
        return
      end
      local desired = { mode = self.mode, model = self.model }
      client:new_session(cwd, function(result, err)
        if self.client ~= client then
          on_session(nil, nil, { message = "client replaced" })
          return
        end
        if err or not result or not result.sessionId then
          vim.notify("acp: session/new failed: " .. vim.inspect(err), vim.log.levels.ERROR)
          on_session(nil, nil, err or { message = "session/new failed" })
          return
        end
        self.session_id = result.sessionId
        self:_set_config_options(result.configOptions)
        client:subscribe(result.sessionId, {
          on_update = function(update)
            self:_handle_update(update)
          end,
          on_request_permission = function(request, respond)
            self:_handle_permission(request, respond)
          end,
          on_fs_read_text_file = function(params, respond)
            self:_handle_fs_read(params, respond)
          end,
          on_fs_write_text_file = function(params, respond)
            self:_handle_fs_write(params, respond)
          end,
        })
        self:_apply_initial_session_config(desired, function()
          on_session(client, result.sessionId, nil)
        end)
      end)
    end)
  end

  self:_ensure_checkpoint(function(checkpoint, cerr)
    if cerr or not checkpoint then
      on_session(nil, nil, cerr or { message = "checkpoint unavailable" })
      return
    end
    start_session(checkpoint.root)
  end)
end

function Chat:open()
  self.widget:open()
end

---@param sel { path: string|nil, filetype: string|nil, start_line: integer, end_line: integer, lines: string[] }
function Chat:add_selection(sel)
  if not sel or not sel.lines or #sel.lines == 0 then
    return
  end
  local fence = sel.filetype and sel.filetype ~= "" and sel.filetype or ""
  local header
  if sel.path and sel.path ~= "" then
    header = ("%s:%d-%d"):format(sel.path, sel.start_line, sel.end_line)
  else
    header = ("lines %d-%d"):format(sel.start_line, sel.end_line)
  end
  local block = { header, "```" .. fence }
  for _, line in ipairs(sel.lines) do
    block[#block + 1] = line
  end
  block[#block + 1] = "```"
  block[#block + 1] = ""
  self.widget:prepend_input(block)
  self:open()
  self.widget:focus_input()
end

function Chat:close()
  self.widget:close()
end

function Chat:toggle()
  if self.widget:is_open() then
    self.widget:close()
  else
    self.widget:open()
  end
end

function Chat:new_session()
  self:_persist_now()
  self:_reset_session()
  self.history:clear()
  self.widget:reset()
  self.persist_id = HistoryStore.new_id()
  self.persist_created_at = os.time()
  self:open()
end

local SLASH_COMMANDS = {
  clear = "new_session",
  new = "new_session",
  changes = "show_changes",
  accept = "accept_all",
  discard = "discard_all",
  stop = "stop",
  cancel = "cancel",
}

local SLASH_HELP = [[Slash commands:
  /clear   start a new session
  /changes list files changed since checkpoint
  /accept  accept all pending changes
  /discard discard all pending changes
  /cancel  cancel the in-flight turn
  /stop    reset the session]]

---@param prompt string
---@return boolean handled
function Chat:_dispatch_slash(prompt)
  local cmd = prompt:match("^/([%w_-]+)%s*$")
  if not cmd then
    return false
  end
  if cmd == "help" then
    vim.notify(SLASH_HELP, vim.log.levels.INFO)
    self.widget:clear_input()
    return true
  end
  local method = SLASH_COMMANDS[cmd]
  if not method then
    return false
  end
  self.widget:clear_input()
  self[method](self)
  return true
end

function Chat:submit()
  local prompt = self.widget:read_input()
  if prompt == "" then
    vim.notify("acp: empty prompt", vim.log.levels.WARN)
    return
  end
  if self:_dispatch_slash(prompt) then
    return
  end
  self.widget:push_history(prompt)
  if self.in_flight then
    local id = self.history:add_user(prompt, "queued")
    table.insert(self.queued_prompts, { id = id, text = prompt })
    self.widget:clear_input()
    self:_set_turn_activity(self.widget.activity_state or "waiting", self.widget.activity_label or "Working")
    self.widget:render()
    return
  end
  local id = self.history:add_user(prompt, "active")
  self:_submit_prompt(prompt, id)
end

---@param prompt string
---@param user_id string
---@param retried_session? boolean
function Chat:_submit_prompt(prompt, user_id, retried_session)
  self.in_flight = true
  self.response_started = false
  self.cancel_requested = false
  self.history:set_user_status(user_id, "active")
  self.widget:clear_input()
  self:_set_turn_activity("waiting", "Starting session")
  self.widget:render()

  self:_ensure_session(function(client, session_id, sess_err)
    if sess_err or not client or not session_id then
      vim.schedule(function()
        local msg = sess_err and (sess_err.message or vim.inspect(sess_err)) or "failed to start session"
        self.history:add_agent_chunk("agent", "_error: " .. msg .. "_")
        self:_set_activity(nil)
        self.widget:render()
        self.in_flight = false
        self.response_started = false
        self:_notify_or_continue()
      end)
      return
    end
    self:_set_turn_activity("waiting", "Waiting for model")
    client:prompt(session_id, ReferenceMentions.to_prompt_blocks(prompt, self:_session_cwd()), function(result, err)
      vim.schedule(function()
        if self.client ~= client or self.session_id ~= session_id then
          return
        end
        local was_cancelled = self.cancel_requested or is_cancel_result(result)
        if err and is_session_missing(err) and not retried_session then
          self.client = nil
          self.session_id = nil
          self:_set_turn_activity("waiting", "Restarting session")
          self.widget:render()
          self:_submit_prompt(prompt, user_id, true)
          return
        end
        if err and not (was_cancelled and is_transport_disconnected(err)) then
          local m = error_message(err)
          self.history:add_agent_chunk("agent", "\n_error: " .. m .. "_")
        elseif
          result
          and result.stopReason
          and result.stopReason ~= "end_turn"
          and result.stopReason ~= "cancelled"
        then
          self.history:add_agent_chunk("agent", "\n_stopped: " .. tostring(result.stopReason) .. "_")
        end
        if err and is_transport_disconnected(err) then
          self.client = nil
          self.session_id = nil
        end
        self:_set_activity(nil)
        self.widget:render()
        self.in_flight = false
        self.response_started = false
        self.cancel_requested = false
        self:_notify_or_continue()
      end)
    end)
  end)
end

function Chat:_notify_or_continue()
  local next_prompt = table.remove(self.queued_prompts, 1)
  if next_prompt then
    self:_submit_prompt(next_prompt.text, next_prompt.id)
    return
  end
  notify_user("ZeroChatTurnEnd")
end

function Chat:cancel()
  if self.client and self.session_id and self.in_flight then
    self.cancel_requested = true
    self:_set_turn_activity("waiting", "Cancelling")
    self.client:cancel(self.session_id)
  end
end

---@return string|nil
function Chat:_session_cwd()
  return self.repo_root
end

function Chat:_clear_checkpoint()
  InlineDiff.set_active(nil)
  if self.reconcile then
    self.reconcile:set_checkpoint(nil)
  end
  if not self.checkpoint then
    return
  end
  Checkpoint.delete_ref(self.checkpoint)
  self.checkpoint = nil
end

function Chat:_reset_session()
  self.widget:unbind_permission_keys()
  if self.client and self.session_id then
    self.client:cancel(self.session_id)
    self.client:unsubscribe(self.session_id)
  end
  if self.client then
    self.client:stop()
  end
  self.client = nil
  self.session_id = nil
  self.in_flight = false
  self.response_started = false
  self.cancel_requested = false
  self.queued_prompts = {}
  self:_set_activity(nil)
  self.config_options = {}
  self:_clear_checkpoint()
end

function Chat:accept_all()
  if not self.checkpoint then
    vim.notify("0x0: no checkpoint to accept against", vim.log.levels.INFO)
    return
  end
  local files = Checkpoint.changed_files(self.checkpoint)
  if #files == 0 then
    vim.notify("0x0: no pending changes", vim.log.levels.INFO)
    return
  end
  self:_clear_checkpoint()
  vim.notify(("0x0: accepted %d file%s"):format(#files, #files == 1 and "" or "s"), vim.log.levels.INFO)
  return true
end

function Chat:discard_all()
  if not self.checkpoint then
    vim.notify("0x0: no checkpoint to discard against", vim.log.levels.INFO)
    return
  end
  local ok, err = Checkpoint.restore_all(self.checkpoint)
  if not ok then
    vim.notify("0x0: " .. (err or "discard failed"), vim.log.levels.ERROR)
    return
  end
  self:_clear_checkpoint()
  vim.cmd.checktime()
  vim.notify("0x0: discarded chat changes", vim.log.levels.INFO)
  return true
end

function Chat:show_changes()
  if not self.checkpoint then
    vim.notify("0x0: no active checkpoint", vim.log.levels.INFO)
    return
  end
  local files = Checkpoint.changed_files(self.checkpoint)
  if #files == 0 then
    vim.notify("0x0: no changes since checkpoint", vim.log.levels.INFO)
    return
  end
  vim.ui.select(files, {
    prompt = ("0x0: %d changed file%s"):format(#files, #files == 1 and "" or "s"),
    format_item = function(p)
      return p
    end,
  }, function(choice)
    if not choice then
      return
    end
    local abs = self.checkpoint.root .. "/" .. choice
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  end)
end

function Chat:stop()
  self:_reset_session()
end

---@return { provider: string, model: string|nil, mode: string|nil, config_options: table }
function Chat:current_settings()
  return {
    provider = self.provider_name or config.current.provider,
    model = self.model,
    mode = self.mode,
    config_options = self.config_options,
  }
end

function Chat:set_provider(name)
  self:_reset_session()
  self.provider_name = name
  self.model = nil
  self.mode = nil
end

function Chat:set_model(model)
  self.model = model
  if self.client and self.session_id then
    self:_apply_config_option("model", model, function() end)
  end
end

function Chat:set_mode(mode)
  self.mode = mode
  if self.client and self.session_id then
    self:_apply_config_option("mode", mode, function() end)
  end
end

function Chat:discover_options(callback)
  self:_ensure_client(function(client, cerr)
    if cerr or not client then
      local msg = cerr and (cerr.message or vim.inspect(cerr)) or "client unavailable"
      vim.notify("acp: option discovery failed: " .. msg, vim.log.levels.ERROR)
      if callback then
        callback(self:current_settings())
      end
      return
    end
    client:new_session(vim.fn.getcwd(), function(result, err)
      if self.client ~= client then
        return
      end
      if err or not result or not result.sessionId then
        vim.notify("acp: option discovery failed: " .. vim.inspect(err), vim.log.levels.ERROR)
        if callback then
          callback(self:current_settings())
        end
        return
      end
      local session_id = result.sessionId
      self:_set_config_options(result.configOptions)
      client:cancel(session_id)
      client:unsubscribe(session_id)
      if callback then
        callback(self:current_settings())
      end
    end)
  end)
end

function Chat:option_items(category)
  local items = {}
  local option = self.config_options[category]
  if option and option.options then
    for _, item in ipairs(option.options) do
      items[#items + 1] = {
        value = item.value,
        name = item.name or item.value,
        description = item.description,
        current = item.value == option.currentValue,
      }
    end
  end
  return items
end

function Chat:has_config_option(category)
  return self.config_options[category] ~= nil
end

-- Registry: one Chat per tabpage.

---@type table<integer, zeroxzero.Chat>
local instances = {}

local function for_current_tab()
  local tab = api.nvim_get_current_tabpage()
  local chat = instances[tab]
  if not chat then
    chat = Chat.new(tab)
    instances[tab] = chat
  end
  return chat
end

local augroup = api.nvim_create_augroup("zeroxzero_chat", { clear = true })

api.nvim_create_autocmd("TabClosed", {
  group = augroup,
  callback = function(args)
    local tab = tonumber(args.file)
    if not tab then
      return
    end
    local chat = instances[tab]
    if chat then
      pcall(function()
        chat:_persist_now()
      end)
      local root = chat.repo_root
      chat:stop()
      if root then
        pcall(Checkpoint.gc, root, config.current.checkpoint_keep_n or 20)
      end
      instances[tab] = nil
    end
  end,
})

local M = {}

function M.open()
  for_current_tab():open()
end

function M.close()
  for_current_tab():close()
end

function M.toggle()
  for_current_tab():toggle()
end

---@param sel table
function M.add_selection(sel)
  for_current_tab():add_selection(sel)
end

function M.history_picker()
  local entries = HistoryStore.list()
  if #entries == 0 then
    vim.notify("0x0: no saved chat history", vim.log.levels.INFO)
    return
  end
  vim.ui.select(entries, {
    prompt = "0x0 chat history",
    format_item = function(e)
      local when = os.date("%Y-%m-%d %H:%M", e.updated_at)
      return ("%s  %s  (%d msgs)"):format(when, e.title, e.message_count)
    end,
  }, function(choice)
    if not choice then
      return
    end
    for_current_tab():load_thread(choice.id)
  end)
end

function M.new()
  for_current_tab():new_session()
end

function M.submit()
  for_current_tab():submit()
end

function M.cancel()
  for_current_tab():cancel()
end

function M.changes()
  for_current_tab():show_changes()
end

function M.accept_all()
  for_current_tab():accept_all()
end

function M.discard_all()
  for_current_tab():discard_all()
end

function M.stop()
  for_current_tab():stop()
end

function M.current_settings()
  return for_current_tab():current_settings()
end

function M.set_provider(name)
  for_current_tab():set_provider(name)
end

function M.set_model(model)
  for_current_tab():set_model(model)
end

function M.set_mode(mode)
  for_current_tab():set_mode(mode)
end

function M.discover_options(callback)
  for_current_tab():discover_options(callback)
end

function M.option_items(category)
  return for_current_tab():option_items(category)
end

function M.has_config_option(category)
  return for_current_tab():has_config_option(category)
end

return M
