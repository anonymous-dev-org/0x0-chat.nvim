local helpers = require("tests.helpers")
local Worktree = require("zxz.worktree")
local Review = require("zxz.review")

local function run(cmd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, "command failed: " .. vim.inspect(cmd) .. "\n" .. out)
end

describe("zxz.review.open", function()
  local repo, wt

  before_each(function()
    repo = helpers.make_repo({ ["a.txt"] = "one\n" })
    vim.fn.chdir(repo)
    wt = assert(Worktree.create({ cwd = repo }))
    helpers.write_file(wt.path .. "/a.txt", "one\ntwo\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "agent" })
  end)

  after_each(function()
    -- Reset any in-progress merge so the after-each Worktree.remove succeeds.
    pcall(vim.fn.system, { "git", "-C", repo, "merge", "--abort" })
    if wt then
      pcall(Worktree.remove, wt)
      wt = nil
    end
    helpers.cleanup(repo)
  end)

  it("stages the agent branch via git merge --no-ff --no-commit", function()
    Review.open({ worktree = wt })
    -- MERGE_HEAD set ⇒ a non-fast-forward merge is in progress with the
    -- agent branch's tip recorded as the incoming parent.
    local merge_head = vim.fn.system({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" })
    assert.equals(0, vim.v.shell_error, "MERGE_HEAD not set: " .. merge_head)
    -- Index now reflects the agent's a.txt content (two lines).
    local staged = vim.fn.system({ "git", "-C", repo, "show", ":a.txt" }):gsub("\n$", "")
    assert.equals("one\ntwo", staged)
  end)

  it("notifies when there is no active term AND no worktrees to review", function()
    -- Drop the before_each-created wt so Worktree.list() returns empty.
    pcall(Worktree.remove, wt)
    wt = nil
    local notifications = {}
    local orig = vim.notify
    vim.notify = function(msg, lvl)
      table.insert(notifications, { msg = msg, lvl = lvl })
    end
    Review.open() -- no explicit wt, no active term, no listable worktrees
    vim.notify = orig
    local saw = false
    for _, n in ipairs(notifications) do
      if n.msg:match("no agent worktrees") then
        saw = true
      end
    end
    assert.is_true(saw, vim.inspect(notifications))
  end)

  it("survives a merge with conflicts (soft warning, leaves index populated)", function()
    -- Make the user's main worktree diverge on the same line the agent touched.
    helpers.write_file(repo .. "/a.txt", "ONE\n")
    run({ "git", "-C", repo, "commit", "-am", "user edit" })

    local notifications = {}
    local orig = vim.notify
    vim.notify = function(msg, lvl)
      table.insert(notifications, { msg = msg, lvl = lvl })
    end
    Review.open({ worktree = wt })
    vim.notify = orig

    local saw_conflict_notice = false
    for _, n in ipairs(notifications) do
      if n.msg:match("conflicts") then
        saw_conflict_notice = true
      end
    end
    assert.is_true(saw_conflict_notice, vim.inspect(notifications))
    -- MERGE_HEAD still set; user can resolve in their git UI.
    vim.fn.system({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" })
    assert.equals(0, vim.v.shell_error)
  end)
end)
