local config = require("zeroxzero.config")

local api = vim.api

local NS = api.nvim_create_namespace("zeroxzero_chat_widget")

local STATUS_ICONS = {
  pending = "·",
  in_progress = "⠋",
  completed = "✓",
  failed = "✗",
}

local STATUS_HL = {
  pending = "ZeroChatStatusPending",
  in_progress = "ZeroChatStatusInProgress",
  completed = "ZeroChatStatusCompleted",
  failed = "ZeroChatStatusFailed",
}

local PERMISSION_PENDING_HL = "ZeroChatStatusPending"
local PERMISSION_DECIDED_HL = "Comment"

local ACTIVITY_SPINNER = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
local ACTIVITY_LABELS = {
  waiting = "Waiting for model",
  responding = "Model responding",
}

local PERMISSION_HINT = "[a] allow once  [A] allow always  [r] reject once  [R] reject always"
local PERMISSION_HINT_INLINE = "  — " .. PERMISSION_HINT
local KEY_TO_KIND = {
  a = "allow_once",
  A = "allow_always",
  r = "reject_once",
  R = "reject_always",
}

---@class zeroxzero.ChatWidget
---@field tab_page_id integer
---@field history zeroxzero.History
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
local ChatWidget = {}
ChatWidget.__index = ChatWidget

---@param tab_page_id integer
---@param history zeroxzero.History
---@param on_submit fun()
---@param on_cancel fun()
---@return zeroxzero.ChatWidget
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
  }, ChatWidget)
end

local function buf_valid(bufnr)
  return bufnr and api.nvim_buf_is_valid(bufnr)
end

local function win_valid(winid)
  return winid and api.nvim_win_is_valid(winid)
end

local function setup_highlights()
  api.nvim_set_hl(0, "ZeroChatStatusPending", { link = "DiagnosticVirtualTextWarn", default = true })
  api.nvim_set_hl(0, "ZeroChatStatusInProgress", { link = "DiagnosticVirtualTextInfo", default = true })
  api.nvim_set_hl(0, "ZeroChatStatusCompleted", { link = "DiagnosticVirtualTextOk", default = true })
  api.nvim_set_hl(0, "ZeroChatStatusFailed", { link = "DiagnosticVirtualTextError", default = true })
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
  self.transcript_buf = bufnr
  self.rendered_count = 0
  self.tool_extmarks = {}
  self.user_extmarks = {}
  self.last_kind = nil
  self.activity_extmark = nil
  return bufnr
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
  vim.bo[bufnr].filetype = "markdown"

  local opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set("n", "<CR>", function()
    self.on_submit()
  end, vim.tbl_extend("force", opts, { desc = "0x0 chat submit" }))
  vim.keymap.set("n", "<localleader>c", function()
    self.on_cancel()
  end, vim.tbl_extend("force", opts, { desc = "0x0 chat cancel" }))

  self.input_buf = bufnr
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
  self:set_activity(nil)
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
  local last_line = math.max(api.nvim_buf_line_count(bufnr) - 1, 0)
  self.activity_extmark = api.nvim_buf_set_extmark(bufnr, NS, last_line, 0, {
    virt_lines = { { { spinner .. " " .. label, "Comment" } } },
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
  local title = (tool.title and tool.title ~= "") and tool.title or "(no title)"
  return ("%s %s — %s"):format(icon, tool.kind or "tool", title)
end

local function format_permission_line(perm)
  local base = ("> tool request: `%s` %s"):format(perm.kind or "tool", perm.description or "")
  if perm.decision then
    return base .. " — " .. perm.decision
  end
  return base .. PERMISSION_HINT_INLINE
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
  agent = "## Assistant",
  thought = "## Thinking",
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
local function place_status_extmark(bufnr, row, msg)
  return api.nvim_buf_set_extmark(bufnr, NS, row, 0, {
    line_hl_group = line_hl_for(msg),
  })
end

function ChatWidget:render()
  local bufnr = self.transcript_buf
  if not buf_valid(bufnr) then
    return
  end
  setup_highlights()
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
          api.nvim_buf_set_lines(bufnr, pos[1], pos[1] + 1, false, { line })
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
    elseif msg.type == "agent" or msg.type == "thought" then
      if self.last_kind ~= msg.type then
        append_lines(bufnr, { "", AGENT_HEADERS[msg.type], "" })
      end
      append_chunk_text(bufnr, msg.text or "")
      self.last_kind = msg.type
    elseif msg.type == "tool_call" then
      local start_line = append_lines(bufnr, { "", format_tool_line(msg) })
      self.tool_extmarks[msg.tool_call_id] = place_status_extmark(bufnr, start_line + 1, msg)
      self.last_kind = "tool_call"
    elseif msg.type == "permission" then
      local start_line = append_lines(bufnr, { "", format_permission_line(msg) })
      self.tool_extmarks[msg.tool_call_id] = place_status_extmark(bufnr, start_line + 1, msg)
      self.last_kind = "permission"
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
