local helpers = require("tests.helpers")
local Checkpoint = require("zxz.core.checkpoint")

describe("checkpoint", function()
  local root

  before_each(function()
    -- macOS canonicalizes /var -> /private/var; git returns the resolved path.
    -- Use fs_realpath so equality checks work regardless of platform symlinks.
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["README.md"] = "hello\n",
      ["src/a.lua"] = "return 1\n",
      [".gitignore"] = "ignored/\n*.log\n",
    }))
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  it("git_root resolves the repo top", function()
    assert.are.equal(root, Checkpoint.git_root(root))
    assert.are.equal(root, Checkpoint.git_root(root .. "/src"))
  end)

  it("git_root returns nil outside a repo", function()
    local outside = vim.fn.tempname()
    vim.fn.mkdir(outside, "p")
    assert.is_nil(Checkpoint.git_root(outside))
    helpers.cleanup(outside)
  end)

  it("snapshot returns a checkpoint with a valid ref", function()
    local cp, err = Checkpoint.snapshot(root)
    assert.is_nil(err)
    assert.is_truthy(cp)
    assert.is_truthy(cp.ref)
    assert.is_truthy(cp.sha)
    assert.are.equal(root, cp.root)
    assert.is_true(Checkpoint.is_valid(cp))
  end)

  it("snapshot includes untracked files (excluding .gitignore)", function()
    helpers.write_file(root .. "/new.txt", "fresh\n")
    helpers.write_file(root .. "/ignored/skip.txt", "nope\n")
    helpers.write_file(root .. "/run.log", "nope\n")
    local cp = assert(Checkpoint.snapshot(root))
    local content, existed = Checkpoint.read_file(cp, "new.txt")
    assert.is_true(existed)
    assert.are.equal("fresh\n", content)
    local _, ignored = Checkpoint.read_file(cp, "run.log")
    assert.is_false(ignored)
  end)

  it("changed_files lists files modified since checkpoint", function()
    local cp = assert(Checkpoint.snapshot(root))
    -- Use a larger payload so git's stat-based shortcut (which can miss
    -- same-size, same-mtime overwrites at fast wall-clock resolution) does
    -- not skip re-hashing during test runs.
    helpers.write_file(root .. "/src/a.lua", "return 2\n-- modified\n")
    helpers.write_file(root .. "/src/b.lua", "return 'b'\n")
    local files = Checkpoint.changed_files(cp)
    table.sort(files)
    assert.are.same({ "src/a.lua", "src/b.lua" }, files)
  end)

  it("changed_files is empty when working tree matches checkpoint", function()
    local cp = assert(Checkpoint.snapshot(root))
    assert.are.same({}, Checkpoint.changed_files(cp))
  end)

  it("diff_text contains additions and deletions", function()
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/src/a.lua", "return 2\n-- changed\n")
    local diff = Checkpoint.diff_text(cp, { "src/a.lua" })
    assert.is_truthy(diff:find("%-return 1"))
    assert.is_truthy(diff:find("%+return 2"))
  end)

  it("restore_file rewinds a modified file", function()
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/src/a.lua", "return 999\n")
    local ok = Checkpoint.restore_file(cp, "src/a.lua")
    assert.is_true(ok)
    assert.are.equal("return 1\n", helpers.read_file(root .. "/src/a.lua"))
  end)

  it("restore_file deletes files that did not exist in the checkpoint", function()
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/new.txt", "added\n")
    assert.is_truthy(helpers.read_file(root .. "/new.txt"))
    local ok = Checkpoint.restore_file(cp, "new.txt")
    assert.is_true(ok)
    assert.is_nil(helpers.read_file(root .. "/new.txt"))
  end)

  it("restore_all rewinds every changed file", function()
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/src/a.lua", "return 2\n")
    helpers.write_file(root .. "/added.txt", "x\n")
    local ok = Checkpoint.restore_all(cp)
    assert.is_true(ok)
    assert.are.equal("return 1\n", helpers.read_file(root .. "/src/a.lua"))
    assert.is_nil(helpers.read_file(root .. "/added.txt"))
  end)

  it("is_ignored honours .gitignore", function()
    assert.is_true(Checkpoint.is_ignored(root, root .. "/run.log"))
    assert.is_true(Checkpoint.is_ignored(root, root .. "/ignored/anything.txt"))
    assert.is_false(Checkpoint.is_ignored(root, root .. "/src/a.lua"))
  end)

  it("delete_ref makes the checkpoint invalid", function()
    local cp = assert(Checkpoint.snapshot(root))
    Checkpoint.delete_ref(cp)
    assert.is_false(Checkpoint.is_valid(cp))
  end)

  it("snapshot accepts a custom ref_suffix and parent_sha", function()
    local turn_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "after-tool-1\n")
    local tool_cp, err = Checkpoint.snapshot(root, {
      ref_suffix = turn_cp.turn_id .. "__tool_call_001",
      parent_sha = turn_cp.sha,
      label = "tool checkpoint",
    })
    assert.is_nil(err)
    assert.is_truthy(tool_cp)
    assert.is_truthy(tool_cp.ref:find("tool_call_001"))
    -- The tool checkpoint's commit chains onto the turn checkpoint.
    local parents = vim.fn.systemlist({ "git", "-C", root, "rev-list", "--parents", "-n", "1", tool_cp.sha })
    assert.is_truthy(parents[1]:find(turn_cp.sha, 1, true))
    -- The diff between turn and tool checkpoint surfaces the tool edit.
    local diff = vim.fn.system({ "git", "-C", root, "diff", turn_cp.sha, tool_cp.sha, "--", "src/a.lua" })
    assert.are.equal("", diff) -- src/a.lua wasn't modified at this stage
    local diff2 = vim.fn.system({ "git", "-C", root, "diff", turn_cp.sha, tool_cp.sha, "--", "a.txt" })
    assert.is_truthy(diff2:find("after%-tool%-1"))
  end)

  it("gc keeps newest N refs", function()
    local refs = {}
    for i = 1, 5 do
      helpers.write_file(root .. "/tick.txt", tostring(i))
      local cp = assert(Checkpoint.snapshot(root))
      table.insert(refs, cp.ref)
      vim.loop.sleep(1100)
    end
    Checkpoint.gc(root, 2)
    local remaining = vim.fn.systemlist({
      "git",
      "-C",
      root,
      "for-each-ref",
      "--format=%(refname)",
      "refs/0x0/checkpoints/",
    })
    assert.are.equal(2, #remaining)
  end)
end)
