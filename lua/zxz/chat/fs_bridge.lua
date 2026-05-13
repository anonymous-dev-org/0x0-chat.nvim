-- Host-mediated filesystem bridge for the agent. Routes ACP fs_read /
-- fs_write through Reconcile so we can detect conflicts with user edits.

local Checkpoint = require("zxz.core.checkpoint")
local config = require("zxz.core.config")
local EditEvents = require("zxz.core.edit_events")
local InlineDiff = require("zxz.edit.inline_diff")
local ToolAttribution = require("zxz.core.tool_attribution")

local M = {}

local function normalize_path(path)
  local absolute = path:sub(1, 1) == "/"
  local parts = {}
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      if #parts == 0 then
        return nil
      end
      parts[#parts] = nil
    elseif part ~= "." and part ~= "" then
      parts[#parts + 1] = part
    end
  end
  return (absolute and "/" or "") .. table.concat(parts, "/")
end

local function record_dropped_event(chat, run, params, abs, err)
  local path = params.path or abs
  local diagnostic = EditEvents.record_diagnostic(run, {
    path = path,
    reason = "edit_event_record_failed",
    message = tostring(err),
    source = "fs_bridge",
  })
  if run and diagnostic then
    pcall(require("zxz.core.runs_store").save, run)
  end
  require("zxz.core.log").warn("fs_bridge: edit-event recording failed: " .. tostring(err))
  if chat.history then
    chat.history:add_activity(
      ("edit tracking failed for `%s` — review may fall back to checkpoint diff"):format(path or "?"),
      "failed"
    )
  end
  if chat._render then
    chat:_render()
  end
end

local function record_write_event(
  chat,
  params,
  abs,
  before_content,
  after_content,
  tool_call_id,
  tool_call_id_source,
  run
)
  vim.schedule(function()
    local ok, err = pcall(function()
      local event = EditEvents.from_write({
        root = chat.repo_root,
        path = params.path,
        abs_path = abs,
        run_id = run and run.run_id,
        tool_call_id = tool_call_id,
        tool_call_id_source = tool_call_id_source,
        before_content = before_content,
        after_content = after_content,
        limits = config.current.edit_events or {},
      })
      if not event then
        return
      end
      if run then
        EditEvents.append_to_run(run, event)
        EditEvents.record(event)
        pcall(require("zxz.core.runs_store").save, run)
      end
      if tool_call_id and chat.history:append_tool_edit_event(tool_call_id, event) then
        chat:_render()
      else
        chat.history:add_activity(EditEvents.summary(event), "completed")
        chat:_render()
      end
    end)
    if not ok then
      record_dropped_event(chat, run, params, abs, err)
    end
  end)
end

---Standalone resolver: ACP-supplied path → absolute path. Relative paths
---are joined onto repo_root so we never read/write outside the project.
---Exposed for reuse by run_registry's detached fs handlers (T1.11).
---@param repo_root string|nil
---@param path string|nil
---@return string|nil
function M.resolve_path(repo_root, path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if not repo_root or repo_root == "" then
    return nil
  end
  local root = vim.fn.fnamemodify(repo_root, ":p")
  root = root:gsub("/+$", "")
  if root == "" then
    return nil
  end
  local abs = path:sub(1, 1) == "/" and path or (root .. "/" .. path)
  abs = normalize_path(vim.fn.fnamemodify(abs, ":p"):gsub("/+$", ""))
  if not abs then
    return nil
  end
  if abs == root or abs:sub(1, #root + 1) == root .. "/" then
    return abs
  end
  return nil
end

---Resolve an ACP-supplied path to an absolute filesystem path. ACP paths
---are meant to be absolute, but be defensive.
---@param path string
---@return string|nil
function M:_resolve_acp_path(path)
  return M.resolve_path(self.repo_root, path)
end

function M:_handle_fs_read(params, respond)
  vim.schedule(function()
    if not self.reconcile then
      respond(nil, { code = -32000, message = "no active reconcile session" })
      return
    end
    local abs = self:_resolve_acp_path(params.path)
    if not abs then
      respond(nil, { code = -32602, message = "invalid path" })
      return
    end
    local content, err = self.reconcile:read_for_agent(abs, params.line, params.limit)
    if err then
      respond(nil, { code = -32000, message = err })
      return
    end
    respond(content, nil)
  end)
end

function M:_handle_fs_write(params, respond)
  vim.schedule(function()
    if not self.reconcile then
      respond({ code = -32000, message = "no active reconcile session" })
      return
    end
    local abs = self:_resolve_acp_path(params.path)
    if not abs then
      respond({ code = -32602, message = "invalid path" })
      return
    end
    local before_content = EditEvents.read_file(abs)
    local ok, werr = self.reconcile:write_for_agent(abs, params.content or "")
    if not ok then
      self:_run_record_conflict(params.path or abs, werr or "write rejected")
      self.history:add({
        type = "activity",
        status = "failed",
        text = ("reconcile conflict on `%s` — user edited since the agent's last read"):format(
          vim.fn.fnamemodify(abs, ":~:.")
        ),
      })
      self:_render()
      respond({ code = -32000, message = werr or "write rejected" })
      return
    end
    local after_content = params.content or ""
    local run = self.current_run
    local tool_call_id, tool_call_id_source = ToolAttribution.resolve(params, self.active_tool_call_id, run)
    respond(nil)
    if self.repo_root and Checkpoint.is_ignored(self.repo_root, abs) then
      local rel = vim.fn.fnamemodify(abs, ":~:.")
      self.history:add({
        type = "activity",
        status = "failed",
        text = ("wrote `%s` — outside checkpoint, no rewind available"):format(rel),
      })
      self:_render()
    end
    local inline_cfg = config.current.inline_diff or {}
    if self.checkpoint and inline_cfg.streaming_refresh ~= false then
      InlineDiff.refresh_path_streaming(self.checkpoint, abs, inline_cfg.streaming_refresh_delay_ms)
    end
    record_write_event(self, params, abs, before_content, after_content, tool_call_id, tool_call_id_source, run)
  end)
end

return M
