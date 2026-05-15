# 0x0.nvim

Workflow plugin for Agentic chat sessions in isolated git worktrees, with
Fugitive-based review back into the main worktree.

## Install

Example with lazy.nvim:

```lua
{
  "anonymous-dev-org/0x0.nvim",
  dependencies = {
    {
      "carlos-algms/agentic.nvim",
      opts = {
        provider = "claude-acp",
      },
    },
    "tpope/vim-fugitive",
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
