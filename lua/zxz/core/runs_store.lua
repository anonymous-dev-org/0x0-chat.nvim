local ChatDB = require("zxz.core.chat_db")

local M = {}

---@param run table
function M.save(run)
  ChatDB.save_run(run)
end

---@param run_id string
---@return table|nil
function M.load(run_id)
  return ChatDB.load_run(run_id)
end

---@return table[] runs (sorted by started_at desc)
function M.list()
  return ChatDB.list_runs()
end

---@param thread_id string
---@return table[]
function M.list_for_thread(thread_id)
  return ChatDB.list_runs_for_chat(thread_id)
end

---@param run_id string
function M.delete(run_id)
  ChatDB.delete_run(run_id)
end

return M
