local Checkpoint = require("zxz.core.checkpoint")
local EditEvents = require("zxz.core.edit_events")
local FsBridge = require("zxz.chat.fs_bridge")
local History = require("zxz.core.history")
local Reconcile = require("zxz.core.reconcile")
local helpers = require("tests.helpers")

describe("fs_bridge structured edit events", function()
  local root

  after_each(function()
    EditEvents._reset()
    helpers.cleanup(root)
    root = nil
  end)

  it("records successful writes as run and tool-call edit events", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    local history = History.new()
    history:add({
      type = "tool_call",
      tool_call_id = "tool-1",
      kind = "edit",
      title = "Edit",
      status = "in_progress",
    })
    local chat = {
      repo_root = root,
      checkpoint = cp,
      reconcile = Reconcile.new({ checkpoint = cp, mode = "strict" }),
      active_tool_call_id = "tool-1",
      current_run = {
        run_id = cp.turn_id,
        tool_calls = {
          { tool_call_id = "tool-1", status = "pending" },
        },
        files_touched = {},
        edit_events = {},
      },
      history = history,
      render_count = 0,
    }
    setmetatable(chat, { __index = FsBridge })
    function chat:_run_record_edit_event(event)
      EditEvents.append_to_run(self.current_run, event)
      EditEvents.record(event)
    end
    function chat:_run_record_conflict() end
    function chat:_render()
      self.render_count = self.render_count + 1
    end

    local called = false
    local err
    local events_at_response
    FsBridge._handle_fs_write(chat, { path = "a.txt", content = "new\n" }, function(response_err)
      called = true
      err = response_err
      events_at_response = #chat.current_run.edit_events
    end)

    assert.is_true(vim.wait(2000, function()
      return called
    end, 10))
    assert.is_nil(err)
    assert.are.equal("new\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal(0, events_at_response)
    assert.is_true(vim.wait(2000, function()
      return #chat.current_run.edit_events == 1
    end, 10))
    assert.are.equal(1, #chat.current_run.edit_events)
    local event = chat.current_run.edit_events[1]
    assert.are.equal(cp.turn_id, event.run_id)
    assert.are.equal("tool-1", event.tool_call_id)
    assert.are.equal("active", event.tool_call_id_source)
    assert.are.equal("a.txt", event.path)
    assert.are.same({ "a.txt" }, chat.current_run.files_touched)
    assert.are.equal(event.id, history.messages[1].edit_events[1].id)
    assert.is_true(chat.render_count > 0)
  end)

  it("does not attribute fallback writes to terminal active tool calls", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    local history = History.new()
    history:add({
      type = "tool_call",
      tool_call_id = "tool-done",
      kind = "edit",
      title = "Edit",
      status = "completed",
    })
    local chat = {
      repo_root = root,
      checkpoint = cp,
      reconcile = Reconcile.new({ checkpoint = cp, mode = "strict" }),
      active_tool_call_id = "tool-done",
      current_run = {
        run_id = cp.turn_id,
        tool_calls = {
          { tool_call_id = "tool-done", status = "completed" },
        },
        files_touched = {},
        edit_events = {},
      },
      history = history,
      render_count = 0,
    }
    setmetatable(chat, { __index = FsBridge })
    function chat:_run_record_conflict() end
    function chat:_render()
      self.render_count = self.render_count + 1
    end

    local called = false
    FsBridge._handle_fs_write(chat, { path = "a.txt", content = "new\n" }, function(response_err)
      called = true
      assert.is_nil(response_err)
    end)

    assert.is_true(vim.wait(2000, function()
      return called and #chat.current_run.edit_events == 1
    end, 10))
    local event = chat.current_run.edit_events[1]
    assert.is_nil(event.tool_call_id)
    assert.are.equal("unattributed", event.tool_call_id_source)
    assert.is_nil(history.messages[1].edit_events)
    assert.are.equal("activity", history.messages[2].type)
  end)

  it("uses explicit protocol tool ids over active fallback", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    local history = History.new()
    history:add({
      type = "tool_call",
      tool_call_id = "tool-protocol",
      kind = "edit",
      title = "Edit",
      status = "in_progress",
    })
    local chat = {
      repo_root = root,
      checkpoint = cp,
      reconcile = Reconcile.new({ checkpoint = cp, mode = "strict" }),
      active_tool_call_id = "tool-active",
      current_run = {
        run_id = cp.turn_id,
        tool_calls = {
          { tool_call_id = "tool-active", status = "pending" },
          { tool_call_id = "tool-protocol", status = "pending" },
        },
        files_touched = {},
        edit_events = {},
      },
      history = history,
      render_count = 0,
    }
    setmetatable(chat, { __index = FsBridge })
    function chat:_run_record_conflict() end
    function chat:_render()
      self.render_count = self.render_count + 1
    end

    local called = false
    FsBridge._handle_fs_write(chat, {
      path = "a.txt",
      content = "new\n",
      toolCall = { toolCallId = "tool-protocol" },
    }, function(response_err)
      called = true
      assert.is_nil(response_err)
    end)

    assert.is_true(vim.wait(2000, function()
      return called and #chat.current_run.edit_events == 1
    end, 10))
    local event = chat.current_run.edit_events[1]
    assert.are.equal("tool-protocol", event.tool_call_id)
    assert.are.equal("protocol:toolCall.toolCallId", event.tool_call_id_source)
    assert.are.equal(event.id, history.messages[1].edit_events[1].id)
  end)

  it("does not guess attribution when multiple active tools are live", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    local history = History.new()
    local chat = {
      repo_root = root,
      checkpoint = cp,
      reconcile = Reconcile.new({ checkpoint = cp, mode = "strict" }),
      active_tool_call_id = "tool-active",
      current_run = {
        run_id = cp.turn_id,
        tool_calls = {
          { tool_call_id = "tool-active", status = "pending" },
          { tool_call_id = "tool-other", status = "in_progress" },
        },
        files_touched = {},
        edit_events = {},
      },
      history = history,
      render_count = 0,
    }
    setmetatable(chat, { __index = FsBridge })
    function chat:_run_record_conflict() end
    function chat:_render()
      self.render_count = self.render_count + 1
    end

    local called = false
    FsBridge._handle_fs_write(chat, { path = "a.txt", content = "new\n" }, function(response_err)
      called = true
      assert.is_nil(response_err)
    end)

    assert.is_true(vim.wait(2000, function()
      return called and #chat.current_run.edit_events == 1
    end, 10))
    local event = chat.current_run.edit_events[1]
    assert.is_nil(event.tool_call_id)
    assert.are.equal("ambiguous_active", event.tool_call_id_source)
    assert.are.equal("activity", history.messages[1].type)
  end)

  it("surfaces dropped edit-event diagnostics without failing the write", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "old\n" }))
    local cp = assert(Checkpoint.snapshot(root))
    local history = History.new()
    local chat = {
      repo_root = root,
      checkpoint = cp,
      reconcile = Reconcile.new({ checkpoint = cp, mode = "strict" }),
      active_tool_call_id = "tool-1",
      current_run = {
        run_id = cp.turn_id,
        tool_calls = {
          { tool_call_id = "tool-1", status = "pending" },
        },
        files_touched = {},
        edit_events = {},
      },
      history = history,
      render_count = 0,
    }
    setmetatable(chat, { __index = FsBridge })
    function chat:_run_record_conflict() end
    function chat:_render()
      self.render_count = self.render_count + 1
    end

    local from_write = EditEvents.from_write
    EditEvents.from_write = function()
      error("synthetic edit-event failure")
    end

    local called = false
    local err
    FsBridge._handle_fs_write(chat, { path = "a.txt", content = "new\n" }, function(response_err)
      called = true
      err = response_err
    end)

    assert.is_true(vim.wait(2000, function()
      return called and #(chat.current_run.edit_event_diagnostics or {}) == 1
    end, 10))
    EditEvents.from_write = from_write

    assert.is_nil(err)
    assert.are.equal("new\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal(0, #chat.current_run.edit_events)
    local diagnostic = chat.current_run.edit_event_diagnostics[1]
    assert.are.equal("a.txt", diagnostic.path)
    assert.are.equal("edit_event_record_failed", diagnostic.reason)
    assert.is_truthy(diagnostic.message:find("synthetic edit%-event failure"))
    assert.are.equal("activity", history.messages[1].type)
    assert.are.equal("failed", history.messages[1].status)
  end)
end)
