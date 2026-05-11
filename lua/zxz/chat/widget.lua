local config = require("zxz.core.config")
local file_completion = require("zxz.context.file_completion")
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
---@field permission_pending string|nil
---@field permission_keymap_set boolean
---@field last_kind string|nil
---@field activity_state string|nil
---@field activity_label string|nil
---@field activity_extmark integer|nil
---@field activity_frame integer
---@field activity_timer uv_timer_t|nil
---@field agent_run_open boolean
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
---@param history zxz.History
---@param on_submit fun()
---@param on_cancel fun()
---@return zxz.ChatWidget
function ChatWidget.new(tab_page_id, history, on_submit, on_cancel)
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
    permission_pending = nil,
    permission_keymap_set = false,
    last_kind = nil,
    activity_state = nil,
    activity_label = nil,
    activity_extmark = nil,
    activity_frame = 1,
    activity_timer = nil,
    agent_run_open = false,
    prompt_history = {},
    prompt_history_index = 0,
    prompt_history_draft = nil,
  }, ChatWidget)
end

-- Forward declarations for locals used by ChatWidget methods declared
-- before their bodies.
local default_expanded
local place_status_extmark

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
    self:toggle_tool_expand_at_cursor()
  end, { buffer = bufnr, nowait = true, silent = true, desc = "0x0 chat toggle tool output" })
  self.transcript_buf = bufnr
  self.rendered_count = 0
  self.tool_extmarks = {}
  self.user_extmarks = {}
  self.last_kind = nil
  self.activity_extmark = nil
  return bufnr
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
  local function feed(keys)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "n", false)
  end
  local ReferenceMentions = require("zxz.context.reference_mentions")

  map("n", "<CR>", function()
    self.on_submit()
  end, "0x0 chat submit")
  map("n", "<localleader>c", function()
    self.on_cancel()
  end, "0x0 chat cancel")
  map("n", "<localleader>d", function()
    require("zxz.chat.chat").review()
  end, "0x0 chat review diff")
  map("i", "@", function()
    -- Only auto-trigger when `@` would start a real mention. Probe the
    -- parser's own boundary rule by asking cursor_token what it would see
    -- if `@` were already inserted at the cursor.
    local line = api.nvim_get_current_line()
    local col = api.nvim_win_get_cursor(0)[2]
    local probe = line:sub(1, col) .. "@" .. line:sub(col + 1)
    if ReferenceMentions.cursor_token(probe, col + 1) then
      vim.schedule(file_completion.trigger)
    end
    return "@"
  end, "0x0 chat file mention", { expr = true })
  map("i", "<C-n>", function()
    file_completion.select_next(1)
  end, "0x0 chat next file mention")
  map("i", "<C-p>", function()
    file_completion.select_next(-1)
  end, "0x0 chat previous file mention")
  map("i", "<Tab>", function()
    if not file_completion.accept() then
      feed("<Tab>")
    end
  end, "0x0 chat accept file mention")
  map("i", "<CR>", function()
    if not file_completion.accept() then
      feed("<CR>")
    end
  end, "0x0 chat accept file mention")
  map("i", "<Esc>", function()
    file_completion.close()
    feed("<Esc>")
  end, "0x0 chat close file mention")
  map("n", "<C-p>", function()
    self:nav_history(-1)
  end, "0x0 chat previous prompt")
  map("n", "<C-n>", function()
    self:nav_history(1)
  end, "0x0 chat next prompt")

  self.input_buf = bufnr
  file_completion.attach(bufnr)
  -- Highlight mentions inline; no surface notification (no winbar to feed).
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
  self.last_kind = nil
  self.agent_run_open = false
  self:set_activity(nil)
end

function ChatWidget:rerender_all()
  if buf_valid(self.transcript_buf) then
    vim.bo[self.transcript_buf].modifiable = true
    api.nvim_buf_set_lines(self.transcript_buf, 0, -1, false, {})
    api.nvim_buf_clear_namespace(self.transcript_buf, NS, 0, -1)
    vim.bo[self.transcript_buf].modifiable = false
  end
  self.rendered_count = 0
  self.tool_extmarks = {}
  self.user_extmarks = {}
  self.last_kind = nil
  self.agent_run_open = false
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
    virt_lines = { { { spinner .. " ", hl }, { label, "Comment" } } },
    virt_lines_above = false,
  })
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
        table.insert(virt, { { ("  │ … %d more lines"):format(#summary.lines - cap), "Comment" } })
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
      table.insert(virt, { { "  → ", "Comment" }, { vim.fn.fnamemodify(path, ":~:."), "Identifier" } })
    end
    local text = raw.content or raw.new_string or raw.newText
    if type(text) == "string" and text ~= "" then
      local lines = vim.split(text, "\n", { plain = true })
      table.insert(virt, { { "  + ", "DiffAdd" }, { lines[1] or "", "DiffAdd" } })
      if #lines > 2 then
        table.insert(virt, { { "  ⋮ ", "Comment" }, { ("(%d more)"):format(#lines - 2), "Comment" } })
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
      table.insert(virt, { { "  in ", "Comment" }, { vim.fn.fnamemodify(raw.cwd, ":~:."), "Comment" } })
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
          self.user_extmarks[msg.id] = api.nvim_buf_set_extmark(bufnr, NS, pos[1], 0, {})
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
      lines[#lines + 1] = ""
      for _, line in ipairs(vim.split(msg.text or "", "\n", { plain = true })) do
        lines[#lines + 1] = line
      end
      local start_line = append_lines(bufnr, lines)
      if msg.id then
        self.user_extmarks[msg.id] = api.nvim_buf_set_extmark(bufnr, NS, start_line + header_index - 1, 0, {})
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
      local start_line = append_lines(bufnr, { "", tostring(line) })
      line:set_highlights(NS, bufnr, start_line + 1)
      self.tool_extmarks[msg.tool_call_id] = place_status_extmark(bufnr, start_line + 1, msg)
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
  self:_scroll_to_end()
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

  local opts = { buffer = self.transcript_buf, nowait = true, silent = true, desc = "0x0 chat permission" }
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
