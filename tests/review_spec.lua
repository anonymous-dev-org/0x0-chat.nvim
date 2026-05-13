local helpers = require("tests.helpers")

describe("zxz review buffer", function()
  local root

  after_each(function()
    pcall(vim.cmd, "tabclose")
    pcall(function()
      require("zxz.core.edit_events")._reset()
    end)
    helpers.cleanup(root)
    root = nil
  end)

  local function cursor_to_line(pattern)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    for i, line in ipairs(lines) do
      if line:find(pattern, 1, true) then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    error("line not found: " .. pattern)
  end

  local function current_line()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    return vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  end

  local function two_hunk_content(first, second)
    return table.concat({
      first,
      "gap-01",
      "gap-02",
      "gap-03",
      "gap-04",
      "gap-05",
      "gap-06",
      "gap-07",
      "gap-08",
      second,
      "",
    }, "\n")
  end

  local function three_hunk_content(first, second, third)
    return table.concat({
      first,
      "gap-a-01",
      "gap-a-02",
      "gap-a-03",
      "gap-a-04",
      "gap-a-05",
      "gap-a-06",
      "gap-a-07",
      "gap-a-08",
      second,
      "gap-b-01",
      "gap-b-02",
      "gap-b-03",
      "gap-b-04",
      "gap-b-05",
      "gap-b-06",
      "gap-b-07",
      "gap-b-08",
      third,
      "",
    }, "\n")
  end

  it("opens active checkpoint changes in a zxz-review buffer", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "alpha\nbeta\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })

    assert.are.equal("zxz-review", vim.bo.filetype)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "# 0x0 Review"))
    assert.is_truthy(vim.tbl_contains(lines, "M a.txt (1 hunk)"))
    assert.is_truthy(vim.tbl_contains(lines, "[ ] hunk 1/1 @@ -1 +1,2 @@"))
  end)

  it("keeps the selected hunk stable when checkpoint review refreshes", function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["a.txt"] = three_hunk_content("old-one", "old-two", "old-three"),
    }))
    local Checkpoint = require("zxz.core.checkpoint")
    local Review = require("zxz.edit.review")
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", three_hunk_content("old-one", "old-two", "new-three"))

    Review.open_checkpoint(cp, { chat = {} })
    cursor_to_line("+new-three")
    helpers.write_file(root .. "/a.txt", three_hunk_content("new-one\nnew-extra", "old-two", "new-three"))
    Review.refresh_checkpoint(cp)

    assert.is_truthy((current_line() or ""):find("hunk 2/2", 1, true))
  end)

  it("refreshes an open review buffer from inline diff path refresh", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local InlineDiff = require("zxz.edit.inline_diff")
    local old_directory = vim.o.directory
    vim.o.directory = "/tmp//"
    local cp = assert(Checkpoint.snapshot(root))
    local abs = root .. "/a.txt"
    helpers.write_file(abs, "alpha\nbeta\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })
    local review_buf = vim.api.nvim_get_current_buf()
    assert.is_truthy(
      vim.tbl_contains(vim.api.nvim_buf_get_lines(review_buf, 0, -1, false), "[ ] hunk 1/1 @@ -1 +1,2 @@")
    )

    vim.cmd("vsplit " .. vim.fn.fnameescape(abs))
    helpers.write_file(abs, "alpha\nbeta\ngamma\n")
    InlineDiff.refresh_path(cp, abs)

    assert.is_truthy(
      vim.tbl_contains(vim.api.nvim_buf_get_lines(review_buf, 0, -1, false), "[ ] hunk 1/1 @@ -1 +1,3 @@")
    )
    vim.o.directory = old_directory
  end)

  it("rejects a file from an active checkpoint review", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "alpha\nbeta\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })
    cursor_to_line("M a.txt")
    assert.is_true(require("zxz.edit.verbs").reject_file())

    assert.are.equal("alpha\n", helpers.read_file(root .. "/a.txt"))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "No unresolved changes."))
    assert.is_false(vim.tbl_contains(lines, "[ ] M a.txt (1 hunk)"))
  end)

  it("rejects a file from a saved run review", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local start_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "alpha\nbeta\n")
    local end_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "user edit\n")

    require("zxz.edit.review").open_run({
      run_id = "run-review-test",
      root = root,
      start_sha = start_cp.sha,
      end_sha = end_cp.sha,
      files_touched = { "a.txt" },
    }, { chat = {} })
    cursor_to_line("M a.txt")
    assert.is_true(require("zxz.edit.verbs").reject_file())

    assert.are.equal("alpha\n", helpers.read_file(root .. "/a.txt"))
  end)

  it("accepts a hunk from an event-backed saved run review", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local start_cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = "saved-hunk-accept",
      tool_call_id = "tool-saved",
      before_content = "old\n",
      after_content = "new\n",
    }))
    helpers.write_file(root .. "/a.txt", "new\n")
    local end_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "old\n")

    require("zxz.edit.review").open_run({
      run_id = "saved-hunk-accept",
      root = root,
      start_sha = start_cp.sha,
      end_sha = end_cp.sha,
      files_touched = { "a.txt" },
      edit_events = { event },
    }, { chat = {} })
    cursor_to_line("tool-saved")
    assert.is_true(require("zxz.edit.verbs").accept_current())

    assert.are.equal("new\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal("accepted", event.status)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "No unresolved changes."))
  end)

  it("rejects one hunk from an event-backed saved run review", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = two_hunk_content("old-one", "old-two") }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local start_cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = "saved-hunk-reject",
      tool_call_id = "tool-saved",
      before_content = two_hunk_content("old-one", "old-two"),
      after_content = two_hunk_content("new-one", "new-two"),
    }))
    helpers.write_file(root .. "/a.txt", two_hunk_content("new-one", "new-two"))
    local end_cp = assert(Checkpoint.snapshot(root))

    require("zxz.edit.review").open_run({
      run_id = "saved-hunk-reject",
      root = root,
      start_sha = start_cp.sha,
      end_sha = end_cp.sha,
      files_touched = { "a.txt" },
      edit_events = { event },
    }, { chat = {} })
    cursor_to_line("[ ] hunk 2/2")
    assert.is_true(require("zxz.edit.verbs").reject_current())

    assert.are.equal(two_hunk_content("new-one", "old-two"), helpers.read_file(root .. "/a.txt"))
    assert.are.equal("pending", event.hunks[1].status)
    assert.are.equal("rejected", event.hunks[2].status)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_filter(function(line)
      return line:find("hunk 1/1", 1, true) and line:find("tool-saved", 1, true)
    end, lines)[1])
  end)

  it("refuses a stale saved-run hunk", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local start_cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = "saved-hunk-stale",
      tool_call_id = "tool-saved",
      before_content = "old\n",
      after_content = "new\n",
    }))
    helpers.write_file(root .. "/a.txt", "new\n")
    local end_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "user edit\n")

    require("zxz.edit.review").open_run({
      run_id = "saved-hunk-stale",
      root = root,
      start_sha = start_cp.sha,
      end_sha = end_cp.sha,
      files_touched = { "a.txt" },
      edit_events = { event },
    }, { chat = {} })
    cursor_to_line("tool-saved")
    assert.is_true(require("zxz.edit.verbs").accept_current())

    assert.are.equal("user edit\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal("pending", event.status)
  end)

  it("refuses saved-run hunk actions when the source buffer is modified", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local start_cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = "saved-hunk-dirty",
      tool_call_id = "tool-saved",
      before_content = "old\n",
      after_content = "new\n",
    }))
    helpers.write_file(root .. "/a.txt", "new\n")
    local end_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", "old\n")
    local source_buf = vim.api.nvim_create_buf(true, false)
    vim.bo[source_buf].swapfile = false
    vim.api.nvim_buf_set_name(source_buf, root .. "/a.txt")
    vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "unsaved" })
    vim.bo[source_buf].modified = true

    require("zxz.edit.review").open_run({
      run_id = "saved-hunk-dirty",
      root = root,
      start_sha = start_cp.sha,
      end_sha = end_cp.sha,
      files_touched = { "a.txt" },
      edit_events = { event },
    }, { chat = {} })
    cursor_to_line("tool-saved")
    assert.is_true(require("zxz.edit.verbs").accept_current())

    assert.are.equal("old\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal("pending", event.status)
    vim.bo[source_buf].modified = false
    pcall(vim.api.nvim_buf_delete, source_buf, { force = true })
  end)

  it("accepts only the hunk under cursor from an active checkpoint review", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = two_hunk_content("old-one", "old-two") }))
    local Checkpoint = require("zxz.core.checkpoint")
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", two_hunk_content("new-one", "new-two"))

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })
    cursor_to_line("[ ] hunk 1/2")
    assert.is_true(require("zxz.edit.verbs").accept_current())

    assert.are.equal(two_hunk_content("new-one", "new-two"), helpers.read_file(root .. "/a.txt"))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_false(vim.tbl_contains(lines, "-old-one"))
    assert.is_truthy(vim.tbl_contains(lines, "-old-two"))
    assert.is_truthy((current_line() or ""):find("[ ] hunk 1/1", 1, true))

    assert.is_true((Checkpoint.restore_all(cp)))
    assert.are.equal(two_hunk_content("new-one", "old-two"), helpers.read_file(root .. "/a.txt"))
  end)

  it("rejects only the hunk under cursor from an active checkpoint review", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = two_hunk_content("old-one", "old-two") }))
    local Checkpoint = require("zxz.core.checkpoint")
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", two_hunk_content("new-one", "new-two"))

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })
    cursor_to_line("[ ] hunk 2/2")
    assert.is_true(require("zxz.edit.verbs").reject_current())

    assert.are.equal(two_hunk_content("new-one", "old-two"), helpers.read_file(root .. "/a.txt"))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "M a.txt (1 hunk)"))
    assert.is_truthy(vim.tbl_contains(lines, "-old-one"))
    assert.is_false(vim.tbl_contains(lines, "-old-two"))
    assert.is_truthy((current_line() or ""):find("[ ] hunk 1/1", 1, true))
  end)

  it("opens the hunk source in a split while keeping the review buffer alive", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = two_hunk_content("old-one", "old-two") }))
    local Checkpoint = require("zxz.core.checkpoint")
    local cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", two_hunk_content("new-one", "new-two"))

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })
    local review_buf = vim.api.nvim_get_current_buf()
    cursor_to_line("[ ] hunk 2/2")
    assert.is_true(require("zxz.edit.review").current_action("open_file"))

    assert.are.equal(root .. "/a.txt", vim.api.nvim_buf_get_name(0))
    assert.are.equal(10, vim.api.nvim_win_get_cursor(0)[1])
    assert.is_true(vim.api.nvim_buf_is_valid(review_buf))
  end)

  it("renders pending event hunks and removes them after accept", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-review",
      before_content = "old\n",
      after_content = "new\n",
    }))
    EditEvents.record(event)
    helpers.write_file(root .. "/a.txt", "new\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "[ ] hunk 1/1 @@ -1 +1 @@ · tool-review"))
    cursor_to_line("tool-review")
    assert.is_true(require("zxz.edit.verbs").accept_current())

    lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "No unresolved changes."))
    assert.are.equal("accepted", event.hunks[1].status)
  end)

  it("renders non-event checkpoint files alongside pending event hunks", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n", ["b.txt"] = "before\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-review-mixed",
      before_content = "old\n",
      after_content = "new\n",
    }))
    EditEvents.record(event)
    helpers.write_file(root .. "/a.txt", "new\n")
    helpers.write_file(root .. "/b.txt", "after\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "[ ] hunk 1/1 @@ -1 +1 @@ · tool-review-mixed"))
    assert.is_truthy(vim.tbl_contains(lines, "M b.txt (1 hunk)"))
  end)

  it("renders independent same-file event hunks together", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = two_hunk_content("old-a", "old-b") }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local cp = assert(Checkpoint.snapshot(root))
    local before = two_hunk_content("old-a", "old-b")
    local after_first = two_hunk_content("new-a", "old-b")
    local after_second = two_hunk_content("new-a", "new-b")
    local first = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-first",
      before_content = before,
      after_content = after_first,
    }))
    local second = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-second",
      before_content = after_first,
      after_content = after_second,
    }))
    EditEvents.record(first)
    EditEvents.record(second)
    helpers.write_file(root .. "/a.txt", after_second)

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "M a.txt (2 hunks)"))
    assert.is_truthy(vim.tbl_contains(lines, "[ ] hunk 1/2 @@ -1,4 +1,4 @@ · tool-first"))
    assert.is_truthy(vim.tbl_contains(lines, "[ ] hunk 2/2 @@ -7,4 +7,4 @@ gap-05 · tool-second"))
    assert.is_false(vim.tbl_contains(lines, "M a.txt (file-level, blocked)"))

    cursor_to_line("tool-second")
    assert.is_true(require("zxz.edit.verbs").accept_current())
    assert.are.equal("pending", first.status)
    assert.are.equal("accepted", second.status)
    assert.is_truthy((current_line() or ""):find("tool-first", 1, true))
  end)

  it("blocks overlapping same-file events until earlier event hunks are resolved", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local cp = assert(Checkpoint.snapshot(root))
    local first = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-first",
      before_content = "old\n",
      after_content = "new\n",
    }))
    local second = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-second",
      before_content = "new\n",
      after_content = "newer\n",
    }))
    EditEvents.record(first)
    EditEvents.record(second)
    helpers.write_file(root .. "/a.txt", "newer\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "[ ] hunk 1/1 @@ -1 +1 @@ · tool-first"))
    assert.is_truthy(vim.tbl_contains(lines, "M a.txt (file-level, blocked)"))
    assert.is_truthy(vim.tbl_contains(lines, "[ ] M a.txt (file-level, overlapping event hunks · blocked)"))

    cursor_to_line("overlapping event hunks")
    assert.is_true(require("zxz.edit.verbs").accept_file())
    assert.are.equal("pending", second.status)
  end)

  it("renders guarded summary events as file-level only review items", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["large.txt"] = "old\n" }))
    local Checkpoint = require("zxz.core.checkpoint")
    local EditEvents = require("zxz.core.edit_events")
    local cp = assert(Checkpoint.snapshot(root))
    local event = assert(EditEvents.from_write({
      root = root,
      path = "large.txt",
      abs_path = root .. "/large.txt",
      run_id = cp.turn_id,
      tool_call_id = "tool-summary",
      before_content = "old\n",
      after_content = "new\n",
      limits = {
        max_content_bytes = 3,
        max_diff_bytes = 1024,
      },
    }))
    EditEvents.record(event)
    helpers.write_file(root .. "/large.txt", "new\n")

    require("zxz.edit.review").open_checkpoint(cp, { chat = {} })

    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "M large.txt (file-level)"))
    assert.is_truthy(vim.tbl_contains(lines, "[ ] M large.txt (file-level, content too large)"))

    cursor_to_line("content too large")
    assert.is_true(require("zxz.edit.verbs").accept_current())
    assert.are.equal("pending", event.status)
    assert.is_true(require("zxz.edit.verbs").accept_file())
    assert.are.equal("accepted", event.status)
  end)
end)
