# 0x0.nvim

Inline ghost-text completion for Neovim, backed by an ACP provider over stdio
(`codex-acp` by default; `claude-acp`, `claude-agent-acp`, and `gemini-acp` also
wired up).

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {
    complete = {
      enabled = true,
      provider = "codex-acp",
      keymaps = {
        accept = "<Tab>",
        dismiss = "<C-]>",
      },
    },
  },
}
```

Ghost text streams from the configured ACP provider as you type, with caching
and debouncing. `:ZxzCompleteSettings` opens a live settings buffer.

See `lua/zxz/core/config.lua` for the full default `complete` block (debounce,
max tokens, filetype excludes, cache, telemetry, per-provider commands).
