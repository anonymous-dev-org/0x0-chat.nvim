local Checkpoint = require("zxz.core.checkpoint")
local EditEvents = require("zxz.core.edit_events")

local M = {}

local listeners = {}
local last_reject

local function read_disk(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_disk(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = assert(io.open(path, "wb"))
  f:write(content)
  f:close()
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
  return lines
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

local function hunk_old_block(hunk)
  return hunk.old_block or hunk.old_lines or {}
end

local function hunk_new_block(hunk)
  return hunk.new_block or hunk.new_lines or {}
end

local function mark_hunk_status(checkpoint, hunk, status)
  if checkpoint and checkpoint.turn_id and hunk and hunk.event_id and hunk.hunk_id then
    EditEvents.set_hunk_status(checkpoint.turn_id, hunk.event_id, hunk.hunk_id, status)
  end
end

local function mark_path_status(checkpoint, path, status)
  if checkpoint and checkpoint.turn_id and path then
    EditEvents.set_path_status(checkpoint.turn_id, path, status)
  end
end

local function emit(checkpoint)
  for _, fn in ipairs(listeners) do
    pcall(fn, checkpoint)
  end
end

local function path_snapshot(checkpoint, path)
  local content = read_disk(checkpoint.root .. "/" .. path)
  return {
    path = path,
    existed = content ~= nil,
    content = content,
  }
end

local function push_reject_undo(checkpoint, paths)
  local files = {}
  for _, path in ipairs(paths or {}) do
    files[#files + 1] = path_snapshot(checkpoint, path)
  end
  last_reject = {
    checkpoint = checkpoint,
    root = checkpoint.root,
    files = files,
  }
end

local function restore_snapshot(root, file)
  local abs = root .. "/" .. file.path
  if file.existed then
    write_disk(abs, file.content or "")
  else
    vim.fn.delete(abs)
  end
end

local function modified_open_buffer(checkpoint, path)
  local abs = checkpoint.root .. "/" .. path
  local bufnr = vim.fn.bufnr(abs)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.bo[bufnr].modified == true
end

function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

---@param checkpoint table
---@param paths? string[]
---@param context? integer
---@return table<string,zxz.InlineFile>
function M.files(checkpoint, paths, context)
  local diff_text = Checkpoint.diff_text(checkpoint, paths, context or 3)
  return require("zxz.edit.inline_diff").parse(diff_text)
end

---@param checkpoint table
---@param path string
---@param hunk zxz.InlineHunk
---@return boolean ok, string|nil err
function M.accept_hunk(checkpoint, path, hunk)
  if not checkpoint then
    return false, "checkpoint missing"
  end
  local base, existed = Checkpoint.read_file(checkpoint, path)
  local base_lines = split_content(base)
  local had_newline = base and base:sub(-1) == "\n"
  if not existed then
    had_newline = true
  end
  if not block_matches(base_lines, hunk.old_start, hunk.old_count, hunk_old_block(hunk)) then
    return false, "hunk is stale; refresh review before accepting"
  end
  replace_block(base_lines, hunk.old_start, hunk.old_count, hunk_new_block(hunk))
  local content = join_lines(base_lines, had_newline)
  if read_disk(checkpoint.root .. "/" .. path) == nil and #base_lines == 0 then
    content = nil
  end
  local ok, err = Checkpoint.replace_file(checkpoint, path, content)
  if ok then
    mark_hunk_status(checkpoint, hunk, "accepted")
    emit(checkpoint)
  end
  return ok, err
end

---@param checkpoint table
---@param path string
---@return boolean ok, string|nil err
function M.accept_file(checkpoint, path)
  local ok, err = Checkpoint.accept_file(checkpoint, path)
  if ok then
    mark_path_status(checkpoint, path, "accepted")
    emit(checkpoint)
  end
  return ok, err
end

---@param checkpoint table
---@param path string
---@param hunk zxz.InlineHunk
---@return boolean ok, string|nil err
function M.reject_hunk(checkpoint, path, hunk)
  if not checkpoint then
    return false, "checkpoint missing"
  end
  if modified_open_buffer(checkpoint, path) then
    return false, "source buffer has unsaved edits; save or revert it before rejecting"
  end
  local abs = checkpoint.root .. "/" .. path
  local current = read_disk(abs)
  if current == nil then
    current = ""
  end
  local current_lines = split_content(current)
  local had_newline = current == "" or current:sub(-1) == "\n"
  if not block_matches(current_lines, hunk.new_start, hunk.new_count, hunk_new_block(hunk)) then
    return false, "hunk is stale; refresh review before rejecting"
  end
  push_reject_undo(checkpoint, { path })
  replace_block(current_lines, hunk.new_start, hunk.new_count, hunk_old_block(hunk))
  local _, existed = Checkpoint.read_file(checkpoint, path)
  if not existed and #current_lines == 0 then
    vim.fn.delete(abs)
  else
    write_disk(abs, join_lines(current_lines, had_newline))
  end
  mark_hunk_status(checkpoint, hunk, "rejected")
  emit(checkpoint)
  return true, nil
end

---@param checkpoint table
---@param path string
---@return boolean ok, string|nil err
function M.reject_file(checkpoint, path)
  if modified_open_buffer(checkpoint, path) then
    return false, "source buffer has unsaved edits; save or revert it before rejecting"
  end
  push_reject_undo(checkpoint, { path })
  local ok, err = Checkpoint.restore_file(checkpoint, path)
  if ok then
    mark_path_status(checkpoint, path, "rejected")
    emit(checkpoint)
  end
  return ok, err
end

---@param checkpoint table
---@return boolean ok, string|nil err
function M.accept_all(checkpoint)
  local files = Checkpoint.changed_files(checkpoint)
  for _, path in ipairs(files) do
    local ok, err = M.accept_file(checkpoint, path)
    if not ok then
      return false, err
    end
  end
  emit(checkpoint)
  return true, nil
end

---@param checkpoint table
---@return boolean ok, string|nil err
function M.reject_all(checkpoint)
  push_reject_undo(checkpoint, Checkpoint.changed_files(checkpoint))
  local ok, err = Checkpoint.restore_all(checkpoint)
  if ok then
    if checkpoint and checkpoint.turn_id then
      EditEvents.set_run_status(checkpoint.turn_id, "rejected")
    end
    emit(checkpoint)
  end
  return ok, err
end

---@return boolean ok, string|nil err, table|nil checkpoint
function M.undo_last_reject()
  if not last_reject or not last_reject.root or #(last_reject.files or {}) == 0 then
    return false, "no rejected change to undo", nil
  end
  local record = last_reject
  last_reject = nil
  for _, file in ipairs(record.files) do
    restore_snapshot(record.root, file)
    mark_path_status(record.checkpoint, file.path, "pending")
  end
  emit(record.checkpoint)
  return true, nil, record.checkpoint
end

return M
