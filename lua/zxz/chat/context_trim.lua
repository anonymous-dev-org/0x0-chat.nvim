-- Context trim picker: shows the records parsed from the chat input and
-- lets the user toggle which ones the next submit should suppress. The
-- decision is stored on the Chat as `pending_trim: { [raw]=true }` and
-- consumed (then cleared) at submit time.

local M = {}

local api = vim.api

local function chat_module()
  return require("zxz.chat.chat")
end

local function format_row(record, suppressed)
  local mark = suppressed and "[ ]" or "[x]"
  local label = record.label or record.raw or ("@" .. tostring(record.type))
  if record.resolved == false then
    label = label .. "  (unresolved)"
  end
  return ("%s %s"):format(mark, label)
end

---@param records table[]
---@param trim table<string, boolean>
local function render(bufnr, records, trim)
  local lines = {
    "0x0 — trim next-turn context",
    "  <Tab>/x: toggle  <CR>: apply  q/<Esc>: cancel",
    "",
  }
  for _, record in ipairs(records) do
    lines[#lines + 1] = format_row(record, trim[record.raw or ""])
  end
  vim.bo[bufnr].modifiable = true
  api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

---Open the trim picker on `records`. Returns `trim_map` to the chat via
---`on_apply(trim_map)`. `trim_map` is keyed by record `raw`.
---@param records table[]
---@param initial table<string, boolean>
---@param on_apply fun(trim: table<string, boolean>)
function M.open_picker(records, initial, on_apply)
  if #records == 0 then
    vim.notify("0x0: no context to trim", vim.log.levels.INFO)
    return
  end

  local trim = {}
  for k, v in pairs(initial or {}) do
    trim[k] = v
  end

  local bufnr = api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "zxz-context-trim"

  local width = 50
  for _, record in ipairs(records) do
    local label = record.label or record.raw or ""
    width = math.max(width, #label + 12)
  end
  local height = #records + 4

  local winid = api.nvim_open_win(bufnr, true, {
    relative = "editor",
    row = math.max(1, math.floor((vim.o.lines - height) / 2)),
    col = math.max(1, math.floor((vim.o.columns - width) / 2)),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " context trim ",
    title_pos = "center",
  })

  render(bufnr, records, trim)
  -- Cursor on the first record row (line 4 in 1-based).
  pcall(api.nvim_win_set_cursor, winid, { 4, 0 })

  local function record_at_cursor()
    local row = api.nvim_win_get_cursor(winid)[1]
    local idx = row - 3
    return records[idx]
  end

  local function close()
    if api.nvim_win_is_valid(winid) then
      api.nvim_win_close(winid, true)
    end
  end

  local function toggle()
    local rec = record_at_cursor()
    if not rec or not rec.raw then
      return
    end
    trim[rec.raw] = not trim[rec.raw]
    local saved = api.nvim_win_get_cursor(winid)
    render(bufnr, records, trim)
    pcall(api.nvim_win_set_cursor, winid, saved)
  end

  local function apply()
    close()
    on_apply(trim)
  end

  local map_opts = { buffer = bufnr, nowait = true, silent = true }
  vim.keymap.set("n", "<Tab>", toggle, map_opts)
  vim.keymap.set("n", "x", toggle, map_opts)
  vim.keymap.set("n", "<Space>", toggle, map_opts)
  vim.keymap.set("n", "<CR>", apply, map_opts)
  vim.keymap.set("n", "q", close, map_opts)
  vim.keymap.set("n", "<Esc>", close, map_opts)
end

---@param index? integer|string
function M.open(index)
  local chat = chat_module()
  if not chat.trim_open then
    vim.notify("0x0: chat is not loaded", vim.log.levels.ERROR)
    return
  end
  if index and tostring(index) ~= "" and not tonumber(index) then
    vim.notify("0x0: queued context index must be a number", vim.log.levels.ERROR)
    return
  end
  local n = tonumber(index)
  chat.trim_open(n)
end

return M
