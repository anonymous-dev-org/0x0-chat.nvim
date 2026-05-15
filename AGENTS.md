# 0x0.nvim — agents working on this codebase

This file codifies the invariants and operational rules for the plugin. It is
the contract every change has to honour. When something feels load-bearing and
non-obvious, document it here with a **Why:** line tying it to an observable
failure mode.

---

## 1. What this plugin is (and is not)

0x0.nvim ships **two independent products**:

1. **Inline ghost-text completion** — `lua/zxz/complete/`, driven by ACP over
   stdio. This product still uses the ACP client because completion needs a
   long-lived streaming session.
2. **Agent-in-a-worktree workflow** — `lua/zxz/{worktree,terminal,review,
   context_share,commands,edit/}.lua`. The plugin spawns an agent CLI in a
   `:terminal` window inside a dedicated git worktree, lets the user push
   buffer context into that terminal's stdin, and reviews the resulting diff
   with Fugitive-style keymaps.

What was deleted in the terminal+worktree refactor (do **not** re-add without
discussion):

- Chat UI (`zxz/chat/*`), the chat-side ACP client wiring (sessions, runs,
  permissions, persistence, queue, run-review), the context picker, the
  edit-action palette (verbs, code-actions, ledger). The agent CLI itself
  owns those surfaces now inside its terminal.

If a feature request smells like "add a chat panel" or "add a runs registry",
push back: the answer is "use the agent's terminal".

---

## 2. Worktree lifecycle

`lua/zxz/worktree.lua`. **One worktree per agent invocation**, never reused.

- **Layout:** `<repo>/.git/zxz/wt-<id>/` on branch `zxz/agent-<id>`.
- **`base_ref` is pinned at creation** to a concrete SHA. Diffs are always
  taken against that SHA, never `HEAD`. **Why:** the user's `main` (or whatever
  branch they're on) can advance while the agent works — for example via
  another `:ZxzCleanup --merged`, an unrelated commit, or a rebase. The
  review buffer must continue to show "what the agent proposed" relative to
  the worktree state at start time, regardless of those later moves.
- **`repo` is always canonicalised** through `vim.fn.resolve` so callers from
  inside a worktree (where macOS symlinks `/var ↔ /private/var` would
  otherwise produce different strings) compare equal to callers from the main
  worktree. **Why:** tests broke on this exact symlink mismatch.
- **No auto-cleanup.** `:ZxzCleanup` is explicit; `:ZxzCleanup!` removes
  even live worktrees. Worktrees survive nvim restart — they're just git
  state. **Why:** the user chose this; agent branches are often the only
  record of what happened in a session.

### Diff orientation (load-bearing — read carefully)

`Worktree.pending_diff(wt)` returns `git diff <branch>` from the main
worktree. That diff is oriented **branch → worktree**:

- `+` lines come from the worktree (user's current content)
- `-` lines come from the branch (agent's proposed content)

To "accept" the agent's version into the worktree, callers apply this patch
with `{ reverse = true }`. The review buffer's UI section labels are
inverted (`UI_LABEL` in `review.lua`) so the user sees "Added (by agent)"
where the raw diff status is `deleted` (worktree-POV).

**FORBIDDEN: `git diff -R <branch>`.** The `-R` form produces non-standard
`b/... a/...` headers that our parser does not handle, and `git apply` has
edge cases with reversed prefixes. The orientation is encoded in apply
direction, not in the diff itself. **Why:** discovered while wiring the
review buffer; the `-R` form silently broke `apply_patch` because the parser
couldn't extract paths.

### Post-accept staging

Every `apply_patch` in the review buffer is followed by
`git add -A -- <path>`. **Why:** `git diff <branch>` from the main worktree
ignores untracked files. After accepting an "added" file, the file physically
exists in the worktree but is untracked, so the next `pending_diff` still
shows it as missing. Staging via `git add -A` makes git treat the file as
"now matches the branch", and the accumulated index is exactly what `:cc`
commits.

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

## 5. Review buffer

`lua/zxz/review.lua`. Reads `pending_diff(wt)`, groups files into sections,
applies hunks via the Fugitive splice trick.

### Sections

| Section | Bucket key | Meaning |
|---|---|---|
| Conflicts | `conflicts` | User has locally diverged from `base_ref` on a path the agent also modified |
| Modified  | `modified`  | Agent modified a tracked file |
| Added     | `deleted`*  | Agent added a new file (worktree-POV: file is "deleted" because it's only on the branch) |
| Deleted   | `added`*    | Agent deleted a file (worktree-POV: file is "added" in our direction because the branch lacks it) |

\* the bucket key is the parser's status; the UI label is the inverted
agent-facing meaning. The mapping is `UI_LABEL` in `review.lua`. **Why:** the
diff is branch→worktree; without the inversion the labels would read
backwards from the user's perspective.

### Conflict detection

`detect_conflict` runs `git diff --quiet <base_ref> -- <path>` from the main
worktree. Exit 1 = local divergence on that file = conflict. **FORBIDDEN:
relying on `git apply --check` for conflict detection.** **Why:** the diff is
generated from the current worktree, so a reverse-apply check always
succeeds — it's tautological, not informative. The only meaningful conflict
signal is "user has uncommitted/committed work on this path since the agent
started".

A conflicted file refuses `s` and `X` until the user resolves it via `dv`
(3-way diff). They can then write the buffer and the next refresh moves the
file back into the regular sections.

### Patch reassembly

`build_hunk_patch` and `build_file_patch` reassemble single-hunk and whole-
file patches from parsed records. **FORBIDDEN: feeding the parser's body
lines through `table.concat` without filtering.** Hunk body lines must start
with one of `' '`, `'+'`, `'-'`, `'\'`. Anything else (typically the
trailing empty line from the diff's terminating newline) corrupts the patch
and causes `git apply` to fail silently. The parser drops such lines.
**Why:** lost 30 min on this in Phase 4; tests `parse_diff` and `accepting a
hunk lands the agent's change` pin the fix.

### Section-header `s`

Pressing `s` on a section header accepts every non-conflict file in that
section in one shot, sequentially. Conflicted files are skipped without
notify (the user can target them individually).

### Commit step

`cc` collects `state.touched` (files the user has applied at least one hunk
or whole-file accept on), prompts for a commit message defaulting to
`zxz: accept from <branch>`, runs `git -C <repo> add -A -- <files>` (idempotent
with the per-accept staging), then `git commit -m <msg> -- <files>`. A single
commit per `cc` invocation.

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
| Patch body filter (no trailing empties) | `zxz_review_spec.lua::"accepting a hunk (reverse-apply) lands the agent's change"` |
| Conflict detection uses base_ref diff | `zxz_review_spec.lua::"conflict is detected when the user's worktree edits the same line"` |
| Hunk row shift after accept | `inline_diff_spec.lua::"ga ... lands new lines and shifts subsequent hunks"` |
| chansend orientation | `context_share_spec.lua::"send_path chansends @<file> with newline"` |
| Resolved cwd-stripping | `context_share_spec.lua::"send_paths joins multiple @refs into one chansend"` |
