-- Global registry for detached agent runs spawned via :ZxzChatSpawn.
-- A DetachedRun owns its own ACP client subprocess, its own session
-- and checkpoint, and persists its Run record to runs_store just like
-- a Chat-driven run. No tabpage coupling.

local acp_client = require("zxz.core.acp_client")
local Checkpoint = require("zxz.core.checkpoint")
local config = require("zxz.core.config")
local EditEvents = require("zxz.core.edit_events")
local History = require("zxz.core.history")
local Reconcile = require("zxz.core.reconcile")
local Runs = require("zxz.chat.runs")
local ToolAttribution = require("zxz.core.tool_attribution")
local util = require("zxz.chat.util")

local M = {}

---@type table<string, zxz.DetachedRun>
local active = {}

local function next_id()
  return ("det-%d-%d"):format(os.time(), math.random(1, 1e9))
end

---@param run zxz.DetachedRun
local function teardown(run)
  if run.client and run.session_id then
    pcall(function()
      run.client:cancel(run.session_id)
    end)
    pcall(function()
      run.client:unsubscribe(run.session_id)
    end)
  end
  if run.client then
    pcall(function()
      run.client:stop()
    end)
  end
  run.client = nil
  run.session_id = nil
end

---@param run zxz.DetachedRun
---@param status "completed"|"cancelled"|"failed"
local function finalize_and_cleanup(run, status)
  if run.state == "done" then
    return
  end
  run.state = "completing"
  pcall(function()
    run:_finalize_run(status)
  end)
  -- After _finalize_run: self.current_run is nil but the JSON has been
  -- persisted to runs_store with files_touched populated. Re-read to
  -- snapshot for the on_complete callback. (T1.4)
  local files = {}
  local ok, persisted = pcall(require("zxz.core.runs_store").load, run.run_id)
  if ok and persisted and type(persisted.files_touched) == "table" then
    files = persisted.files_touched
  end
  run.state = "done"
  run.ended_at = os.time()
  teardown(run)
  active[run.run_id] = nil
  if run.on_complete then
    pcall(run.on_complete, run.run_id, status, files)
  end
  util.notify_user("ZxzDetachedRunEnd")
end

---@param run zxz.DetachedRun
---@param update table
local function handle_update(run, update)
  local kind = update.sessionUpdate
  if kind == "tool_call" then
    if not update.toolCallId then
      return
    end
    run.active_tool_call_id = update.toolCallId
    run.history:add({
      type = "tool_call",
      tool_call_id = update.toolCallId,
      kind = update.kind or "tool",
      title = update.title or "",
      status = update.status or "pending",
      raw_input = update.rawInput,
      content = update.content,
      locations = update.locations,
    })
    run:_run_append_tool_call(update.toolCallId, update)
  elseif kind == "tool_call_update" then
    if not update.toolCallId then
      return
    end
    local patch = util.tool_patch(update)
    run.history:update_tool_call(update.toolCallId, patch)
    run:_run_update_tool_call(update.toolCallId, patch)
  elseif kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
    local text = update.content and update.content.text or ""
    if text ~= "" then
      local msg_kind = kind == "agent_thought_chunk" and "thought" or "agent"
      run.history:add_agent_chunk(msg_kind, text)
    end
  end
end

---@param run zxz.DetachedRun
---@param request table
---@param respond fun(option_id: string)
local function auto_permission(_run, request, respond)
  -- Detached runs run autonomously. Prefer allow_once / allow_always when
  -- offered; otherwise pick the first option. ALWAYS invoke respond —
  -- never returning a decision would hang the provider indefinitely.
  -- (T1.5)
  local options = (request and request.options) or {}
  local function find(kind)
    for _, o in ipairs(options) do
      if o.kind == kind then
        return o.optionId
      end
    end
  end
  local pick = find("allow_once") or find("allow_always") or (options[1] and options[1].optionId)
  -- acp_client maps empty-string option_id → cancelled outcome.
  respond(pick or "")
