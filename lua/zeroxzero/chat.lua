-- Chat orchestrator: defines the Chat class, mixes in lifecycle methods from
-- chat/* submodules, owns the per-tabpage registry, and exposes the M
-- surface consumed by lua/zeroxzero/init.lua.

local config = require("zeroxzero.config")
local History = require("zeroxzero.history")
local HistoryStore = require("zeroxzero.history_store")
local ChatWidget = require("zeroxzero.chat_widget")
local Checkpoint = require("zeroxzero.checkpoint")
local InlineDiff = require("zeroxzero.inline_diff")

local api = vim.api

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
---@field title string|nil
---@field title_requested boolean
---@field title_pending boolean
local Chat = {}
Chat.__index = Chat

local function mixin(target, src)
  for k, v in pairs(src) do
    target[k] = v
  end
end

mixin(Chat, require("zeroxzero.chat.session"))
mixin(Chat, require("zeroxzero.chat.turn"))
mixin(Chat, require("zeroxzero.chat.permissions"))
mixin(Chat, require("zeroxzero.chat.fs_bridge"))
mixin(Chat, require("zeroxzero.chat.persistence"))
mixin(Chat, require("zeroxzero.chat.checkpoints"))

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
    title = nil,
    title_requested = false,
    title_pending = false,
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
  local mentions = require("zeroxzero.reference_mentions").parse(text, cwd)
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
