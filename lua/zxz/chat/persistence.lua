-- Persistence: history snapshot to disk + thread reload.

local HistoryStore = require("zxz.core.history_store")
local RunsStore = require("zxz.core.runs_store")

local M = {}

local function summarize(prompt)
  if type(prompt) ~= "string" then
    return ""
  end
  local trimmed = prompt:gsub("^%s+", ""):gsub("%s+$", "")
  if #trimmed <= 200 then
    return trimmed
  end
  return trimmed:sub(1, 200)
end

local function tool_ids(messages)
  local seen = {}
  for _, msg in ipairs(messages or {}) do
    if msg.type == "tool_call" and msg.tool_call_id then
      seen[msg.tool_call_id] = true
    end
  end
  return seen
end

local function edit_events_for_tool(run, tool)
  local events = {}
  local ids = {}
  for _, id in ipairs(tool.edit_event_ids or {}) do
    ids[id] = true
  end
  for _, event in ipairs((run and run.edit_events) or {}) do
    if event.tool_call_id == tool.tool_call_id or ids[event.id] then
      events[#events + 1] = event
    end
  end
  if #events == 0 then
    return nil
  end
  return events
end

local function history_tool_call(run, tool)
  return {
    type = "tool_call",
    tool_call_id = tool.tool_call_id,
    kind = tool.kind or "tool",
    title = tool.title or "",
    status = tool.status or "pending",
    raw_input = tool.raw_input,
    content = tool.content,
    locations = tool.locations,
    edit_events = edit_events_for_tool(run, tool),
  }
end

local function run_insert_index(messages, run)
  local user_id = run and run.user_id
  if user_id then
    for index, msg in ipairs(messages) do
      if msg.type == "user" and msg.id == user_id then
        return index + 1
      end
    end
  end

  local prompt = summarize(run and run.prompt_summary)
  if prompt == "" then
    return #messages + 1
  end
  local user_index
  for index, msg in ipairs(messages) do
    if msg.type == "user" and summarize(msg.text) == prompt then
      user_index = index
    end
  end
  if not user_index then
    return #messages + 1
  end
  local index = user_index + 1
  while index <= #messages do
    if messages[index].type == "user" then
      return index
    end
    index = index + 1
  end
  return #messages + 1
end

local function restore_missing_tool_calls(messages, run_ids)
  messages = messages or {}
  local seen = tool_ids(messages)
  for _, run_id in ipairs(run_ids or {}) do
    local run = RunsStore.load(run_id)
    local missing = {}
    for _, tool in ipairs((run and run.tool_calls) or {}) do
      if tool.tool_call_id and not seen[tool.tool_call_id] then
        missing[#missing + 1] = history_tool_call(run, tool)
        seen[tool.tool_call_id] = true
      end
    end
    if #missing > 0 then
      local index = run_insert_index(messages, run)
      for offset, msg in ipairs(missing) do
        table.insert(messages, index + offset - 1, msg)
      end
    end
  end
  return messages
end

function M:_schedule_persist()
  if self.persist_timer then
    self.persist_timer:stop()
    self.persist_timer:close()
  end
  self.persist_timer = vim.defer_fn(function()
    self.persist_timer = nil
    self:_persist_now()
  end, 1000)
end

function M:_persist_now()
  local status = self.status_snapshot and self:status_snapshot() or nil
  local messages = vim.deepcopy(self.history.messages or {})
  messages = restore_missing_tool_calls(messages, self.run_ids or {})
  HistoryStore.save({
    id = self.persist_id,
    title = self.title,
    created_at = self.persist_created_at,
    root = self.repo_root,
    messages = messages,
    run_ids = self.run_ids or {},
    status = status and status.key or nil,
    settings = {
      provider = self.provider_name,
      model = self.model,
      mode = self.mode,
    },
  })
end

---@param entry table
function M:_apply_thread_entry(entry)
  self.history:clear()
  self.history.messages = restore_missing_tool_calls(vim.deepcopy(entry.messages or {}), entry.run_ids or {})
  for _, msg in ipairs(self.history.messages) do
    if msg.type == "user" and msg.id then
      self.history.next_id = math.max(self.history.next_id, (tonumber(msg.id) or 0) + 1)
    end
  end
  self.persist_id = entry.id
  self.run_ids = entry.run_ids or {}
  self.title = entry.title
  self.title_requested = entry.title and entry.title ~= "" and entry.title ~= "untitled"
  self.title_pending = false
  self.persist_created_at = entry.created_at or os.time()
  if entry.settings then
    self.provider_name = entry.settings.provider or self.provider_name
    self.model = entry.settings.model
    self.mode = entry.settings.mode
  end
end

function M:refresh_from_store()
  local entry = HistoryStore.load(self.persist_id)
  if not entry then
    return false
  end
  self:_apply_thread_entry(entry)
  self.widget:rerender_all({ preserve_scroll = true })
  return true
end

---@param id string
---@param opts? { hidden?: boolean }
function M:load_thread(id, opts)
  opts = opts or {}
  local entry = HistoryStore.load(id)
  if not entry then
    vim.notify("0x0: chat history entry not found", vim.log.levels.WARN)
    return
  end
  self:_reset_session()
  self:_apply_thread_entry(entry)
  self.widget:reset()
  if not opts.hidden then
    self:open()
    self.widget:render()
  end
end

return M
