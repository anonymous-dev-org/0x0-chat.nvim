---Thin workflow shim over agentic.nvim.
---
---Each :ZxzChat creates a fresh worktree, opens a new tabpage, sets the
---tabpage-local cwd to that worktree, then calls require("agentic").open().
---Agentic is per-tabpage and uses cwd at ACP session creation, so the chat
---is naturally pinned to the worktree. Review is the same flow as for
---:ZxzStart terminals — `:ZxzReview` enumerates `Worktree.list()` and
---merges the picked branch into the user's main worktree.

local Worktree = require("zxz.worktree")

local M = {}

---@param mod_name string
---@return any|nil, string?
local function safe_require(mod_name)
  local ok, mod = pcall(require, mod_name)
  if not ok then
    return nil, tostring(mod)
  end
  return mod, nil
end

---@param opts? { provider?: string, base?: string }
---@return zxz.Worktree|nil
---@return string? err
function M.open(opts)
  opts = opts or {}
  local agentic, rerr = safe_require("agentic")
  if not agentic then
    return nil, "agentic.nvim is not installed (" .. tostring(rerr) .. ")"
  end

  local wt, werr = Worktree.create({ base = opts.base, agent = "agentic" })
  if not wt then
    return nil, werr
  end

  vim.cmd("tabnew")
  -- Tabpage-local cwd ⇒ agentic's per-tabpage SessionManager picks this up
  -- when it calls vim.fn.getcwd() during ACP session creation.
  vim.cmd("tcd " .. vim.fn.fnameescape(wt.path))

  -- If the user passed a provider, set it on the live agentic.Config before
  -- open(); agentic reads Config.provider when constructing AgentInstance.
  if opts.provider then
    local Config = safe_require("agentic.config")
    if Config then
      Config.provider = opts.provider
    end
  end

  local ok, err = pcall(agentic.open)
  if not ok then
    return nil, "agentic.open failed: " .. tostring(err)
  end

  return wt, nil
end

return M
