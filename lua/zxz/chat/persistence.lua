-- Persistence: history snapshot to disk + thread reload.

local HistoryStore = require("zxz.core.history_store")

local M = {}

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
  HistoryStore.save({
    id = self.persist_id,
    title = self.title,
    created_at = self.persist_created_at,
    root = self.repo_root,
    messages = self.history.messages,
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
  self.history.messages = entry.messages or {}
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
