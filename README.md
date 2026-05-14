# 0x0.nvim

Neovim plugin for 0x0 chat, inline edit/review, repo context, and ACP-backed
ghost-text completion.

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  opts = {
    provider = "claude-acp",
  },
}
```

The published plugin repository includes a bundled Claude ACP runtime at
`claude-agent-server/bin/run`, so the default `claude-acp` provider works from a
normal plugin checkout. Set `ANTHROPIC_API_KEY` in the environment Neovim starts
from.

```sh
export ANTHROPIC_API_KEY="..."
```

Other ACP providers can be selected by overriding `provider` or
`providers.<name>.command` in `opts`.
