---Registry of agent CLIs we know how to launch.
---Each entry is a no-frills shell command run inside a fresh worktree.
---Users can override or extend this table via setup().

---@class zxz.AgentDef
---@field name string
---@field cmd string[]              -- interactive argv (used by zxz.terminal)
---@field headless_cmd? string[]    -- non-interactive argv (used by zxz.edit.inline_edit)
---@field env? table<string,string>
---@field describe? string

local M = {}

---@type table<string, zxz.AgentDef>
M.registry = {
  claude = {
    name = "claude",
    cmd = { "claude" },
    headless_cmd = { "claude", "-p" },
    describe = "Anthropic Claude Code",
  },
  codex = {
    name = "codex",
    cmd = { "codex" },
    headless_cmd = { "codex", "exec" },
    describe = "OpenAI Codex CLI",
  },
  gemini = {
    name = "gemini",
    cmd = { "gemini" },
    headless_cmd = { "gemini", "-p" },
    describe = "Google Gemini CLI",
  },
  opencode = {
    name = "opencode",
    cmd = { "opencode" },
    headless_cmd = { "opencode", "run" },
    describe = "OpenCode CLI",
  },
}

---@param name string
---@return zxz.AgentDef|nil
function M.get(name)
  return M.registry[name]
end

---@return string[] sorted names
function M.names()
  local out = {}
  for k in pairs(M.registry) do
    table.insert(out, k)
  end
  table.sort(out)
  return out
end

---@param name string
---@param def zxz.AgentDef
function M.register(name, def)
  def.name = def.name or name
  M.registry[name] = def
end

---@param name string
---@return boolean available
function M.available(name)
  local def = M.get(name)
  if not def then
    return false
  end
  return vim.fn.executable(def.cmd[1]) == 1
end

---Resolve the headless argv for a one-shot invocation. Falls back to the
---interactive `cmd` when the agent didn't declare a `headless_cmd` — most
---modern CLIs auto-detect a non-TTY stdin and switch to one-shot mode anyway.
---@param name string
---@return string[]|nil argv
function M.headless_argv(name)
  local def = M.get(name)
  if not def then
    return nil
  end
  return def.headless_cmd or def.cmd
end

return M
