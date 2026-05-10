-- Host-mediated filesystem bridge for the agent. Routes ACP fs_read /
-- fs_write through Reconcile so we can detect conflicts with user edits.

local Checkpoint = require("zeroxzero.checkpoint")
local InlineDiff = require("zeroxzero.inline_diff")

local M = {}

---Resolve an ACP-supplied path to an absolute filesystem path. ACP paths are
---meant to be absolute, but be defensive: relative paths are joined onto the
---repo root so we never read/write something outside the project.
---@param path string
---@return string|nil
function M:_resolve_acp_path(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return path
  end
  if self.repo_root then
    return self.repo_root .. "/" .. path
  end
  return nil
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
