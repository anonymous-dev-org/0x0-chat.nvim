local M = {}

local events_by_run = {}
local diagnostics_by_run = {}
local run_meta = {}
local sequence = 0

local DEFAULT_LIMITS = {
  max_content_bytes = 512 * 1024,
  max_diff_bytes = 256 * 1024,
  max_retained_runs = 64,
  max_age_seconds = 24 * 60 * 60,
}

local function current_limits()
  local ok, config = pcall(require, "zxz.core.config")
  if ok and config.current and type(config.current.edit_events) == "table" then
    return vim.tbl_extend("force", DEFAULT_LIMITS, config.current.edit_events)
  end
  return vim.deepcopy(DEFAULT_LIMITS)
end

local function touch_run(run_id, timestamp)
  if not run_id or run_id == "" then
    return
  end
  run_meta[run_id] = run_meta[run_id] or {}
  run_meta[run_id].last_seen = math.max(run_meta[run_id].last_seen or 0, timestamp or os.time())
end

local function run_timestamp(run_id)
  local meta = run_meta[run_id]
  if meta and meta.last_seen then
    return meta.last_seen
  end
  local latest = 0
  for _, event in ipairs(events_by_run[run_id] or {}) do
    latest = math.max(latest, tonumber(event.timestamp) or 0)
  end
  for _, diagnostic in ipairs(diagnostics_by_run[run_id] or {}) do
    latest = math.max(latest, tonumber(diagnostic.timestamp) or 0)
  end
  touch_run(run_id, latest)
  return latest
end

local function drop_run(run_id)
  events_by_run[run_id] = nil
  diagnostics_by_run[run_id] = nil
  run_meta[run_id] = nil
end

