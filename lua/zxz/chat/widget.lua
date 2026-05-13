local config = require("zxz.core.config")
local Line = require("zxz.chat.line")
local mention_highlight = require("zxz.context.mention_highlight")
local tool_policy = require("zxz.chat.tool_policy")

local api = vim.api

local NS = api.nvim_create_namespace("zxz_chat_widget")

local STATUS_ICONS = {
  pending = "·",
  in_progress = "⠋",
  completed = "✓",
  failed = "✗",
}

local STATUS_HL = {
  pending = "ZxzChatStatusPending",
  in_progress = "ZxzChatStatusInProgress",
  completed = "ZxzChatStatusCompleted",
  failed = "ZxzChatStatusFailed",
}

local STATE_HL = {
  waiting = "ZxzChatHeaderStateWaiting",
  responding = "ZxzChatHeaderStateResponding",
}

local PERMISSION_PENDING_HL = "ZxzChatStatusPending"
local PERMISSION_DECIDED_HL = "Comment"

local ACTIVITY_SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ACTIVITY_LABELS = {
  waiting = "Working",
  responding = "Working",
}
local ACTIVITY_FOOTER_PADDING = 2

local PERMISSION_HINT_INLINE = "  — [a] allow once  [A] allow always  [r] reject once  [R] reject always"
local KEY_TO_KIND = {
  a = "allow_once",
  A = "allow_always",
  r = "reject_once",
  R = "reject_always",
}

---@class zxz.ChatWidget
---@field tab_page_id integer
---@field history zxz.History
---@field on_submit fun()
---@field on_cancel fun()
---@field transcript_buf integer|nil
---@field input_buf integer|nil
---@field transcript_win integer|nil
---@field input_win integer|nil
---@field rendered_count integer
---@field tool_extmarks table<string, integer>
---@field user_extmarks table<string, integer>
---@field context_detail_expanded table<string, boolean>
---@field context_row_refs table<integer, table>
---@field tool_row_refs table<integer, table>
---@field tool_event_signatures table<string, string>
---@field permission_pending string|nil
---@field permission_keymap_set boolean
---@field last_kind string|nil
---@field activity_state string|nil
---@field activity_label string|nil
---@field activity_extmark integer|nil
---@field activity_frame integer
---@field activity_timer uv_timer_t|nil
---@field work_state_provider (fun(): table|nil)|nil
---@field agent_run_open boolean
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
---@param history zxz.History
---@param on_submit fun()
---@param on_cancel fun()
---@param work_state_provider? fun(): table|nil
---@return zxz.ChatWidget
function ChatWidget.new(tab_page_id, history, on_submit, on_cancel, work_state_provider)
  return setmetatable({
    tab_page_id = tab_page_id,
    history = history,
    on_submit = on_submit,
    on_cancel = on_cancel,
    transcript_buf = nil,
    input_buf = nil,
    transcript_win = nil,
    input_win = nil,
    rendered_count = 0,
    tool_extmarks = {},
    user_extmarks = {},
    context_detail_expanded = {},
    context_row_refs = {},
    tool_row_refs = {},
    tool_event_signatures = {},
    permission_pending = nil,
    permission_keymap_set = false,
    last_kind = nil,
    activity_state = nil,
    activity_label = nil,
    activity_extmark = nil,
    activity_frame = 1,
    activity_timer = nil,
    work_state_provider = work_state_provider,
    agent_run_open = false,
    suppress_scroll_once = false,
    prompt_history = {},
    prompt_history_index = 0,
    prompt_history_draft = nil,
  }, ChatWidget)
end

-- Forward declarations for locals used by ChatWidget methods declared
-- before their bodies.
local default_expanded
local place_status_extmark
local place_user_extmark
local tool_hunk_context

local function buf_valid(bufnr)
  return bufnr and api.nvim_buf_is_valid(bufnr)
end

local function win_valid(winid)
  return winid and api.nvim_win_is_valid(winid)
end

local HIGHLIGHTS = {
  ZxzChatStatusPending = "DiagnosticVirtualTextWarn",
  ZxzChatStatusInProgress = "DiagnosticVirtualTextInfo",
  ZxzChatStatusCompleted = "DiagnosticVirtualTextOk",
  ZxzChatStatusFailed = "DiagnosticVirtualTextError",
  ZxzChatHeaderStateWaiting = "DiagnosticVirtualTextWarn",
  ZxzChatHeaderStateResponding = "DiagnosticVirtualTextInfo",
}

for name, link in pairs(HIGHLIGHTS) do
  api.nvim_set_hl(0, name, { link = link, default = true })
end

local function tab_win_for_buf(tab_page_id, bufnr)
  if not bufnr or not api.nvim_tabpage_is_valid(tab_page_id) then
    return nil
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(tab_page_id)) do
    if api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

local function disable_ambient_completion(bufnr)
  vim.bo[bufnr].completefunc = ""
  vim.bo[bufnr].omnifunc = ""
  vim.bo[bufnr].tagfunc = ""
  vim.bo[bufnr].complete = ""
  vim.b[bufnr].cmp_enabled = false
  vim.b[bufnr].blink_cmp_enabled = false
  -- Explicit contract for our own inline ghost completion: opt out here.
  -- Chat input / transcript are not file-backed; ambient AI completion is
  -- noise, and rerendering virt_text on every keystroke disrupts the UI.
  vim.b[bufnr].zxz_complete_disable = true
end

local INPUT_CONTROL_PATTERN = "["
  .. string.char(1)
  .. "-"
  .. string.char(8)
  .. string.char(11)
  .. "-"
  .. string.char(31)
  .. string.char(127)
  .. "]"

local function strip_input_controls(line)
  return (line:gsub(INPUT_CONTROL_PATTERN, ""))
end

local function sanitize_input_buffer(bufnr)
  if not buf_valid(bufnr) or vim.b[bufnr].zxz_chat_sanitizing then
    return
  end

  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local changed = false
  for i, line in ipairs(lines) do
    local clean = strip_input_controls(line)
    if clean ~= line then
      lines[i] = clean
      changed = true
    end
  end
  if not changed then
    return
  end

  vim.b[bufnr].zxz_chat_sanitizing = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.b[bufnr].zxz_chat_sanitizing = false
end

local function attach_input_sanitizer(bufnr)
  local pending = false
  local function schedule_sanitize()
    if pending then
      return
    end
    pending = true
    vim.schedule(function()
      pending = false
      sanitize_input_buffer(bufnr)
    end)
  end

  api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      schedule_sanitize()
    end,
    on_detach = function()
      pending = false
    end,
  })
