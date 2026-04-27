local M = {}

---@class zeroxzero.ProviderConfig
---@field name string
---@field command string
---@field args? string[]
---@field env? table<string, string>
---@field models? string[]

---@class zeroxzero.Config
---@field provider string
---@field width number
---@field input_height integer
---@field providers table<string, zeroxzero.ProviderConfig>

---@type zeroxzero.Config
M.defaults = {
  provider = "claude-acp",
  width = 0.4,
  input_height = 8,
  providers = {
    ["claude-acp"] = {
      name = "Claude ACP",
      command = "claude-code-acp",
      models = { "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5" },
    },
    ["claude-agent-acp"] = {
      name = "Claude Agent ACP",
      command = "claude-agent-acp",
      models = { "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5" },
    },
    ["codex-acp"] = {
      name = "Codex ACP",
      command = "codex-acp",
      models = { "gpt-5-codex", "gpt-5", "o3" },
    },
    ["gemini-acp"] = {
      name = "Gemini ACP",
      command = "gemini",
      args = { "--acp" },
      models = { "gemini-2.5-pro", "gemini-2.5-flash" },
    },
  },
}

M.current = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

---@param name? string
---@return zeroxzero.ProviderConfig|nil, string|nil
function M.resolve_provider(name)
  name = name or M.current.provider
  local provider = M.current.providers[name]
  if not provider then
    return nil, "unknown provider: " .. tostring(name)
  end
  return provider, nil
end

return M
