-- Live chat runtime registry. The DB owns durable chat state; this module owns
-- in-process chat objects that may still be streaming or waiting on input.

local M = {}

---@class zxz.ChatTabState
---@field active zxz.Chat|nil
---@field by_id table<string, zxz.Chat>
---@field unsubscribe (fun()|nil)

---@type table<integer, zxz.ChatTabState>
local tabs = {}

---@type table<string, zxz.Chat>
local chats = {}

---@param tab integer
---@param create? boolean
---@return zxz.ChatTabState|nil
function M.tab_state(tab, create)
  local state = tabs[tab]
  if not state and create ~= false then
    state = { by_id = {} }
    tabs[tab] = state
  end
  return state
end

---@param chat zxz.Chat
---@param tab? integer
function M.register(chat, tab)
  if not chat or not chat.persist_id then
    return
  end
  chats[chat.persist_id] = chat
  tab = tab or chat.tab_page_id
  if tab then
    local state = M.tab_state(tab)
    state.by_id[chat.persist_id] = chat
  end
end

---@param chat_or_id zxz.Chat|string
function M.unregister(chat_or_id)
  local id = type(chat_or_id) == "table" and chat_or_id.persist_id or chat_or_id
  if not id then
    return
  end
  chats[id] = nil
  for _, state in pairs(tabs) do
    state.by_id[id] = nil
    if state.active and state.active.persist_id == id then
      state.active = nil
    end
  end
end

---@param tab integer
---@param chat zxz.Chat
function M.set_active(tab, chat)
  local state = M.tab_state(tab)
  state.active = chat
  M.register(chat, tab)
end

---@param tab integer
---@return zxz.Chat|nil
function M.active(tab)
  local state = M.tab_state(tab, false)
  return state and state.active or nil
end

---@param id string
---@return zxz.Chat|nil
function M.find(id)
  return chats[id]
end

---@param tab integer
---@return table<string, zxz.Chat>
function M.live_for_tab(tab)
  local state = M.tab_state(tab, false)
  return state and state.by_id or {}
end

---@param tab integer
---@return zxz.Chat[]
function M.list_for_tab(tab)
  local out = {}
  for _, chat in pairs(M.live_for_tab(tab)) do
    out[#out + 1] = chat
  end
  return out
end

---@param tab integer
---@return zxz.ChatTabState|nil
function M.detach_tab(tab)
  local state = tabs[tab]
  if not state then
    return nil
  end
  tabs[tab] = nil
  for id in pairs(state.by_id or {}) do
    chats[id] = nil
  end
  return state
end

---@param id string
function M.cancel(id)
  local chat = M.find(id)
  if chat then
    chat:cancel()
  end
end

---@param id string
function M.stop(id)
  local chat = M.find(id)
  if chat then
    chat:stop()
  end
end

---@param id string
function M.submit(id)
  local chat = M.find(id)
  if chat then
    chat:submit()
  end
end

---@param id string
---@param prompt string
---@param opts? table
function M.submit_prompt(id, prompt, opts)
  local chat = M.find(id)
  if chat then
    chat:submit_prompt(prompt, opts)
  end
end

function M._reset_for_tests()
  for _, state in pairs(tabs) do
    if state.unsubscribe then
      state.unsubscribe()
    end
  end
  tabs = {}
  chats = {}
end

return M
