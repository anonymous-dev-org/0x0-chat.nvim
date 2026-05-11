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
  HistoryStore.save({
    id = self.persist_id,
    title = self.title,
    created_at = self.persist_created_at,
    messages = self.history.messages,
    run_ids = self.run_ids or {},
    settings = {
      provider = self.provider_name,
      model = self.model,
      mode = self.mode,
    },
  })
end

---@param id string
function M:load_thread(id)
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
  self.widget:reset()
  self:open()
  self.widget:render()
end

return M
