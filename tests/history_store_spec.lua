local helpers = require("tests.helpers")

describe("history_store", function()
  local tmp

  before_each(function()
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.env.XDG_STATE_HOME = tmp
  end)

  after_each(function()
    helpers.cleanup(tmp)
    vim.env.XDG_STATE_HOME = nil
  end)

  it("persists structured context records with user messages", function()
    local HistoryStore = require("zxz.core.history_store")
    local paths = require("zxz.core.paths")
    local entry = {
      id = "context-records",
      title = "context records",
      status = "working",
      created_at = os.time(),
      settings = {
        provider = "codex",
        model = "gpt-test",
        mode = "write",
      },
      messages = {
        {
          type = "user",
          id = "1",
          text = "inspect @a.txt",
          context_records = {
            {
              raw = "@a.txt",
              type = "file",
              label = "@a.txt",
              source = "a.txt",
              resolved = true,
            },
          },
        },
      },
    }

    HistoryStore.save(entry)
    local loaded = HistoryStore.load("context-records")

    assert.is_truthy(loaded)
    assert.are.equal("@a.txt", loaded.messages[1].context_records[1].raw)
    assert.are.equal("file", loaded.messages[1].context_records[1].type)
    assert.is_true(loaded.messages[1].context_records[1].resolved)

    local entries = HistoryStore.list()
    assert.are.equal(1, #entries)
    assert.are.equal("context-records", entries[1].id)
    assert.are.equal("working", entries[1].status)
    assert.are.equal("codex", entries[1].provider)
    assert.are.equal("gpt-test", entries[1].model)
    assert.are.equal("write", entries[1].mode)
    assert.are.equal(1, entries[1].message_count)
    assert.are.equal(1, vim.fn.filereadable(paths.chat_db_path()))
  end)

  it("persists run records in the chat database", function()
    local RunsStore = require("zxz.core.runs_store")
    local run = {
      run_id = "run-1",
      thread_id = "chat-1",
      status = "completed",
      prompt_summary = "do work",
      root = tmp,
      started_at = os.time(),
      ended_at = os.time(),
      files_touched = { "a.txt" },
      tool_calls = {
        { tool_call_id = "tool-1", kind = "edit", status = "completed" },
      },
    }

    RunsStore.save(run)

    local loaded = RunsStore.load("run-1")
    assert.is_truthy(loaded)
    assert.are.equal("chat-1", loaded.thread_id)
    assert.are.equal("a.txt", loaded.files_touched[1])
    assert.are.equal(1, #RunsStore.list_for_thread("chat-1"))
  end)

  it("persists queue items, permission decisions, and tool calls", function()
    local ChatDB = require("zxz.core.chat_db")

    ChatDB.save_queue_item({
      id = "queue-1",
      chat_id = "chat-1",
      message_id = "msg-1",
      seq = 1,
      text = "queued work",
      context_records = {
        { type = "file", source = "a.txt" },
      },
      trim = { mode = "compact" },
      status = "queued",
    })

    local queue = ChatDB.list_queue_items("chat-1", "queued")
    assert.are.equal(1, #queue)
    assert.are.equal("queued work", queue[1].text)
    assert.are.equal("file", queue[1].context_records[1].type)
    assert.are.equal("compact", queue[1].trim.mode)

    ChatDB.save_permission({
      id = "perm-1",
      chat_id = "chat-1",
      run_id = "run-1",
      tool_call_id = "tool-1",
      status = "pending",
      request = { title = "Edit file" },
      options = { "allow", "deny" },
    })
    assert.are.equal(1, #ChatDB.list_permissions("chat-1", "pending"))

    ChatDB.resolve_permission("perm-1", "allow")
    local decided = ChatDB.list_permissions("chat-1", "decided")
    assert.are.equal(1, #decided)
    assert.are.equal("allow", decided[1].decision)
    assert.are.equal("Edit file", decided[1].request.title)

    ChatDB.save_tool_call({
      id = "tool-1",
      chat_id = "chat-1",
      run_id = "run-1",
      kind = "edit",
      title = "Edit a.txt",
      status = "running",
      raw_input = { path = "a.txt" },
      content = { "diff" },
      locations = { { path = "a.txt" } },
      started_at = 1,
    })
    ChatDB.save_tool_call({
      id = "tool-1",
      chat_id = "chat-1",
      run_id = "run-1",
      kind = "edit",
      title = "Edit a.txt",
      status = "completed",
      raw_input = { path = "a.txt" },
      content = { "diff" },
      locations = { { path = "a.txt" } },
      started_at = 1,
      ended_at = 2,
    })

    local tool_calls = ChatDB.list_tool_calls_for_run("run-1")
    assert.are.equal(1, #tool_calls)
    assert.are.equal("completed", tool_calls[1].status)
    assert.are.equal("a.txt", tool_calls[1].raw_input.path)
    assert.are.equal("a.txt", tool_calls[1].locations[1].path)
  end)
end)
