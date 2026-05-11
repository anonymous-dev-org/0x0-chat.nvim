local EditEvents = require("zxz.core.edit_events")
local helpers = require("tests.helpers")

describe("edit_events", function()
  local root

  after_each(function()
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
end)
