local helpers = require("tests.helpers")
local Worktree = require("zxz.worktree")

local function run(cmd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, "command failed: " .. vim.inspect(cmd) .. "\n" .. out)
  return out
end

describe("zxz.worktree", function()
  local repo

  before_each(function()
    repo = helpers.make_repo({ ["README.md"] = "hello\n" })
  end)

  after_each(function()
    helpers.cleanup(repo)
  end)

  it("creates a worktree on a zxz/agent-* branch pinned to HEAD", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "test1" }))
    assert.equals("test1", wt.id)
    assert.equals("zxz/agent-test1", wt.branch)
    assert.equals(vim.fn.resolve(repo), wt.repo)
    assert.is_truthy(wt.path:match("/%.git/zxz/wt%-test1$"))
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 1)
    -- The README should exist inside the worktree
    assert.equals("hello\n", helpers.read_file(wt.path .. "/README.md"))
  end)

  it("lists only zxz/agent-* worktrees", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "alpha" }))
    local list = Worktree.list(repo)
    local ids = {}
    for _, w in ipairs(list) do
      ids[w.id] = w.path
    end
    assert.equals(wt.path, ids.alpha)
  end)

  it("removes a worktree and its branch", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "tmp" }))
    assert(Worktree.remove(wt))
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 0)
    local branches = run({ "git", "-C", repo, "branch", "--list", wt.branch })
    assert.equals("", vim.trim(branches))
  end)

  it("diff reports changes made on the agent branch", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "d1" }))
    helpers.write_file(wt.path .. "/new.txt", "agent wrote this\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "agent change" })
    local diff = assert(Worktree.diff(wt))
    assert.is_truthy(diff:match("new.txt"))
    assert.is_truthy(diff:match("agent wrote this"))
  end)

  it("apply_patch lands a hunk in the main worktree", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "ap1" }))
    helpers.write_file(wt.path .. "/README.md", "hello\nworld\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "add world" })
    local diff = Worktree.diff(wt)
    assert(Worktree.apply_patch(wt, diff, { cwd = repo }))
    assert.equals("hello\nworld\n", helpers.read_file(repo .. "/README.md"))
  end)

  it("apply_patch with reverse undoes the change", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "ap2" }))
    helpers.write_file(wt.path .. "/README.md", "hello\nworld\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "add world" })
    local diff = Worktree.diff(wt)
    assert(Worktree.apply_patch(wt, diff, { cwd = repo }))
    assert(Worktree.apply_patch(wt, diff, { cwd = repo, reverse = true }))
    assert.equals("hello\n", helpers.read_file(repo .. "/README.md"))
  end)

  it("checkout_file lands the whole file from agent branch", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "co1" }))
    helpers.write_file(wt.path .. "/README.md", "completely rewritten\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "rewrite" })
    assert(Worktree.checkout_file(wt, "README.md"))
    assert.equals("completely rewritten\n", helpers.read_file(repo .. "/README.md"))
  end)

  it("show_file returns the content on the agent branch", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "sf1" }))
    helpers.write_file(wt.path .. "/README.md", "branch content\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "x" })
    assert.equals("branch content\n", Worktree.show_file(wt, "README.md"))
  end)

  it("resolves repo_root from inside an agent worktree", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "rr1" }))
    local root = Worktree.repo_root(wt.path)
    assert.equals(vim.fn.resolve(repo), root)
  end)
end)
