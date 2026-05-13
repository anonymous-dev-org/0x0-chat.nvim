local Checkpoint = require("zxz.core.checkpoint")
local EditEvents = require("zxz.core.edit_events")
local InlineDiff = require("zxz.edit.inline_diff")
local Ledger = require("zxz.edit.ledger")

local M = {}

local NS = vim.api.nvim_create_namespace("zxz_review")
local states = {}

local STATUS_LABEL = {
  add = "A",
  delete = "D",
  modify = "M",
}

local function run_root(run)
  return run and (run.root or Checkpoint.git_root(vim.fn.getcwd()))
end

---@param root string
---@param sha string
---@param path string
---@return boolean
local function exists_in_ref(root, sha, path)
  vim.fn.system({ "git", "-C", root, "cat-file", "-e", sha .. ":" .. path })
  return vim.v.shell_error == 0
end

local function write_disk_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(content or "")
  f:close()
  return true
end

local function read_disk_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function split_content(content)
  if content == nil or content == "" then
    return {}
  end
  local lines = vim.split(content, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function join_lines(lines, had_newline)
  local content = table.concat(lines, "\n")
  if had_newline and content ~= "" then
    content = content .. "\n"
  end
  return content
end

local function hunk_old_block(hunk)
  return hunk.old_block or hunk.old_lines or {}
end

local function hunk_new_block(hunk)
  return hunk.new_block or hunk.new_lines or {}
end

local function block_matches(lines, start_line, count, expected)
  expected = expected or {}
  if count ~= #expected then
    return false
  end
  local start_index = math.max(1, start_line or 1)
  for i = 1, count do
    if lines[start_index + i - 1] ~= expected[i] then
      return false
    end
  end
  return true
end

local function replace_block(lines, start_line, count, replacement)
  local start_index = math.max(1, start_line or 1)
  local remove_count = math.max(0, count or 0)
  for _ = 1, remove_count do
    if lines[start_index] ~= nil then
      table.remove(lines, start_index)
    end
  end
  for i = #(replacement or {}), 1, -1 do
    table.insert(lines, start_index, replacement[i])
  end
end

local function source_buffer_modified(root, path)
  local abs = root .. "/" .. path
  local bufnr = vim.fn.bufnr(abs)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.bo[bufnr].modified == true
end

---@param root string
---@param sha string
---@param path string
---@return boolean ok, string|nil err
local function restore_path_from(root, sha, path)
  if exists_in_ref(root, sha, path) then
    local out = vim.fn.system({ "git", "-C", root, "show", sha .. ":" .. path })
    if vim.v.shell_error ~= 0 then
      return false, out
    end
    if not write_disk_file(root .. "/" .. path, out or "") then
      return false, "write failed for " .. path
    end
    return true, nil
  end
  local abs = root .. "/" .. path
  if vim.fn.filereadable(abs) == 1 then
    os.remove(abs)
  end
  return true, nil
end

---@param diff_text string
---@return table[]
local function file_chunks(diff_text)
  local parsed = InlineDiff.parse(diff_text)
  local chunks = {}
  local current
  for line in (diff_text or ""):gmatch("([^\n]*)\n?") do
    if line == "" and not current then
      goto continue
    end
    local path = line:match("^diff %-%-git a/.- b/(.+)$")
    if path then
      current = {
        path = path,
        lines = { line },
        parsed = parsed[path],
      }
      chunks[#chunks + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = line
    end
    ::continue::
  end
  return chunks
end

local function build_checkpoint_state(checkpoint, chat)
  local diff_text = Checkpoint.diff_text(checkpoint, nil, 3)
  if diff_text == "" then
    return nil, "no changes since checkpoint"
  end
  local diff_files = file_chunks(diff_text)
  EditEvents.annotate_chunks(diff_files, checkpoint.turn_id)
  local files = EditEvents.review_chunks(checkpoint.turn_id, diff_files)
  return {
    kind = "checkpoint",
    checkpoint = checkpoint,
    chat = chat,
    root = checkpoint.root,
    title = ("0x0 Review | checkpoint %s"):format(checkpoint.turn_id or "?"),
    files = files,
    statuses = {},
  }
end

local function refresh_checkpoint_state(state)
  if not state or state.kind ~= "checkpoint" then
    return
  end
  local diff_text = Checkpoint.diff_text(state.checkpoint, nil, 3)
  local diff_files = file_chunks(diff_text)
  EditEvents.annotate_chunks(diff_files, state.checkpoint.turn_id)
  state.files = EditEvents.review_chunks(state.checkpoint.turn_id, diff_files)
  state.statuses = {}
end

local function build_run_state(run, chat)
  if not run or not run.start_sha or not run.end_sha then
    return nil, "run has no end snapshot; nothing to review"
  end
  local root = run_root(run)
  if not root then
    return nil, "not in a git repository"
  end
  local args = {
    "git",
    "-C",
    root,
    "diff",
    "--no-ext-diff",
    "--unified=3",
    run.start_sha,
    run.end_sha,
  }
  if run.files_touched and #run.files_touched > 0 then
    args[#args + 1] = "--"
    vim.list_extend(args, run.files_touched)
  end
  local diff_text = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    return nil, diff_text or "git diff failed"
  end
  if diff_text == "" then
    return nil, "run touched no files"
  end
  local diff_files = file_chunks(diff_text)
  EditEvents.annotate_chunks(diff_files, run)
  local files = EditEvents.review_chunks(run, diff_files)
  return {
    kind = "run",
    run = run,
    chat = chat,
    root = root,
    title = ("0x0 Review | run %s"):format(run.run_id or "?"),
    files = files,
    statuses = {},
  }
end

local function file_label(state, file)
  local parsed = file.parsed or {}
  local kind = STATUS_LABEL[parsed.type or "modify"] or "M"
  local status = state.statuses[file.path]
  local prefix = status and ("[" .. status:sub(1, 1) .. "]") or "[ ]"
  local hunks = parsed.hunks and #parsed.hunks or 0
  if parsed.summary_only then
    local reason = (parsed.summary_reason or "summary_only"):gsub("_", " ")
    if parsed.diagnostic then
      return ("%s ! %s (diagnostic, %s)"):format(prefix, file.path, reason)
    end
    if parsed.blocked_by_event_id then
      reason = reason .. " · blocked"
    end
    return ("%s %s %s (file-level, %s)"):format(prefix, kind, file.path, reason)
  end
  return ("%s %s %s (%d hunk%s)"):format(prefix, kind, file.path, hunks, hunks == 1 and "" or "s")
end

local function file_header(file)
  local parsed = file.parsed or {}
  local kind = STATUS_LABEL[parsed.type or "modify"] or "M"
  local hunks = parsed.hunks and #parsed.hunks or 0
  if parsed.summary_only then
    if parsed.diagnostic then
      return ("! %s (diagnostic)"):format(file.path)
    end
    local suffix = parsed.blocked_by_event_id and ", blocked" or ""
    return ("%s %s (file-level%s)"):format(kind, file.path, suffix)
  end
  return ("%s %s (%d hunk%s)"):format(kind, file.path, hunks, hunks == 1 and "" or "s")
end

local function hunk_label(state, file, hunk, idx, total)
  local status = state.statuses[file.path]
  local prefix = status and ("[" .. status:sub(1, 1) .. "]") or "[ ]"
  local header = hunk.diff_lines and hunk.diff_lines[1]
  if not header or header == "" then
    header = ("@@ -%d,%d +%d,%d @@"):format(
      hunk.old_start or 0,
      hunk.old_count or #(hunk.old_lines or {}),
      hunk.new_start or 0,
      hunk.new_count or #(hunk.new_lines or {})
    )
  end
  local provenance = hunk.tool_call_id and (" · " .. hunk.tool_call_id) or ""
  return ("%s hunk %d/%d %s%s"):format(prefix, idx, total, header, provenance)
end

local function render(bufnr)
  local state = states[bufnr]
  if not state then
    return
  end
  local lines = {
    "# 0x0 Review",
    state.title,
    "Keys: a/r hunk | A/R file | ga/gr all | u undo reject | <CR> open file | q close",
    "",
  }
  local line_file = {}
  local line_item = {}
  if #(state.files or {}) == 0 then
    lines[#lines + 1] = "No unresolved changes."
  end
  for _, file in ipairs(state.files or {}) do
    local row = #lines + 1
    lines[row] = file_header(file)
    line_file[row] = file
    line_item[row] = { kind = "file", file = file }
    local hunks = file.parsed and file.parsed.hunks or {}
    for idx, hunk in ipairs(hunks) do
      local n = #lines + 1
      lines[n] = hunk_label(state, file, hunk, idx, #hunks)
      line_file[n] = file
      line_item[n] = { kind = "hunk_header", file = file, hunk = hunk, hunk_index = idx }
      for _, line in ipairs(hunk.diff_lines or {}) do
        if not line:match("^@@") then
          local diff_row = #lines + 1
          lines[diff_row] = line
          line_file[diff_row] = file
          line_item[diff_row] = { kind = "hunk_line", file = file, hunk = hunk, hunk_index = idx }
        end
      end
      lines[#lines + 1] = ""
    end
    if #hunks == 0 then
      local n = #lines + 1
      lines[n] = file_label(state, file)
      line_file[n] = file
      line_item[n] = { kind = "file", file = file }
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for row, item in pairs(line_item) do
    local file = item.file
    if item.kind == "hunk_header" then
      vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, { line_hl_group = "CursorLine" })
    elseif item.kind == "file" then
      vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, { line_hl_group = "Title" })
    elseif file then
      local line = lines[row] or ""
      local hl = line:sub(1, 1) == "+" and "DiffAdd" or (line:sub(1, 1) == "-" and "DiffDelete" or nil)
      if hl then
        vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, { line_hl_group = hl })
      end
    end
  end
  vim.bo[bufnr].modifiable = false
  state.line_file = line_file
  state.line_item = line_item
end

local function sorted_hunk_rows(state)
  local rows = {}
  for row, item in pairs(state.line_item or {}) do
    if item.kind == "hunk_header" then
      rows[#rows + 1] = row
    end
  end
  table.sort(rows)
  return rows
end

local function nearest_hunk_row(state, row)
  local rows = sorted_hunk_rows(state)
  if #rows == 0 then
    return nil
  end
  for _, candidate in ipairs(rows) do
    if candidate >= row then
      return candidate
    end
  end
  return rows[#rows]
end

local function hunk_key(file, hunk)
  if not file or not hunk then
    return nil
  end
  if hunk.event_id and hunk.hunk_id then
    return table.concat({
      "event",
      file.path or "",
      tostring(hunk.event_id),
      tostring(hunk.hunk_id),
    }, "\n")
  end
  return table.concat({
    "diff",
    file.path or "",
    tostring(hunk.old_start or ""),
    tostring(hunk.old_count or ""),
    table.concat(hunk.old_lines or {}, "\n"),
    tostring(hunk.new_count or ""),
    table.concat(hunk.new_lines or {}, "\n"),
  }, "\n")
end

local function hunk_old_start(hunk)
  return tonumber(hunk and hunk.old_start)
end

local function selection_at_row(state, row)
  if not state then
    return nil
  end
  for i = row, 1, -1 do
    local item = state.line_item and state.line_item[i]
    if item and item.hunk then
      return {
        kind = "hunk",
        file_path = item.file and item.file.path,
        hunk_key = hunk_key(item.file, item.hunk),
        old_start = hunk_old_start(item.hunk),
      }
    end
    local file = item and item.file or (state.line_file and state.line_file[i])
    if file then
      return {
        kind = "file",
        file_path = file.path,
      }
    end
  end
  return nil
end

local function row_for_selection(state, selection)
  if not state or not selection then
    return nil
  end
  if selection.kind == "hunk" and selection.hunk_key then
    for row, item in pairs(state.line_item or {}) do
      if item.kind == "hunk_header" and hunk_key(item.file, item.hunk) == selection.hunk_key then
        return row
      end
    end
  end
  if selection.file_path then
    local first_file_row
    local nearest_hunk_row_in_file
    for row, item in pairs(state.line_item or {}) do
      if item.file and item.file.path == selection.file_path then
        if not first_file_row or row < first_file_row then
          first_file_row = row
        end
        if selection.kind == "hunk" and item.kind == "hunk_header" then
          if selection.old_start and hunk_old_start(item.hunk) == selection.old_start then
            return row
          end
          if not nearest_hunk_row_in_file or row < nearest_hunk_row_in_file then
            nearest_hunk_row_in_file = row
          end
        end
      end
    end
    if selection.kind == "hunk" then
      return nearest_hunk_row_in_file or first_file_row
    end
    return first_file_row
  end
  return nil
end

local function refresh_path_without_review(state, file)
  InlineDiff.refresh_path(state.checkpoint, state.root .. "/" .. file.path, { refresh_review = false })
end

local function save_review_views(bufnr, state)
  local views = {}
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(winid) then
      local ok, view = pcall(vim.api.nvim_win_call, winid, vim.fn.winsaveview)
      if ok and view then
        views[#views + 1] = {
          winid = winid,
          view = view,
          selection = selection_at_row(state, view.lnum),
        }
      end
    end
  end
  return views
end

local function restore_review_view(bufnr, view, target_row)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local line_count = math.max(1, vim.api.nvim_buf_line_count(bufnr))
  target_row = math.max(1, math.min(target_row or view.lnum or 1, line_count))
  view.lnum = target_row
  view.col = 0
  view.curswant = 0
  view.topline = math.max(1, math.min(view.topline or 1, line_count))
  if target_row < view.topline then
    view.topline = target_row
  end
  pcall(vim.fn.winrestview, view)
end

local function restore_review_views(bufnr, state, views)
  for _, item in ipairs(views or {}) do
    if vim.api.nvim_win_is_valid(item.winid) and vim.api.nvim_win_get_buf(item.winid) == bufnr then
      pcall(vim.api.nvim_win_call, item.winid, function()
        local target_row = row_for_selection(state, item.selection) or item.view.lnum
        restore_review_view(bufnr, item.view, target_row)
      end)
    end
  end
end

local function render_preserving_selection(bufnr)
  local state = states[bufnr]
  if not state then
    return
  end
  local views = save_review_views(bufnr, state)
  render(bufnr)
  restore_review_views(bufnr, state, views)
end

local function render_after_action(bufnr, opts)
  opts = opts or {}
  local state = states[bufnr]
  if not state then
    return
  end
  local view = vim.fn.winsaveview()
  local anchor_row = opts.anchor_row or view.lnum
  render(bufnr)
  local target_row = opts.prefer_hunk and nearest_hunk_row(state, anchor_row) or anchor_row
  restore_review_view(bufnr, view, target_row)
end

local function current_state()
  local bufnr = vim.api.nvim_get_current_buf()
  return states[bufnr], bufnr
end

local function current_file(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row, 1, -1 do
    local item = state.line_item and state.line_item[i]
    local file = item and item.file or (state.line_file and state.line_file[i])
    if file then
      return file
    end
  end
  return nil
end

local function current_hunk(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row, 1, -1 do
    local item = state.line_item and state.line_item[i]
    if item and item.hunk then
      return item.file, item.hunk, item.hunk_index
    end
    if item and item.kind == "file" then
      return nil
    end
  end
  return nil
end

local function hunk_target_line(hunk)
  local offset = 0
  for _, line in ipairs(hunk.diff_lines or {}) do
    local prefix = line:sub(1, 1)
    if prefix == " " then
      offset = offset + 1
    elseif prefix == "+" or prefix == "-" then
      break
    end
  end
  return math.max(1, (hunk.new_start or 1) + offset)
end

local accept_file
local reject_file

local function refresh_run_file(state, action, file)
  local run = state.run
  local root = state.root
  if action == "accept" then
    if not run.end_sha then
      return false, "run has no end snapshot"
    end
    return restore_path_from(root, run.end_sha, file.path)
  end
  return restore_path_from(root, run.start_sha, file.path)
end

local function refresh_run_state(state)
  if not state or state.kind ~= "run" then
    return
  end
  local refreshed = build_run_state(state.run, state.chat)
  state.files = refreshed and refreshed.files or {}
  state.statuses = {}
end

local function apply_run_hunk(state, file, hunk, action)
  if not state.run or not state.run.run_id then
    return false, "run missing"
  end
  if source_buffer_modified(state.root, file.path) then
    return false, "source buffer has unsaved edits; save or revert it before applying run hunk"
  end
  local abs = state.root .. "/" .. file.path
  local current = read_disk_file(abs) or ""
  local current_lines = split_content(current)
  local had_newline = current == "" or current:sub(-1) == "\n"
  local match_start
  local match_count
  local expected
  local replacement
  if action == "accept" then
    match_start = hunk.old_start
    match_count = hunk.old_count
    expected = hunk_old_block(hunk)
    replacement = hunk_new_block(hunk)
  else
    match_start = hunk.new_start
    match_count = hunk.new_count
    expected = hunk_new_block(hunk)
    replacement = hunk_old_block(hunk)
  end
  if not block_matches(current_lines, match_start, match_count, expected) then
    return false, "hunk is stale; refresh review before applying"
  end
  replace_block(current_lines, match_start, match_count, replacement)
  local content = join_lines(current_lines, had_newline)
  local target_sha = action == "accept" and state.run.end_sha or state.run.start_sha
  if target_sha and not exists_in_ref(state.root, target_sha, file.path) and #current_lines == 0 then
    os.remove(abs)
  elseif not write_disk_file(abs, content) then
    return false, "write failed for " .. file.path
  end
  if hunk.event_id and hunk.hunk_id then
    EditEvents.set_source_hunk_status(
      state.run,
      hunk.event_id,
      hunk.hunk_id,
      action == "accept" and "accepted" or "rejected"
    )
  end
  return true, nil
end

local function blocked_file_reason(file)
  local parsed = file and file.parsed
  if parsed and parsed.diagnostic then
    return "edit-event diagnostic rows are informational"
  end
  if parsed and parsed.blocked_by_event_id then
    return "resolve earlier event hunks in " .. file.path .. " first"
  end
  return nil
end

local function file_level_only_reason(file)
  local parsed = file and file.parsed
  if parsed and parsed.summary_only and not parsed.blocked_by_event_id then
    return "file-level review item; use A/R for file actions"
  end
  return nil
end

local function accept_hunk(state, bufnr)
  local anchor_row = vim.api.nvim_win_get_cursor(0)[1]
  local file, hunk = current_hunk(state)
  if not file or not hunk then
    local reason = file_level_only_reason(current_file(state))
    if reason then
      vim.notify("0x0: " .. reason, vim.log.levels.INFO)
      return true
    end
    return false
  end
  if state.kind ~= "checkpoint" then
    local ok, err = apply_run_hunk(state, file, hunk, "accept")
    if not ok then
      vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    refresh_run_state(state)
    vim.cmd.checktime()
    render_after_action(bufnr, { anchor_row = anchor_row, prefer_hunk = true })
    vim.notify("0x0: accepted hunk in " .. file.path, vim.log.levels.INFO)
    return true
  end
  local ok, err = Ledger.accept_hunk(state.checkpoint, file.path, hunk)
  if not ok then
    vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
    return true
  end
  refresh_checkpoint_state(state)
  refresh_path_without_review(state, file)
  render_after_action(bufnr, { anchor_row = anchor_row, prefer_hunk = true })
  vim.notify("0x0: accepted hunk in " .. file.path, vim.log.levels.INFO)
  return true
end

local function reject_hunk(state, bufnr)
  local anchor_row = vim.api.nvim_win_get_cursor(0)[1]
  local file, hunk = current_hunk(state)
  if not file or not hunk then
    local reason = file_level_only_reason(current_file(state))
    if reason then
      vim.notify("0x0: " .. reason, vim.log.levels.INFO)
      return true
    end
    return false
  end
  if state.kind ~= "checkpoint" then
    local ok, err = apply_run_hunk(state, file, hunk, "reject")
    if not ok then
      vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    refresh_run_state(state)
    vim.cmd.checktime()
    render_after_action(bufnr, { anchor_row = anchor_row, prefer_hunk = true })
    vim.notify("0x0: rejected hunk in " .. file.path, vim.log.levels.INFO)
    return true
  end
  local ok, err = Ledger.reject_hunk(state.checkpoint, file.path, hunk)
  if not ok then
    vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
    return true
  end
  refresh_checkpoint_state(state)
  refresh_path_without_review(state, file)
  vim.cmd.checktime()
  render_after_action(bufnr, { anchor_row = anchor_row, prefer_hunk = true })
  vim.notify("0x0: rejected hunk in " .. file.path, vim.log.levels.INFO)
  return true
end

accept_file = function(state, bufnr)
  local anchor_row = vim.api.nvim_win_get_cursor(0)[1]
  local file = current_file(state)
  if not file then
    return false
  end
  local blocked = blocked_file_reason(file)
  if blocked then
    vim.notify("0x0: accept blocked: " .. blocked, vim.log.levels.WARN)
    return true
  end
  if state.kind == "checkpoint" then
    local ok, err = Ledger.accept_file(state.checkpoint, file.path)
    if not ok then
      vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    refresh_checkpoint_state(state)
    refresh_path_without_review(state, file)
  else
    local ok, err = refresh_run_file(state, "accept", file)
    if not ok then
      vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    vim.cmd.checktime()
  end
  if state.kind ~= "checkpoint" then
    EditEvents.set_source_path_status(state.run, file.path, "accepted")
    state.statuses[file.path] = "accepted"
  end
  render_after_action(bufnr, { anchor_row = anchor_row, prefer_hunk = true })
  vim.notify("0x0: accepted " .. file.path, vim.log.levels.INFO)
  return true
end

reject_file = function(state, bufnr)
  local anchor_row = vim.api.nvim_win_get_cursor(0)[1]
  local file = current_file(state)
  if not file then
    return false
  end
  local blocked = blocked_file_reason(file)
  if blocked then
    vim.notify("0x0: reject blocked: " .. blocked, vim.log.levels.WARN)
    return true
  end
  if state.kind == "checkpoint" then
    local ok, err = Ledger.reject_file(state.checkpoint, file.path)
    if not ok then
      vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    refresh_checkpoint_state(state)
    refresh_path_without_review(state, file)
  else
    local ok, err = refresh_run_file(state, "reject", file)
    if not ok then
      vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
  end
  vim.cmd.checktime()
  if state.kind ~= "checkpoint" then
    EditEvents.set_source_path_status(state.run, file.path, "rejected")
    state.statuses[file.path] = "rejected"
  end
  render_after_action(bufnr, { anchor_row = anchor_row, prefer_hunk = true })
  vim.notify("0x0: rejected " .. file.path, vim.log.levels.INFO)
  return true
end

local function accept_all(state)
  if state.kind == "checkpoint" then
    if state.chat and state.chat.accept_all then
      state.chat:accept_all()
    else
      require("zxz.chat.chat").accept_all()
    end
  elseif state.chat and state.chat.run_accept then
    state.chat:run_accept(state.run.run_id)
  else
    require("zxz.chat.chat").run_accept(state.run.run_id)
  end
  return true
end

local function reject_all(state)
  if state.kind == "checkpoint" then
    if state.chat and state.chat.discard_all then
      state.chat:discard_all()
    else
      require("zxz.chat.chat").discard_all()
    end
  elseif state.chat and state.chat.run_reject then
    state.chat:run_reject(state.run.run_id)
  else
    require("zxz.chat.chat").run_reject(state.run.run_id)
  end
  return true
end

local function open_file(state)
  local file = current_file(state)
  if not file then
    return false
  end
  local _, hunk = current_hunk(state)
  local abs = state.root .. "/" .. file.path
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == abs then
      vim.api.nvim_set_current_win(win)
      if hunk then
        pcall(vim.api.nvim_win_set_cursor, win, { hunk_target_line(hunk), 0 })
      end
      return true
    end
  end
  vim.cmd("rightbelow vertical noswapfile split " .. vim.fn.fnameescape(abs))
  if hunk then
    pcall(vim.api.nvim_win_set_cursor, 0, { hunk_target_line(hunk), 0 })
  end
  return true
end

local function jump_hunk(direction)
  local state = select(1, current_state())
  if not state or not state.line_item then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = sorted_hunk_rows(state)
  local target
  if direction > 0 then
    for _, r in ipairs(rows) do
      if r > row then
        target = r
        break
      end
    end
    target = target or rows[1]
  else
    for i = #rows, 1, -1 do
      local r = rows[i]
      if r < row then
        target = r
        break
      end
    end
    target = target or rows[#rows]
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    return true
  end
  return false
end

local ACTIONS = {
  accept_current = accept_hunk,
  accept_file = accept_file,
  reject_current = reject_hunk,
  reject_file = reject_file,
  accept_run = accept_all,
  reject_run = reject_all,
}

function M.current_action(action)
  local state, bufnr = current_state()
  if not state then
    return false
  end
  if action == "next_hunk" then
    return jump_hunk(1)
  elseif action == "prev_hunk" then
    return jump_hunk(-1)
  elseif action == "open_file" then
    return open_file(state)
  end
  local fn = ACTIONS[action]
  if not fn then
    return false
  end
  return fn(state, bufnr)
end

local function bind(bufnr)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "a", function()
    require("zxz.edit.verbs").accept_current()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: accept hunk" }))
  vim.keymap.set("n", "r", function()
    require("zxz.edit.verbs").reject_current()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: reject hunk" }))
  vim.keymap.set("n", "u", function()
    require("zxz.edit.verbs").undo_reject()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: undo last reject" }))
  vim.keymap.set("n", "A", function()
    require("zxz.edit.verbs").accept_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: accept file" }))
  vim.keymap.set("n", "R", function()
    require("zxz.edit.verbs").reject_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: reject file" }))
  vim.keymap.set("n", "ga", function()
    require("zxz.edit.verbs").accept_run()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: accept all" }))
  vim.keymap.set("n", "gr", function()
    require("zxz.edit.verbs").reject_run()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: reject all" }))
  vim.keymap.set("n", "<CR>", function()
    local state = states[bufnr]
    if state then
      open_file(state)
    end
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: open file" }))
  vim.keymap.set("n", "]h", function()
    require("zxz.edit.verbs").next_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: next hunk" }))
  vim.keymap.set("n", "[h", function()
    require("zxz.edit.verbs").prev_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: previous hunk" }))
  vim.keymap.set("n", "q", function()
    pcall(vim.cmd, "bdelete")
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: close" }))
end

local function open_state(state)
  vim.cmd("tabnew")
  local bufnr = vim.api.nvim_get_current_buf()
  states[bufnr] = state
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_name(bufnr, state.title)
  vim.bo[bufnr].filetype = "zxz-review"
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.cursorline = true
  render(bufnr)
  bind(bufnr)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      states[bufnr] = nil
    end,
  })
end

function M.open_checkpoint(checkpoint, opts)
  local state, err = build_checkpoint_state(checkpoint, opts and opts.chat)
  if not state then
    vim.notify("0x0: " .. (err or "nothing to review"), vim.log.levels.INFO)
    return
  end
  open_state(state)
end

function M.open_run(run, opts)
  local state, err = build_run_state(run, opts and opts.chat)
  if not state then
    vim.notify("0x0: " .. (err or "nothing to review"), vim.log.levels.INFO)
    return
  end
  open_state(state)
end

function M.refresh_checkpoint(checkpoint)
  if not checkpoint then
    return
  end
  for bufnr, state in pairs(states) do
    if vim.api.nvim_buf_is_valid(bufnr) and state.kind == "checkpoint" and state.checkpoint == checkpoint then
      refresh_checkpoint_state(state)
      render_preserving_selection(bufnr)
    end
  end
end

Ledger.on_change(function(checkpoint)
  vim.schedule(function()
    M.refresh_checkpoint(checkpoint)
  end)
end)

function M._state(bufnr)
  return states[bufnr]
end

return M