end

function ChatWidget:_ensure_transcript_buf()
  if buf_valid(self.transcript_buf) then
    return self.transcript_buf
  end
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, ("[0x0 Chat #%d]"):format(self.tab_page_id))
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  vim.bo[bufnr].modifiable = false
  pcall(vim.treesitter.start, bufnr, "markdown")
  vim.keymap.set("n", "<localleader>o", function()
    self:toggle_detail_at_cursor()
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "0x0 chat toggle details",
  })
  vim.keymap.set("n", "<CR>", function()
    self:jump_context_at_cursor()
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "0x0 chat open context",
  })
  vim.keymap.set("n", "<localleader>a", function()
    self:ask_tool_hunk_at_cursor()
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "0x0 chat ask about hunk",
  })
  vim.keymap.set("n", "<localleader>e", function()
    self:edit_tool_hunk_at_cursor()
  end, {
    buffer = bufnr,
    nowait = true,
    silent = true,
    desc = "0x0 chat edit hunk",
  })
  self.transcript_buf = bufnr
  self.rendered_count = 0
  self.tool_extmarks = {}
  self.user_extmarks = {}
  self.context_row_refs = {}
  self.tool_row_refs = {}
  self.tool_event_signatures = {}
  self.last_kind = nil
  self.activity_extmark = nil
  return bufnr
end

---@param row integer
---@return table|nil
function ChatWidget:_user_at_row(row)
  if not buf_valid(self.transcript_buf) then
    return nil
  end
  for _, msg in ipairs(self.history.messages) do
    if msg.type == "user" and msg.id then
      local mark = self.user_extmarks[msg.id]
      if mark then
        local pos = api.nvim_buf_get_extmark_by_id(self.transcript_buf, NS, mark, {})
        if pos[1] and (row == pos[1] or row == pos[1] + 1) then
          return msg
        end
      end
    end
  end
  return nil
end

---Find the tool_call history entry whose extmark sits at `row` (0-indexed).
---@param row integer
---@return table|nil
function ChatWidget:_tool_at_row(row)
  if not buf_valid(self.transcript_buf) then
    return nil
  end
  for _, msg in ipairs(self.history.messages) do
    if msg.type == "tool_call" and msg.tool_call_id then
      local mark = self.tool_extmarks[msg.tool_call_id]
      if mark then
        local pos = api.nvim_buf_get_extmark_by_id(self.transcript_buf, NS, mark, {})
        if pos[1] == row then
          return msg
        end
      end
    end
  end
  return nil
end

---@param row integer 0-indexed buffer row
---@return table|nil
function ChatWidget:_context_ref_at_row(row)
  return self.context_row_refs and self.context_row_refs[row] or nil
end

---@param row integer 0-indexed buffer row
---@return table|nil
function ChatWidget:_tool_ref_at_row(row)
  return self.tool_row_refs and self.tool_row_refs[row] or nil
end

---@param record table
---@return table|nil
local function context_target(record)
  if type(record) ~= "table" or record.trimmed or record.resolved == false then
    return nil
  end
  local mention = type(record.mention) == "table" and record.mention or record
  local kind = record.type or mention.type
  if kind ~= "file" and kind ~= "range" then
    return nil
  end
  local path = mention.absolute_path or record.absolute_path
  if not path or path == "" then
    return nil
  end
  local stat = vim.loop.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return {
    path = path,
    line = math.max(1, tonumber(mention.start_line or record.start_line) or 1),
    end_line = tonumber(mention.end_line or record.end_line),
  }
end

---@return integer|nil
function ChatWidget:_source_window()
  if not api.nvim_tabpage_is_valid(self.tab_page_id) then
    return nil
  end
  for _, win in ipairs(api.nvim_tabpage_list_wins(self.tab_page_id)) do
    local buf = api.nvim_win_get_buf(win)
    local buftype = vim.bo[buf].buftype
    local filetype = vim.bo[buf].filetype
    local name = api.nvim_buf_get_name(buf)
    if
      buf ~= self.transcript_buf
      and buf ~= self.input_buf
      and buftype == ""
      and name ~= ""
      and filetype ~= "zxz-review"
    then
      return win
    end
  end
  return nil
end

---@param record table
---@return boolean
function ChatWidget:jump_context_record(record)
  local target = context_target(record)
  if not target then
    return false
  end

  local source_win = self:_source_window()
  if source_win and win_valid(source_win) then
    api.nvim_set_current_win(source_win)
  elseif win_valid(self.transcript_win) then
    api.nvim_set_current_win(self.transcript_win)
    vim.cmd("leftabove vsplit")
  end

  vim.cmd("edit " .. vim.fn.fnameescape(target.path))
  local last = api.nvim_buf_line_count(0)
  api.nvim_win_set_cursor(0, { math.min(target.line, last), 0 })
  pcall(vim.cmd, "normal! zz")
  return true
end

---@param path string|nil
---@param root? string
---@return string|nil
local function resolve_event_path(path, root)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if vim.fn.fnamemodify(path, ":p") == path then
    return vim.fn.fnamemodify(path, ":p")
  end
  return vim.fn.fnamemodify((root or vim.fn.getcwd()) .. "/" .. path, ":p")
end

---@param ref table
---@return boolean
function ChatWidget:jump_tool_ref(ref)
  local event = ref and ref.event
  if type(event) ~= "table" then
    return false
  end
  local path = resolve_event_path(event.path, event.root)
  if not path then
    return false
  end
  local stat = vim.loop.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return false
  end

  local hunk = ref.hunk or (event.hunks and event.hunks[1])
  local line = math.max(1, tonumber(hunk and hunk.new_start) or 1)
  local source_win = self:_source_window()
  if source_win and win_valid(source_win) then
    api.nvim_set_current_win(source_win)
  elseif win_valid(self.transcript_win) then
    api.nvim_set_current_win(self.transcript_win)
    vim.cmd("leftabove vsplit")
  end

  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local last = api.nvim_buf_line_count(0)
  api.nvim_win_set_cursor(0, { math.min(line, last), 0 })
  pcall(vim.cmd, "normal! zz")
  return true
end