local function all_run_ids()
  local seen = {}
  local ids = {}
  for run_id, _ in pairs(events_by_run) do
    if not seen[run_id] then
      ids[#ids + 1] = run_id
      seen[run_id] = true
    end
  end
  for run_id, _ in pairs(diagnostics_by_run) do
    if not seen[run_id] then
      ids[#ids + 1] = run_id
      seen[run_id] = true
    end
  end
  return ids
end

---@param opts? table
---@return integer removed
function M.gc(opts)
  opts = vim.tbl_extend("force", current_limits(), opts or {})
  local now = opts.now or os.time()
  local removed = 0
  local ids = all_run_ids()

  local max_age = tonumber(opts.max_age_seconds)
  if max_age and max_age > 0 then
    for _, run_id in ipairs(vim.deepcopy(ids)) do
      local seen_at = run_timestamp(run_id)
      if seen_at > 0 and now - seen_at > max_age then
        drop_run(run_id)
        removed = removed + 1
      end
    end
  end

  ids = all_run_ids()
  local max_runs = tonumber(opts.max_retained_runs)
  if max_runs and max_runs > 0 and #ids > max_runs then
    table.sort(ids, function(a, b)
      return run_timestamp(a) < run_timestamp(b)
    end)
    for idx = 1, #ids - max_runs do
      drop_run(ids[idx])
      removed = removed + 1
    end
  end

  return removed
end

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

local function line_count(content)
  if not content or content == "" then
    return 0
  end
  local _, count = content:gsub("\n", "\n")
  if content:sub(-1) ~= "\n" then
    count = count + 1
  end
  return count
end

local function contains_nul(content)
  return type(content) == "string" and content:find("%z") ~= nil
end

local function guard_reason(before_content, after_content, limits)
  limits = vim.tbl_extend("force", DEFAULT_LIMITS, limits or {})
  if contains_nul(before_content) or contains_nul(after_content) then
    return "binary"
  end
  local before_len = before_content and #before_content or 0
  local after_len = after_content and #after_content or 0
  if before_len > limits.max_content_bytes or after_len > limits.max_content_bytes then
    return "content_too_large"
  end
  return nil
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
  local limits = opts.limits or opts
  local summary_reason = guard_reason(before_content, after_content, limits)
  local diff = ""
  local additions
  local deletions
  local stats_exact = true
  if summary_reason then
    additions = line_count(after_content)
    deletions = line_count(before_content)
    stats_exact = false
  else
    diff = diff_text(path, before_content, after_content)
    if #diff > (limits.max_diff_bytes or DEFAULT_LIMITS.max_diff_bytes) then
      summary_reason = "diff_too_large"
      diff = ""
      additions = line_count(after_content)
      deletions = line_count(before_content)
      stats_exact = false
    else
      additions, deletions = diff_stats(diff)
    end
  end
  local event = {
    id = event_id,
    run_id = opts.run_id,
    root = opts.root,
    tool_call_id = opts.tool_call_id,
    tool_call_id_source = opts.tool_call_id_source,
    path = path,
    before_sha = blob_sha(opts.root, before_content),
    after_sha = blob_sha(opts.root, after_content),
    diff = diff,
    additions = additions,
    deletions = deletions,
    change_type = before_content == nil and "add" or "modify",
    status = "pending",
    summary_only = summary_reason ~= nil,
    summary_reason = summary_reason,
    stats_exact = stats_exact,
    timestamp = os.time(),
  }
  event.hunks = summary_reason and {} or diff_hunks(event.id, diff)
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

local function set_hunk_status_in_events(events, event_id, hunk_id, status)
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

local function set_path_status_in_events(events, path, status)
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
    return set_hunk_status_in_events(events, event_id, hunk_id, status)
  end
  changed = apply(events_by_run[run_id]) or mutate_persisted_run(run_id, apply)
  return changed
end

---@param source table|string|nil run table or run_id
---@param event_id string|nil
---@param hunk_id string|nil
---@param status "pending"|"accepted"|"rejected"
---@return boolean
function M.set_source_hunk_status(source, event_id, hunk_id, status)
  if type(source) == "table" then
    local changed = set_hunk_status_in_events(source.edit_events or {}, event_id, hunk_id, status)
    if source.run_id then
      changed = M.set_hunk_status(source.run_id, event_id, hunk_id, status) or changed
    end
    return changed
  end
  return M.set_hunk_status(source, event_id, hunk_id, status)
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
    return set_path_status_in_events(events, path, status)
  end
  changed = apply(events_by_run[run_id]) or mutate_persisted_run(run_id, apply)
  return changed
end

---@param source table|string|nil run table or run_id
---@param path string|nil
---@param status "pending"|"accepted"|"rejected"
---@return boolean
function M.set_source_path_status(source, path, status)
  if type(source) == "table" then
    local changed = set_path_status_in_events(source.edit_events or {}, path, status)
    if source.run_id then
      changed = M.set_path_status(source.run_id, path, status) or changed
    end
    return changed
  end
  return M.set_path_status(source, path, status)
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
  touch_run(event.run_id, event.timestamp)
  M.gc()
end

---@param source table|string|nil run table or run_id
---@param diagnostic table
---@return table|nil diagnostic
function M.record_diagnostic(source, diagnostic)
  diagnostic = diagnostic or {}
  local run_id = diagnostic.run_id
  if type(source) == "table" then
    run_id = run_id or source.run_id
  elseif type(source) == "string" then
    run_id = run_id or source
  end
  if not run_id or run_id == "" then
    return nil
  end
  local entry = {
    run_id = run_id,
    path = diagnostic.path,
    reason = diagnostic.reason or "edit_event_record_failed",
    message = diagnostic.message,
    source = diagnostic.source,
    timestamp = diagnostic.timestamp or os.time(),
  }
  diagnostics_by_run[run_id] = diagnostics_by_run[run_id] or {}
  diagnostics_by_run[run_id][#diagnostics_by_run[run_id] + 1] = entry
  if type(source) == "table" then
    source.edit_event_diagnostics = source.edit_event_diagnostics or {}
    source.edit_event_diagnostics[#source.edit_event_diagnostics + 1] = entry
  end
  touch_run(run_id, entry.timestamp)
  M.gc()
  return entry
end

---@param run_id string|nil
---@return table[]
function M.for_run(run_id)
  if not run_id then
    return {}
  end
  return events_by_run[run_id] or {}
end

---@param source table|string|nil run table or run_id
---@return table[]
function M.diagnostics_for_run(source)
  if type(source) == "table" then
    if type(source.edit_event_diagnostics) == "table" and #source.edit_event_diagnostics > 0 then
      return source.edit_event_diagnostics
    end
    return diagnostics_by_run[source.run_id] or {}
  end
  if not source then
    return {}
  end
  return diagnostics_by_run[source] or {}
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

local function pending_event_hunks(event, blocked_by_event_id, blocked_reason)
  if blocked_by_event_id then
    return {
      type = event.change_type or "modify",
      hunks = {},
      summary_only = true,
      summary_reason = blocked_reason or "resolve_earlier_event_first",
      blocked_by_event_id = blocked_by_event_id,
    }
  end
  if event.summary_only then
    return {
      type = event.change_type or "modify",
      hunks = {},
      summary_only = true,
      summary_reason = event.summary_reason,
    }
  end
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

local function hunk_range(hunk, side)
  local start = hunk[(side == "old" and "old_start" or "new_start")] or 0
  local count = hunk[(side == "old" and "old_count" or "new_count")] or 0
  local finish = count > 0 and (start + count - 1) or start
  return start, finish
end

local function ranges_overlap(a_start, a_end, b_start, b_end)
  return a_start <= b_end and b_start <= a_end
end

local function line_neutral(hunk)
  return (hunk.old_count or 0) == (hunk.new_count or 0) and (hunk.old_count or 0) > 0
end

local function hunk_conflict(existing, candidate)
  if not line_neutral(existing) or not line_neutral(candidate) then
    return true
  end
  local existing_old_start, existing_old_end = hunk_range(existing, "old")
  local candidate_old_start, candidate_old_end = hunk_range(candidate, "old")
  if ranges_overlap(existing_old_start, existing_old_end, candidate_old_start, candidate_old_end) then
    return true
  end
  local existing_new_start, existing_new_end = hunk_range(existing, "new")
  local candidate_new_start, candidate_new_end = hunk_range(candidate, "new")
  return ranges_overlap(existing_new_start, existing_new_end, candidate_new_start, candidate_new_end)
end

local function mergeable_hunks(existing_hunks, candidate_hunks)
  for _, candidate in ipairs(candidate_hunks or {}) do
    if not line_neutral(candidate) then
      return false
    end
    for _, existing in ipairs(existing_hunks or {}) do
      if hunk_conflict(existing, candidate) then
        return false
      end
    end
  end
  return true
end

local function append_event_chunk(target, event, parsed)
  vim.list_extend(target.parsed.hunks, parsed.hunks or {})
  target.lines[#target.lines + 1] = ""
  vim.list_extend(target.lines, vim.split(event.diff or "", "\n", { plain = true }))
  target.edit_events[#target.edit_events + 1] = event
end

local function diagnostic_chunk(diagnostic)
  local path = diagnostic.path or "(edit events)"
  local reason = diagnostic.reason or "edit_event_record_failed"
  return {
    path = path,
    lines = {},
    parsed = {
      type = "modify",
      hunks = {},
      summary_only = true,
      summary_reason = reason,
      diagnostic = true,
      diagnostic_message = diagnostic.message,
    },
    edit_event_diagnostics = { diagnostic },
  }
end

---@param source table|string|nil run table or run_id
---@return table[]
function M.diagnostic_chunks(source)
  local chunks = {}
  for _, diagnostic in ipairs(M.diagnostics_for_run(source)) do
    chunks[#chunks + 1] = diagnostic_chunk(diagnostic)
  end
  return chunks
end

---@param source table|string|nil run table or run_id
---@return table[]
function M.pending_chunks(source)
  local chunks = {}
  local by_path = {}
  for _, event in ipairs(events_from_source(source)) do
    if (event.status or "pending") ~= "accepted" and (event.status or "pending") ~= "rejected" then
      local path_state = by_path[event.path] or {
        hunks = {},
      }
      by_path[event.path] = path_state
      local blocked_by_event_id = path_state.blocked_by_event_id
      local blocked_reason = path_state.blocked_reason
      local parsed = pending_event_hunks(event, blocked_by_event_id, blocked_reason)
      if parsed then
        local chunk = {
          path = event.path,
          lines = vim.split(event.diff or "", "\n", { plain = true }),
          parsed = parsed,
          edit_events = { event },
          event_id = event.id,
          blocked_by_event_id = blocked_by_event_id,
        }
        if blocked_by_event_id or parsed.summary_only then
          chunks[#chunks + 1] = chunk
          path_state.blocked_by_event_id = path_state.blocked_by_event_id or event.id
          path_state.blocked_reason = path_state.blocked_reason or "resolve_earlier_event_first"
        elseif not path_state.chunk then
          chunks[#chunks + 1] = chunk
          path_state.chunk = chunk
          vim.list_extend(path_state.hunks, parsed.hunks or {})
        elseif mergeable_hunks(path_state.hunks, parsed.hunks) then
          append_event_chunk(path_state.chunk, event, parsed)
          vim.list_extend(path_state.hunks, parsed.hunks or {})
        else
          local blocked = pending_event_hunks(event, path_state.chunk.event_id, "overlapping_event_hunks")
          chunks[#chunks + 1] = {
            path = event.path,
            lines = vim.split(event.diff or "", "\n", { plain = true }),
            parsed = blocked,
            edit_events = { event },
            event_id = event.id,
            blocked_by_event_id = path_state.chunk.event_id,
          }
          path_state.blocked_by_event_id = event.id
          path_state.blocked_reason = "resolve_earlier_event_first"
        end
      end
    end
  end
  return chunks
end

local function hunk_count(chunk)
  return chunk and chunk.parsed and chunk.parsed.hunks and #chunk.parsed.hunks or 0
end

local function file_level_fallback(chunk, reason, blocked_by_event_id)
  local parsed = chunk.parsed or {}
  return {
    path = chunk.path,
    lines = {},
    parsed = {
      type = parsed.type or "modify",
      hunks = {},
      summary_only = true,
      summary_reason = reason,
      blocked_by_event_id = blocked_by_event_id,
    },
    checkpoint_fallback = true,
    blocked_by_event_id = blocked_by_event_id,
  }
end

---@param source table|string|nil run table or run_id
---@param fallback_chunks table[]|nil checkpoint/run diff chunks
---@return table[]
function M.review_chunks(source, fallback_chunks)
  local chunks = M.diagnostic_chunks(source)
  vim.list_extend(chunks, M.pending_chunks(source))
  if not fallback_chunks or #fallback_chunks == 0 then
    return chunks
  end
  local event_paths = {}
  for _, event in ipairs(events_from_source(source)) do
    local bucket = event_paths[event.path] or {
      hunk_count = 0,
      has_summary = false,
    }
    bucket.hunk_count = bucket.hunk_count + #(event.hunks or {})
    bucket.has_summary = bucket.has_summary or event.summary_only == true
    event_paths[event.path] = bucket
  end
  local by_path = {}
  for _, chunk in ipairs(chunks) do
    if not chunk.edit_event_diagnostics then
      local bucket = by_path[chunk.path] or {
        first_event_id = chunk.event_id,
        hunk_count = 0,
      }
      bucket.first_event_id = bucket.first_event_id or chunk.event_id
      bucket.hunk_count = bucket.hunk_count + hunk_count(chunk)
      by_path[chunk.path] = bucket
    end
  end
  for _, fallback in ipairs(fallback_chunks) do
    local path = fallback.path
    local bucket = path and by_path[path]
    local event_bucket = path and event_paths[path]
    if not bucket then
      if not event_bucket then
        chunks[#chunks + 1] = fallback
      elseif not event_bucket.has_summary and hunk_count(fallback) > event_bucket.hunk_count then
        chunks[#chunks + 1] = file_level_fallback(fallback, "unattributed_changes", nil)
      end
    elseif not (event_bucket and event_bucket.has_summary) and hunk_count(fallback) > bucket.hunk_count then
      chunks[#chunks + 1] = file_level_fallback(fallback, "resolve_event_hunks_first", bucket.first_event_id)
    end
  end
  return chunks
end

---@param event table
---@return string
function M.summary(event)
  local adds = tonumber(event and event.additions) or 0
  local dels = tonumber(event and event.deletions) or 0
  if event and event.summary_only then
    return ("edited `%s` (summary only: %s)"):format(event.path or "?", event.summary_reason or "guarded")
  end
  return ("edited `%s` (+%d/-%d)"):format(event.path or "?", adds, dels)
end

function M._reset()
  events_by_run = {}
  diagnostics_by_run = {}
  run_meta = {}
  sequence = 0
end

return M
