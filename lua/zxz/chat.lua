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

---@type table<integer, zxz.Worktree>
local worktrees_by_tab = {}
local hook_installed = false
local agentic_patched = false

---@param mod_name string
---@return any|nil, string?
local function safe_require(mod_name)
  local ok, mod = pcall(require, mod_name)
  if not ok then
    return nil, tostring(mod)
  end
  return mod, nil
end

---@param wt zxz.Worktree
local function commit_turn(wt)
  local ok, err, committed = Worktree.snapshot(wt, {
    message = ("zxz: agent turn %s"):format(os.date("%Y-%m-%d %H:%M:%S")),
  })
  if not ok then
    vim.notify("zxz.chat: failed to commit agent turn: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if committed then
    vim.notify(("zxz.chat: committed agent turn on %s"):format(wt.branch), vim.log.levels.INFO)
  end
end

---@param Config table
local function install_response_hook(Config)
  Config.hooks = Config.hooks or {}
  if hook_installed then
    return
  end

  local user_hook = Config.hooks.on_response_complete
  Config.hooks.on_response_complete = function(data)
    if user_hook then
      local ok, err = pcall(user_hook, data)
      if not ok then
        vim.notify("zxz.chat: agentic on_response_complete hook failed: " .. tostring(err), vim.log.levels.WARN)
      end
    end

    local wt = worktrees_by_tab[data.tab_page_id]
    if wt then
      commit_turn(wt)
    end
  end
  hook_installed = true
end

local function install_agentic_worktree_guard(agentic)
  if agentic_patched then
    return
  end

  local original_new_session = agentic.new_session
  agentic.new_session = function(opts)
    local current_tab = vim.api.nvim_get_current_tabpage()
    if worktrees_by_tab[current_tab] then
      local wt, err = M.open({ provider = opts and opts.provider or nil })
      if not wt then
        vim.notify("zxz.chat: " .. tostring(err), vim.log.levels.ERROR)
      end
      return
    end
    if original_new_session then
      return original_new_session(opts)
    end
  end

  agentic_patched = true
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
  install_agentic_worktree_guard(agentic)

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
  local Config = safe_require("agentic.config")
  if Config then
    worktrees_by_tab[vim.api.nvim_get_current_tabpage()] = wt
    install_response_hook(Config)
  end

  local ok, err = pcall(agentic.open)
  if not ok then
    worktrees_by_tab[vim.api.nvim_get_current_tabpage()] = nil
    return nil, "agentic.open failed: " .. tostring(err)
  end

  return wt, nil
end

function M._reset_for_tests()
  worktrees_by_tab = {}
  hook_installed = false
  agentic_patched = false
end

return M
