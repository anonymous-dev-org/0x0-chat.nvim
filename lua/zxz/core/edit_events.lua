local M = {}

local events_by_run = {}
local sequence = 0

local function chomp(s)
  return (s or ""):gsub("[\r\n]+$", "")
end

local function write_file(path, content)
  local f = assert(io.open(path, "wb"))
  f:write(content or "")
  f:close()
end

local function relpath(root, abs_path, fallback)
  if fallback and fallback ~= "" then
    if fallback:sub(1, 1) ~= "/" then
      return fallback
    end
  end
  if root and abs_path and abs_path:sub(1, #root + 1) == root .. "/" then
    return abs_path:sub(#root + 2)
  end
  return fallback or abs_path
end

local function blob_sha(root, content)
  if content == nil then
    return nil
  end
  local cmd = root and { "git", "-C", root, "hash-object", "--stdin" } or { "git", "hash-object", "--stdin" }
  local out = vim.fn.system(cmd, content)
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return chomp(out)
end

local function normalize_no_index_diff(diff, path, before_exists)
  local lines = {}
  for line in (diff or ""):gmatch("([^\n]*)\n?") do
    if not (line == "" and #lines == 0) then
      if line:match("^diff %-%-git ") then
        line = "diff --git a/" .. path .. " b/" .. path
      elseif line:match("^%-%-%- ") then
        line = before_exists and ("--- a/" .. path) or "--- /dev/null"
      elseif line:match("^%+%+%+ ") then
        line = "+++ b/" .. path
      end
      lines[#lines + 1] = line
    end
  end
  return table.concat(lines, "\n")
end

local function diff_text(path, before_content, after_content)
  local base = vim.fn.tempname()
  local before_path = base .. ".before"
  local after_path = base .. ".after"
  write_file(before_path, before_content or "")
  write_file(after_path, after_content or "")
  local out = vim.fn.system({
    "git",
    "diff",
    "--no-index",
    "--no-ext-diff",
    "--unified=3",
    "--",
    before_path,
    after_path,
  })
  local code = vim.v.shell_error
  vim.fn.delete(before_path)
  vim.fn.delete(after_path)
  if code ~= 0 and code ~= 1 then
    return ""
  end
  return normalize_no_index_diff(out, path, before_content ~= nil)
end

local function diff_stats(diff)
  local additions = 0
  local deletions = 0
  for line in (diff or ""):gmatch("([^\n]*)\n?") do
    if line:sub(1, 1) == "+" and not line:match("^%+%+%+") then
      additions = additions + 1
    elseif line:sub(1, 1) == "-" and not line:match("^%-%-%-") then
      deletions = deletions + 1
    end
  end
  return additions, deletions
end

local function diff_hunks(event_id, diff)
  local hunks = {}
  for line in (diff or ""):gmatch("([^\n]*)\n?") do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      local idx = #hunks + 1
      hunks[idx] = {
        id = ("%s#h%d"):format(event_id, idx),
        status = "pending",
        old_start = tonumber(old_start) or 0,
        old_count = old_count == "" and 1 or (tonumber(old_count) or 0),
        new_start = tonumber(new_start) or 0,
        new_count = new_count == "" and 1 or (tonumber(new_count) or 0),
        header = line,
      }
    end
  end
  return hunks
end

local function unique_insert(list, value)
  if not value or value == "" then
    return
  end
  for _, existing in ipairs(list) do
    if existing == value then
      return
    end
  end
  list[#list + 1] = value
end

---@param path string
---@return string|nil
function M.read_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

---@param opts { root: string, path?: string, abs_path: string, run_id?: string, tool_call_id?: string, before_content?: string, after_content?: string }
---@return table|nil event
function M.from_write(opts)
  opts = opts or {}
  local path = relpath(opts.root, opts.abs_path, opts.path)
  if not path or path == "" then
    return nil
  end
  local before_content = opts.before_content
  local after_content = opts.after_content or ""
  if before_content == after_content then
    return nil
  end
  sequence = sequence + 1
  local event_id = ("%s:%s:%d:%d"):format(opts.run_id or "run", path, os.time(), sequence)
  local diff = diff_text(path, before_content, after_content)
  local additions, deletions = diff_stats(diff)
  local event = {
    id = event_id,
    run_id = opts.run_id,
    tool_call_id = opts.tool_call_id,
    path = path,
    before_sha = blob_sha(opts.root, before_content),
    after_sha = blob_sha(opts.root, after_content),
    diff = diff,
    additions = additions,
    deletions = deletions,
    change_type = before_content == nil and "add" or "modify",
    status = "pending",
    timestamp = os.time(),
  }
  event.hunks = diff_hunks(event.id, diff)
  return event
end

local function update_event_rollup(event)
  local hunks = event and event.hunks or {}
  if #hunks == 0 then
    return
  end
  local first = hunks[1].status or "pending"
  for _, hunk in ipairs(hunks) do
    if (hunk.status or "pending") ~= first then
      event.status = "partial"
      return
    end
  end
  event.status = first
end

local function find_event(events, event_id)
  for _, event in ipairs(events or {}) do
    if event.id == event_id then
      return event
    end
  end
  return nil
end

local function mutate_persisted_run(run_id, fn)
  if not run_id or run_id == "" then
    return false
  end
  local ok, RunsStore = pcall(require, "zxz.core.runs_store")
  if not ok then
    return false
  end
  local run = RunsStore.load(run_id)
  if not run then
    return false
  end
  if fn(run.edit_events or {}) then
    RunsStore.save(run)
    return true
  end
  return false
end

---@param run_id string|nil
---@param event_id string|nil
---@param hunk_id string|nil
---@param status "pending"|"accepted"|"rejected"
---@return boolean
function M.set_hunk_status(run_id, event_id, hunk_id, status)
  if not run_id or not event_id or not hunk_id or not status then
    return false
  end
  local changed = false
  local function apply(events)
    local event = find_event(events, event_id)
    if not event then
      return false
    end
    for _, hunk in ipairs(event.hunks or {}) do
      if hunk.id == hunk_id then
        hunk.status = status
        update_event_rollup(event)
        return true
      end
    end
    return false
  end
  changed = apply(events_by_run[run_id]) or mutate_persisted_run(run_id, apply)
  return changed
end

---@param run_id string|nil
---@param path string|nil
---@param status "pending"|"accepted"|"rejected"
---@return boolean
function M.set_path_status(run_id, path, status)
  if not run_id or not path or path == "" or not status then
    return false
  end
  local changed = false
  local function apply(events)
    local any = false
    for _, event in ipairs(events or {}) do
      if event.path == path then
        event.status = status
        for _, hunk in ipairs(event.hunks or {}) do
          hunk.status = status
        end
        any = true
      end
    end
    return any
  end
  changed = apply(events_by_run[run_id]) or mutate_persisted_run(run_id, apply)
  return changed
end

---@param run_id string|nil
---@param status "pending"|"accepted"|"rejected"
---@return boolean
function M.set_run_status(run_id, status)
  if not run_id or not status then
    return false
  end
  local changed = false
  local function apply(events)
    local any = false
    for _, event in ipairs(events or {}) do
      event.status = status
      for _, hunk in ipairs(event.hunks or {}) do
        hunk.status = status
      end
      any = true
    end
    return any
  end
  changed = apply(events_by_run[run_id]) or mutate_persisted_run(run_id, apply)
  return changed
end

---@param event table|nil
function M.record(event)
  if not event or not event.run_id then
    return
  end
  events_by_run[event.run_id] = events_by_run[event.run_id] or {}
  events_by_run[event.run_id][#events_by_run[event.run_id] + 1] = event
end

---@param run_id string|nil
---@return table[]
function M.for_run(run_id)
  if not run_id then
    return {}
  end
  return events_by_run[run_id] or {}
end

---@param run table
---@param event table
function M.append_to_run(run, event)
  if not run or not event then
    return
  end
  run.edit_events = run.edit_events or {}
  run.edit_events[#run.edit_events + 1] = event
  run.files_touched = run.files_touched or {}
  unique_insert(run.files_touched, event.path)
  for _, tool in ipairs(run.tool_calls or {}) do
    if tool.tool_call_id == event.tool_call_id then
      tool.edit_event_ids = tool.edit_event_ids or {}
      tool.edit_event_ids[#tool.edit_event_ids + 1] = event.id
      return
    end
  end
end

local function events_from_source(source)
  if type(source) == "table" then
    return source.edit_events or M.for_run(source.run_id)
  end
  return M.for_run(source)
end

---@param chunks table[]
---@param source table|string|nil run table or run_id
function M.annotate_chunks(chunks, source)
  local events = events_from_source(source)
  if not chunks or #chunks == 0 or #events == 0 then
    return chunks
  end
  local by_path = {}
  for _, event in ipairs(events) do
    by_path[event.path] = by_path[event.path] or {}
    by_path[event.path][#by_path[event.path] + 1] = event
  end
  for _, file in ipairs(chunks) do
    local parsed = file.parsed
    local path_events = by_path[file.path]
    if parsed and parsed.hunks and path_events and #path_events > 0 then
      local latest = path_events[#path_events]
      file.edit_events = path_events
      for idx, hunk in ipairs(parsed.hunks) do
        local event_hunk = latest.hunks and latest.hunks[idx]
        hunk.event_id = latest.id
        hunk.tool_call_id = latest.tool_call_id
        hunk.hunk_id = event_hunk and event_hunk.id or ("%s#h%d"):format(latest.id, idx)
      end
    end
  end
  return chunks
end

local function pending_event_hunks(event)
  local parsed = require("zxz.edit.inline_diff").parse(event.diff or "")
  local file = parsed[event.path]
  if not file or not file.hunks then
    return nil
  end
  local kept = {}
  for idx, hunk in ipairs(file.hunks) do
    local event_hunk = event.hunks and event.hunks[idx]
    local status = (event_hunk and event_hunk.status) or event.status or "pending"
    if status == "pending" then
      hunk.event_id = event.id
      hunk.tool_call_id = event.tool_call_id
      hunk.hunk_id = event_hunk and event_hunk.id or ("%s#h%d"):format(event.id, idx)
      hunk.status = status
      kept[#kept + 1] = hunk
    end
  end
  if #kept == 0 then
    return nil
  end
  file.hunks = kept
  return file
end

---@param source table|string|nil run table or run_id
---@return table[]
function M.pending_chunks(source)
  local chunks = {}
  for _, event in ipairs(events_from_source(source)) do
    if (event.status or "pending") ~= "accepted" and (event.status or "pending") ~= "rejected" then
      local parsed = pending_event_hunks(event)
      if parsed then
        chunks[#chunks + 1] = {
          path = event.path,
          lines = vim.split(event.diff or "", "\n", { plain = true }),
          parsed = parsed,
          edit_events = { event },
        }
      end
    end
  end
  return chunks
end

---@param event table
---@return string
function M.summary(event)
  local adds = tonumber(event and event.additions) or 0
  local dels = tonumber(event and event.deletions) or 0
  return ("edited `%s` (+%d/-%d)"):format(event.path or "?", adds, dels)
end

return M
