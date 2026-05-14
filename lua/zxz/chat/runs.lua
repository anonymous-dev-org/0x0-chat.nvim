-- Run lifecycle: a Run aggregates everything an agent did between a single
-- user prompt and the end of that turn (or its cancellation/failure). Refs
-- come from the existing checkpoint namespace; persistence is a sibling of
-- the chat thread store.

local Checkpoint = require("zxz.core.checkpoint")
local ChatDB = require("zxz.core.chat_db")
local EditEvents = require("zxz.core.edit_events")
local RunsStore = require("zxz.core.runs_store")

local M = {}

local function summarize(prompt)
  if type(prompt) ~= "string" then
    return ""
  end
  local trimmed = prompt:gsub("^%s+", ""):gsub("%s+$", "")
  if #trimmed <= 200 then
    return trimmed
  end
  return trimmed:sub(1, 200)
end

---Begin a Run record. Called from `_submit_prompt` once a checkpoint exists
---and we are not in a retry path. `self.checkpoint` carries the start ref.
---@param prompt string
function M:_start_run(prompt)
  if not self.checkpoint then
    return
  end
  if self.current_run then
    -- A previous run never finalized (likely a bug). Mark and drop it.
    self.current_run.status = "failed"
    self.current_run.ended_at = os.time()
    RunsStore.save(self.current_run)
    self:_record_run_id(self.current_run.run_id)
    self.current_run = nil
  end
  self.current_run = {
    run_id = self.checkpoint.turn_id,
    thread_id = self.persist_id,
    agent = {
      provider = self.provider_name,
      model = self.model,
      mode = self.mode,
    },
    prompt_summary = summarize(prompt),
    root = self.checkpoint.root,
    start_ref = self.checkpoint.ref,
    start_sha = self.checkpoint.sha,
    end_ref = nil,
    end_sha = nil,
    tool_refs = {},
    tool_calls = {},
    edit_events = {},
    files_touched = {},
    status = "running",
    started_at = os.time(),
    ended_at = nil,
  }
  RunsStore.save(self.current_run)
end

---@param tool_call_id string
---@param update table
function M:_run_append_tool_call(tool_call_id, update)
  local run = self.current_run
  if not run or not tool_call_id then
    return
  end
  run.tool_calls[#run.tool_calls + 1] = {
    tool_call_id = tool_call_id,
    kind = update.kind or "tool",
    title = update.title or "",
    status = update.status or "pending",
    raw_input = update.rawInput,
    content = update.content,
    locations = update.locations,
    started_at = os.time(),
    ended_at = nil,
  }
  ChatDB.save_tool_call(vim.tbl_extend("force", run.tool_calls[#run.tool_calls], {
    id = ("%s:%s"):format(run.run_id, tool_call_id),
    chat_id = self.persist_id,
    run_id = run.run_id,
  }))
  RunsStore.save(run)
end

---@param tool_call_id string
---@param patch table
function M:_run_update_tool_call(tool_call_id, patch)
  local run = self.current_run
  if not run or not tool_call_id then
    return
  end
  for _, tc in ipairs(run.tool_calls) do
    if tc.tool_call_id == tool_call_id then
      if patch.status then
        tc.status = patch.status
        if patch.status == "completed" or patch.status == "failed" then
          tc.ended_at = os.time()
        end
      end
      if patch.title and patch.title ~= "" then
        tc.title = patch.title
      end
      if patch.kind then
        tc.kind = patch.kind
      end
      if patch.raw_input ~= nil then
        tc.raw_input = patch.raw_input
      end
      if patch.content ~= nil then
        tc.content = patch.content
      end
      if patch.locations ~= nil then
        tc.locations = patch.locations
      end
      ChatDB.save_tool_call(vim.tbl_extend("force", tc, {
        id = ("%s:%s"):format(run.run_id, tool_call_id),
        chat_id = self.persist_id,
        run_id = run.run_id,
      }))
      RunsStore.save(run)
      return
    end
  end
end

---@param event table
function M:_run_record_edit_event(event)
  local run = self.current_run
  if not run or not event then
    return
  end
  EditEvents.append_to_run(run, event)
  EditEvents.record(event)
  RunsStore.save(run)
end

---Append a reconcile conflict observed during the active Run.
---@param path string
---@param message string
function M:_run_record_conflict(path, message)
  local run = self.current_run
  if not run then
    return
  end
  run.conflicts = run.conflicts or {}
  run.conflicts[#run.conflicts + 1] = {
    path = path,
    message = message,
    at = os.time(),
  }
end

---@param tool_call_id string
---@param tool_checkpoint table { ref, sha, ... }
function M:_run_record_tool_ref(tool_call_id, tool_checkpoint)
  local run = self.current_run
  if not run or not tool_call_id or not tool_checkpoint then
    return
  end
  run.tool_refs[tool_call_id] = tool_checkpoint.ref
end

---Finalize the active Run. Captures an end snapshot, computes files_touched
---from the start ref, persists the record, and appends to the thread.
---@param status string  -- "completed" | "cancelled" | "failed"
function M:_finalize_run(status)
  local run = self.current_run
  if not run then
    return
  end
  self.current_run = nil

  run.status = status or "completed"
  run.ended_at = os.time()

  local start_cp = {
    ref = run.start_ref,
    sha = run.start_sha,
    root = run.root or (self.checkpoint and self.checkpoint.root),
  }

  if start_cp.root and start_cp.ref then
    local end_cp = Checkpoint.snapshot(start_cp.root, {
      ref_suffix = ("%s__end"):format(run.run_id),
      parent_sha = start_cp.sha,
      label = ("0x0 run end %s"):format(run.run_id),
    })
    if end_cp then
      run.end_ref = end_cp.ref
      run.end_sha = end_cp.sha
    end
    local ok, files = pcall(Checkpoint.changed_files, start_cp)
    if ok and type(files) == "table" then
      run.files_touched = files
    end
  end

  RunsStore.save(run)
  self:_record_run_id(run.run_id)
end

---@param run_id string
function M:_record_run_id(run_id)
  self.run_ids = self.run_ids or {}
  for _, existing in ipairs(self.run_ids) do
    if existing == run_id then
      return
    end
  end
  self.run_ids[#self.run_ids + 1] = run_id
  self:_schedule_persist()
end

return M
