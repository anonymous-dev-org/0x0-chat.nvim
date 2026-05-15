# 0x0.nvim

Small editing-tool smoke test.

Workflow plugin for Agentic chat sessions in isolated git worktrees, with a
small accept-and-merge review flow back into the main worktree.

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
  },
}
```

0x0.nvim deliberately depends on `agentic.nvim` instead of forking its chat UI.
`:ZxzChat [provider]` creates a fresh git worktree, opens a new tabpage rooted
there, then starts Agentic in that tab. Every completed Agentic turn commits
dirty files as one normal commit on the agent branch, so follow-up turns stack
like regular git history. If Agentic starts a new session from a 0x0-managed
chat tab, 0x0 redirects it into a fresh worktree.

`:ZxzReview` lets you pick an agent worktree and opens a full-tab review view
without touching the main worktree. Press `A` to accept all remaining changes,
`a` on the file list to accept a file, or `a` in the diff pane to accept the
hunk under the cursor. Accepted changes are committed onto a temporary review
branch. Press `f` to send feedback back to the same agent worktree, or `m` to
merge the accepted review branch into main. Press `q` to close review with no
merge state to abort.
