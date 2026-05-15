# 0x0.nvim — agents working on this codebase

This file codifies the invariants and operational rules for the plugin. It is
the contract every change has to honour. When something feels load-bearing and
non-obvious, document it here with a **Why:** line tying it to an observable
failure mode.

---

## 1. What this plugin is (and is not)

0x0.nvim is a **workflow plugin** that wraps two existing agent surfaces in
a worktree-per-session discipline:

1. **Inline ghost-text completion** — `lua/zxz/complete/`, driven by ACP over
   stdio. Long-lived streaming session.
2. **Agent-in-a-worktree workflow** — `lua/zxz/{worktree,terminal,review,
   chat,context_share,commands,edit/}.lua`. Two front-ends share the same
   worktree+review backend:
   - **`:ZxzStart`** spawns an agent CLI in a `:terminal` window inside a
     dedicated git worktree (the terminal IS the chat for CLI agents).
   - **`:ZxzChat [provider]`** delegates to `agentic.nvim` inside a dedicated
     git worktree — a new tabpage is opened, tab-local cwd is `tcd`'d to the
     worktree, then `require("agentic").open()` is called. Agentic is
     per-tabpage and uses cwd at ACP session creation, so chat sessions are
     pinned to their worktree. Every completed Agentic turn commits dirty files
     as one new commit on the agent branch. Agentic `new_session()` calls from
     a 0x0-managed chat tab are redirected into a fresh `:ZxzChat` worktree.
   - **`:ZxzReview`** reviews any agent worktree (terminal or chat). If a
     terminal is active in the current buffer, it picks that one; otherwise
     it lists every `zxz/agent-*` worktree via `vim.ui.select` and merges the
     picked branch via `git merge --no-ff --no-commit` into the user's main
     worktree, then hands off to fugitive/Neogit.

We **depend on, not fork**, agentic.nvim. Its rich chat UI / session manager
/ permissions / restore live in that plugin; 0x0.nvim only provides the
worktree shell and the review handoff. If a feature request smells like
"build a better chat UI", push back: the answer is "fix it in agentic.nvim
upstream, or open `:ZxzChat` and use what's there".

Forbidden: re-adding a 0x0-owned chat panel, ACP session manager, or
permission ledger. That layer was deleted; agentic.nvim is the source of
truth for chat.

---

## 2. Worktree lifecycle

`lua/zxz/worktree.lua`. **One worktree per agent invocation**, never reused.

