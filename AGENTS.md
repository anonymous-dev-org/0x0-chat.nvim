# 0x0.nvim - agents working on this codebase

This file codifies the invariants and operational rules for the plugin. When
something feels load-bearing and non-obvious, document it here with a **Why:**
line tying it to an observable failure mode.

---

## 1. What this plugin is

0x0.nvim is a **workflow plugin** around two external Neovim plugins:

- **agentic.nvim** owns the chat UI, ACP session manager, permissions, provider
  switching, and restore behavior.
- **vim-fugitive** owns review, staging, conflict resolution, commit messages,
  and merge abort.

0x0.nvim only owns the workflow around those tools:

- **`:ZxzChat [provider]`** creates a fresh git worktree, opens a new tabpage,
  sets the tab-local cwd to that worktree, and calls `require("agentic").open()`.
- Every completed Agentic turn commits dirty files as one normal commit on the
  agent branch.
- Agentic `new_session()` calls from a 0x0-managed chat tab are redirected into
  a fresh `:ZxzChat` worktree.
- **`:ZxzReview`** lets the user pick an agent worktree, refuses dirty
  worktrees, runs `git merge --no-ff --no-commit <agent-branch>` in the main
  worktree, and opens Fugitive (`:Git`) for review.
- **`:ZxzCleanup [merged]`** removes agent worktrees.

Forbidden: re-adding a 0x0-owned chat panel, ACP session manager, permission
ledger, inline edit UI, terminal-agent launcher, context-share helper, or custom
review buffer. Fix rich chat behavior in agentic.nvim; use Fugitive for review.

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

`lua/zxz/review.lua` is intentionally not a review UI.

`:ZxzReview` selects a `zxz/agent-*` worktree via `vim.ui.select`, refuses dirty
worktrees, then runs:

```sh
git merge --no-ff --no-commit <agent-branch>
```

in the user's main worktree. The merge state is real git state: `MERGE_HEAD` is
set, conflicts are real conflict markers, and committing from Fugitive creates
the final merge commit.

Use Fugitive for review:

- `s` / `u` to stage and unstage
- `cc` to commit
- `dv` for 3-way diff
- `:Git merge --abort` to abort

Neogit is an optional fallback if Fugitive is not loaded. Shell fallback is
standard `git status`, `git add -p`, `git commit`, and `git merge --abort`.

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
| Review uses no-ff no-commit merge | `zxz_review_spec.lua::"stages the agent branch via git merge --no-ff --no-commit"` |
| Review refuses dirty worktrees | `zxz_review_spec.lua::"refuses review while the agent worktree has uncommitted changes"` |
| Review prefers Fugitive | `zxz_review_spec.lua::"opens fugitive when both supported git UIs are available"` |
| Conflict path leaves index populated | `zxz_review_spec.lua::"survives a merge with conflicts ..."` |
| Review picker over multiple worktrees | `zxz_chat_spec.lua::"pick() invokes vim.ui.select when multiple worktrees exist"` |
| Chat opens Agentic with worktree cwd | `zxz_chat_spec.lua::"creates a worktree and opens agentic with the worktree as cwd"` |
