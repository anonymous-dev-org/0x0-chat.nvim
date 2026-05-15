# 0x0.nvim

Neovim plugin for 0x0 chat, inline edit/review, repo context, and ACP-backed
ghost-text completion.

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  dependencies = {
    "carlos-algms/agentic.nvim",
    "tpope/vim-fugitive",
  },
  opts = {
    provider = "claude-acp",
  },
}
```

0x0.nvim deliberately depends on `agentic.nvim` instead of forking its chat UI.
`:ZxzChat [provider]` creates a fresh git worktree, opens a new tabpage rooted
there, then starts Agentic in that tab. Every completed Agentic turn commits
dirty files as one normal commit on the agent branch, so follow-up turns stack
like regular git history. If Agentic starts a new session from a 0x0-managed
chat tab, 0x0 redirects it into a fresh worktree. `:ZxzReview` lets you pick an
agent worktree, runs `git merge --no-ff --no-commit <agent-branch>` in the main
worktree, and opens Fugitive for review. Committing from Fugitive is the
approval step and creates the merge commit in the main worktree.

The published plugin repository includes a bundled Claude ACP runtime at
`claude-agent-server/bin/run`, so the default `claude-acp` provider works from a
normal plugin checkout. Set `ANTHROPIC_API_KEY` in the environment Neovim starts
from.

```sh
export ANTHROPIC_API_KEY="..."
```

Other ACP providers can be selected by overriding `provider` or
`providers.<name>.command` in `opts`.
