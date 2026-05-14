local ChatDB = require("zxz.core.chat_db")

local M = {}

---@return string id
function M.new_id()
  return ChatDB.new_id("chat")
end

---@param entry table
function M.save(entry)
  ChatDB.save_chat(entry)
end

---@param id string
---@return table|nil
function M.load(id)
  return ChatDB.load_chat(id)
end

---@return table[] entries (sorted by updated_at desc, summary fields only)
function M.list()
  return ChatDB.list_chats()
end

---@param id string
function M.delete(id)
  ChatDB.delete_chat(id)
end

return M
