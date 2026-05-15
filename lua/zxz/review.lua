---Hand off review of the agent's worktree to the user's git UI.
---
---We do exactly one thing: `git merge --no-ff --no-commit <agent-branch>` in
---the user's main worktree. That stages every change the agent made as a
---real git merge state — index populated, MERGE_HEAD set, conflict markers
---inserted where needed — and then we open Neogit (or fugitive) for the
---per-hunk staging / commit / abort flow.
---
---This deletes ~660 lines of bespoke review buffer. We were reinventing
---staging UIs that those plugins have already polished for years, badly:
---missing rename detection, no real conflict-marker workflow, no integration
---with diffview / merge tools, no familiar keymaps. Use the right tool.
---
---Aborting: `:Git merge --abort` (fugitive) or the Neogit equivalent, or
---`git merge --abort` from any shell. We don't wrap that either; it's one
---typed command and lives in the user's git vocabulary.

local Terminal = require("zxz.terminal")
local Worktree = require("zxz.worktree")

local M = {}

---@param wt zxz.Worktree
---@return boolean ok
---@return string? err
local function stage_branch(wt)
  local out = vim.fn.system({
    "git",
    "-C",
    wt.repo,
    "merge",
    "--no-ff",
    "--no-commit",
    wt.branch,
  })
  if vim.v.shell_error ~= 0 then
    -- Conflicts produce a non-zero exit but DO leave the index populated and
    -- MERGE_HEAD set; surface that as a soft notice so the user can resolve
    -- in their git UI normally.
    if out:match("CONFLICT") then
      vim.notify("zxz.review: merge has conflicts — resolve in your git UI", vim.log.levels.WARN)
      return true, nil
    end
    return false, out
  end
  return true, nil
end

local function open_git_ui()
  for _, cmd in ipairs({ "Neogit", "Git" }) do
    if vim.fn.exists(":" .. cmd) == 2 then
      vim.cmd(cmd)
      return true
    end
  end
  return false
end

---Pick a worktree to review. Picks the current terminal's worktree when one
---exists; otherwise prompts via `vim.ui.select` over all live agent worktrees
---(spawned by :ZxzStart or :ZxzChat). Calls `cb(wt)` with the choice, or
---nothing if the user cancelled / nothing to review.
---@param cb fun(wt: zxz.Worktree)
function M.pick(cb)
  local term = Terminal.current()
  if term then
    return cb(term.worktree)
  end
  local wts = Worktree.list()
  if #wts == 0 then
    vim.notify("zxz.review: no agent worktrees — :ZxzStart or :ZxzChat first", vim.log.levels.WARN)
    return
  end
  if #wts == 1 then
    return cb(wts[1])
  end
  vim.ui.select(wts, {
    prompt = "Review which agent worktree?",
    format_item = function(wt)
      return wt.branch .. "  -  " .. wt.path
    end,
  }, function(choice)
    if choice then
      cb(choice)
    end
  end)
end

---Stage the chosen agent worktree's branch into the user's main worktree and
---hand control to their git UI for review.
---@param opts? { worktree?: zxz.Worktree }
function M.open(opts)
  opts = opts or {}
  if opts.worktree then
    return M._open_for(opts.worktree)
  end
  M.pick(function(wt)
    M._open_for(wt)
  end)
end

---@param wt zxz.Worktree
function M._open_for(wt)
  local ok, err = stage_branch(wt)
  if not ok then
    vim.notify("zxz.review: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  if not open_git_ui() then
    vim.notify(
      "zxz.review: agent changes staged. Install Neogit or vim-fugitive "
        .. "to review, or run `git status` from the shell. Abort with "
        .. "`git merge --abort`.",
      vim.log.levels.INFO
    )
  end
end

---Convenience: kept so commands.lua (and any external callers) don't need
---to change.
function M.open_current()
  M.open()
end

return M