end

local function record_write_event(
  run,
  params,
  abs,
  before_content,
  after_content,
  tool_call_id,
  tool_call_id_source,
  run_record
)
  vim.schedule(function()
    local ok, err = pcall(function()
      local event = EditEvents.from_write({
        root = run.repo_root,
        path = params.path,
        abs_path = abs,
        run_id = run_record and run_record.run_id,
        tool_call_id = tool_call_id,
        tool_call_id_source = tool_call_id_source,
        before_content = before_content,
        after_content = after_content,
        limits = config.current.edit_events or {},
      })
      if not event or not run_record then
        return
      end
      EditEvents.append_to_run(run_record, event)
      EditEvents.record(event)
      pcall(require("zxz.core.runs_store").save, run_record)
      run.history:append_tool_edit_event(tool_call_id, event)
    end)
    if not ok then
      require("zxz.core.log").warn("run_registry: edit-event recording failed: " .. tostring(err))
      local diagnostic = EditEvents.record_diagnostic(run_record, {
        path = params.path or abs,
        reason = "edit_event_record_failed",
        message = tostring(err),
        source = "run_registry",
      })
      if run_record and diagnostic then
        pcall(require("zxz.core.runs_store").save, run_record)
      end
      return
    end
  end)
end

---@param run zxz.DetachedRun
---@param params table
---@param respond fun(content: string|nil, err: table|nil)
local function fs_read(run, params, respond)
  -- ACP paths may be absolute OR repo-relative; resolve through the
  -- shared fs-bridge helper so detached runs match Chat behavior. (T1.11)
  local abs = require("zxz.chat.fs_bridge").resolve_path(run.repo_root, params.path)
  if not abs or abs == "" then
    respond(nil, { code = -32602, message = "invalid path" })
    return
  end
  if run.reconcile then
    local content, err = run.reconcile:read_for_agent(abs, params.line, params.limit)
    if err then
      respond(nil, { code = -32000, message = err })
      return
    end
    respond(content, nil)
    return
  end
  local f = io.open(abs, "rb")
  if not f then
    respond(nil, { code = -32000, message = "file not found" })
    return
  end
  local content = f:read("*a")
  f:close()
  respond(content, nil)
end

---@param run zxz.DetachedRun
---@param params table
---@param respond fun(result: table|nil)
local function fs_write(run, params, respond)
  if not run.reconcile then
    respond({ code = -32000, message = "no reconcile session" })
    return
  end
  -- Resolve relative paths against the run's repo_root. (T1.11)
  local abs = require("zxz.chat.fs_bridge").resolve_path(run.repo_root, params.path)
  if not abs or abs == "" then
    respond({ code = -32602, message = "invalid path" })
    return
  end
  local before_content = EditEvents.read_file(abs)
  local ok, err = run.reconcile:write_for_agent(abs, params.content or "")
  if not ok then
    run:_run_record_conflict(abs, err or "write rejected")
    respond({ code = -32000, message = err or "write rejected" })
    return
  end
  local after_content = params.content or ""
  local run_record = run.current_run
  local tool_call_id, tool_call_id_source = ToolAttribution.resolve(params, run.active_tool_call_id, run_record)
  respond(nil)
  record_write_event(run, params, abs, before_content, after_content, tool_call_id, tool_call_id_source, run_record)
end

