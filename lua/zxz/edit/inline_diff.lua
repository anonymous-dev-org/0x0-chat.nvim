local Checkpoint = require("zxz.core.checkpoint")
local EditEvents = require("zxz.core.edit_events")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("zxz_inline_diff")

---@class zxz.InlineHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]
---@field old_block string[]
---@field new_block string[]
---@field diff_lines string[]
---@field type "modify"|"add"|"delete"

---@class zxz.InlineFile
---@field path string repo-relative
---@field abspath string
---@field type "modify"|"add"|"delete"
---@field hunks zxz.InlineHunk[]

-- Per-buffer state: bufnr -> { file = InlineFile, checkpoint = checkpoint }
local buf_state = {}

-- Per-path set of accepted hunk signatures. The baseline checkpoint blob is
-- not rewritten on accept, so we filter accepted hunks at refresh time so they
-- don't reappear after the next tool-completion refresh.
-- map: rel_path -> { [signature] = true }
local accepted_signatures = {}

-- Active checkpoint set by the chat module so autocmds can refresh on the fly.
local active_checkpoint = nil
local streaming_refreshes = {}

-- Hooks invoked when the set of attached buffers / hunks changes. Used by the
-- chat widget to update its pending-diffs winbar segment.
local change_listeners = {}

local function notify_change()
  for _, fn in ipairs(change_listeners) do
    pcall(fn)
  end
end

---Register a callback that fires whenever the attached-overlay set changes.
---@param fn fun()
function M.on_change(fn)
  table.insert(change_listeners, fn)
end

local function hunk_signature(hunk)
  local new = table.concat(hunk.new_lines or {}, "\n")
  local old = table.concat(hunk.old_lines or {}, "\n")
  return ("%d:%d:%s::%s"):format(hunk.new_count or 0, hunk.old_count or 0, new, old)
end

local function is_accepted(rel, hunk)
  local set = accepted_signatures[rel]
  return set and set[hunk_signature(hunk)] == true
end

local function mark_accepted(rel, hunk)
  if not rel then
    return
  end
  accepted_signatures[rel] = accepted_signatures[rel] or {}
  accepted_signatures[rel][hunk_signature(hunk)] = true
end

---Drop accepted-hunk memory for paths whose checkpoint was cleared.
local function clear_accepted_signatures()
  accepted_signatures = {}
end

local function ensure_highlights()
  local set = vim.api.nvim_set_hl
  pcall(set, 0, "ZxzChatDiffAdd", { default = true, link = "DiffAdd" })
  pcall(set, 0, "ZxzChatDiffDelete", { default = true, link = "DiffDelete" })
  pcall(set, 0, "ZxzChatDiffChange", { default = true, link = "DiffChange" })
  pcall(set, 0, "ZxzChatDiffSign", { default = true, link = "DiffChange" })
  pcall(set, 0, "ZxzChatDiffHint", { default = true, link = "Comment" })
end

ensure_highlights()