- **Layout:** `<repo>/.git/zxz/wt-<id>/` on branch `zxz/agent-<id>`.
- **`base_ref` is pinned at creation** to a concrete SHA. **Why:** the user's
  `main` (or whatever branch they're on) can advance while the agent works.
  Pinning means we can always trace what state the agent forked from, even
  weeks later when the surrounding history has moved on.
- **`repo` is always canonicalised** through `vim.fn.resolve` so callers from
  inside a worktree (where macOS symlinks `/var ↔ /private/var` would
  otherwise produce different strings) compare equal to callers from the main
  worktree. **Why:** tests broke on this exact symlink mismatch.
- **No auto-cleanup.** `:ZxzCleanup` is explicit; `:ZxzCleanup!` removes
  even live worktrees. Worktrees survive nvim restart — they're just git
  state. **Why:** the user chose this; agent branches are often the only
  record of what happened in a session.
- **Agentic turns stack commits.** `:ZxzChat` installs an Agentic
  `on_response_complete` hook. If the worktree is dirty at the end of a turn,
  `Worktree.snapshot()` creates exactly one normal commit for that turn. Later
  turns create later commits on the same agent branch. **Why:** the review
  flow should look like normal git history, not a squash buffer or an
  uncommitted scratch tree.
- **New Agentic sessions do not reuse a managed tab's worktree.** From inside
  a 0x0-managed chat tab, Agentic `new_session()` is redirected to `:ZxzChat`
  so the new session is created in a new tab and a new worktree. **Why:**
  Agentic sessions bind to cwd at creation time; reusing the tab would silently
  put two sessions in one agent branch.

---

## 3. Terminal launcher

`lua/zxz/terminal.lua`.

- **One subprocess per `Terminal.start` call.** No reuse, no pooling. Two
  `:ZxzStart claude` calls spawn two processes in two worktrees.
- **`job_id` discipline.** The job channel is the *only* way we feed input to
  the agent. Never write to the terminal buffer to "type into" the agent —
  use `Terminal.send(term, text)` which `chansend`s. **Why:** typing into a
  terminal buffer doesn't reach the subprocess; it only renders locally.
- **Buffer names follow `zxz://<agent>/<id>`.** Used by `Terminal.current()`
  for cwd-based agent lookup, and by `:ls` for human-readable identification.
- **`Terminal.stop(term)` defaults to removing the worktree too.** Pass
  `{ keep_worktree = true }` only when the caller has a reason to keep the
  branch (e.g. user wants to inspect it later). The default matches the
  one-worktree-per-invocation lifecycle rule above.

---

## 4. Context-share contract

`lua/zxz/context_share.lua`. Keymaps under `<leader>a` by default.

Payload formats sent to the agent's stdin via chansend (these are part of the
user's vocabulary — do not change without coordinating with the user):

| Trigger | Payload |
|---|---|
| `<leader>a` in normal mode | `@<relative_path>\n` |
| `<leader>a` over a visual range | `@<relative_path>:L<a>-<b>\n\`\`\`<filetype>\n<lines>\n\`\`\`\n` |
| `<leader>aP` multi-pick | `@a @b @c\n` (space-joined) |

- **Always `chansend` directly, never round-trip via the clipboard.** **Why:**
  the user wanted zero-friction push-into-stdin; clipboard hops are reserved
  for the explicit yank-to-clipboard sibling action.
- **Path normalisation:** both `cwd` and the buffer path are resolved through
  `vim.fn.resolve` before stripping the prefix. **Why:** the macOS symlink
  bug bit here too.
- **Active term resolution order:** explicit `opts.term` → `Terminal.current()`
  (= current buffer is an agent term) → most-recently-opened term.

---

## 5. Review (hand off to the user's git UI)

`lua/zxz/review.lua` is intentionally not a UI of its own.

`:ZxzReview` picks a worktree (current terminal's, or `vim.ui.select` over
`Worktree.list()` when multiple `zxz/agent-*` worktrees exist — terminal
sessions and chat sessions are in the same list because they live in the
same branch namespace), refuses dirty worktrees, then runs `git merge --no-ff
--no-commit <agent-branch>` in the user's main worktree and opens whichever git
UI is loaded — fugitive's `:Git` first, Neogit second, or notifies the user if
neither is present.

After that, all per-hunk staging, commit-message editing, conflict resolution
and merge abort happens through whatever the user already knows how to use:

- **Neogit**: `s` / `u` to stage/unstage, `cc` to commit, `M` for merge ops.
- **fugitive**: `s` / `u` / `cc`, `dv` for 3-way diff, `:Git merge --abort`.
- **shell fallback**: standard `git status`, `git add -p`, `git commit`,
  `git merge --abort`.

The previous incarnation of this module was a ~660-line bespoke status buffer
that reimplemented (badly) what those plugins have polished for years —
worse rename detection, no real conflict-marker workflow, no integration
with mergetool/diffview, foreign keymap vocabulary. **FORBIDDEN: re-adding
the bespoke review buffer.** Use the right tool.

The merge state is a real git merge: `MERGE_HEAD` is set, the agent's
branch shows up as a real parent on commit, conflicts surface as real
conflict markers. The agent worktree itself is unchanged by `:ZxzReview`
and remains available for further iteration; `:ZxzCleanup` retires it
when the user is done.

---

## 6. Inline edit (one-shot)

`lua/zxz/edit/inline_edit.lua` + `inline_diff.lua`.

- **One-shot only.** No conversation, no follow-up. The user runs `:ZxzEdit`
  with optional inline instruction, the agent CLI runs in headless mode
  (`headless_cmd` per agent, defaults to `cmd` if not declared), and the
  output is rendered as an inline diff overlay.
- **Prompt contract:** "Respond with ONLY the replacement text. No markdown
  fences, no commentary." `clean_response` defensively strips a single
  outermost ` ```lang ... ``` ` fence anyway because every CLI ignores
  "no fences" some fraction of the time.
- **Inline-diff overlay state is buffer-local** (`states_by_buf[bufnr]`). One
  overlay per buffer; calling `render` again closes the previous one. The
  overlay clears itself when all hunks have been resolved (`pending_count` == 0).
- **Subsequent-hunk row shifts on accept.** After applying hunk `i`, all
  pending hunks `j > i` have their `old_start` shifted by
  `#new_lines - old_count`. **Why:** without this the second hunk's row
  drifts off-by-N once the first hunk changes the line count.

---

## 7. ACP-for-completion (legacy survivor)

`lua/zxz/core/acp_client.lua` and `acp_transport.lua` are kept *only* because
`lua/zxz/complete/init.lua` uses them for streaming inline completions.
They are not used by the agent-terminal flow.

If/when inline completion gets a different transport (HTTP API, vendor SDK),
these can be deleted.

---

## 8. Forbidden patterns

- **`vim.notify` from libuv fast context.** Crashes nvim. Always
  `vim.schedule` first if the call site might be a fast callback. None of
  the current code triggers this because the completion path is the only
  remaining libuv consumer and it already schedules.
- **Re-adding the chat / ACP-session abstraction.** This was the whole point
  of the refactor. The agent CLI's `:terminal` is the chat.
- **Cwd-dependent shell calls.** Always use `git -C <path>` and pass an
  explicit cwd in `vim.fn.system` / `jobstart`. **Why:** nvim's process cwd
  can be anywhere; relying on it makes tests flaky.

---

## 9. Test discipline

- Tests are plenary-busted specs under `tests/*_spec.lua`. `make test` runs
  the lot; `make test-file FILE=tests/foo_spec.lua` targets one.
- **`make lint`** runs stylua in check mode; **`make lint-fix`** writes the
  formatted output. CI runs `lint` after `test`.
- **Every "MUST" or "FORBIDDEN" in this file should pin a regression test.**
  When a rule is violated and the test catches it, link the test from the
  rule. When you write a new rule with no test, write the test first.

Currently pinned regression tests:

| Rule | Pinned test |
|---|---|
| Worktree path canonicalisation | `worktree_spec.lua::"resolves repo_root from inside an agent worktree"` |
| Three-dot diff is base-vs-branch | `worktree_spec.lua::"diff reports changes made on the agent branch"` |
| Agentic turn commits stack | `zxz_chat_spec.lua::"commits each completed agentic turn onto the agent branch"` |
| Agentic new session gets a new worktree | `zxz_chat_spec.lua::"redirects agentic new_session from a managed tab into a fresh worktree"` |
| Review uses no-ff no-commit merge | `zxz_review_spec.lua::"stages the agent branch via git merge --no-ff --no-commit"` |
| Review refuses dirty worktrees | `zxz_review_spec.lua::"refuses review while the agent worktree has uncommitted changes"` |
| Review prefers fugitive | `zxz_review_spec.lua::"opens fugitive when both supported git UIs are available"` |
| Conflict path leaves index populated | `zxz_review_spec.lua::"survives a merge with conflicts ..."` |
| Review picker over multiple worktrees | `zxz_chat_spec.lua::"pick() invokes vim.ui.select when multiple worktrees exist"` |
| Chat opens agentic with worktree cwd | `zxz_chat_spec.lua::"creates a worktree and opens agentic with the worktree as cwd"` |
| Hunk row shift after accept | `inline_diff_spec.lua::"ga ... lands new lines and shifts subsequent hunks"` |
| chansend orientation | `context_share_spec.lua::"send_path chansends @<file> with newline"` |
| Resolved cwd-stripping | `context_share_spec.lua::"send_paths joins multiple @refs into one chansend"` |
