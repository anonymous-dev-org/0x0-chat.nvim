-- Host-mediated filesystem bridge for the agent. Routes ACP fs_read /
-- fs_write through Reconcile so we can detect conflicts with user edits.

local Checkpoint = require("zxz.core.checkpoint")
local config = require("zxz.core.config")
local EditEvents = require("zxz.core.edit_events")
local InlineDiff = require("zxz.edit.inline_diff")

local M = {}

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
  if path:sub(1, 1) == "/" then
    return path
  end
  if repo_root and repo_root ~= "" then
    return repo_root .. "/" .. path
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
    local tool_call_id = params.toolCallId or params.tool_call_id or self.active_tool_call_id
    local event = EditEvents.from_write({
      root = self.repo_root,
      path = params.path,
      abs_path = abs,
      run_id = self.current_run and self.current_run.run_id,
      tool_call_id = tool_call_id,
      before_content = before_content,
      after_content = params.content or "",
    })
    if event then
      self:_run_record_edit_event(event)
      if tool_call_id and self.history:append_tool_edit_event(tool_call_id, event) then
        self:_render()
      else
        self.history:add_activity(EditEvents.summary(event), "completed")
        self:_render()
      end
    end
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
    respond(nil)
  end)
end

return M
