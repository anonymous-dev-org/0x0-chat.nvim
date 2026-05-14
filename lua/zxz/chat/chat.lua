-- Chat orchestrator: defines the Chat class, mixes in lifecycle methods from
-- chat/* submodules, owns the per-tabpage registry, and exposes the M
-- surface consumed by lua/zxz/init.lua.

local config = require("zxz.core.config")
local ChatDB = require("zxz.core.chat_db")
local History = require("zxz.core.history")
local HistoryStore = require("zxz.core.history_store")
local RunsStore = require("zxz.core.runs_store")
local Events = require("zxz.core.events")
local ChatWidget = require("zxz.chat.widget")
local Checkpoint = require("zxz.core.checkpoint")
local InlineDiff = require("zxz.edit.inline_diff")
local Runtime = require("zxz.chat.runtime")

local api = vim.api

---@class zxz.Chat
---@field tab_page_id integer
---@field client table|nil
---@field session_id string|nil
---@field provider_name string|nil
---@field model string|nil
---@field mode string|nil
---@field config_options table<string, table>
---@field history zxz.History
---@field widget zxz.ChatWidget
---@field in_flight boolean
---@field response_started boolean
---@field queued_prompts table[]
---@field cancel_requested boolean
---@field checkpoint table|nil
---@field repo_root string|nil
---@field reconcile zxz.Reconcile|nil
---@field title string|nil
---@field title_requested boolean
---@field title_pending boolean
---@field current_run table|nil
---@field run_ids string[]
---@field on_new_chat (fun(source: zxz.Chat)|nil)
local Chat = {}
Chat.__index = Chat

local function mixin(target, src)
  for k, v in pairs(src) do
    target[k] = v
  end
end

mixin(Chat, require("zxz.chat.session"))
mixin(Chat, require("zxz.chat.turn"))
mixin(Chat, require("zxz.chat.permissions"))
mixin(Chat, require("zxz.chat.fs_bridge"))
mixin(Chat, require("zxz.chat.persistence"))
mixin(Chat, require("zxz.chat.checkpoints"))
mixin(Chat, require("zxz.chat.runs"))
mixin(Chat, require("zxz.chat.run_review"))
mixin(Chat, require("zxz.chat.run_actions"))
mixin(Chat, require("zxz.chat.run_timeline"))
mixin(Chat, require("zxz.chat.ephemeral"))

local TERMINAL_TOOL_STATUS = {
  completed = true,
  failed = true,
  cancelled = true,
}

local function unique_insert(list, seen, value)
  if not value or value == "" or seen[value] then
    return
  end
  seen[value] = true
  list[#list + 1] = value
end

local function files_touched(run)
  local files = {}
  local seen = {}
  for _, path in ipairs((run and run.files_touched) or {}) do
    unique_insert(files, seen, path)
  end
  for _, event in ipairs((run and run.edit_events) or {}) do
    unique_insert(files, seen, event.path)
  end
  return files
end

local function pending_review_count(run)
  local count = 0
  local events = (run and run.edit_events) or {}
  for _, event in ipairs(events) do
    local event_status = event.status or "pending"
    if event_status == "pending" or event_status == "partial" then
      local hunks = event.hunks or {}
      if #hunks == 0 then
        count = count + 1
      else
        for _, hunk in ipairs(hunks) do
          if (hunk.status or event_status) == "pending" then
            count = count + 1
          end
        end
      end
    end
  end
  if #events == 0 then
    count = #files_touched(run)
  end
  return count
end

local function blocked_review_count(run)
  local count = 0
  for _, event in ipairs((run and run.edit_events) or {}) do
    local event_status = event.status or "pending"
    if
      (event_status == "pending" or event_status == "partial")
      and (event.summary_only or event.blocked_by_event_id)
    then
      count = count + 1
    end
  end
  count = count + #((run and run.edit_event_diagnostics) or {})
  return count
end

local function running_tool(run, active_tool_call_id)
  local latest_running
  for index = #((run and run.tool_calls) or {}), 1, -1 do
    local tool = run.tool_calls[index]
    local is_running = not TERMINAL_TOOL_STATUS[tool.status]
    if tool.tool_call_id == active_tool_call_id and is_running then
      return tool
    end
    if not latest_running and is_running then
      latest_running = tool
    end
  end
  return latest_running
end

---@param tab_page_id integer
---@param opts? { on_new_chat?: fun(source: zxz.Chat) }
---@return zxz.Chat
function Chat.new(tab_page_id, opts)
  opts = opts or {}
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
    title = nil,
    title_requested = false,
    title_pending = false,
    persist_created_at = os.time(),
    persist_timer = nil,
    current_run = nil,
    run_ids = {},
    permission_queue = {},
    pending_trim = {},
    on_new_chat = opts.on_new_chat,
  }, Chat)
  self.widget = ChatWidget.new(tab_page_id, self.history, function()
    self:submit()
  end, function()
    self:cancel()
  end, function()
    return self:_work_state()
  end)
  return self
end

local function last_run(chat)
  local ids = chat.run_ids or {}
  for index = #ids, 1, -1 do
    local run = RunsStore.load(ids[index])
    if run then
      return run
    end
  end
end

local STATUS_META = {
  request_approval = { label = "request approval", group = "active", order = 10 },
  approval = { label = "request approval", group = "active", order = 10 },
  working = { label = "working", group = "active", order = 20 },
  failed = { label = "failed", group = "active", order = 30 },
  queued = { label = "queued", group = "queued", order = 40 },
  needs_input = { label = "needs input", group = "open", order = 50 },
  saved = { label = "saved", group = "history", order = 60 },
}

---@return { key: string, label: string, group: string, order: integer }
function Chat:status_snapshot()
  local key
  if self.widget and self.widget.permission_pending then
    key = "request_approval"
  elseif self.permission_queue and #self.permission_queue > 0 then
    key = "request_approval"
  elseif self.in_flight then
    key = "working"
  elseif self.queued_prompts and #self.queued_prompts > 0 then
    key = "queued"
  else
    local run = last_run(self)
    key = run and run.status == "failed" and "failed" or "needs_input"
  end
  local meta = STATUS_META[key] or STATUS_META.needs_input
  return {
    key = key,
    label = meta.label,
    group = meta.group,
    order = meta.order,
  }
end

---@return table
function Chat:summary_entry()
  local status = self:status_snapshot()
  return {
    id = self.persist_id,
    title = self.title or "untitled",
    updated_at = os.time(),
    created_at = self.persist_created_at or 0,
    message_count = self.history and #(self.history.messages or {}) or 0,
    status = status.key,
    status_label = status.label,
    group_label = status.group,
    status_order = status.order,
    live = true,
    chat = self,
    provider = self.provider_name,
    model = self.model,
    mode = self.mode,
  }
end

---@return table|nil
function Chat:_work_state()
  local run = self.current_run
  if not run or not self.in_flight then
    return nil
  end
  return {
    running_tool = running_tool(run, self.active_tool_call_id),
    files_touched = files_touched(run),
    pending_review = pending_review_count(run),
    conflicts = #((run and run.conflicts) or {}),
    blocked = blocked_review_count(run),
  }
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
  self:_set_turn_activity("responding", label or "Working")
end

function Chat:_render()
  vim.schedule(function()
    self.widget:render()
    self:_schedule_persist()
  end)
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

---@param lines string[]
function Chat:_add_prompt_block(lines)
  self.widget:prepend_input(lines)
  self:open()
  self.widget:focus_input()
end

function Chat:_rerender_transcript()
  self.widget:rerender_all()
  self:_schedule_persist()
end

---@param item table|string
---@return string
function Chat:_queue_db_id(item)
  local message_id = type(item) == "table" and item.id or item
  return ("%s:%s"):format(self.persist_id, message_id or "")
end

---@param item table
---@param index integer
function Chat:_persist_queue_item(item, index)
  if not item or not self.persist_id then
    return
  end
  item.queue_id = item.queue_id or self:_queue_db_id(item)
  ChatDB.save_queue_item({
    id = item.queue_id,
    chat_id = self.persist_id,
    message_id = item.id,
    seq = index,
    text = item.text or "",
    context_records = item.context_records or {},
    trim = item.trim or {},
    status = "queued",
  })
end

---@param item table
function Chat:_delete_queue_item(item)
  if item then
    ChatDB.delete_queue_item(item.queue_id or self:_queue_db_id(item))
  end
end

function Chat:_persist_queue_order()
  for index, item in ipairs(self.queued_prompts or {}) do
    self:_persist_queue_item(item, index)
  end
end

---@param token string
function Chat:add_context_token(token)
  token = type(token) == "string" and vim.trim(token) or ""
  if token == "" then
    return
  end
  self:_add_prompt_block({ token, "" })
end

---@return { count: integer, in_flight: boolean, items: table[] }
function Chat:queue_state()
  local items = {}
  for index, item in ipairs(self.queued_prompts) do
    local trimmed = 0
    for _, v in pairs(item.trim or {}) do
      if v then
        trimmed = trimmed + 1
      end
    end
    items[#items + 1] = {
      index = index,
      id = item.id,
      text = item.text,
      context_records = item.context_records,
      context_summary = item.context_summary,
      trimmed = trimmed,
    }
  end
  return {
    count = #items,
    in_flight = self.in_flight,
    items = items,
  }
end

---@param id string
---@param text string
---@param summary? string[]
---@param records? table[]
function Chat:_update_queued_history_text(id, text, summary, records)
  for i = #self.history.messages, 1, -1 do
    local msg = self.history.messages[i]
    if msg.type == "user" and msg.id == id then
      msg.text = text
      msg.status = "queued"
      msg.context_summary = summary
      msg.context_records = records
      return
    end
  end
end

---@param id string
function Chat:_remove_queued_history_message(id)
  for i = #self.history.messages, 1, -1 do
    local msg = self.history.messages[i]
    if msg.type == "user" and msg.id == id then
      table.remove(self.history.messages, i)
      return
    end
  end
end

---@param index integer
---@param text string
---@return boolean ok
---@return string|nil err
function Chat:queue_update(index, text)
  index = tonumber(index)
  text = type(text) == "string" and vim.trim(text) or ""
  local item = index and self.queued_prompts[index] or nil
  if not item then
    return false, "queued message not found"
  end
  if text == "" then
    return false, "queued message cannot be empty"
  end
  item.text = text
  local records, summary = self:_context_for_prompt(text, self:_session_cwd())
  item.trim = self:_filter_context_trim(item.trim, records)
  self:_apply_context_trim(records, item.trim)
  item.context_records = records
  item.context_summary = summary
  self:_update_queued_history_text(item.id, text, summary, records)
  self:_persist_queue_item(item, index)
  self:_rerender_transcript()
  return true
end

---@param index integer
---@return boolean ok
---@return string|nil err
function Chat:queue_remove(index)
  index = tonumber(index)
  local item = index and self.queued_prompts[index] or nil
  if not item then
    return false, "queued message not found"
  end
  table.remove(self.queued_prompts, index)
  self:_delete_queue_item(item)
  self:_persist_queue_order()
  self:_remove_queued_history_message(item.id)
  self:_set_turn_activity(self.widget.activity_state, self.widget.activity_label)
  self:_rerender_transcript()
  return true
end

function Chat:queue_clear()
  while #self.queued_prompts > 0 do
    local item = table.remove(self.queued_prompts)
    self:_delete_queue_item(item)
    self:_remove_queued_history_message(item.id)
  end
  self:_set_turn_activity(self.widget.activity_state, self.widget.activity_label)
  self:_rerender_transcript()
end

---@param records table[]
---@param trim table<string, boolean>
---@return integer kept, integer suppressed
function Chat:_context_trim_counts(records, trim)
  local kept, suppressed = 0, 0
  for _, record in ipairs(records or {}) do
    if record.raw and trim and trim[record.raw] then
      suppressed = suppressed + 1
    else
      kept = kept + 1
    end
  end
  return kept, suppressed
end

---@param index integer
---@return boolean ok
---@return string|nil err
function Chat:trim_queued(index)
  index = tonumber(index)
  local item = index and self.queued_prompts[index] or nil
  if not item then
    return false, "queued message not found"
  end
  local records = item.context_records
  if type(records) ~= "table" then
    records = self:_context_for_prompt(item.text, self:_session_cwd())
  end
  require("zxz.chat.context_trim").open_picker(records, item.trim or {}, function(trim)
    item.trim = self:_filter_context_trim(trim, records)
    self:_apply_context_trim(records, item.trim)
    item.context_records = records
    item.context_summary = require("zxz.context.reference_mentions").summary_from_records(records)
    self:_update_queued_history_text(item.id, item.text, item.context_summary, records)
    self:_persist_queue_item(item, index)
    local kept, suppressed = self:_context_trim_counts(records, item.trim)
    vim.notify(("0x0 trim: queued %d has %d kept, %d suppressed"):format(index, kept, suppressed), vim.log.levels.INFO)
    self:_rerender_transcript()
  end)
  return true
end

---Read the current input, parse its context records, and open the trim
---picker. With an index, trim that queued message instead. The picker writes
---back to `pending_trim` or the queued item; `_submit_prompt` consumes and
---clears current-input trim on submit.
---@param index? integer
function Chat:trim_open(index)
  if index then
    local ok, err = self:trim_queued(index)
    if not ok then
      vim.notify("0x0: " .. (err or "trim failed"), vim.log.levels.ERROR)
    end
    return ok, err
  end
  if not self.widget or not self.widget.input_buf or not api.nvim_buf_is_valid(self.widget.input_buf) then
    vim.notify("0x0: chat input not open", vim.log.levels.WARN)
    return
  end
  local text = vim.trim(table.concat(api.nvim_buf_get_lines(self.widget.input_buf, 0, -1, false), "\n"))
  if text == "" then
    vim.notify("0x0: input is empty — type a prompt first", vim.log.levels.INFO)
    return
  end
  local cwd = self:_session_cwd() or vim.fn.getcwd()
  local records = self:_context_for_prompt(text, cwd)
  require("zxz.chat.context_trim").open_picker(records, self.pending_trim or {}, function(trim)
    self.pending_trim = self:_filter_context_trim(trim, records)
    local on, off = self:_context_trim_counts(records, self.pending_trim)
    vim.notify(("0x0 trim: %d kept, %d suppressed for next turn"):format(on, off), vim.log.levels.INFO)
  end)
end

function Chat:trim_clear()
  self.pending_trim = {}
end

---@return boolean ok
---@return string|nil err
function Chat:queue_send_next()
  if self.in_flight then
    return false, "agent is still working"
  end
  local item = table.remove(self.queued_prompts, 1)
  if not item then
    return false, "queue is empty"
  end
  self:_delete_queue_item(item)
  self:_persist_queue_order()
  self:_submit_prompt(item.text, item.id, nil, {
    context_records = item.context_records,
    trim = item.trim,
  })
  return true
end

---Return true if the chat input already mentions the given path
---(optionally with the same range).
---@param rel string repo-relative or display path
---@param start_line integer|nil
---@param end_line integer|nil
function Chat:_input_mentions(rel, start_line, end_line)
  if not self.widget or not self.widget.input_buf or not api.nvim_buf_is_valid(self.widget.input_buf) then
    return false
  end
  local text = table.concat(api.nvim_buf_get_lines(self.widget.input_buf, 0, -1, false), "\n")
  local cwd = self.repo_root or vim.fn.getcwd()
  local mentions = require("zxz.context.reference_mentions").parse(text, cwd)
  for _, m in ipairs(mentions) do
    if m.path == rel or m.absolute_path == rel then
      if not start_line then
        return true
      end
      if m.start_line == start_line and m.end_line == end_line then
        return true
      end
    end
  end
  return false
end

function Chat:add_current_file()
  local path = api.nvim_buf_get_name(0)
  if path == "" then
    vim.notify("0x0: current buffer has no file path", vim.log.levels.INFO)
    return
  end
  local root = self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
  local rel = vim.fn.fnamemodify(path, ":~:.")
  if root and path:sub(1, #root + 1) == root .. "/" then
    rel = path:sub(#root + 2)
  end
  if self:_input_mentions(rel) then
    vim.notify("0x0: " .. rel .. " is already attached", vim.log.levels.INFO)
    return
  end
  self:_add_prompt_block({ "@" .. rel, "" })
end

function Chat:add_current_hunk()
  local ref = InlineDiff.current_hunk_reference()
  if not ref then
    vim.notify("0x0: no chat diff hunk under cursor", vim.log.levels.INFO)
    return
  end
  local block = {
    ("Changed hunk in %s:"):format(ref.path),
    "```diff",
  }
  vim.list_extend(block, ref.lines)
  block[#block + 1] = "```"
  block[#block + 1] = ""
  self:_add_prompt_block(block)
end

---Pull the most recent visual selection from the previously-focused
---non-chat window and prepend a `@path#L<a>-L<b>` mention.
function Chat:add_visual_selection_from_prev()
  -- Find a window in this tabpage whose buffer is not the chat input/transcript.
  local target_win
  for _, win in ipairs(api.nvim_tabpage_list_wins(self.tab_page_id)) do
    local buf = api.nvim_win_get_buf(win)
    if buf ~= self.widget.input_buf and buf ~= self.widget.transcript_buf then
      target_win = win
      break
    end
  end
  if not target_win then
    vim.notify("0x0: no source window to pull a selection from", vim.log.levels.INFO)
    return
  end
  local buf = api.nvim_win_get_buf(target_win)
  local path = api.nvim_buf_get_name(buf)
  if path == "" then
    vim.notify("0x0: source buffer has no file path", vim.log.levels.INFO)
    return
  end
  local s = api.nvim_buf_get_mark(buf, "<")
  local e = api.nvim_buf_get_mark(buf, ">")
  if not s or s[1] == 0 or not e or e[1] == 0 then
    vim.notify("0x0: no recent visual selection in source buffer", vim.log.levels.INFO)
    return
  end
  local sl, el = math.min(s[1], e[1]), math.max(s[1], e[1])
  local root = self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
  local rel = vim.fn.fnamemodify(path, ":~:.")
  if root and path:sub(1, #root + 1) == root .. "/" then
    rel = path:sub(#root + 2)
  end
  if self:_input_mentions(rel, sl, el) then
    vim.notify(("0x0: %s#L%d-L%d already attached"):format(rel, sl, el), vim.log.levels.INFO)
    return
  end
  self:_add_prompt_block({ ("@%s#L%d-L%d"):format(rel, sl, el), "" })
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

-- Registry: one visible Chat per tabpage, with any number of live hidden
-- chats kept running behind it.

local new_chat_for_tab

local function create_chat(tab)
  return Chat.new(tab, {
    on_new_chat = function(source)
      new_chat_for_tab(source.tab_page_id, source)
    end,
  })
end

local function tab_state(tab)
  return Runtime.tab_state(tab)
end

local function attach_to_tab(chat, tab)
  chat.tab_page_id = tab
  if chat.widget then
    chat.widget.tab_page_id = tab
  end
end

local function set_active_chat(tab, chat)
  local state = tab_state(tab)
  if state.active and state.active ~= chat then
    pcall(function()
      state.active:_persist_now()
    end)
    state.active:close()
  end
  attach_to_tab(chat, tab)
  Runtime.set_active(tab, chat)
  if state.unsubscribe then
    state.unsubscribe()
  end
  state.unsubscribe = Events.on("zxz_chat_updated", function(chat_id)
    if state.active ~= chat or chat_id ~= chat.persist_id then
      return
    end
    vim.schedule(function()
      if state.active == chat then
        chat:refresh_from_store()
      end
    end)
  end)
  chat:open()
  chat.widget:render()
end

new_chat_for_tab = function(tab, source)
  if source then
    pcall(function()
      source:_persist_now()
    end)
  end
  local chat = create_chat(tab)
  if source then
    chat.provider_name = source.provider_name
    chat.model = source.model
    chat.mode = source.mode
    chat.config_values = vim.deepcopy(source.config_values or {})
  end
  set_active_chat(tab, chat)
  return chat
end

local function for_current_tab()
  local tab = api.nvim_get_current_tabpage()
  local state = tab_state(tab)
  local chat = state.active
  if not chat then
    chat = new_chat_for_tab(tab)
  end
  return chat
end

local function switch_to_thread(id)
  local tab = api.nvim_get_current_tabpage()
  local state = tab_state(tab)
  local live = state.by_id[id]
  live = live or Runtime.find(id)
  if live then
    set_active_chat(tab, live)
    return
  end
  local previous = state.active
  local chat = create_chat(tab)
  chat:load_thread(id, { hidden = true })
  Runtime.register(chat, tab)
  if previous and previous ~= chat then
    Runtime.register(previous, tab)
  end
  set_active_chat(tab, chat)
end

local augroup = api.nvim_create_augroup("zxz_chat", { clear = true })

api.nvim_create_autocmd("TabClosed", {
  group = augroup,
  callback = function(args)
    local tab = tonumber(args.file)
    if not tab then
      return
    end
    local state = Runtime.detach_tab(tab)
    if state then
      if state.unsubscribe then
        state.unsubscribe()
      end
      local roots = {}
      for _, chat in pairs(state.by_id or {}) do
        if chat.repo_root then
          roots[chat.repo_root] = true
        end
        chat:stop()
        pcall(function()
          chat:_persist_now()
        end)
      end
      for root in pairs(roots) do
        pcall(Checkpoint.gc, root, config.current.checkpoint_keep_n or 20)
      end
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
    switch_to_thread(choice.id)
  end)
end

local function saved_status(entry)
  local status = entry.status or "saved"
  local meta = STATUS_META[status] or STATUS_META.saved
  return status, meta.label, meta.group, meta.order
end

local function chat_agent_label(entry)
  local model = entry.model or entry.provider
  if model and model ~= "" then
    return model
  end
  return "-"
end

function M.chats_picker()
  local tab = api.nvim_get_current_tabpage()
  local state = tab_state(tab)
  local items = {}
  local seen = {}
  for _, chat in ipairs(Runtime.list_for_tab(tab)) do
    local entry = chat:summary_entry()
    entry.current = state.active == chat
    items[#items + 1] = entry
    seen[entry.id] = true
  end
  for _, entry in ipairs(HistoryStore.list()) do
    if not seen[entry.id] then
      local status, label, group, order = saved_status(entry)
      entry.status = status
      entry.status_label = label
      entry.group_label = group
      entry.status_order = order
      entry.live = false
      items[#items + 1] = entry
    end
  end
  if #items == 0 then
    vim.notify("0x0: no chats", vim.log.levels.INFO)
    return
  end
  table.sort(items, function(a, b)
    if (a.status_order or 99) ~= (b.status_order or 99) then
      return (a.status_order or 99) < (b.status_order or 99)
    end
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  vim.ui.select(items, {
    prompt = "0x0 chats",
    format_item = function(e)
      local current = e.current and "* " or "  "
      local scope = e.live and "live" or "saved"
      local when = e.updated_at and e.updated_at > 0 and os.date("%Y-%m-%d %H:%M", e.updated_at) or "---- -- -- --:--"
      return ("%s%-7s  %-16s  %-5s  %-16s  %s  %s  (%d msgs)"):format(
        current,
        e.group_label or "open",
        e.status_label or "saved",
        scope,
        chat_agent_label(e),
        when,
        e.title or "untitled",
        e.message_count or 0
      )
    end,
  }, function(choice)
    if choice then
      switch_to_thread(choice.id)
    end
  end)
end

function M.new()
  local tab = api.nvim_get_current_tabpage()
  new_chat_for_tab(tab, Runtime.active(tab))
end

local STATUS_ICON = {
  completed = "✓",
  cancelled = "⊘",
  failed = "✗",
  running = "…",
  accepted = "★",
  rejected = "✗",
}

---@param current_thread_only boolean
function M.runs_picker(current_thread_only)
  local chat = for_current_tab()
  local runs
  if current_thread_only then
    runs = RunsStore.list_for_thread(chat.persist_id)
  else
    runs = RunsStore.list()
  end
  if #runs == 0 then
    vim.notify("0x0: no AI tasks recorded", vim.log.levels.INFO)
    return
  end
  vim.ui.select(runs, {
    prompt = current_thread_only and "0x0 tasks in this chat" or "0x0 tasks",
    format_item = function(run)
      local when = os.date("%Y-%m-%d %H:%M", run.started_at or 0)
      local icon = STATUS_ICON[run.status or ""] or "·"
      local agent = run.agent or {}
      local model = agent.model or agent.provider or "?"
      local files = #(run.files_touched or {})
      local conflicts = #(run.conflicts or {})
      local summary = run.prompt_summary or ""
      if #summary > 60 then
        summary = summary:sub(1, 57) .. "..."
      end
      local conflict_tag = conflicts > 0 and (" ⚠%d"):format(conflicts) or ""
      return ("%s %s  %-18s  %d file%s%s  %s"):format(
        icon,
        when,
        model,
        files,
        files == 1 and " " or "s",
        conflict_tag,
        summary
      )
    end,
  }, function(choice)
    if not choice then
      return
    end
    for_current_tab():run_review(choice.run_id)
  end)
end

M.tasks_picker = M.runs_picker

function M.submit()
  local chat = for_current_tab()
  Runtime.submit(chat.persist_id)
end

---@param prompt string
function M.run_headless(prompt)
  local chat = for_current_tab()
  Runtime.submit_prompt(chat.persist_id, prompt, { headless = true })
end

---@param opts { prompt_blocks: table[], on_chunk: fun(text), on_done: fun(err) }
---@return fun() cancel
function M.run_inline_ask(opts)
  return for_current_tab():run_inline_ask(opts)
end

function M.cancel()
  local chat = for_current_tab()
  Runtime.cancel(chat.persist_id)
end

function M.changes()
  for_current_tab():show_changes()
end

function M.review()
  for_current_tab():review()
end

function M.add_current_file()
  for_current_tab():add_current_file()
end

function M.add_current_hunk()
  for_current_tab():add_current_hunk()
end

function M.add_visual_selection_from_prev()
  for_current_tab():add_visual_selection_from_prev()
end

---@param tool_call_id? string
function M.diff(tool_call_id)
  for_current_tab():diff(tool_call_id)
end

---@param run_id? string
function M.run_review(run_id)
  for_current_tab():run_review(run_id)
end

---@param run_id? string
function M.run_accept(run_id)
  for_current_tab():run_accept(run_id)
end

---@param run_id? string
function M.run_reject(run_id)
  for_current_tab():run_reject(run_id)
end

---@param run_id? string
function M.run_timeline(run_id)
  for_current_tab():run_timeline(run_id)
end

function M.accept_all()
  for_current_tab():accept_all()
end

function M.discard_all()
  for_current_tab():discard_all()
end

function M.stop()
  local chat = for_current_tab()
  Runtime.stop(chat.persist_id)
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

function M.set_config_option(category, value)
  for_current_tab():set_config_option(category, value)
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

function M.add_context_token(token)
  for_current_tab():add_context_token(token)
end

function M.queue_state()
  return for_current_tab():queue_state()
end

function M.queue_update(index, text)
  return for_current_tab():queue_update(index, text)
end

function M.queue_remove(index)
  return for_current_tab():queue_remove(index)
end

function M.queue_clear()
  for_current_tab():queue_clear()
end

function M.queue_send_next()
  return for_current_tab():queue_send_next()
end

function M.trim_open(index)
  return for_current_tab():trim_open(index)
end

function M.trim_clear()
  return for_current_tab():trim_clear()
end

return M
