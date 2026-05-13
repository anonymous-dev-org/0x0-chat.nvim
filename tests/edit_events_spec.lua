local EditEvents = require("zxz.core.edit_events")
local helpers = require("tests.helpers")

describe("edit_events", function()
  local root

  local function spaced_content(first, second)
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

  after_each(function()
    EditEvents._reset()
    helpers.cleanup(root)
    root = nil
  end)

  it("creates a structured event from a host-mediated write", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local before = helpers.read_file(root .. "/a.txt")

    local event = assert(EditEvents.from_write({
      root = root,
      path = "a.txt",
      abs_path = root .. "/a.txt",
      run_id = "run-1",
      tool_call_id = "tool-1",
      before_content = before,
      after_content = "new\n",
    }))

    assert.are.equal("run-1", event.run_id)
    assert.are.equal("tool-1", event.tool_call_id)
    assert.are.equal("a.txt", event.path)
    assert.are.equal("modify", event.change_type)
    assert.are.equal("pending", event.status)
    assert.is_truthy(event.before_sha)
    assert.is_truthy(event.after_sha)
    assert.are.equal(1, event.additions)
    assert.are.equal(1, event.deletions)
    assert.is_truthy(event.diff:find("diff --git a/a.txt b/a.txt", 1, true))
    assert.are.equal(1, #event.hunks)
    assert.are.equal("pending", event.hunks[1].status)
    assert.is_truthy(event.hunks[1].id:find(event.id, 1, true))
  end)

  it("records events and annotates parsed review chunks", function()
    local event = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-annotate",
      tool_call_id = "tool-annotate",
      before_content = "old\n",
      after_content = "new\n",
    }))
    EditEvents.record(event)

    local chunks = {
      {
        path = "a.txt",
        parsed = {
          hunks = {
            {},
          },
        },
      },
    }
    EditEvents.annotate_chunks(chunks, "run-annotate")

    local hunk = chunks[1].parsed.hunks[1]
    assert.are.equal(event.id, hunk.event_id)
    assert.are.equal("tool-annotate", hunk.tool_call_id)
    assert.is_truthy(hunk.hunk_id)
  end)

  it("tracks pending hunk status for review projections", function()
    local event = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-status",
      tool_call_id = "tool-status",
      before_content = "old\n",
      after_content = "new\n",
    }))
    EditEvents.record(event)

    local chunks = EditEvents.pending_chunks("run-status")
    assert.are.equal(1, #chunks)
    assert.are.equal(1, #chunks[1].parsed.hunks)

    assert.is_true(EditEvents.set_hunk_status("run-status", event.id, event.hunks[1].id, "accepted"))

    assert.are.equal("accepted", event.status)
    assert.are.equal("accepted", event.hunks[1].status)
    assert.are.equal(0, #EditEvents.pending_chunks("run-status"))
  end)

  it("stores guarded writes as summary-only pending file events", function()
    local event = assert(EditEvents.from_write({
      root = nil,
      path = "big.txt",
      abs_path = "/tmp/big.txt",
      run_id = "run-summary",
      tool_call_id = "tool-summary",
      before_content = "old\n",
      after_content = "new\n",
      limits = {
        max_content_bytes = 3,
        max_diff_bytes = 1024,
      },
    }))
    EditEvents.record(event)

    assert.is_true(event.summary_only)
    assert.are.equal("content_too_large", event.summary_reason)
    assert.are.equal(0, #event.hunks)

    local chunks = EditEvents.pending_chunks("run-summary")
    assert.are.equal(1, #chunks)
    assert.are.equal("big.txt", chunks[1].path)
    assert.are.equal(0, #chunks[1].parsed.hunks)
    assert.is_truthy(EditEvents.summary(event):find("summary only", 1, true))
  end)

  it("merges pending event chunks with fallback checkpoint chunks", function()
    local event = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-review-chunks",
      tool_call_id = "tool-review-chunks",
      before_content = "old\n",
      after_content = "new\n",
    }))
    EditEvents.record(event)

    local chunks = EditEvents.review_chunks("run-review-chunks", {
      {
        path = "b.txt",
        parsed = {
          type = "modify",
          hunks = { {} },
        },
      },
    })

    assert.are.equal(2, #chunks)
    assert.are.equal("a.txt", chunks[1].path)
    assert.are.equal("b.txt", chunks[2].path)
  end)

  it("merges independent same-file event chunks", function()
    local before = spaced_content("old-a", "old-b")
    local after_first = spaced_content("new-a", "old-b")
    local after_second = spaced_content("new-a", "new-b")
    local first = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-independent",
      tool_call_id = "tool-1",
      before_content = before,
      after_content = after_first,
    }))
    local second = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-independent",
      tool_call_id = "tool-2",
      before_content = after_first,
      after_content = after_second,
    }))
    EditEvents.record(first)
    EditEvents.record(second)

    local chunks = EditEvents.pending_chunks("run-independent")

    assert.are.equal(1, #chunks)
    assert.are.equal("a.txt", chunks[1].path)
    assert.are.equal(2, #chunks[1].parsed.hunks)
    assert.are.equal(first.id, chunks[1].parsed.hunks[1].event_id)
    assert.are.equal(second.id, chunks[1].parsed.hunks[2].event_id)
    assert.are.equal("tool-1", chunks[1].parsed.hunks[1].tool_call_id)
    assert.are.equal("tool-2", chunks[1].parsed.hunks[2].tool_call_id)
  end)

  it("keeps fallback changes visible beside merged same-file event chunks", function()
    local before = spaced_content("old-a", "old-b")
    local after_first = spaced_content("new-a", "old-b")
    local after_second = spaced_content("new-a", "new-b")
    local first = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-mixed-same-file",
      tool_call_id = "tool-1",
      before_content = before,
      after_content = after_first,
    }))
    local second = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-mixed-same-file",
      tool_call_id = "tool-2",
      before_content = after_first,
      after_content = after_second,
    }))
    EditEvents.record(first)
    EditEvents.record(second)

    local chunks = EditEvents.review_chunks("run-mixed-same-file", {
      {
        path = "a.txt",
        parsed = {
          type = "modify",
          hunks = { {}, {}, {} },
        },
      },
    })

    assert.are.equal(2, #chunks)
    assert.are.equal(2, #chunks[1].parsed.hunks)
    assert.is_true(chunks[2].parsed.summary_only)
    assert.are.equal("resolve_event_hunks_first", chunks[2].parsed.summary_reason)
    assert.are.equal(first.id, chunks[2].blocked_by_event_id)
  end)

  it("blocks overlapping same-file event chunks", function()
    local first = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-order",
      tool_call_id = "tool-1",
      before_content = "old\n",
      after_content = "new\n",
    }))
    local second = assert(EditEvents.from_write({
      root = nil,
      path = "a.txt",
      abs_path = "/tmp/a.txt",
      run_id = "run-order",
      tool_call_id = "tool-2",
      before_content = "new\n",
      after_content = "newer\n",
    }))
    EditEvents.record(first)
    EditEvents.record(second)

    local chunks = EditEvents.pending_chunks("run-order")

    assert.are.equal(2, #chunks)
    assert.are.equal(1, #chunks[1].parsed.hunks)
    assert.are.equal(0, #chunks[2].parsed.hunks)
    assert.are.equal(first.id, chunks[2].blocked_by_event_id)
    assert.are.equal("overlapping_event_hunks", chunks[2].parsed.summary_reason)
  end)

  it("prunes old in-memory runs by age", function()
    local now = os.time()
    local old = assert(EditEvents.from_write({
      root = nil,
      path = "old.txt",
      abs_path = "/tmp/old.txt",
      run_id = "run-old",
      before_content = "old\n",
      after_content = "new\n",
    }))
    old.timestamp = now - 100
    local recent = assert(EditEvents.from_write({
      root = nil,
      path = "recent.txt",
      abs_path = "/tmp/recent.txt",
      run_id = "run-recent",
      before_content = "old\n",
      after_content = "new\n",
    }))
    recent.timestamp = now
    EditEvents.record(old)
    EditEvents.record(recent)

    assert.are.equal(1, EditEvents.gc({ now = now, max_age_seconds = 50, max_retained_runs = 0 }))
    assert.are.equal(0, #EditEvents.for_run("run-old"))
    assert.are.equal(1, #EditEvents.for_run("run-recent"))
  end)

  it("prunes oldest in-memory runs by retained run cap", function()
    local now = os.time()
    for idx = 1, 3 do
      local event = assert(EditEvents.from_write({
        root = nil,
        path = ("file-%d.txt"):format(idx),
        abs_path = ("/tmp/file-%d.txt"):format(idx),
        run_id = ("run-%d"):format(idx),
        before_content = "old\n",
        after_content = "new\n",
      }))
      event.timestamp = now + idx
      EditEvents.record(event)
    end

    assert.are.equal(1, EditEvents.gc({ max_retained_runs = 2, max_age_seconds = 0 }))
    assert.are.equal(0, #EditEvents.for_run("run-1"))
    assert.are.equal(1, #EditEvents.for_run("run-2"))
    assert.are.equal(1, #EditEvents.for_run("run-3"))
  end)

  it("records dropped-event diagnostics as informational review chunks", function()
    local run = {
      run_id = "run-diagnostic",
    }
    local diagnostic = assert(EditEvents.record_diagnostic(run, {
      path = "a.txt",
      reason = "edit_event_record_failed",
      message = "boom",
      source = "test",
      timestamp = os.time(),
    }))

    assert.are.equal(diagnostic, run.edit_event_diagnostics[1])

    local chunks = EditEvents.review_chunks(run, {
      {
        path = "a.txt",
        parsed = {
          type = "modify",
          hunks = { {} },
        },
      },
    })

    assert.are.equal(2, #chunks)
    assert.are.equal("a.txt", chunks[1].path)
    assert.is_true(chunks[1].parsed.diagnostic)
    assert.are.equal("edit_event_record_failed", chunks[1].parsed.summary_reason)
    assert.are.equal("a.txt", chunks[2].path)
    assert.are.equal(1, #chunks[2].parsed.hunks)
  end)
end)
