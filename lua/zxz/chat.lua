---Thin workflow shim over agentic.nvim.
---
---Each :ZxzChat creates a fresh worktree, opens a new tabpage, sets the
---tabpage-local cwd to that worktree, then calls require("agentic").open().
---Agentic is per-tabpage and uses cwd at ACP session creation, so the chat
---is naturally pinned to the worktree. Review feedback reopens the same
---worktree so the agent can add another commit to the same branch.

local Worktree = require("zxz.worktree")

local M = {}

---@type table<integer, zxz.Worktree>
local worktrees_by_tab = {}
local hook_installed = false
local agentic_patched = false
local permission_patched = false
local permission_manager_module
local permission_add_request_original

---@param mod_name string
---@return any|nil, string?
local function safe_require(mod_name)
  local ok, mod = pcall(require, mod_name)
  if not ok then
    return nil, tostring(mod)
  end
  return mod, nil
end

---@param reason string
local function play_sound(reason)
  require("zxz.sound").play(reason)
end

---@param wt zxz.Worktree
local function commit_turn(wt)
  local ok, err, committed = Worktree.snapshot(wt, {
    message = ("zxz: agent turn %s"):format(os.date("%Y-%m-%d %H:%M:%S")),
  })
  if not ok then
    play_sound("agent_error")
    vim.notify("zxz.chat: failed to commit agent turn: " .. tostring(err), vim.log.levels.ERROR)
    return
  end
  if committed then
    vim.notify(("zxz.chat: committed agent turn on %s"):format(wt.branch), vim.log.levels.INFO)
  end
end

---@param hook_name string
---@param user_hook function|nil
---@param data table
local function call_user_hook(hook_name, user_hook, data)
  if not user_hook then
    return
  end
  local ok, err = pcall(user_hook, data)
  if not ok then
    play_sound("agent_error")
    vim.notify(("zxz.chat: agentic %s hook failed: %s"):format(hook_name, tostring(err)), vim.log.levels.WARN)
  end
end

---@param Config table
local function install_agentic_hooks(Config)
  Config.hooks = Config.hooks or {}
  if hook_installed then
    return
  end

  local user_response_complete = Config.hooks.on_response_complete
  Config.hooks.on_response_complete = function(data)
    call_user_hook("on_response_complete", user_response_complete, data)

    if data and data.success == false then
      play_sound("agent_error")
    else
      play_sound("agent_turn")
    end

    local wt = data and worktrees_by_tab[data.tab_page_id]
    if wt then
      commit_turn(wt)
    end
  end

  local user_create_session_response = Config.hooks.on_create_session_response
  Config.hooks.on_create_session_response = function(data)
    call_user_hook("on_create_session_response", user_create_session_response, data)
    if data and data.err then
      play_sound("agent_error")
    end
  end

  hook_installed = true
end

local function install_permission_sound()
  if permission_patched then
    return
  end

  local PermissionManager = safe_require("agentic.ui.permission_manager")
  if not PermissionManager or type(PermissionManager.add_request) ~= "function" then
    return
  end

  permission_manager_module = PermissionManager
  permission_add_request_original = PermissionManager.add_request
  PermissionManager.add_request = function(self, request, callback)
    play_sound("permission_request")
    return permission_add_request_original(self, request, callback)
  end
  permission_patched = true
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

---@param prompt string
local function submit_prompt(prompt)
  local SessionRegistry = safe_require("agentic.session_registry")
  if not SessionRegistry or type(SessionRegistry.get_session_for_tab_page) ~= "function" then
    vim.fn.setreg("+", prompt)
    vim.notify("zxz.chat: copied feedback prompt; paste it into Agentic", vim.log.levels.WARN)
    return
  end

  local submitted = false
  SessionRegistry.get_session_for_tab_page(nil, function(session)
    if session and type(session._handle_input_submit) == "function" then
      session:_handle_input_submit(prompt)
      submitted = true
    end
  end)

  if not submitted then
    vim.fn.setreg("+", prompt)
    vim.notify("zxz.chat: copied feedback prompt; paste it into Agentic", vim.log.levels.WARN)
  end
end

---@param wt zxz.Worktree
---@param opts { provider?: string, prompt?: string }
---@return zxz.Worktree|nil
---@return string? err
local function open_in_worktree(wt, opts)
  local agentic, rerr = safe_require("agentic")
  if not agentic then
    return nil, "agentic.nvim is not installed (" .. tostring(rerr) .. ")"
  end
  install_agentic_worktree_guard(agentic)
  install_permission_sound()

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
    install_agentic_hooks(Config)
  end

  local ok, err = pcall(agentic.open, { auto_add_to_context = false, focus_prompt = true })
  if not ok then
    worktrees_by_tab[vim.api.nvim_get_current_tabpage()] = nil
    return nil, "agentic.open failed: " .. tostring(err)
  end

  if opts.prompt and opts.prompt ~= "" then
    submit_prompt(opts.prompt)
  end

  return wt, nil
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
  return open_in_worktree(wt, opts)
end

---@param wt zxz.Worktree
---@param opts? { provider?: string, prompt?: string }
---@return zxz.Worktree|nil
---@return string? err
function M.open_existing(wt, opts)
  return open_in_worktree(wt, opts or {})
end

function M._reset_for_tests()
  worktrees_by_tab = {}
  hook_installed = false
  agentic_patched = false
  if permission_patched and permission_manager_module then
    permission_manager_module.add_request = permission_add_request_original
  end
  permission_patched = false
  permission_manager_module = nil
  permission_add_request_original = nil
end

return M
