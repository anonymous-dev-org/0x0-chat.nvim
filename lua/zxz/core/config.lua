local M = {}

---@class zxz.ProviderConfig
---@field name string
---@field command string
---@field args? string[]
---@field env? table<string, string>
---@field models? string[]
---@field ignore_stderr_patterns? string[]  Lua patterns; matching stderr lines are silenced

---@class zxz.Config
---@field provider string
---@field width number
---@field input_height integer
---@field title_model string|table<string, string>|nil
---@field sound string|false  one of: false / "off" / "bell" / "notification" / absolute path
---@field request_timeout_ms integer  per-request ACP timeout (cancelled with timeout error after)
---@field idle_kill_ms integer  kill provider subprocess if no stdout/stderr for this long during a request
---@field initialize_retries integer  retry count for the ACP initialize handshake
---@field providers table<string, zxz.ProviderConfig>

-- Default stderr noise patterns by provider. Users can extend or override
-- these via config.providers.<name>.ignore_stderr_patterns.
local DEFAULT_STDERR_PATTERNS = {
  ["claude-acp"] = {
    "Session not found",
    "session/prompt",
    "Spawning Claude Code",
    "does not appear in the file:",
    "Experiments loaded",
    "No onPostToolUseHook found",
    "%[PreToolUseHook%]",
  },
  ["claude-agent-acp"] = {
    "Session not found",
    "session/prompt",
    "Spawning Claude Code",
    "Experiments loaded",
  },
}

---@type zxz.Config
M.defaults = {
  provider = "claude-acp",
  width = 0.4,
  input_height = 8,
  title_model = {
    ["claude-acp"] = "claude-haiku-4-5",
    ["claude-agent-acp"] = "claude-haiku-4-5",
    ["codex-acp"] = "o3",
    ["gemini-acp"] = "gemini-2.5-flash",
  },
  sound = vim.fn.has("mac") == 1 and "notification" or "bell",
  request_timeout_ms = 60000,
  idle_kill_ms = 120000,
  initialize_retries = 3,
  checkpoint_keep_n = 20,
  reconcile = "strict",
  profile = "write",
  default_profile = "write",
  profiles = {
    ask = {
      name = "Ask",
      description = "Read-only codebase inspection.",
      tool_policy = {
        auto_approve = { "read" },
        deny = { "write", "shell" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
    write = {
      name = "Write",
      description = "Edit files with approval gates for risky actions.",
      tool_policy = {
        auto_approve = { "read" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
    review = {
      name = "Review",
      description = "Inspect diffs, diagnostics, tests, and risks.",
      tool_policy = {
        auto_approve = { "read" },
        deny = { "write", "shell" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
    autonomous = {
      name = "Autonomous",
      description = "Long-running codebase work with explicit review.",
      tool_policy = {
        auto_approve = { "read" },
        auto_approve_paths = {},
        deny_paths = {},
      },
    },
  },
  favorite_models = {},
  thinking = {
    enabled = nil,
    effort = nil,
  },
  tool_policy = {
    auto_approve = { "read" },
    -- Path globs (lua patterns) for which write/shell get auto-approved.
    -- Matched against rawInput.file_path / path / filePath when present.
    auto_approve_paths = {},
    -- Path globs that always force the gating prompt, even for classes in
    -- auto_approve. Wins over auto_approve_paths.
    deny_paths = {},
  },
  repo_map = {
    budget_bytes = 50 * 1024,
  },
  rules = {
    paths = { ".0x0/rules.md", ".zed/rules.md", "AGENTS.md" },
  },
  auto_prelude = {
    cursor = false,
    repo_map = false,
    recent = false,
  },
  code_actions = {},
  inline_diff = {
    streaming_refresh = true,
    streaming_refresh_delay_ms = 40,
  },
  edit_events = {
    max_content_bytes = 512 * 1024,
    max_diff_bytes = 256 * 1024,
  },
  detached_runs_max = 4,
  test_command = nil, -- auto-detected per project; override per-setup if needed
  test_command_timeout_ms = 5000, -- @test-output kill-on-timeout (T2.1, T2.7)
  context = {
    summarize_threshold = 8 * 1024, -- bare @path of files larger than this emits a summary
  },
  tool_output_max_lines = 200,
  complete = {
    enabled = true,
    model = nil,
    debounce_ms = 150,
    max_tokens = 128,
    temperature = 0,
    suppress_in_strings_and_comments = true,
    keymaps = {
      accept = "<Tab>",
      dismiss = "<C-]>",
    },
    filetypes = {
      exclude = { "TelescopePrompt", "NvimTree", "help", "qf", "alpha", "dashboard" },
    },
    cache = {
      enabled = true,
      max_entries = 100,
    },
    telemetry = {
      enabled = false,
      path = nil,
    },
    acp = {
      provider = "codex-acp",
      command = "codex-acp",
      args = { "-c", "notify=[]" },
      auth_method = "chatgpt",
    },
  },
  providers = {
    ["claude-acp"] = {
      name = "Claude ACP",
      command = (function()
        local local_bin = vim.fn.stdpath("data") .. "/0x0/claude-agent-server/bin/run"
        if vim.fn.executable(local_bin) == 1 then
          return local_bin
        end
        return "claude-code-acp"
      end)(),
      models = { "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5" },
      ignore_stderr_patterns = DEFAULT_STDERR_PATTERNS["claude-acp"],
    },
    ["claude-agent-acp"] = {
      name = "Claude Agent ACP",
      command = "claude-agent-acp",
      models = { "claude-opus-4-7", "claude-sonnet-4-6", "claude-haiku-4-5" },
      ignore_stderr_patterns = DEFAULT_STDERR_PATTERNS["claude-agent-acp"],
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
  M.current.profile = M.current.profile or M.current.default_profile
  local profile = M.current.profiles and M.current.profiles[M.current.profile]
  if profile and profile.tool_policy and not (opts and opts.tool_policy) then
    M.current.tool_policy = vim.tbl_deep_extend("force", vim.deepcopy(M.current.tool_policy or {}), profile.tool_policy)
  end
end

---@param name? string
---@return zxz.ProviderConfig|nil, string|nil
function M.resolve_provider(name)
  name = name or M.current.provider
  local provider = M.current.providers[name]
  if not provider then
    return nil, "unknown provider: " .. tostring(name)
  end
  return provider, nil
end

return M