---@param ref table|nil
---@return { bufnr: integer, range: { start_line: integer, end_line: integer } }|nil
function ChatWidget:_open_tool_hunk_ref(ref)
  if type(ref) ~= "table" or type(ref.hunk) ~= "table" then
    return nil
  end
  if not self:jump_tool_ref(ref) then
    return nil
  end

  local bufnr = api.nvim_get_current_buf()
  local last = api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, tonumber(ref.hunk.new_start) or 1)
  local count = math.max(1, tonumber(ref.hunk.new_count) or 1)
  local end_line = start_line + count - 1
  start_line = math.min(start_line, last)
  end_line = math.min(math.max(start_line, end_line), last)
  return {
    bufnr = bufnr,
    range = {
      start_line = start_line,
      end_line = end_line,
    },
    hunk_context = tool_hunk_context(ref),
  }
end

---@return boolean
function ChatWidget:jump_tool_at_cursor()
  local win = self.transcript_win
  if not win_valid(win) then
    return false
  end
  local cursor = api.nvim_win_get_cursor(win)
  local ref = self:_tool_ref_at_row(cursor[1] - 1)
  if not ref then
    return false
  end
  return self:jump_tool_ref(ref)
end

---@param opts? { question?: string }
---@return boolean
function ChatWidget:ask_tool_hunk_at_cursor(opts)
  local win = self.transcript_win
  if not win_valid(win) then
    return false
  end
  local cursor = api.nvim_win_get_cursor(win)
  local target = self:_open_tool_hunk_ref(self:_tool_ref_at_row(cursor[1] - 1))
  if not target then
    vim.notify("0x0: no tool hunk under cursor", vim.log.levels.INFO)
    return false
  end
  require("zxz.edit.inline_ask").ask({
    bufnr = target.bufnr,
    range = target.range,
    hunk_context = target.hunk_context,
    question = opts and opts.question,
  })
  return true
end

---@param opts? { instruction?: string }
---@return boolean
function ChatWidget:edit_tool_hunk_at_cursor(opts)
  local win = self.transcript_win
  if not win_valid(win) then
    return false
  end
  local cursor = api.nvim_win_get_cursor(win)
  local target = self:_open_tool_hunk_ref(self:_tool_ref_at_row(cursor[1] - 1))
  if not target then
    vim.notify("0x0: no tool hunk under cursor", vim.log.levels.INFO)
    return false
  end
  require("zxz.edit.inline_edit").start({
    bufnr = target.bufnr,
    range = target.range,
    hunk_context = target.hunk_context,
    instruction = opts and opts.instruction,
  })
  return true
end

---@return boolean
function ChatWidget:jump_context_at_cursor()
  local win = self.transcript_win
  if not win_valid(win) then
    return false
  end
  local cursor = api.nvim_win_get_cursor(win)
  local ref = self:_context_ref_at_row(cursor[1] - 1)
  if not ref then
    return self:jump_tool_at_cursor()
  end
  return self:jump_context_record(ref.record)
end

function ChatWidget:toggle_context_detail_at_cursor()
  local win = self.transcript_win
  if not win_valid(win) then
    return false
  end
  local cursor = api.nvim_win_get_cursor(win)
  local msg = self:_user_at_row(cursor[1] - 1)
    or (self:_context_ref_at_row(cursor[1] - 1) and self:_context_ref_at_row(cursor[1] - 1).msg)
  if not msg or not msg.id then
    return false
  end
  self.context_detail_expanded[msg.id] = not self.context_detail_expanded[msg.id]
  self:rerender_all({ preserve_scroll = true })
  if win_valid(win) then
    local last = api.nvim_buf_line_count(self.transcript_buf)
    pcall(api.nvim_win_set_cursor, win, { math.min(cursor[1], last), cursor[2] })
  end
  return true
end

function ChatWidget:toggle_tool_expand_at_cursor()
  local win = self.transcript_win
  if not win_valid(win) then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)
  local msg = self:_tool_at_row(cursor[1] - 1)
  if not msg then
    return
  end
  local current = msg.expanded
  if current == nil then
    current = default_expanded(msg)
  end
  msg.expanded = not current
  -- Re-place this extmark with new virt_lines.
  local mark = self.tool_extmarks[msg.tool_call_id]
  if mark and buf_valid(self.transcript_buf) then
    local pos = api.nvim_buf_get_extmark_by_id(self.transcript_buf, NS, mark, {})
    if pos[1] then
      api.nvim_buf_del_extmark(self.transcript_buf, NS, mark)
      self.tool_extmarks[msg.tool_call_id] = place_status_extmark(self.transcript_buf, pos[1], msg)
    end
  end
end

function ChatWidget:toggle_detail_at_cursor()
  if self:toggle_context_detail_at_cursor() then
    return
  end
  self:toggle_tool_expand_at_cursor()
end

function ChatWidget:_ensure_input_buf()
  if buf_valid(self.input_buf) then
    return self.input_buf
  end
  local bufnr = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(bufnr, ("[0x0 Chat Input #%d]"):format(self.tab_page_id))
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "zxz-chat-input"
  disable_ambient_completion(bufnr)

  local base_opts = { buffer = bufnr, nowait = true, silent = true }
  local function map(mode, lhs, fn, desc, extra)
    local o = vim.tbl_extend("force", base_opts, { desc = desc })
    if extra then
      o = vim.tbl_extend("force", o, extra)
    end
    vim.keymap.set(mode, lhs, fn, o)
  end

  map("n", "<CR>", function()
    self.on_submit()
  end, "0x0 chat submit")
  map("n", "<localleader>c", function()
    self.on_cancel()
  end, "0x0 chat cancel")
  map("n", "<localleader>d", function()
    require("zxz.chat.chat").review()
  end, "0x0 chat review diff")
  map("n", "<C-p>", function()
    self:nav_history(-1)
  end, "0x0 chat previous prompt")
  map("n", "<C-n>", function()
    self:nav_history(1)
  end, "0x0 chat next prompt")

  self.input_buf = bufnr
  attach_input_sanitizer(bufnr)
  -- Highlight manually typed mentions inline; keep the input itself plain.
  mention_highlight.attach(bufnr, vim.fn.getcwd(), nil)
  return bufnr
end

