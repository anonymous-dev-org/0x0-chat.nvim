local helpers = require("tests.helpers")
local Reconcile = require("zxz.core.reconcile")
local Checkpoint = require("zxz.core.checkpoint")

describe("reconcile", function()
  local root, cp

  before_each(function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["a.txt"] = "alpha\n",
      ["b.txt"] = "beta\n",
    }))
    cp = assert(Checkpoint.snapshot(root))
  end)

  after_each(function()
    helpers.cleanup(root)
  end)

  it("read_for_agent returns disk content and records the read", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    local content, err = rec:read_for_agent(root .. "/a.txt")
    assert.is_nil(err)
    assert.are.equal("alpha\n", content)
    assert.are.equal("alpha\n", rec.agent_view[root .. "/a.txt"])
  end)

  it("read_for_agent returns an error for missing files", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    local content, err = rec:read_for_agent(root .. "/nope.txt")
    assert.is_nil(content)
    assert.is_string(err)
  end)

  it("read_for_agent slices by line/limit", function()
    helpers.write_file(root .. "/multi.txt", "one\ntwo\nthree\nfour\n")
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    local content = assert(rec:read_for_agent(root .. "/multi.txt", 2, 2))
    assert.are.equal("two\nthree", content)
  end)

  it("write_for_agent allows a write when no prior view exists for a new file", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    local ok, err = rec:write_for_agent(root .. "/new.txt", "fresh\n")
    assert.is_true(ok)
    assert.is_nil(err)
    assert.are.equal("fresh\n", helpers.read_file(root .. "/new.txt"))
  end)

  it("write_for_agent allows write when expected matches checkpoint baseline", function()
    -- Agent has not read a.txt; expected_for falls back to the checkpoint blob.
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    local ok = rec:write_for_agent(root .. "/a.txt", "alpha-v2\n")
    assert.is_true(ok)
    assert.are.equal("alpha-v2\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("write_for_agent rejects in strict mode when disk diverges from agent view", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    rec:read_for_agent(root .. "/a.txt") -- agent view = "alpha\n"
    helpers.write_file(root .. "/a.txt", "user-edit\n") -- user edits behind agent's back
    local ok, err = rec:write_for_agent(root .. "/a.txt", "agent-edit\n")
    assert.is_false(ok)
    assert.is_string(err)
    assert.is_truthy(err:find("user has edited"))
    assert.are.equal("user-edit\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("write_for_agent in force mode bypasses the conflict check", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "force" })
    rec:read_for_agent(root .. "/a.txt")
    helpers.write_file(root .. "/a.txt", "user-edit\n")
    local ok = rec:write_for_agent(root .. "/a.txt", "agent-edit\n")
    assert.is_true(ok)
    assert.are.equal("agent-edit\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("write_for_agent records the new content so subsequent writes don't conflict", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    rec:read_for_agent(root .. "/a.txt")
    assert.is_true(rec:write_for_agent(root .. "/a.txt", "v2\n"))
    -- Second write from agent against its own prior write must succeed.
    assert.is_true(rec:write_for_agent(root .. "/a.txt", "v3\n"))
    assert.are.equal("v3\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("set_checkpoint clears the agent view (turn boundary)", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    rec:read_for_agent(root .. "/a.txt")
    assert.is_truthy(rec.agent_view[root .. "/a.txt"])
    rec:set_checkpoint(cp)
    assert.is_nil(rec.agent_view[root .. "/a.txt"])
  end)

  it("set_mode normalizes invalid modes to strict", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "force" })
    rec:set_mode("nonsense")
    assert.are.equal("strict", rec.mode)
  end)

  it("write_for_agent creates intermediate directories", function()
    local rec = Reconcile.new({ checkpoint = cp, mode = "strict" })
    local target = root .. "/deep/nested/path/file.txt"
    local ok = rec:write_for_agent(target, "x\n")
    assert.is_true(ok)
    assert.are.equal("x\n", helpers.read_file(target))
  end)
end)
