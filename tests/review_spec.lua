local helpers = require("tests.helpers")

describe("zxz review buffer", function()
  local root

  after_each(function()
    pcall(vim.cmd, "tabclose")
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
end)