function ChatWidget:open()
  local transcript = self:_ensure_transcript_buf()
  local input = self:_ensure_input_buf()

  if api.nvim_get_current_tabpage() ~= self.tab_page_id then
    return
  end

  local need_transcript_win = not win_valid(self.transcript_win)
    or api.nvim_win_get_buf(self.transcript_win) ~= transcript
  local need_input_win = not win_valid(self.input_win) or api.nvim_win_get_buf(self.input_win) ~= input

  if need_transcript_win then
    vim.cmd("botright vsplit")
    self.transcript_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.transcript_win, transcript)
    local width = math.max(60, math.floor(vim.o.columns * (config.current.width or 0.4)))
    api.nvim_win_set_width(self.transcript_win, width)
    vim.wo[self.transcript_win].wrap = true
    vim.wo[self.transcript_win].linebreak = true
    vim.wo[self.transcript_win].number = false
    vim.wo[self.transcript_win].relativenumber = false
    vim.wo[self.transcript_win].signcolumn = "no"
    vim.wo[self.transcript_win].winbar = ""
    pcall(function()
      vim.wo[self.transcript_win].foldmethod = "expr"
      vim.wo[self.transcript_win].foldexpr = "v:lua.vim.treesitter.foldexpr()"
      vim.wo[self.transcript_win].foldlevel = 99
      vim.wo[self.transcript_win].foldenable = true
    end)
  end

  if need_input_win then
    api.nvim_set_current_win(self.transcript_win)
    vim.cmd("belowright split")
    self.input_win = api.nvim_get_current_win()
    api.nvim_win_set_buf(self.input_win, input)
    api.nvim_win_set_height(self.input_win, config.current.input_height or 8)
    vim.wo[self.input_win].wrap = true
    vim.wo[self.input_win].linebreak = true
    vim.wo[self.input_win].winfixheight = true
    vim.wo[self.input_win].number = false
    vim.wo[self.input_win].relativenumber = false
    vim.wo[self.input_win].signcolumn = "no"
    vim.wo[self.input_win].winbar = ""
  end

  if win_valid(self.input_win) then
    api.nvim_set_current_win(self.input_win)
  end
end

function ChatWidget:close()
  if win_valid(self.input_win) then
    pcall(api.nvim_win_close, self.input_win, true)
  end
  if win_valid(self.transcript_win) then
    pcall(api.nvim_win_close, self.transcript_win, true)
  end
  self.input_win = nil
  self.transcript_win = nil
end

---@return boolean
function ChatWidget:is_open()
  if not api.nvim_tabpage_is_valid(self.tab_page_id) then
    return false
  end
  if win_valid(self.transcript_win) and api.nvim_win_get_tabpage(self.transcript_win) == self.tab_page_id then
    return true
  end
  if win_valid(self.input_win) and api.nvim_win_get_tabpage(self.input_win) == self.tab_page_id then
    return true
  end
  -- Fall back to scanning the tabpage in case win handles got out of sync.
  return tab_win_for_buf(self.tab_page_id, self.transcript_buf) ~= nil
    or tab_win_for_buf(self.tab_page_id, self.input_buf) ~= nil
end

function ChatWidget:focus_input()
  if not win_valid(self.input_win) then
    self.input_win = tab_win_for_buf(self.tab_page_id, self.input_buf)
  end
  if win_valid(self.input_win) then
    api.nvim_set_current_win(self.input_win)
  end
end

---@return string
function ChatWidget:read_input()
  if not buf_valid(self.input_buf) then
    return ""
  end
  local lines = api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

function ChatWidget:clear_input()
  if not buf_valid(self.input_buf) then
    return
  end
  api.nvim_buf_set_lines(self.input_buf, 0, -1, false, { "" })
end

---@param lines string[]
function ChatWidget:prepend_input(lines)
  self:_ensure_input_buf()
  if #lines == 0 then
    return
  end
  local existing = api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
  if #existing == 1 and existing[1] == "" then
    existing = {}
  end
  local combined = {}
  vim.list_extend(combined, lines)
  vim.list_extend(combined, existing)
  api.nvim_buf_set_lines(self.input_buf, 0, -1, false, combined)
end