---Parse `git diff` unified output into per-path hunks.
---@param text string
---@return table<string, zxz.InlineFile>
function M.parse(text)
  local files = {}
  local current
  local cur_hunk
  for line in (text or ""):gmatch("([^\n]*)\n?") do
    if line:match("^diff %-%-git ") then
      local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
      local path = b or a or "?"
      current = { path = path, hunks = {}, type = "modify" }
      files[path] = current
      cur_hunk = nil
    elseif current then
      if line:match("^new file mode") or line:match("^%-%-%- /dev/null") then
        current.type = "add"
      elseif line:match("^deleted file mode") or line:match("^%+%+%+ /dev/null") then
        current.type = "delete"
      elseif line:match("^@@") then
        local os_, oc, ns_, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if os_ then
          cur_hunk = {
            old_start = tonumber(os_) or 0,
            old_count = oc == "" and 1 or (tonumber(oc) or 0),
            new_start = tonumber(ns_) or 0,
            new_count = nc == "" and 1 or (tonumber(nc) or 0),
            old_lines = {},
            new_lines = {},
            old_block = {},
            new_block = {},
            diff_lines = { line },
          }
          table.insert(current.hunks, cur_hunk)
        end
      elseif cur_hunk and #line > 0 then
        local p = line:sub(1, 1)
        local body = line:sub(2)
        cur_hunk.diff_lines[#cur_hunk.diff_lines + 1] = line
        if p == "-" then
          table.insert(cur_hunk.old_lines, body)
          table.insert(cur_hunk.old_block, body)
        elseif p == "+" then
          table.insert(cur_hunk.new_lines, body)
          table.insert(cur_hunk.new_block, body)
        elseif p == " " then
          table.insert(cur_hunk.old_block, body)
          table.insert(cur_hunk.new_block, body)
        end
      end
    end
  end
  return files
end

local function clear_marks(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function place_marks(bufnr, file)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  clear_marks(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  for _, hunk in ipairs(file.hunks or {}) do
    -- Render removed lines as virt_lines above the new range.
    if #hunk.old_lines > 0 then
      local anchor = math.max(0, math.min((hunk.new_start or 1) - 1, line_count - 1))
      if hunk.new_count == 0 then
        anchor = math.max(0, math.min(hunk.new_start - 1, line_count - 1))
      end
      local virt_lines = {}
      for _, l in ipairs(hunk.old_lines) do
        table.insert(virt_lines, { { "- " .. l, "ZxzChatDiffDelete" } })
      end
      pcall(api.nvim_buf_set_extmark, bufnr, ns, anchor, 0, {
        virt_lines = virt_lines,
        virt_lines_above = hunk.new_count > 0,
      })
    end

    -- Highlight the added range.
    if hunk.new_count > 0 then
      for i = 0, hunk.new_count - 1 do
        local lnum = (hunk.new_start - 1) + i
        if lnum >= 0 and lnum < line_count then
          pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, 0, {
            line_hl_group = "ZxzChatDiffAdd",
            sign_text = i == 0 and "▍" or " ",
            sign_hl_group = "ZxzChatDiffSign",
          })
        end
      end
    end
  end
end

---Drop accepted hunks from a parsed file before we attach.
---@param file zxz.InlineFile
---@return zxz.InlineFile
local function filter_accepted(file)
  if not file or not file.hunks then
    return file
  end
  local set = accepted_signatures[file.path]
  if not set then
    return file
  end
  local kept = {}
  for _, hunk in ipairs(file.hunks) do
    if not set[hunk_signature(hunk)] then
      kept[#kept + 1] = hunk
    end
  end
  file.hunks = kept
  return file
end

local function bind_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<localleader>a", function()
    require("zxz.edit.verbs").accept_current()
  end, vim.tbl_extend("force", opts, { desc = "0x0: accept hunk" }))
  vim.keymap.set("n", "<localleader>r", function()
    require("zxz.edit.verbs").reject_current()
  end, vim.tbl_extend("force", opts, { desc = "0x0: reject hunk" }))
  vim.keymap.set("n", "<localleader>A", function()
    require("zxz.edit.verbs").accept_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0: accept all hunks in file" }))
  vim.keymap.set("n", "<localleader>R", function()
    require("zxz.edit.verbs").reject_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0: reject all hunks in file" }))
  vim.keymap.set("n", "<localleader>u", function()
    require("zxz.edit.verbs").undo_reject()
  end, vim.tbl_extend("force", opts, { desc = "0x0: undo last reject" }))
  vim.keymap.set("n", "]h", function()
    M.next_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: next hunk" }))
  vim.keymap.set("n", "[h", function()
    M.prev_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: prev hunk" }))
  vim.keymap.set("n", "]H", function()
    M.next_file_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: next file with hunks" }))
  vim.keymap.set("n", "[H", function()
    M.prev_file_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: prev file with hunks" }))
  vim.keymap.set("n", "<localleader>m", function()
    require("zxz.chat.chat").add_current_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: add hunk to chat" }))
  vim.keymap.set("n", "<localleader>f", function()
    require("zxz.chat.chat").add_current_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0: add file to chat" }))
end

local function unbind_keymaps(bufnr)
  for _, key in ipairs({
    "<localleader>a",
    "<localleader>r",
    "<localleader>A",
    "<localleader>R",
    "<localleader>u",
    "]h",
    "[h",
    "]H",
    "[H",
    "<localleader>m",
    "<localleader>f",
  }) do
    pcall(vim.keymap.del, "n", key, { buffer = bufnr })
  end
end

---@param bufnr integer
---@param file zxz.InlineFile|nil
---@param checkpoint table|nil
function M.attach(bufnr, file, checkpoint)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  if file then
    file = filter_accepted(file)
  end
  if not file or not file.hunks or #file.hunks == 0 then
    M.detach(bufnr)
    return
  end
  buf_state[bufnr] = { file = file, checkpoint = checkpoint }
  place_marks(bufnr, file)
  bind_keymaps(bufnr)
  M._refresh_focused_hunk(bufnr)
  notify_change()
end

---@param bufnr integer
function M.detach(bufnr)
  local was_attached = buf_state[bufnr] ~= nil
  buf_state[bufnr] = nil
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    clear_marks(bufnr)
    unbind_keymaps(bufnr)
  end
  if was_attached then
    notify_change()
  end
end

local function save_window_views(bufnr)
  local views = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if api.nvim_win_is_valid(winid) then
      local ok, view = pcall(api.nvim_win_call, winid, vim.fn.winsaveview)
      if ok and view then
        views[#views + 1] = { winid = winid, view = view }
      end
    end
  end
  return views
end

local function restore_window_views(views, bufnr)
  for _, item in ipairs(views or {}) do
    if api.nvim_win_is_valid(item.winid) and api.nvim_win_get_buf(item.winid) == bufnr then
      pcall(api.nvim_win_call, item.winid, function()
        vim.fn.winrestview(item.view)
      end)
    end
  end
end

---Reload the buffer from disk if unmodified, then re-place the overlay using
---the given checkpoint.
---@param checkpoint table
---@param abs_path string
function M.refresh_path(checkpoint, abs_path)
  if not checkpoint or not abs_path then
    return
  end
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local views = save_window_views(bufnr)
  if not vim.bo[bufnr].modified then
    pcall(vim.cmd, "checktime " .. bufnr)
  end
  local rel = abs_path
  if checkpoint.root and abs_path:sub(1, #checkpoint.root + 1) == checkpoint.root .. "/" then
    rel = abs_path:sub(#checkpoint.root + 2)
  end
  local diff_text = Checkpoint.diff_text(checkpoint, { rel }, 0)
  local files = M.parse(diff_text)
  local file = files[rel]
  if file then
    file.abspath = abs_path
    EditEvents.annotate_chunks({ { path = rel, parsed = file } }, checkpoint.turn_id)
  end
  M.attach(bufnr, file, checkpoint)
  restore_window_views(views, bufnr)
end

---Debounced refresh used by host-mediated file writes while the agent is still
---running. Multiple rapid writes to the same path coalesce into one overlay
---refresh, so the UI can track streaming edits without excessive git diffs.
---@param checkpoint table
---@param abs_path string
---@param delay_ms? integer
function M.refresh_path_streaming(checkpoint, abs_path, delay_ms)
  if not checkpoint or not abs_path or abs_path == "" then
    return
  end
  local key = (checkpoint.ref or "?") .. "\n" .. abs_path
  streaming_refreshes[key] = { checkpoint = checkpoint, abs_path = abs_path }
  vim.defer_fn(function()
    local pending = streaming_refreshes[key]
    if not pending then
      return
    end
    streaming_refreshes[key] = nil
    M.refresh_path(pending.checkpoint, pending.abs_path)
  end, delay_ms or 40)
end

---Refresh every buffer that currently has an attached overlay.
---@param checkpoint table
function M.refresh_all(checkpoint)
  if not checkpoint then
    return
  end
  local diff_text = Checkpoint.diff_text(checkpoint, nil, 0)
  local files = M.parse(diff_text)
  -- Detach files that are no longer changed.
  for bufnr, state in pairs(buf_state) do
    if api.nvim_buf_is_valid(bufnr) then
      local rel = state.file and state.file.path
      if rel and not files[rel] then
        M.detach(bufnr)
      end
    else
      buf_state[bufnr] = nil
    end
  end
  -- Attach for every changed file that has an open buffer.
  for rel, file in pairs(files) do
    local abs = checkpoint.root .. "/" .. rel
    local bufnr = vim.fn.bufnr(abs)
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
      if not vim.bo[bufnr].modified then
        pcall(vim.cmd, "checktime " .. bufnr)
      end
      file.abspath = abs
      M.attach(bufnr, file, checkpoint)
    end
  end
end

---Detach every overlay (called when the checkpoint is cleared).
function M.detach_all()
  for bufnr, _ in pairs(buf_state) do
    M.detach(bufnr)
  end
  buf_state = {}
  clear_accepted_signatures()
  notify_change()
end

---@param checkpoint table|nil
function M.set_active(checkpoint)
  active_checkpoint = checkpoint
  if checkpoint then
    M.refresh_all(checkpoint)
  else
    M.detach_all()
  end
end

local augroup = api.nvim_create_augroup("zxz_inline_diff", { clear = true })
api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = augroup,
  callback = function(args)
    if not active_checkpoint then
      return
    end
    local path = api.nvim_buf_get_name(args.buf)
    if path == "" then
      return
    end
    M.refresh_path(active_checkpoint, path)
  end,
})

-- Focused-hunk hint: a single virt_text extmark on whichever hunk the cursor
-- is over, refreshed on CursorMoved. Avoids the per-hunk hint clutter.
local hint_ns = api.nvim_create_namespace("zxz_inline_diff_hint")

function M._refresh_focused_hunk(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  api.nvim_buf_clear_namespace(bufnr, hint_ns, 0, -1)
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    return
  end
  local win = api.nvim_get_current_win()
  if api.nvim_win_get_buf(win) ~= bufnr then
    return
  end
  local cursor = api.nvim_win_get_cursor(win)[1]
  local idx, hunk
  for i, h in ipairs(state.file.hunks) do
    local start = h.new_start
    local stop = start + math.max(0, h.new_count) - 1
    if h.new_count == 0 then
      stop = start
    end
    if cursor >= start and cursor <= stop then
      idx, hunk = i, h
      break
    end
  end
  if not hunk then
    return
  end
  local line_count = api.nvim_buf_line_count(bufnr)
  local hint_line = math.max(0, math.min(hunk.new_start - 1, line_count - 1))
  local lc = vim.g.maplocalleader or "\\"
  pcall(api.nvim_buf_set_extmark, bufnr, hint_ns, hint_line, 0, {
    virt_text = {
      {
        (" [%d/%d] %sa accept · %sr reject · %sA accept file · %su undo reject · %sm attach"):format(
          idx,
          #state.file.hunks,
          lc,
          lc,
          lc,
          lc,
          lc
        ),
        "ZxzChatDiffHint",
      },
    },
    virt_text_pos = "eol",
    hl_mode = "combine",
  })
end

api.nvim_create_autocmd({ "CursorMoved", "BufEnter" }, {
  group = augroup,
  callback = function(args)
    if buf_state[args.buf] then
      M._refresh_focused_hunk(args.buf)
    end
  end,
})

local function find_hunk_at(bufnr)
  local state = buf_state[bufnr]
  if not state or not state.file then
    return nil
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  for i, hunk in ipairs(state.file.hunks) do
    local start = hunk.new_start
    local stop = start + math.max(0, hunk.new_count) - 1
    if hunk.new_count == 0 then
      stop = start
    end
    if cursor >= start and cursor <= stop then
      return state, i, hunk
    end
  end
  return nil
end

local function format_hunk(hunk)
  local old_count = hunk.old_count or #hunk.old_lines
  local new_count = hunk.new_count or #hunk.new_lines
  local lines = {
    ("@@ -%d,%d +%d,%d @@"):format(hunk.old_start or 0, old_count, hunk.new_start or 0, new_count),
  }
  for _, line in ipairs(hunk.old_lines or {}) do
    lines[#lines + 1] = "-" .. line
  end
  for _, line in ipairs(hunk.new_lines or {}) do
    lines[#lines + 1] = "+" .. line
  end
  return lines
end

function M.current_hunk_reference()
  local state, _, hunk = find_hunk_at(api.nvim_get_current_buf())
  if not state or not hunk or not state.file then
    return nil
  end
  return {
    path = state.file.path,
    hunk = hunk,
    lines = format_hunk(hunk),
  }
end

---@param bufnr? integer
---@return boolean
function M.has_attached(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  return state ~= nil and state.file ~= nil and #(state.file.hunks or {}) > 0
end

---@param checkpoint table
---@param path string
function M.accept_path(checkpoint, path)
  if not checkpoint or not path or path == "" then
    return false
  end
  local ok, err = require("zxz.edit.ledger").accept_file(checkpoint, path)
  if not ok then
    vim.notify("0x0: accept failed: " .. (err or "unknown"), vim.log.levels.ERROR)
    return false
  end
  M.refresh_path(checkpoint, checkpoint.root .. "/" .. path)
  return true
end

function M.next_hunk()
  local bufnr = api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    return
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  for _, hunk in ipairs(state.file.hunks) do
    if hunk.new_start > cursor then
      api.nvim_win_set_cursor(0, { hunk.new_start, 0 })
      return
    end
  end
  api.nvim_win_set_cursor(0, { state.file.hunks[1].new_start, 0 })
end

function M.prev_hunk()
  local bufnr = api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    return
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  local prev
  for _, hunk in ipairs(state.file.hunks) do
    if hunk.new_start < cursor then
      prev = hunk
    else
      break
    end
  end
  prev = prev or state.file.hunks[#state.file.hunks]
  api.nvim_win_set_cursor(0, { prev.new_start, 0 })
end

function M.accept_hunk_at_cursor()
  local bufnr = api.nvim_get_current_buf()
  local state, idx, hunk = find_hunk_at(bufnr)
  if not state or not idx then
    vim.notify("0x0: no hunk under cursor", vim.log.levels.INFO)
    return
  end
  if state.checkpoint then
    local ok, err = require("zxz.edit.ledger").accept_hunk(state.checkpoint, state.file.path, hunk)
    if not ok then
      vim.notify("0x0: accept failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    M.refresh_path(state.checkpoint, state.file.abspath or vim.api.nvim_buf_get_name(bufnr))
    return
  end
  -- Memoise so the next refresh against the unchanged baseline filters it out.
  mark_accepted(state.file.path, hunk)
  table.remove(state.file.hunks, idx)
  if #state.file.hunks == 0 then
    M.detach(bufnr)
  else
    place_marks(bufnr, state.file)
    M._refresh_focused_hunk(bufnr)
    notify_change()
  end
end

---Return the line ranges (1-indexed inclusive) where the buffer differs from
---the on-disk file. Used to scope the reject-dirty check to the hunk.
local function dirty_ranges(bufnr)
  local path = api.nvim_buf_get_name(bufnr)
  if path == "" or vim.fn.filereadable(path) ~= 1 then
    return nil -- can't compare; fall back to global modified flag
  end
  local buf_lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local disk_lines = vim.fn.readfile(path)
  if not vim.diff then
    return nil
  end
  local indices = vim.diff(table.concat(disk_lines, "\n"), table.concat(buf_lines, "\n"), {
    result_type = "indices",
    algorithm = "histogram",
  })
  if not indices then
    return nil
  end
  local out = {}
  for _, h in ipairs(indices) do
    -- h = { a_start, a_count, b_start, b_count } in buffer (b) coordinates.
    local b_start, b_count = h[3], h[4]
    if b_count == 0 then
      out[#out + 1] = { b_start, b_start } -- pure deletion, anchor line
    else
      out[#out + 1] = { b_start, b_start + b_count - 1 }
    end
  end
  return out
end

local function range_overlap(a_start, a_end, b_start, b_end)
  return not (a_end < b_start or b_end < a_start)
end

function M.reject_hunk_at_cursor()
  local bufnr = api.nvim_get_current_buf()
  local state, _, hunk = find_hunk_at(bufnr)
  if not state or not hunk then
    vim.notify("0x0: no hunk under cursor", vim.log.levels.INFO)
    return
  end
  if vim.bo[bufnr].modified then
    local hunk_start = hunk.new_start
    local hunk_end = hunk.new_count > 0 and (hunk.new_start + hunk.new_count - 1) or hunk.new_start
    local dirty = dirty_ranges(bufnr)
    local conflicts = false
    if dirty == nil then
      conflicts = true
    else
      for _, r in ipairs(dirty) do
        if range_overlap(hunk_start, hunk_end, r[1], r[2]) then
          conflicts = true
          break
        end
      end
    end
    if conflicts then
      vim.notify("0x0: save (or revert) the dirty edits over this hunk before rejecting", vim.log.levels.WARN)
      return
    end
    -- Persist edits outside the hunk first so our diff baseline stays sane.
    pcall(function()
      api.nvim_buf_call(bufnr, function()
        vim.cmd("silent! write")
      end)
    end)
  end
  if state.checkpoint then
    local ok, err = require("zxz.edit.ledger").reject_hunk(state.checkpoint, state.file.path, hunk)
    if not ok then
      vim.notify("0x0: reject failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    pcall(vim.cmd, "checktime " .. bufnr)
    M.refresh_path(state.checkpoint, state.file.abspath or vim.api.nvim_buf_get_name(bufnr))
    return
  end
  -- Replace [new_start, new_start+new_count) with the old hunk block.
  local s = hunk.new_start - 1
  local e = s + hunk.new_count
  if hunk.new_count == 0 then
    s = hunk.new_start
    e = s
  end
  pcall(api.nvim_buf_set_lines, bufnr, s, e, false, hunk.old_block or hunk.old_lines)
  pcall(function()
    api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! write")
    end)
  end)
  if state.checkpoint then
    M.refresh_path(state.checkpoint, state.file.abspath or vim.api.nvim_buf_get_name(bufnr))
  end
end

---Accept every hunk in the current buffer's overlay.
function M.accept_file()
  local bufnr = api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    vim.notify("0x0: no hunks attached to this buffer", vim.log.levels.INFO)
    return
  end
  if state.checkpoint then
    local ok, err = require("zxz.edit.ledger").accept_file(state.checkpoint, state.file.path)
    if not ok then
      vim.notify("0x0: accept_file failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    M.refresh_path(state.checkpoint, state.file.abspath or vim.api.nvim_buf_get_name(bufnr))
    return
  end
  for _, hunk in ipairs(state.file.hunks) do
    mark_accepted(state.file.path, hunk)
  end
  M.detach(bufnr)
end

---Reject every hunk in the current buffer's overlay (in reverse line order).
function M.reject_file()
  local bufnr = api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    vim.notify("0x0: no hunks attached to this buffer", vim.log.levels.INFO)
    return
  end
  if state.checkpoint then
    local rel = state.file.path
    local ok, err = require("zxz.edit.ledger").reject_file(state.checkpoint, rel)
    if not ok then
      vim.notify("0x0: reject_file failed: " .. (err or "unknown"), vim.log.levels.ERROR)
      return
    end
    pcall(vim.cmd, "checktime " .. bufnr)
    M.refresh_path(state.checkpoint, state.file.abspath or vim.api.nvim_buf_get_name(bufnr))
  end
end

---Jump to the first hunk in the next buffer with attached hunks.
local function jump_in_attached(direction)
  local list = M.list_attached()
  if #list == 0 then
    return
  end
  table.sort(list, function(a, b)
    return a.path < b.path
  end)
  local cur = api.nvim_get_current_buf()
  local idx
  for i, e in ipairs(list) do
    if e.bufnr == cur then
      idx = i
      break
    end
  end
  idx = idx or 0
  local target = list[((idx - 1 + direction) % #list) + 1]
  if not target then
    return
  end
  vim.cmd("buffer " .. target.bufnr)
  local state = buf_state[target.bufnr]
  if state and state.file and state.file.hunks[1] then
    api.nvim_win_set_cursor(0, { state.file.hunks[1].new_start, 0 })
  end
end

function M.next_file_hunk()
  jump_in_attached(1)
end

function M.prev_file_hunk()
  jump_in_attached(-1)
end

---Returns a list of currently-attached buffers.
---@return { bufnr: integer, path: string, hunks: integer }[]
function M.list_attached()
  local out = {}
  for bufnr, state in pairs(buf_state) do
    if api.nvim_buf_is_valid(bufnr) and state.file then
      table.insert(out, {
        bufnr = bufnr,
        path = state.file.path,
        hunks = #state.file.hunks,
      })
    end
  end
  return out
end

return M
