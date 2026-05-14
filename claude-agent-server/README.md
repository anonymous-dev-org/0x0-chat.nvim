# @0x0/claude-agent-server

In-repo ACP server that drives Claude (via `@anthropic-ai/sdk`) and speaks
the same protocol as `claude-code-acp` / `claude-agent-acp`. Replaces
the external dependency for the `claude-acp` provider in `0x0.nvim`.

## Protocol

Newline-delimited JSON-RPC 2.0 over stdio. Implements the ACP surface
documented in the 0x0.nvim `acp_client.lua`:

- Inbound: `initialize`, `session/new`, `session/prompt`,
  `session/cancel` (notification), `session/set_model`,
  `session/set_config_option`
- Outbound notifications: `session/update` (kinds:
  `agent_message_chunk`, `agent_thought_chunk`, `tool_call`,
  `tool_call_update`, `config_option_update`)
- Outbound requests: `fs/read_text_file`, `fs/write_text_file`,
  `session/request_permission`

## Build & run

```sh
bun install
bun run build          # typecheck + bundled dist/index.js
./bin/run              # spawns the server on stdio
```

## Tests

```sh
bun test               # transport + server unit tests
```

## Configuration in 0x0.nvim

`config.lua` detects this binary when installed at
`stdpath("data")/0x0/claude-agent-server/bin/run`, when published inside the
public `0x0.nvim` plugin repo at `claude-agent-server/bin/run`, and when running
from this monorepo checkout. If none of those paths exists, it tries
`claude-agent-server`, `claude-agent-acp`, then `claude-code-acp` from `PATH`.