---@param text string
function ChatWidget:push_history(text)
  if not text or text == "" then
    return
  end
  if self.prompt_history[#self.prompt_history] == text then
    self.prompt_history_index = 0
    self.prompt_history_draft = nil
    return
  end
  self.prompt_history[#self.prompt_history + 1] = text
  if #self.prompt_history > 100 then
    table.remove(self.prompt_history, 1)
  end
  self.prompt_history_index = 0
  self.prompt_history_draft = nil
end

---@param direction integer -1 = older (C-p), 1 = newer (C-n)
function ChatWidget:nav_history(direction)
  if not buf_valid(self.input_buf) then
    return
  end
  local total = #self.prompt_history
  if total == 0 then
    return
  end
  if self.prompt_history_index == 0 and direction == -1 then
    local current = api.nvim_buf_get_lines(self.input_buf, 0, -1, false)
    self.prompt_history_draft = table.concat(current, "\n")
    self.prompt_history_index = total
  elseif direction == -1 then
    self.prompt_history_index = math.max(1, self.prompt_history_index - 1)
  elseif direction == 1 then
    self.prompt_history_index = self.prompt_history_index + 1
    if self.prompt_history_index > total then
      self.prompt_history_index = 0
      local draft = self.prompt_history_draft or ""
      api.nvim_buf_set_lines(self.input_buf, 0, -1, false, vim.split(draft, "\n", { plain = true }))
      self.prompt_history_draft = nil
      return
    end
  end
  local entry = self.prompt_history[self.prompt_history_index]
  if entry then
    api.nvim_buf_set_lines(self.input_buf, 0, -1, false, vim.split(entry, "\n", { plain = true }))
  end
end

function ChatWidget:reset()
  self:unbind_permission_keys()
  if buf_valid(self.transcript_buf) then
    vim.bo[self.transcript_buf].modifiable = true
    api.nvim_buf_set_lines(self.transcript_buf, 0, -1, false, {})
    api.nvim_buf_clear_namespace(self.transcript_buf, NS, 0, -1)
    vim.bo[self.transcript_buf].modifiable = false
  end
  self:clear_input()
  self.rendered_count = 0
  self.tool_extmarks = {}
  self.user_extmarks = {}
  self.context_detail_expanded = {}
  self.context_row_refs = {}
  self.tool_row_refs = {}
  self.tool_event_signatures = {}
  self.last_kind = nil
  self.agent_run_open = false
  self:set_activity(nil)
end

---@param opts? { preserve_scroll?: boolean }
function ChatWidget:rerender_all(opts)
  opts = opts or {}
  if buf_valid(self.transcript_buf) then
    vim.bo[self.transcript_buf].modifiable = true
    api.nvim_buf_set_lines(self.transcript_buf, 0, -1, false, {})
    api.nvim_buf_clear_namespace(self.transcript_buf, NS, 0, -1)
    vim.bo[self.transcript_buf].modifiable = false
  end
  self.rendered_count = 0
  self.tool_extmarks = {}
  self.user_extmarks = {}
  self.context_row_refs = {}
  self.tool_row_refs = {}
  self.tool_event_signatures = {}
  self.last_kind = nil
  self.agent_run_open = false
  self.suppress_scroll_once = opts.preserve_scroll == true
  self:render()
end

function ChatWidget:_stop_activity_timer()
  if not self.activity_timer then
    return
  end
  self.activity_timer:stop()
  self.activity_timer:close()
  self.activity_timer = nil
end

function ChatWidget:_ensure_activity_timer()
  if self.activity_timer then
    return
  end
  local timer = vim.loop.new_timer()
  self.activity_timer = timer
  timer:start(
    0,
    120,
    vim.schedule_wrap(function()
      if not self.activity_state then
        self:_stop_activity_timer()
        return
      end
      self.activity_frame = (self.activity_frame % #ACTIVITY_SPINNER) + 1
      self:_render_activity()
    end)
  )
  pcall(function()
    timer:unref()
  end)
end

function ChatWidget:_render_activity()
  local bufnr = self.transcript_buf
  if not buf_valid(bufnr) then
    return
  end

  if self.activity_extmark then
    pcall(api.nvim_buf_del_extmark, bufnr, NS, self.activity_extmark)
    self.activity_extmark = nil
  end
  if not self.activity_state then
    return
  end

  local spinner = ACTIVITY_SPINNER[self.activity_frame] or ACTIVITY_SPINNER[1]
  local label = self.activity_label or ACTIVITY_LABELS[self.activity_state] or "Working"
  local hl = STATE_HL[self.activity_state] or "Comment"
  local last_line = math.max(api.nvim_buf_line_count(bufnr) - 1, 0)
  self.activity_extmark = api.nvim_buf_set_extmark(bufnr, NS, last_line, 0, {
    virt_lines = { self:_activity_chunks(spinner, hl, label) },
    virt_lines_above = false,
  })
end

---@param files string[]|nil
---@return string|nil
local function files_summary(files)
  if type(files) ~= "table" or #files == 0 then
    return nil
  end
  local labels = {}
  for index, path in ipairs(files) do
    if index > 2 then
      break
    end
    labels[#labels + 1] = vim.fn.fnamemodify(tostring(path), ":~:.")
  end
  local suffix = #files > 2 and (" +" .. (#files - 2)) or ""
  return table.concat(labels, ", ") .. suffix
end

---@param text string|nil
---@return integer
local function display_width(text)
  return vim.fn.strdisplaywidth(tostring(text or ""))
end

---@param chunks table[]
---@return integer
local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks) do
    width = width + display_width(chunk[1])
  end
  return width
end

---@param text string
---@param max_width integer
---@return string
local function truncate_display(text, max_width)
  text = tostring(text or "")
  if max_width <= 0 then
    return ""
  end
  if display_width(text) <= max_width then
    return text
  end
  if max_width <= 3 then
    return string.rep(".", max_width)
  end

  local limit = max_width - 3
  local out = {}
  local width = 0
  for char in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
    local char_width = display_width(char)
    if width + char_width > limit then
      break
    end
    out[#out + 1] = char
    width = width + char_width
  end
  return table.concat(out) .. "..."
end

---@param state table|nil
---@return string[]
local function activity_state_parts(state)
  if type(state) ~= "table" then
    return {}
  end
  local parts = {}
  local tool = state.running_tool
  if type(tool) == "table" then
    local tool_label = tool.kind or "tool"
    if tool.title and tool.title ~= "" then
      tool_label = tool_label .. " " .. tool.title
    end
    parts[#parts + 1] = "tool: " .. tool_label
  elseif type(tool) == "string" and tool ~= "" then
    parts[#parts + 1] = "tool: " .. tool
  end
  local files = files_summary(state.files_touched)
  if files then
    parts[#parts + 1] = "files: " .. files
  end
  local pending_review = tonumber(state.pending_review) or 0
  if pending_review > 0 then
    parts[#parts + 1] = "review: " .. pending_review
  end
  local conflicts = tonumber(state.conflicts) or 0
  if conflicts > 0 then
    parts[#parts + 1] = "conflicts: " .. conflicts
  end
  local blocked = tonumber(state.blocked) or 0
  if blocked > 0 then
    parts[#parts + 1] = "blocked: " .. blocked
  end
  return parts
end

---@return table|nil
function ChatWidget:_work_state()
  if type(self.work_state_provider) ~= "function" then
    return nil
  end
  local ok, state = pcall(self.work_state_provider)
  if not ok then
    return nil
  end
  return state
end

---@return integer|nil
function ChatWidget:_activity_width()
  if not win_valid(self.transcript_win) then
    return nil
  end
  return math.max(0, api.nvim_win_get_width(self.transcript_win) - ACTIVITY_FOOTER_PADDING)
end

---@param spinner string
---@param spinner_hl string
---@param label string
---@return table[]
function ChatWidget:_activity_chunks(spinner, spinner_hl, label)
  local chunks = { { spinner .. " ", spinner_hl }, { label, "Comment" } }
  local max_width = self:_activity_width()
  for _, part in ipairs(activity_state_parts(self:_work_state())) do
    if max_width then
      local remaining = max_width - chunks_width(chunks)
      if remaining <= display_width(" · ") then
        break
      end
      chunks[#chunks + 1] = { " · ", "Comment" }
      local text = truncate_display(part, remaining - display_width(" · "))
      if text == "" then
        chunks[#chunks] = nil
        break
      end
      chunks[#chunks + 1] = { text, "Comment" }
      if text ~= part then
        break
      end
    else
      chunks[#chunks + 1] = { " · ", "Comment" }
      chunks[#chunks + 1] = { part, "Comment" }
    end
  end
  if max_width and chunks_width(chunks) > max_width then
    return { { truncate_display(spinner .. " " .. label, max_width), "Comment" } }
  end
  return chunks
end

---@param state string|nil
---@param label string|nil
function ChatWidget:set_activity(state, label)
  if self.activity_state == state and self.activity_label == label then
    return
  end
  self.activity_state = state
  self.activity_label = label
  self.activity_frame = 1
  if state then
    self:_ensure_activity_timer()
  else
    self:_stop_activity_timer()
  end
  self:_render_activity()
end

local function format_tool_line(tool)
  local icon = STATUS_ICONS[tool.status] or "·"
  local icon_hl = STATUS_HL[tool.status]
  local title = (tool.title and tool.title ~= "") and tool.title or "(no title)"
  local kind = tool.kind or "tool"
  return Line:new({
    { icon, icon_hl },
    { " ", nil },
    { kind, "Identifier" },
    { " — ", "Comment" },
    { title, nil },
  })
end

---Default expanded state for a tool_call: shell expands, everything else collapses.
default_expanded = function(tool)
  return tool_policy.classify(tool) == "shell"
end

---@param tool table  history tool_call entry
---@return table[]|nil  list of virt_line chunk arrays
local function tool_virt_lines(tool)
  local class = tool_policy.classify(tool)
  local virt = {}

  local preview = tool_policy.input_preview(class, tool.raw_input)
  if preview then
    table.insert(virt, { { "  ", nil }, { preview, "Comment" } })
  end

  local summary = tool_policy.output_summary(tool.content)
  if summary then
    local expanded = tool.expanded
    if expanded == nil then
      expanded = default_expanded(tool)
    end
    if expanded then
      local cap = config.current.tool_output_max_lines or 200
      local n = math.min(#summary.lines, cap)
      for i = 1, n do
        table.insert(virt, { { "  │ ", "Comment" }, { summary.lines[i] or "", nil } })
      end
      if #summary.lines > cap then
        table.insert(virt, {
          {
            ("  │ … %d more lines"):format(#summary.lines - cap),
            "Comment",
          },
        })
      end
    else
      table.insert(virt, { { "  ", nil }, { summary.summary, "Comment" } })
    end
  end

  if #virt == 0 then
    return nil
  end
  return virt
end

---@param event table
---@return string
local function tool_event_line(event)
  local path = event.path and vim.fn.fnamemodify(event.path, ":~:.") or "?"
  local suffix
  if event.summary_only then
    suffix = ("summary: %s"):format(event.summary_reason or "guarded")
  else
    suffix = ("+%d/-%d"):format(event.additions or 0, event.deletions or 0)
  end
  return ("  ✎ %s %s"):format(path, suffix)
end

---@param hunk table
---@param index integer
---@param total integer
---@return string
local function tool_hunk_line(hunk, index, total)
  local header = hunk.header
    or ("@@ -%d,%d +%d,%d @@"):format(
      hunk.old_start or 0,
      hunk.old_count or 0,
      hunk.new_start or 0,
      hunk.new_count or 0
    )
  return ("    hunk %d/%d %s"):format(index, total, header)
end

---@param tool table
---@return string
local function tool_event_signature(tool)
  local parts = {}
  for _, event in ipairs(tool.edit_events or {}) do
    parts[#parts + 1] = table.concat({
      tostring(event.id or ""),
      tostring(event.path or ""),
      tostring(event.summary_only or false),
      tostring(event.summary_reason or ""),
      tostring(event.additions or ""),
      tostring(event.deletions or ""),
      tostring(event.status or ""),
    }, "\30")
    for _, hunk in ipairs(event.hunks or {}) do
      parts[#parts + 1] = table.concat({
        tostring(hunk.id or ""),
        tostring(hunk.status or ""),
        tostring(hunk.header or ""),
        tostring(hunk.old_start or ""),
        tostring(hunk.old_count or ""),
        tostring(hunk.new_start or ""),
        tostring(hunk.new_count or ""),
      }, "\30")
    end
  end
  return table.concat(parts, "\31")
end

---@param ref table
---@return table|nil
local function parsed_tool_hunk(ref)
  local event = ref and ref.event
  if type(event) ~= "table" or type(event.diff) ~= "string" or event.diff == "" then
    return ref and ref.hunk or nil
  end
  local ok, parsed = pcall(require("zxz.edit.inline_diff").parse, event.diff)
  if not ok or type(parsed) ~= "table" then
    return ref.hunk
  end
  local file = parsed[event.path]
  return file and file.hunks and file.hunks[ref.hunk_index] or ref.hunk
end

---@param ref table
---@return table|nil
tool_hunk_context = function(ref)
  local hunk = parsed_tool_hunk(ref)
  if type(hunk) ~= "table" then
    return nil
  end
  return {
    header = hunk.header or (ref.hunk and ref.hunk.header),
    old_start = hunk.old_start,
    old_count = hunk.old_count,
    new_start = hunk.new_start,
    new_count = hunk.new_count,
    old_lines = hunk.old_lines or hunk.old_block or {},
    new_lines = hunk.new_lines or hunk.new_block or {},
    diff_lines = hunk.diff_lines or {},
  }
end

local function format_permission_line(perm)
  local sections = {
    { "> tool request: ", "Comment" },
    { "`" .. (perm.kind or "tool") .. "`", "Identifier" },
    { " ", nil },
    { perm.description or "", nil },
  }
  if perm.decision then
    table.insert(sections, { " — " .. perm.decision, PERMISSION_DECIDED_HL })
  else
    table.insert(sections, { PERMISSION_HINT_INLINE, "Comment" })
  end
  return Line:new(sections)
end

---@param perm table  history permission entry
---@return table[]|nil  list of virt_line chunk arrays
local function permission_virt_lines(perm)
  if perm.decision then
    return nil
  end
  local class = perm.tool_class
  if class ~= "write" and class ~= "shell" then
    return nil
  end
  local raw = perm.raw_input
  if type(raw) ~= "table" then
    return nil
  end
  local virt = {}
  if class == "write" then
    local path = raw.file_path or raw.path or raw.filePath
    if path then
      table.insert(virt, {
        { "  → ", "Comment" },
        { vim.fn.fnamemodify(path, ":~:."), "Identifier" },
      })
    end
    local text = raw.content or raw.new_string or raw.newText
    if type(text) == "string" and text ~= "" then
      local lines = vim.split(text, "\n", { plain = true })
      table.insert(virt, { { "  + ", "DiffAdd" }, { lines[1] or "", "DiffAdd" } })
      if #lines > 2 then
        table.insert(virt, {
          { "  ⋮ ", "Comment" },
          { ("(%d more)"):format(#lines - 2), "Comment" },
        })
      end
      if #lines > 1 then
        table.insert(virt, { { "  + ", "DiffAdd" }, { lines[#lines] or "", "DiffAdd" } })
      end
    end
  elseif class == "shell" then
    local cmd = raw.command or raw.cmd
    if cmd then
      for _, line in ipairs(vim.split(tostring(cmd), "\n", { plain = true })) do
        table.insert(virt, { { "  $ ", "Comment" }, { line, nil } })
      end
    end
    if raw.cwd then
      table.insert(virt, {
        { "  in ", "Comment" },
        { vim.fn.fnamemodify(raw.cwd, ":~:."), "Comment" },
      })
    end
  end
  if #virt == 0 then
    return nil
  end
  return virt
end

local function format_activity_line(activity)
  local icon = STATUS_ICONS[activity.status] or STATUS_ICONS.completed
  local icon_hl = STATUS_HL[activity.status]
  return Line:new({
    { icon, icon_hl },
    { " ", nil },
    { activity.text or "", nil },
  })
end

---@param bufnr integer
---@param lines string[]
---@return integer start_line
local function append_lines(bufnr, lines)
  local last = api.nvim_buf_line_count(bufnr)
  if last == 1 and api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
    api.nvim_buf_set_lines(bufnr, 0, 1, false, lines)
    return 0
  end
  api.nvim_buf_set_lines(bufnr, last, last, false, lines)
  return last
end

---@param bufnr integer
---@param text string
local function append_chunk_text(bufnr, text)
  local pieces = vim.split(text, "\n", { plain = true })
  local last = api.nvim_buf_line_count(bufnr)
  local current = api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
  pieces[1] = current .. pieces[1]
  api.nvim_buf_set_lines(bufnr, last - 1, last, false, pieces)
end

function ChatWidget:_scroll_to_end()
  local win = self.transcript_win
  if not win_valid(win) then
    win = tab_win_for_buf(self.tab_page_id, self.transcript_buf)
  end
  if not win_valid(win) then
    return
  end
  local last = api.nvim_buf_line_count(self.transcript_buf)
  pcall(api.nvim_win_set_cursor, win, { last, 0 })
end

local AGENT_HEADERS = {
  agent = "## Agent",
  thought = "## Agent",
}

local function user_header(msg)
  if msg.status == "queued" then
    return "## Next message"
  end
  return "## User"
end

local function user_context_line(msg)
  if type(msg.context_records) == "table" and #msg.context_records > 0 then
    local labels = {}
    for _, record in ipairs(msg.context_records) do
      local label = record.label or record.raw or ("@" .. tostring(record.type))
      if record.trimmed then
        label = label .. " (trimmed)"
      elseif record.resolved == false then
        label = label .. " (unresolved)"
      end
      labels[#labels + 1] = label
    end
    return "Context: " .. table.concat(labels, ", ")
  end
  if type(msg.context_summary) ~= "table" or #msg.context_summary == 0 then
    return nil
  end
  return "Context: " .. table.concat(msg.context_summary, ", ")
end

local function context_detail_line(record)
  local parts = {}
  parts[#parts + 1] = record.label or record.raw or ("@" .. tostring(record.type))
  parts[#parts + 1] = "type=" .. tostring(record.type or "?")
  if record.source and record.source ~= "" then
    parts[#parts + 1] = "source=" .. tostring(record.source)
  end
  if record.start_byte and record.end_byte then
    parts[#parts + 1] = ("bytes=%d-%d"):format(record.start_byte, record.end_byte)
  end
  if record.trimmed then
    parts[#parts + 1] = "trimmed"
  elseif record.resolved == false then
    parts[#parts + 1] = "unresolved"
  end
  if record.error and record.error ~= "" then
    parts[#parts + 1] = "error=" .. tostring(record.error)
  end
  return "  - " .. table.concat(parts, "  ")
end

local function context_detail_lines(msg)
  if type(msg.context_records) ~= "table" or #msg.context_records == 0 then
    return nil
  end
  local lines = { "  Context details" }
  for _, record in ipairs(msg.context_records) do
    lines[#lines + 1] = context_detail_line(record)
  end
  return lines
end

---@param msg table
---@return string|nil hl_group
local function line_hl_for(msg)
  if msg.type == "tool_call" then
    return STATUS_HL[msg.status]
  elseif msg.type == "activity" then
    return STATUS_HL[msg.status]
  elseif msg.type == "permission" then
    if msg.decision then
      return PERMISSION_DECIDED_HL
    end
    return PERMISSION_PENDING_HL
  end
  return nil
end

---@param bufnr integer
---@param row integer
---@param msg table
---@param expanded? boolean
---@return integer
place_user_extmark = function(bufnr, row, msg, expanded)
  return api.nvim_buf_set_extmark(bufnr, NS, row, 0, {})
end

---@param bufnr integer
---@param row integer
---@param msg table
---@return integer
place_status_extmark = function(bufnr, row, msg)
  local opts = { line_hl_group = line_hl_for(msg) }
  if msg.type == "tool_call" then
    opts.virt_lines = tool_virt_lines(msg)
  elseif msg.type == "permission" then
    opts.virt_lines = permission_virt_lines(msg)
  end
  return api.nvim_buf_set_extmark(bufnr, NS, row, 0, opts)
end

function ChatWidget:render()
  local bufnr = self.transcript_buf
  if not buf_valid(bufnr) then
    return
  end
  local messages = self.history.messages
  if self.rendered_count > 0 then
    for i = 1, math.min(self.rendered_count, #messages) do
      local msg = messages[i]
      if msg.type == "tool_call" and msg.tool_call_id then
        local signature = tool_event_signature(msg)
        local previous = self.tool_event_signatures[msg.tool_call_id]
        if previous and previous ~= signature then
          self:rerender_all({ preserve_scroll = true })
          return
        end
      end
    end
  end
  vim.bo[bufnr].modifiable = true

  -- Patch in-place: tool_call updates and permission decisions on already-rendered messages.
  for i = 1, math.min(self.rendered_count, #messages) do
    local msg = messages[i]
    if msg.type == "user" and msg.id then
      local mark = self.user_extmarks[msg.id]
      if mark then
        local pos = api.nvim_buf_get_extmark_by_id(bufnr, NS, mark, {})
        if pos[1] then
          api.nvim_buf_set_lines(bufnr, pos[1], pos[1] + 1, false, { user_header(msg) })
          api.nvim_buf_del_extmark(bufnr, NS, mark)
          self.user_extmarks[msg.id] = place_user_extmark(bufnr, pos[1], msg, self.context_detail_expanded[msg.id])
        end
      end
    end

    local mark = msg.tool_call_id and self.tool_extmarks[msg.tool_call_id]
    if mark then
      local pos = api.nvim_buf_get_extmark_by_id(bufnr, NS, mark, {})
      if pos[1] then
        local line
        if msg.type == "tool_call" then
          line = format_tool_line(msg)
        elseif msg.type == "permission" then
          line = format_permission_line(msg)
        end
        if line then
          api.nvim_buf_set_lines(bufnr, pos[1], pos[1] + 1, false, { tostring(line) })
          line:set_highlights(NS, bufnr, pos[1])
          api.nvim_buf_del_extmark(bufnr, NS, mark)
          self.tool_extmarks[msg.tool_call_id] = place_status_extmark(bufnr, pos[1], msg)
        end
      end
    end
  end

  -- Append new messages.
  for i = self.rendered_count + 1, #messages do
    local msg = messages[i]
    if msg.type == "user" then
      local lines = { "" }
      if api.nvim_buf_line_count(bufnr) == 1 and api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == "" then
        lines = {}
      end
      local header_index = #lines + 1
      lines[#lines + 1] = user_header(msg)
      local context_line = user_context_line(msg)
      if context_line then
        lines[#lines + 1] = context_line
      end
      local detail_offsets = {}
      if self.context_detail_expanded[msg.id] then
        local detail_lines = context_detail_lines(msg)
        if detail_lines then
          for i, line in ipairs(detail_lines) do
            lines[#lines + 1] = line
            if i > 1 then
              detail_offsets[#detail_offsets + 1] = {
                offset = #lines - 1,
                msg = msg,
                record = msg.context_records[i - 1],
              }
            end
          end
        end
      end
      lines[#lines + 1] = ""
      for _, line in ipairs(vim.split(msg.text or "", "\n", { plain = true })) do
        lines[#lines + 1] = line
      end
      local start_line = append_lines(bufnr, lines)
      for _, ref in ipairs(detail_offsets) do
        self.context_row_refs[start_line + ref.offset] = ref
      end
      if msg.id then
        self.user_extmarks[msg.id] =
          place_user_extmark(bufnr, start_line + header_index - 1, msg, self.context_detail_expanded[msg.id])
      end
      self.last_kind = "user"
      self.agent_run_open = false
    elseif msg.type == "agent" or msg.type == "thought" then
      if not self.agent_run_open then
        append_lines(bufnr, { "", AGENT_HEADERS[msg.type], "" })
        self.agent_run_open = true
      elseif self.last_kind ~= "agent" and self.last_kind ~= "thought" then
        append_lines(bufnr, { "" })
      end
      append_chunk_text(bufnr, msg.text or "")
      self.last_kind = msg.type
    elseif msg.type == "tool_call" then
      local line = format_tool_line(msg)
      local lines = { "", tostring(line) }
      local tool_refs = {}
      for _, event in ipairs(msg.edit_events or {}) do
        lines[#lines + 1] = tool_event_line(event)
        tool_refs[#tool_refs + 1] = {
          offset = #lines - 1,
          tool = msg,
          event = event,
        }
        for index, hunk in ipairs(event.hunks or {}) do
          lines[#lines + 1] = tool_hunk_line(hunk, index, #(event.hunks or {}))
          tool_refs[#tool_refs + 1] = {
            offset = #lines - 1,
            tool = msg,
            event = event,
            hunk = hunk,
            hunk_index = index,
          }
        end
      end
      local start_line = append_lines(bufnr, lines)
      line:set_highlights(NS, bufnr, start_line + 1)
      self.tool_extmarks[msg.tool_call_id] = place_status_extmark(bufnr, start_line + 1, msg)
      self.tool_event_signatures[msg.tool_call_id] = tool_event_signature(msg)
      for _, ref in ipairs(tool_refs) do
        self.tool_row_refs[start_line + ref.offset] = ref
      end
      self.last_kind = "tool_call"
    elseif msg.type == "permission" then
      local line = format_permission_line(msg)
      local start_line = append_lines(bufnr, { "", tostring(line) })
      line:set_highlights(NS, bufnr, start_line + 1)
      self.tool_extmarks[msg.tool_call_id] = place_status_extmark(bufnr, start_line + 1, msg)
      self.last_kind = "permission"
    elseif msg.type == "activity" then
      local line = format_activity_line(msg)
      local lines = self.last_kind == "activity" and { tostring(line) } or { "", tostring(line) }
      local start_line = append_lines(bufnr, lines)
      local row = start_line + #lines - 1
      line:set_highlights(NS, bufnr, row)
      place_status_extmark(bufnr, row, msg)
      self.last_kind = "activity"
    end
  end

  self.rendered_count = #messages
  vim.bo[bufnr].modifiable = false
  self:_render_activity()
  if self.suppress_scroll_once then
    self.suppress_scroll_once = false
  else
    self:_scroll_to_end()
  end
end

---@param tool_call_id string
---@param options table[]
---@param on_decision fun(option_id: string|nil)
function ChatWidget:bind_permission_keys(tool_call_id, options, on_decision)
  if not buf_valid(self.transcript_buf) then
    return
  end
  self:unbind_permission_keys()
  self.permission_pending = tool_call_id

  local function find_option(kind)
    for _, option in ipairs(options or {}) do
      if option.kind == kind then
        return option.optionId, option.name
      end
    end
  end

  local opts = {
    buffer = self.transcript_buf,
    nowait = true,
    silent = true,
    desc = "0x0 chat permission",
  }
  for key, kind in pairs(KEY_TO_KIND) do
    vim.keymap.set("n", key, function()
      local option_id, option_name = find_option(kind)
      if not option_id then
        local fallback_id, fallback_name = find_option("reject_once")
        option_id = fallback_id
        option_name = fallback_name or kind
        vim.notify(("acp: agent did not offer '%s'"):format(kind), vim.log.levels.WARN)
      end
      self:unbind_permission_keys()
      on_decision(option_id, option_name)
    end, opts)
  end
  self.permission_keymap_set = true
end

function ChatWidget:unbind_permission_keys()
  if not self.permission_keymap_set then
    return
  end
  if buf_valid(self.transcript_buf) then
    for key in pairs(KEY_TO_KIND) do
      pcall(vim.keymap.del, "n", key, { buffer = self.transcript_buf })
    end
  end
  self.permission_keymap_set = false
  self.permission_pending = nil
end

return ChatWidget
