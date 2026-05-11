local helpers = require("tests.helpers")
local Checkpoint = require("zxz.core.checkpoint")
local EditEvents = require("zxz.core.edit_events")
local InlineDiff = require("zxz.edit.inline_diff")
local Ledger = require("zxz.edit.ledger")

describe("edit ledger", function()
  local root

  after_each(function()
    helpers.cleanup(root)
    root = nil
  end)

  it("accept_file moves the checkpoint baseline to the worktree file", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "alpha\nbeta\n")

    assert.is_true((Ledger.accept_file(cp, "a.txt")))
    assert.are.same({}, Checkpoint.changed_files(cp))

    assert.is_true((Checkpoint.restore_all(cp)))
    assert.are.equal("alpha\nbeta\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("accept_hunk preserves the accepted hunk when later rejecting unresolved changes", function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["a.txt"] = table.concat({
        "old-one",
        "gap-01",
        "gap-02",
        "gap-03",
        "gap-04",
        "gap-05",
        "gap-06",
        "gap-07",
        "gap-08",
        "old-two",
        "",
      }, "\n"),
    }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(
      root .. "/a.txt",
      table.concat({
        "new-one",
        "gap-01",
        "gap-02",
        "gap-03",
        "gap-04",
        "gap-05",
        "gap-06",
        "gap-07",
        "gap-08",
        "new-two",
        "",
      }, "\n")
    )

    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "a.txt" }, 0))["a.txt"])
    assert.are.equal(2, #file.hunks)
    assert.is_true((Ledger.accept_hunk(cp, "a.txt", file.hunks[1])))

    assert.is_true((Checkpoint.restore_all(cp)))
    assert.are.equal(
      table.concat({
        "new-one",
        "gap-01",
        "gap-02",
        "gap-03",
        "gap-04",
        "gap-05",
        "gap-06",
        "gap-07",
        "gap-08",
        "old-two",
        "",
      }, "\n"),
      helpers.read_file(root .. "/a.txt")
    )
  end)

  it("reject_hunk restores only that hunk and keeps unrelated worktree edits", function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["a.txt"] = table.concat({
        "old-one",
        "gap-01",
        "gap-02",
        "gap-03",
        "gap-04",
        "gap-05",
        "gap-06",
        "gap-07",
        "gap-08",
        "stable-tail",
        "",
      }, "\n"),
    }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(
      root .. "/a.txt",
      table.concat({
        "new-one",
        "gap-01",
        "gap-02",
        "gap-03",
        "gap-04",
        "gap-05",
        "gap-06",
        "gap-07",
        "gap-08",
        "user-tail",
        "",
      }, "\n")
    )

    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "a.txt" }, 0))["a.txt"])
    assert.are.equal(2, #file.hunks)
    assert.is_true((Ledger.reject_hunk(cp, "a.txt", file.hunks[1])))

    assert.are.equal(
      table.concat({
        "old-one",
        "gap-01",
        "gap-02",
        "gap-03",
        "gap-04",
        "gap-05",
        "gap-06",
        "gap-07",
        "gap-08",
        "user-tail",
        "",
      }, "\n"),
      helpers.read_file(root .. "/a.txt")
    )
  end)

  it("undo_last_reject restores the worktree state from before the reject", function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["a.txt"] = "old\n",
    }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "new\n")

    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "a.txt" }, 0))["a.txt"])
    assert.is_true((Ledger.reject_hunk(cp, "a.txt", file.hunks[1])))
    assert.are.equal("old\n", helpers.read_file(root .. "/a.txt"))

    assert.is_true((Ledger.undo_last_reject()))
    assert.are.equal("new\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("accept_hunk preserves an added file when later rejecting unresolved changes", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["base.txt"] = "base\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/new.txt", "hello\n")

    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "new.txt" }, 0))["new.txt"])
    assert.is_true((Ledger.accept_hunk(cp, "new.txt", file.hunks[1])))

    assert.are.same({}, Checkpoint.changed_files(cp))
    assert.is_true((Checkpoint.restore_all(cp)))
    assert.are.equal("hello\n", helpers.read_file(root .. "/new.txt"))
  end)

  it("accept_hunk preserves a deleted file when later rejecting unresolved changes", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["gone.txt"] = "bye\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    vim.fn.delete(root .. "/gone.txt")

    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "gone.txt" }, 0))["gone.txt"])
    assert.is_true((Ledger.accept_hunk(cp, "gone.txt", file.hunks[1])))

    assert.are.same({}, Checkpoint.changed_files(cp))
    assert.is_true((Checkpoint.restore_all(cp)))
    assert.is_nil(helpers.read_file(root .. "/gone.txt"))
  end)

  it("accept_hunk refuses a stale hunk", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "new\n")
    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "a.txt" }, 0))["a.txt"])
    assert.is_true((Checkpoint.replace_file(cp, "a.txt", "other-old\n")))

    local ok, err = Ledger.accept_hunk(cp, "a.txt", file.hunks[1])

    assert.is_false(ok)
    assert.is_truthy(err:find("stale", 1, true))
    assert.are.equal("new\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("reject_hunk refuses a stale hunk", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "new\n")
    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "a.txt" }, 0))["a.txt"])
    helpers.write_file(root .. "/a.txt", "other-new\n")

    local ok, err = Ledger.reject_hunk(cp, "a.txt", file.hunks[1])

    assert.is_false(ok)
    assert.is_truthy(err:find("stale", 1, true))
    assert.are.equal("other-new\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("reject_hunk refuses to overwrite a modified source buffer", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "new\n")
    local file = assert(InlineDiff.parse(Checkpoint.diff_text(cp, { "a.txt" }, 0))["a.txt"])
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.bo[bufnr].swapfile = false
    vim.api.nvim_buf_set_name(bufnr, root .. "/a.txt")
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved" })
    vim.bo[bufnr].modified = true

    local ok, err = Ledger.reject_hunk(cp, "a.txt", file.hunks[1])

    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.is_false(ok)
    assert.is_truthy(err:find("unsaved edits", 1, true))
    assert.are.equal("new\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("accept_hunk marks the event hunk accepted after projection", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-1",
      before_content = "old\n",
      after_content = "new\n",
    }))
    EditEvents.record(event)
    helpers.write_file(root .. "/a.txt", "new\n")
    local hunk = assert(EditEvents.pending_chunks(cp.turn_id)[1].parsed.hunks[1])

    assert.is_true((Ledger.accept_hunk(cp, "a.txt", hunk)))

    assert.are.equal("accepted", event.status)
    assert.are.equal("accepted", event.hunks[1].status)
    assert.are.equal(0, #EditEvents.pending_chunks(cp.turn_id))
  end)
end)
