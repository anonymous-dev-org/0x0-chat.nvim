# 0x0.nvim - agents working on this codebase

This file codifies the invariants and operational rules for the plugin. When
something feels load-bearing and non-obvious, document it here with a **Why:**
line tying it to an observable failure mode.

---

## 1. What this plugin is

0x0.nvim is a **workflow plugin** around agentic.nvim and git:

- **agentic.nvim** owns the chat UI, ACP session manager, permissions, provider
  switching, and restore behavior.
- **git** owns worktrees, stacked agent commits, and final merge commits.

0x0.nvim only owns the workflow around those tools:

- **`:ZxzChat [provider]`** creates a fresh git worktree, opens a new tabpage,
  sets the tab-local cwd to that worktree, and calls `require("agentic").open()`.
- Every completed Agentic turn commits dirty files as one normal commit on the
  agent branch.
- Agentic `new_session()` calls from a 0x0-managed chat tab are redirected into
  a fresh `:ZxzChat` worktree.
- **`:ZxzReview`** lets the user pick an agent worktree, refuses dirty
  worktrees, opens a full-tab review view, accepts selected hunks/files into a
  temporary review worktree, and only merges accepted changes into main when
  the user presses `m`.
- **`:ZxzCleanup [merged]`** removes agent worktrees.

Forbidden: re-adding a 0x0-owned chat panel, ACP session manager, permission
ledger, inline edit UI, terminal-agent launcher, or context-share helper. Fix
rich chat behavior in agentic.nvim; keep 0x0 review focused on the accept /
feedback / merge workflow.

---

## 2. Worktree lifecycle

`lua/zxz/worktree.lua`. **One worktree per chat session**, never reused.

- **Layout:** `<repo>/.git/zxz/wt-<id>/` on branch `zxz/agent-<id>`.
- **`base_ref` is pinned at creation** to a concrete SHA. **Why:** the user's
  main branch can advance while the agent works.
- **`repo` is canonicalised** through `vim.fn.resolve`. **Why:** macOS symlink
  mismatches (`/var` vs `/private/var`) previously broke comparisons.
- **No auto-cleanup.** Worktrees survive nvim restart and are removed only by
  `:ZxzCleanup`. **Why:** agent branches are often the only durable record of a
  session.
- **Agentic turns stack commits.** `:ZxzChat` installs an Agentic
  `on_response_complete` hook. If the worktree is dirty at the end of a turn,
  `Worktree.snapshot()` creates one normal commit for that turn. Later turns
  create later commits on the same branch. **Why:** review should look like
  normal git history.
- **New Agentic sessions do not reuse a managed tab's worktree.** From inside a
  0x0-managed chat tab, Agentic `new_session()` is redirected to `:ZxzChat`.
  **Why:** Agentic sessions bind to cwd at creation time; reusing the tab would
  silently put two sessions in one branch.

---

## 3. Review

`lua/zxz/review.lua` owns the minimal human review UI.

`:ZxzReview` selects a `zxz/agent-*` worktree via `vim.ui.select` and refuses
dirty worktrees. It creates/reuses a temporary `zxz/review-*` worktree at the
agent branch's `base_ref`. Review never sets `MERGE_HEAD` in the main worktree.

Review controls:

- `A` accepts all remaining proposed changes into the review branch.
- `a` on the file list accepts the selected file.
- `a` in the diff pane accepts only the hunk under the cursor.
- `f` sends feedback plus the selected diff context back to the same agent
  worktree; the agent can add another normal commit to the agent branch.
- `m` merges accepted review-branch commits into main with `git merge --no-ff`.
- `q` closes review only. There is no main-worktree merge state to abort.

---

## 4. Tests

- Tests are plenary-busted specs under `tests/*_spec.lua`.
- `make test` runs the lot.
- `make test-file FILE=tests/foo_spec.lua` targets one.
- `make lint` runs Stylua in check mode.

Currently pinned regression tests:

| Rule | Pinned test |
|---|---|
| Worktree path canonicalisation | `worktree_spec.lua::"resolves repo_root from inside an agent worktree"` |
| Three-dot diff is base-vs-branch | `worktree_spec.lua::"diff reports changes made on the agent branch"` |
| Agentic turn commits stack | `zxz_chat_spec.lua::"commits each completed agentic turn onto the agent branch"` |
| Agentic new session gets a new worktree | `zxz_chat_spec.lua::"redirects agentic new_session from a managed tab into a fresh worktree"` |
| Review does not start a main-worktree merge | `zxz_review_spec.lua::"opens a full review tab without starting a merge in main"` |
| Review accept-all then merge | `zxz_review_spec.lua::"accepts all proposed changes into the review branch, then merges them into main"` |
| Review accepts one file | `zxz_review_spec.lua::"accepts one file without accepting the rest of the proposal"` |
| Review accepts one hunk | `zxz_review_spec.lua::"accepts only the hunk under the cursor from the diff pane"` |
| Review feedback targets same agent worktree | `zxz_review_spec.lua::"sends feedback to the same agent worktree"` |
| Review refuses dirty worktrees | `zxz_review_spec.lua::"refuses review while the agent worktree has uncommitted changes"` |
| Review picker over multiple worktrees | `zxz_chat_spec.lua::"pick() invokes vim.ui.select when multiple worktrees exist"` |
| Chat opens Agentic with worktree cwd | `zxz_chat_spec.lua::"creates a worktree and opens agentic with the worktree as cwd"` |
