-- Host-mediated filesystem bridge for the agent. Routes ACP fs_read /
-- fs_write through Reconcile so we can detect conflicts with user edits.

local Checkpoint = require("zeroxzero.checkpoint")
local InlineDiff = require("zeroxzero.inline_diff")

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
    if self.repo_root and Checkpoint.is_ignored(self.repo_root, abs) then
      local rel = vim.fn.fnamemodify(abs, ":~:.")
      self.history:add({
        type = "activity",
        status = "failed",
        text = ("wrote `%s` — outside checkpoint, no rewind available"):format(rel),
      })
      self:_render()
    end
    if self.checkpoint then
      InlineDiff.refresh_path(self.checkpoint, abs)
    end
    respond(nil)
  end)
end

return M