---@param opts { prompt: string, provider?: string, model?: string, mode?: string, cwd?: string, on_complete?: fun(run_id: string, status: string, files: string[]) }
---@return string|nil run_id, string|nil err
function M.spawn(opts)
  opts = opts or {}
  local prompt = type(opts.prompt) == "string" and vim.trim(opts.prompt) or ""
  if prompt == "" then
    return nil, "empty prompt"
  end
  local cap = config.current.detached_runs_max or 4
  if vim.tbl_count(active) >= cap then
    return nil, ("detached run cap reached (%d)"):format(cap)
  end

  local provider_name = opts.provider or config.current.provider
  local provider, perr = config.resolve_provider(provider_name)
  if not provider then
    return nil, perr or "unknown provider"
  end
  local cwd = opts.cwd or vim.fn.getcwd()
  local root = Checkpoint.git_root(cwd) or cwd

  local run_id = next_id()

  ---@class zxz.DetachedRun
  local run = setmetatable({
    run_id = run_id,
    state = "pending",
    started_at = os.time(),
    ended_at = nil,
    provider_name = provider_name,
    model = opts.model,
    mode = opts.mode,
    repo_root = root,
    persist_id = "detached",
    history = History.new(),
    current_run = nil,
    run_ids = {},
    on_complete = opts.on_complete,
    -- Late-bound:
    client = nil,
    session_id = nil,
    checkpoint = nil,
    reconcile = nil,
    current_run_snapshot = nil,
  }, { __index = Runs })

  -- No persistence beyond runs_store; chat thread JSON not involved.
  run._schedule_persist = function() end

  active[run_id] = run

  local client = acp_client.new(provider, { host_fs = true })
  run.client = client

  client:start(function(_c, cerr)
    if cerr then
      finalize_and_cleanup(run, "failed")
      return
    end
    vim.schedule(function()
      local cp, err = Checkpoint.snapshot(root)
      if not cp then
        require("zxz.core.log").warn("run_registry: checkpoint snapshot failed: " .. tostring(err))
        finalize_and_cleanup(run, "failed")
        return
      end
      run.checkpoint = cp
      run.reconcile = Reconcile.new({
        checkpoint = cp,
        mode = config.current.reconcile or "strict",
      })

      run:_start_run(prompt)

      client:new_session(root, function(result, serr)
        if serr or not result or not result.sessionId then
          finalize_and_cleanup(run, "failed")
          return
        end
        run.session_id = result.sessionId
        client:subscribe(result.sessionId, {
          on_update = function(update)
            vim.schedule(function()
              handle_update(run, update)
            end)
          end,
          on_request_permission = function(request, respond)
            auto_permission(run, request, respond)
          end,
          on_fs_read_text_file = function(params, respond)
            vim.schedule(function()
              fs_read(run, params, respond)
            end)
          end,
          on_fs_write_text_file = function(params, respond)
            vim.schedule(function()
              fs_write(run, params, respond)
            end)
          end,
        })

        run.state = "running"
        client:prompt(result.sessionId, { { type = "text", text = prompt } }, function(_r, perr)
          vim.schedule(function()
            local status = "completed"
            if perr then
              status = "failed"
            end
            -- Snapshot files_touched before finalize_and_cleanup nils out current_run.
            if run.current_run then
              run.current_run_snapshot = {
                files_touched = vim.deepcopy(run.current_run.files_touched or {}),
              }
            end
            finalize_and_cleanup(run, status)
          end)
        end)
      end)
    end)
  end)

  return run_id, nil
end

---@return zxz.DetachedRun[]
function M.list()
  local out = {}
  for _, run in pairs(active) do
    out[#out + 1] = run
  end
  table.sort(out, function(a, b)
    return (a.started_at or 0) > (b.started_at or 0)
  end)
  return out
end

---@param run_id string
---@return boolean ok, string|nil err
function M.cancel(run_id)
  local run = active[run_id]
  if not run then
    return false, "no such run"
  end
  if run.client and run.session_id then
    pcall(function()
      run.client:cancel(run.session_id)
    end)
  end
  -- Snapshot files_touched so on_complete carries it.
  if run.current_run then
    run.current_run_snapshot = {
      files_touched = vim.deepcopy(run.current_run.files_touched or {}),
    }
  end
  finalize_and_cleanup(run, "cancelled")
  return true, nil
end

---@param run_id string
---@return zxz.DetachedRun|nil
function M.get(run_id)
  return active[run_id]
end

function M.shutdown_all()
  for run_id, _ in pairs(vim.deepcopy(active)) do
    pcall(M.cancel, run_id)
  end
end

return M
