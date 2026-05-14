-- Smoke-level coverage of the Chat orchestrator after the chat/* split.
-- Verifies the mixin wires up every method the public API expects so
-- regressions in the split surface immediately.

local helpers = require("tests.helpers")

describe("chat orchestrator", function()
  local M
  local repo
  local state_tmp

  local function current_chat()
    for i = 1, 10 do
      local name, value = debug.getupvalue(M.queue_state, i)
      if name == "for_current_tab" then
        return value()
      end
    end
  end

  before_each(function()
    repo = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    state_tmp = vim.fn.tempname()
    vim.fn.mkdir(state_tmp, "p")
    vim.env.XDG_STATE_HOME = state_tmp
    require("zxz.chat.runtime")._reset_for_tests()
    M = require("zxz.chat.chat")
  end)

  after_each(function()
    helpers.cleanup(repo)
    helpers.cleanup(state_tmp)
    vim.env.XDG_STATE_HOME = nil
  end)

  it("exposes the public M surface used by init.lua", function()
    for _, name in ipairs({
      "open",
      "close",
      "toggle",
      "add_selection",
      "history_picker",
      "chats_picker",
      "runs_picker",
      "new",
      "submit",
      "cancel",
      "changes",
      "review",
      "run_review",
      "run_accept",
      "run_reject",
      "add_current_file",
      "add_current_hunk",
      "accept_all",
      "discard_all",
      "stop",
      "current_settings",
      "set_provider",
      "set_model",
      "set_mode",
      "set_config_option",
      "discover_options",
      "option_items",
      "has_config_option",
      "add_context_token",
      "queue_state",
      "queue_update",
      "queue_remove",
      "queue_clear",
      "queue_send_next",
      "trim_open",
      "trim_clear",
    }) do
      assert.is_function(M[name], "M." .. name .. " missing")
    end
  end)

  it("current_settings runs without raising (mixin wired correctly)", function()
    local ok, err = pcall(M.current_settings)
    assert.is_true(ok, tostring(err))
  end)

  it("leaves mini.starter before opening chat pickers", function()
    assert.is_truthy(current_chat())
    local order = {}
    local original_select = vim.ui.select
    local original_starter = _G.MiniStarter
    local original_filetype = vim.bo.filetype

    vim.bo.filetype = "ministarter"
    _G.MiniStarter = {
      close = function()
        order[#order + 1] = "close"
      end,
    }
    vim.ui.select = function(_, _, on_choice)
      order[#order + 1] = "select"
      on_choice(nil)
    end

    local ok, err = pcall(M.chats_picker)

    vim.ui.select = original_select
    _G.MiniStarter = original_starter
    vim.bo.filetype = original_filetype

    assert.is_true(ok, tostring(err))
    assert.are.same({ "close", "select" }, order)
  end)

  it("summarizes the active run for compact work state", function()
    local chat = current_chat()
    assert.is_truthy(chat)
    chat.in_flight = true
    chat.active_tool_call_id = "tool-2"
    chat.current_run = {
      files_touched = { "a.txt" },
      tool_calls = {
        {
          tool_call_id = "tool-1",
          kind = "read",
          title = "open a.txt",
          status = "completed",
        },
        {
          tool_call_id = "tool-2",
          kind = "edit",
          title = "rewrite b.txt",
          status = "in_progress",
        },
      },
      edit_events = {
        {
          path = "a.txt",
          status = "partial",
          hunks = {
            { status = "accepted" },
            { status = "pending" },
          },
        },
        {
          path = "b.txt",
          status = "pending",
          summary_only = true,
          hunks = {},
        },
      },
      edit_event_diagnostics = { { reason = "edit_event_record_failed" } },
      conflicts = { { path = "c.txt" } },
    }

    local state = chat:_work_state()
    assert.are.equal("tool-2", state.running_tool.tool_call_id)
    assert.are.same({ "a.txt", "b.txt" }, state.files_touched)
    assert.are.equal(2, state.pending_review)
    assert.are.equal(1, state.conflicts)
    assert.are.equal(2, state.blocked)

    chat.active_tool_call_id = "tool-1"
    state = chat:_work_state()
    assert.are.equal("tool-2", state.running_tool.tool_call_id)

    chat.current_run = {
      files_touched = { "a.txt" },
      edit_events = {
        {
          path = "a.txt",
          status = "accepted",
          summary_only = true,
          hunks = { { status = "accepted" } },
        },
      },
    }
    state = chat:_work_state()
    assert.are.equal(0, state.pending_review)
    assert.are.equal(0, state.blocked)

    chat.in_flight = false
    chat.current_run = nil
    chat.active_tool_call_id = nil
  end)

  it("keeps a working chat alive when a new chat is opened", function()
    local chat = current_chat()
    assert.is_truthy(chat)
    chat.title = "working chat"
    chat.in_flight = true
    local old_id = chat.persist_id

    M.new()

    local next_chat = current_chat()
    assert.is_truthy(next_chat)
    assert.not_equal(old_id, next_chat.persist_id)
    assert.is_true(chat.in_flight)

    chat.in_flight = false
    next_chat.in_flight = false
  end)

  it("slash new opens a chat without stopping the old one or self-refreshing", function()
    local Events = require("zxz.core.events")
    local chat = current_chat()
    assert.is_truthy(chat)
    chat.in_flight = true
    local old_id = chat.persist_id

    chat:new_session()

    local next_chat = current_chat()
    assert.is_truthy(next_chat)
    assert.not_equal(old_id, next_chat.persist_id)
    assert.is_true(chat.in_flight)

    local refreshed = false
    function next_chat:refresh_from_store()
      refreshed = true
    end
    Events.emit("zxz_chat_updated", next_chat.persist_id)
    vim.wait(100, function()
      return true
    end)
    assert.is_false(refreshed)

    chat.in_flight = false
    next_chat.in_flight = false
  end)

  it("lists live chats by status and can switch without cancelling them", function()
    local chat = current_chat()
    assert.is_truthy(chat)
    chat.title = "needs approval"
    chat.in_flight = true
    chat.widget.permission_pending = "tool-1"
    local old_id = chat.persist_id

    M.new()
    local next_chat = current_chat()
    next_chat.title = "new chat"
    local new_id = next_chat.persist_id

    local captured
    local format_item
    local original_select = vim.ui.select
    vim.ui.select = function(items, opts, on_choice)
      captured = items
      format_item = opts.format_item
      for _, item in ipairs(items) do
        if item.id == old_id then
          on_choice(item)
          return
        end
      end
      on_choice(nil)
    end
    M.chats_picker()
    vim.ui.select = original_select

    assert.is_truthy(captured)
    local saw_old, saw_new
    for _, item in ipairs(captured) do
      if item.id == old_id then
        saw_old = item
      elseif item.id == new_id then
        saw_new = item
      end
    end
    assert.is_truthy(saw_old)
    assert.is_truthy(saw_new)
    assert.are.equal("request approval", saw_old.status_label)
    assert.are.equal("active", saw_old.group_label)
    assert.are.equal("needs input", saw_new.status_label)
    assert.are.equal("open", saw_new.group_label)
    assert.matches("active", format_item(saw_old), nil, true)
    assert.matches("request approval", format_item(saw_old), nil, true)
    assert.matches("open", format_item(saw_new), nil, true)
    assert.are.equal(old_id, current_chat().persist_id)
    assert.is_true(chat.in_flight)

    chat.widget.permission_pending = nil
    chat.in_flight = false
    next_chat.in_flight = false
  end)

  it("registers the run review commands", function()
    require("zxz").setup()
    local commands = vim.api.nvim_get_commands({})
    assert.is_truthy(commands.ZxzChatRuns)
    assert.is_truthy(commands.ZxzChatRunReview)
    assert.is_truthy(commands.ZxzChatRunAccept)
    assert.is_truthy(commands.ZxzChatRunReject)
    assert.is_truthy(commands.ZxzAgent)
    assert.is_truthy(commands.ZxzContext)
    assert.is_truthy(commands.ZxzProfile)
    assert.is_truthy(commands.ZxzQueue)
    assert.is_truthy(commands.ZxzReview)
    assert.is_truthy(commands.ZxzChats)
    assert.is_truthy(commands.ZxzTasks)
    assert.is_truthy(commands.ZxzRuns)
    assert.is_truthy(commands.ZxzSpawn)
    assert.is_truthy(commands.ZxzAccept)
    assert.is_truthy(commands.ZxzReject)
    assert.is_truthy(commands.ZxzAcceptFile)
    assert.is_truthy(commands.ZxzRejectFile)
    assert.is_truthy(commands.ZxzAcceptRun)
    assert.is_truthy(commands.ZxzRejectRun)
    assert.is_truthy(commands.ZxzContextTrim)
  end)

  it("submit on an empty input only warns, does not throw", function()
    M.toggle() -- open
    -- Empty input: submit should notify and return without error.
    local ok, err = pcall(M.submit)
    assert.is_true(ok, tostring(err))
    M.close()
  end)

  it("changes/review/accept_all/discard_all/diff are no-ops without an active checkpoint", function()
    for _, name in ipairs({
      "changes",
      "review",
      "accept_all",
      "discard_all",
      "diff",
    }) do
      local ok, err = pcall(M[name])
      assert.is_true(ok, name .. " threw: " .. tostring(err))
    end
  end)

  it("exposes diff in the public M surface", function()
    assert.is_function(M.diff)
  end)

  it("queue_update recomputes context records for the edited text", function()
    -- Build a Chat-like value with just the turn mixin's
    -- `_context_for_prompt` + history wiring, mirroring the queue-edit
    -- path. This avoids spinning up the full per-tab Chat singleton.
    local History = require("zxz.core.history")
    local Turn = require("zxz.chat.turn")

    vim.fn.writefile({ "alpha" }, repo .. "/a.txt")
    vim.fn.writefile({ "beta" }, repo .. "/b.txt")

    local chat = setmetatable({
      history = History.new(),
      queued_prompts = {},
      in_flight = true,
      repo_root = repo,
    }, { __index = Turn })
    function chat:_session_cwd()
      return self.repo_root
    end
    function chat:_update_queued_history_text(id, text, summary, records)
      self.history:set_user_context(id, summary, records)
      for i = #self.history.messages, 1, -1 do
        local msg = self.history.messages[i]
        if msg.type == "user" and msg.id == id then
          msg.text = text
          msg.status = "queued"
          return
        end
      end
    end

    local id = chat.history:add_user("use @a.txt", "queued", { "@a.txt" }, {
      { raw = "@a.txt", label = "@a.txt", type = "file", resolved = true },
    })

    local records, summary = chat:_context_for_prompt("use @b.txt", chat:_session_cwd())
    chat:_update_queued_history_text(id, "use @b.txt", summary, records)

    local user_msg
    for _, msg in ipairs(chat.history.messages) do
      if msg.type == "user" and msg.id == id then
        user_msg = msg
      end
    end
    assert.is_truthy(user_msg)
    assert.are.equal("use @b.txt", user_msg.text)
    assert.are.same({ "@b.txt" }, user_msg.context_summary)
    assert.are.equal(1, #user_msg.context_records)
    assert.are.equal("@b.txt", user_msg.context_records[1].label)
    assert.are.equal("file", user_msg.context_records[1].type)
  end)

  it("trim filter suppresses records and marks them on the user message", function()
    local History = require("zxz.core.history")
    local ReferenceMentions = require("zxz.context.reference_mentions")

    vim.fn.writefile({ "alpha" }, repo .. "/a.txt")
    vim.fn.writefile({ "beta" }, repo .. "/b.txt")

    local history = History.new()
    local records = ReferenceMentions.records("use @a.txt and @b.txt", repo)
    assert.are.equal(2, #records)

    local user_id =
      history:add_user("use @a.txt and @b.txt", "active", ReferenceMentions.summary_from_records(records), records)

    -- Mirror the trim filter from _submit_prompt.
    local trim = { ["@b.txt"] = true }
    local provider_records = {}
    for _, record in ipairs(records) do
      if trim[record.raw or ""] then
        record.trimmed = true
      else
        provider_records[#provider_records + 1] = record
      end
    end
    history:set_user_context(user_id, ReferenceMentions.summary_from_records(records), records)

    local blocks = ReferenceMentions.to_prompt_blocks_from_records("use @a.txt and @b.txt", provider_records, repo)

    -- The kept record produces a resource_link block; the trimmed one
    -- must not appear in any provider block.
    local saw_a, saw_b
    for _, block in ipairs(blocks) do
      if block.uri and block.uri:find("a.txt", 1, true) then
        saw_a = true
      end
      if block.uri and block.uri:find("b.txt", 1, true) then
        saw_b = true
      end
    end
    assert.is_true(saw_a)
    assert.is_falsy(saw_b)

    local user_msg = history.messages[1]
    assert.are.equal("@a.txt", user_msg.context_records[1].label)
    assert.is_falsy(user_msg.context_records[1].trimmed)
    assert.are.equal("@b.txt", user_msg.context_records[2].label)
    assert.is_true(user_msg.context_records[2].trimmed)
  end)

  it("active trimmed prompts render trimmed context before provider callback", function()
    local History = require("zxz.core.history")
    local Turn = require("zxz.chat.turn")

    vim.fn.writefile({ "beta" }, repo .. "/b.txt")

    local chat = setmetatable({
      history = History.new(),
      queued_prompts = {},
      pending_trim = { ["@b.txt"] = true },
      repo_root = repo,
      widget = {
        clear_input = function() end,
        render = function() end,
      },
    }, { __index = Turn })
    function chat:_session_cwd()
      return self.repo_root
    end
    function chat:_maybe_generate_title() end
    function chat:_set_turn_activity() end
    function chat:_ensure_session() end

    chat:submit_prompt("use @b.txt")

    local user_msg = chat.history.messages[1]
    assert.is_truthy(user_msg)
    assert.are.equal("active", user_msg.status)
    assert.are.equal("@b.txt", user_msg.context_records[1].label)
    assert.is_true(user_msg.context_records[1].trimmed)
    assert.are.same({}, chat.pending_trim)
  end)

  it("queued prompts keep their own trim state across edits", function()
    local ChatDB = require("zxz.core.chat_db")
    local HistoryStore = require("zxz.core.history_store")

    vim.fn.writefile({ "beta" }, repo .. "/b.txt")
    vim.fn.writefile({ "gamma" }, repo .. "/c.txt")

    local chat = current_chat()
    assert.is_truthy(chat)
    chat.repo_root = repo
    chat.in_flight = true
    chat.pending_trim = { ["@b.txt"] = true }
    chat:submit_prompt("use @a.txt and @b.txt")

    local state = chat:queue_state()
    assert.are.equal(1, state.count)
    assert.are.equal(1, state.items[1].trimmed)

    local user_msg = chat.history.messages[#chat.history.messages]
    assert.is_true(user_msg.context_records[2].trimmed)
    local saved = HistoryStore.load(chat.persist_id)
    assert.are.equal("use @a.txt and @b.txt", saved.messages[#saved.messages].text)
    assert.are.equal("queued", saved.messages[#saved.messages].status)

    local ok, err = chat:queue_update(1, "use @b.txt and @c.txt")
    assert.is_true(ok, tostring(err))
    state = chat:queue_state()
    assert.are.equal(1, state.items[1].trimmed)
    local queued_rows = ChatDB.list_queue_items(chat.persist_id, "queued")
    assert.are.equal(1, #queued_rows)
    assert.are.equal("use @b.txt and @c.txt", queued_rows[1].text)
    assert.is_true(queued_rows[1].context_records[1].trimmed)

    user_msg = chat.history.messages[#chat.history.messages]
    assert.are.equal("@b.txt", user_msg.context_records[1].label)
    assert.is_true(user_msg.context_records[1].trimmed)
    assert.are.equal("@c.txt", user_msg.context_records[2].label)
    assert.is_falsy(user_msg.context_records[2].trimmed)
    saved = HistoryStore.load(chat.persist_id)
    assert.are.equal("use @b.txt and @c.txt", saved.messages[#saved.messages].text)
    assert.are.equal("@b.txt", saved.messages[#saved.messages].context_records[1].label)
    assert.is_true(saved.messages[#saved.messages].context_records[1].trimmed)

    chat:queue_clear()
    assert.are.equal(0, #ChatDB.list_queue_items(chat.persist_id, "queued"))
    chat.in_flight = false
  end)

  it("manual queue send stores the follow-up as an active history message before queue rows emit", function()
    local HistoryStore = require("zxz.core.history_store")

    local chat = current_chat()
    assert.is_truthy(chat)
    chat.in_flight = true
    chat:submit_prompt("follow up")
    chat.in_flight = false

    local submitted
    function chat:_submit_prompt(text, id, _, opts)
      submitted = { text = text, id = id, opts = opts }
    end

    local ok, err = chat:queue_send_next()

    assert.is_true(ok, tostring(err))
    assert.are.equal("follow up", submitted.text)
    local saved = HistoryStore.load(chat.persist_id)
    assert.are.equal("follow up", saved.messages[#saved.messages].text)
    assert.are.equal("active", saved.messages[#saved.messages].status)
  end)

  it("does not let store update events clobber live tool-call history", function()
    local Events = require("zxz.core.events")

    local chat = current_chat()
    assert.is_truthy(chat)
    chat.history:add_user("do work")
    chat:_persist_now()
    chat.history:add({
      type = "tool_call",
      tool_call_id = "tool-1",
      kind = "edit",
      title = "Edit a.txt",
      status = "pending",
    })

    Events.emit("zxz_chat_updated", chat.persist_id)
    vim.wait(100, function()
      return true
    end)

    local tool_calls = vim.tbl_filter(function(msg)
      return msg.type == "tool_call"
    end, chat.history.messages)
    assert.are.equal(1, #tool_calls)
    assert.are.equal("tool-1", tool_calls[1].tool_call_id)
  end)

  it("restores missing tool-call rows from persisted run history", function()
    local HistoryStore = require("zxz.core.history_store")
    local RunsStore = require("zxz.core.runs_store")

    HistoryStore.save({
      id = "chat-with-run-tools",
      title = "run tools",
      created_at = os.time(),
      messages = {
        { type = "user", id = "1", text = "do work", status = "active" },
        { type = "agent", text = "done" },
        { type = "user", id = "2", text = "do work", status = "active" },
        { type = "agent", text = "done again" },
      },
      run_ids = { "run-with-tool" },
    })
    RunsStore.save({
      run_id = "run-with-tool",
      thread_id = "chat-with-run-tools",
      status = "completed",
      user_id = "1",
      prompt_summary = "do work",
      tool_calls = {
        {
          tool_call_id = "tool-1",
          kind = "edit",
          title = "Edit a.txt",
          status = "completed",
          raw_input = { path = "a.txt" },
          content = { { type = "text", text = "done" } },
          edit_event_ids = { "event-1" },
        },
      },
      edit_events = {
        {
          id = "event-1",
          tool_call_id = "tool-1",
          path = "a.txt",
          additions = 1,
          deletions = 0,
          hunks = {},
        },
      },
    })

    local chat = current_chat()
    chat:load_thread("chat-with-run-tools", { hidden = true })

    local tool_calls = vim.tbl_filter(function(msg)
      return msg.type == "tool_call"
    end, chat.history.messages)
    assert.are.equal(1, #tool_calls)
    assert.are.equal("tool-1", tool_calls[1].tool_call_id)
    assert.are.equal("Edit a.txt", tool_calls[1].title)
    assert.are.equal("a.txt", tool_calls[1].raw_input.path)
    assert.are.equal(1, #tool_calls[1].edit_events)
    assert.are.equal("user", chat.history.messages[1].type)
    assert.are.equal("1", chat.history.messages[1].id)
    assert.are.equal("tool_call", chat.history.messages[2].type)
    assert.are.equal("agent", chat.history.messages[3].type)
  end)

  it("auto-drained queued prompts preserve trimmed provider context", function()
    local ReferenceMentions = require("zxz.context.reference_mentions")
    local Turn = require("zxz.chat.turn")

    vim.fn.writefile({ "alpha" }, repo .. "/a.txt")
    vim.fn.writefile({ "beta" }, repo .. "/b.txt")

    local prompt = "use @a.txt and @b.txt"
    local records = ReferenceMentions.records(prompt, repo)
    local trim = { ["@b.txt"] = true }
    Turn._apply_context_trim(nil, records, trim)

    local submitted
    local chat = setmetatable({
      queued_prompts = {
        {
          id = "queued-1",
          text = prompt,
          context_records = records,
          trim = trim,
        },
      },
    }, { __index = Turn })
    function chat:_submit_prompt(text, id, retried, opts)
      submitted = {
        text = text,
        id = id,
        retried = retried,
        opts = opts,
      }
    end

    chat:_notify_or_continue()

    assert.is_truthy(submitted)
    assert.are.equal(prompt, submitted.text)
    assert.are.equal("queued-1", submitted.id)
    assert.is_nil(submitted.retried)
    assert.are.same(trim, submitted.opts.trim)
    assert.are.same(records, submitted.opts.context_records)

    local provider_records = Turn._apply_context_trim(nil, vim.deepcopy(records), submitted.opts.trim)
    local blocks = ReferenceMentions.to_prompt_blocks_from_records(submitted.text, provider_records, repo)
    local saw_a, saw_b
    for _, block in ipairs(blocks) do
      if block.uri and block.uri:find("a.txt", 1, true) then
        saw_a = true
      end
      if block.uri and block.uri:find("b.txt", 1, true) then
        saw_b = true
      end
    end
    assert.is_true(saw_a)
    assert.is_falsy(saw_b)
  end)

  it("persists permission and tool-call lifecycle rows while running", function()
    local ChatDB = require("zxz.core.chat_db")
    local History = require("zxz.core.history")
    local Permissions = require("zxz.chat.permissions")
    local Runs = require("zxz.chat.runs")

    local decision_cb
    local responded
    local chat = setmetatable({
      persist_id = "chat-lifecycle",
      current_run = {
        run_id = "run-lifecycle",
        thread_id = "chat-lifecycle",
        status = "running",
        started_at = os.time(),
        tool_calls = {},
      },
      history = History.new(),
      in_flight = true,
      permission_queue = {},
      widget = {
        render = function() end,
        bind_permission_keys = function(_, _, _, cb)
          decision_cb = cb
        end,
      },
    }, {
      __index = function(_, key)
        return Permissions[key] or Runs[key]
      end,
    })
    function chat:_set_turn_activity() end
    function chat:_schedule_persist() end

    chat:_present_permission({
      toolCall = {
        toolCallId = "tool-1",
        kind = "edit",
        title = "Edit a.txt",
        rawInput = { path = "a.txt" },
      },
      options = {
        { optionId = "allow-once", kind = "allow_once", name = "allow once" },
        { optionId = "reject-once", kind = "reject_once", name = "reject once" },
      },
    }, function(option_id)
      responded = option_id
    end)

    assert.are.equal(1, #ChatDB.list_permissions("chat-lifecycle", "pending"))
    decision_cb("allow-once", "allow once")
    assert.are.equal("allow-once", responded)
    local permissions = ChatDB.list_permissions("chat-lifecycle", "decided")
    assert.are.equal(1, #permissions)
    assert.are.equal("allow once", permissions[1].decision)

    chat:_run_append_tool_call("tool-1", {
      kind = "edit",
      title = "Edit a.txt",
      status = "pending",
      rawInput = { path = "a.txt" },
    })
    chat:_run_update_tool_call("tool-1", {
      status = "completed",
      content = { { type = "text", text = "done" } },
      locations = { { path = "a.txt" } },
    })

    local tool_calls = ChatDB.list_tool_calls_for_run("run-lifecycle")
    assert.are.equal(1, #tool_calls)
    assert.are.equal("completed", tool_calls[1].status)
    assert.are.equal("a.txt", tool_calls[1].raw_input.path)
    assert.are.equal("a.txt", tool_calls[1].locations[1].path)
  end)

  it("reset clears pending context trim", function()
    local Checkpoints = require("zxz.chat.checkpoints")

    local chat = setmetatable({
      pending_trim = { ["@a.txt"] = true },
      queued_prompts = { { id = "1", text = "queued" } },
      permission_queue = {},
      widget = {
        unbind_permission_keys = function() end,
      },
    }, { __index = Checkpoints })
    function chat:_set_activity() end
    function chat:_clear_checkpoint() end

    chat:_reset_session()

    assert.are.same({}, chat.pending_trim)
    assert.are.same({}, chat.queued_prompts)
  end)

  it("widget renders (trimmed) for suppressed context records", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("ctx", "active", nil, {
      { label = "@a.txt", type = "file", resolved = true },
      { label = "@b.txt", type = "file", resolved = true, trimmed = true },
    })
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "Context: @a.txt, @b.txt (trimmed)"))
    widget:close()
    vim.cmd("tabclose")
  end)
end)

describe("chat widget rendering", function()
  local function has_buf_map(bufnr, mode, lhs)
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      if map.lhs == lhs then
        return true
      end
    end
    return false
  end

  it("uses one Agent heading for a run across tool loops", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("do work")
    history:add_agent_chunk("agent", "first response")
    history:add({
      type = "tool_call",
      tool_call_id = "tool-1",
      kind = "edit",
      title = "change file",
      status = "completed",
    })
    history:add_agent_chunk("agent", "final response")
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local agent_headers = 0
    for _, line in ipairs(lines) do
      if line == "## Agent" then
        agent_headers = agent_headers + 1
      end
      assert.not_equal("## Assistant", line)
    end
    assert.are.equal(1, agent_headers)
    widget:close()
    vim.cmd("tabclose")
  end)

  it("renders explicit context provenance under user prompts", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("inspect @a.txt and @diagnostics", "active", { "@a.txt", "@diagnostics" })
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "Context: @a.txt, @diagnostics"))
    widget:close()
    vim.cmd("tabclose")
  end)

  it("renders structured context provenance and unresolved records", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("inspect context", "active", nil, {
      { label = "@a.txt", type = "file", resolved = true },
      {
        label = "@missing.txt",
        type = "unknown",
        resolved = false,
        error = "unresolved context mention",
      },
    })
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "Context: @a.txt, @missing.txt (unresolved)"))
    widget:close()
    vim.cmd("tabclose")
  end)

  it("toggles structured context details on user rows", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("inspect context", "active", nil, {
      {
        label = "@a.txt",
        type = "file",
        source = "a.txt",
        resolved = true,
        start_byte = 8,
        end_byte = 14,
      },
    })
    widget:render()
    vim.api.nvim_win_set_cursor(widget.transcript_win, { 1, 0 })
    assert.is_true(widget:toggle_context_detail_at_cursor())

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "  Context details"))
    local detail
    for _, line in ipairs(lines) do
      if line:find("@a.txt", 1, true) and line:find("type=file", 1, true) then
        detail = line
        break
      end
    end
    assert.is_truthy(detail)
    assert.is_truthy(detail:find("bytes=8-14", 1, true))

    widget:reset()
    assert.are.same({}, widget.context_detail_expanded)

    widget:close()
    vim.cmd("tabclose")
  end)

  it("opens file and range context detail rows with <CR>", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    local repo = vim.loop.fs_realpath(helpers.make_repo({}))
    local abs = repo .. "/a.txt"
    vim.fn.writefile({ "one", "two", "three" }, abs)
    local old_directory = vim.o.directory
    local old_updatecount = vim.o.updatecount
    vim.o.directory = "/tmp//"
    vim.o.updatecount = 0

    vim.cmd("tabnew")
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("inspect context", "active", nil, {
      {
        raw = "@a.txt",
        label = "@a.txt",
        type = "file",
        source = "a.txt",
        resolved = true,
        mention = {
          type = "file",
          path = "a.txt",
          absolute_path = abs,
        },
      },
      {
        raw = "@a.txt#L2-L3",
        label = "@a.txt#L2-L3",
        type = "range",
        source = "a.txt",
        resolved = true,
        mention = {
          type = "range",
          path = "a.txt",
          absolute_path = abs,
          start_line = 2,
          end_line = 3,
        },
      },
    })
    widget:render()
    vim.api.nvim_win_set_cursor(widget.transcript_win, { 1, 0 })
    assert.is_true(widget:toggle_context_detail_at_cursor())

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local range_row
    for i, line in ipairs(lines) do
      if line:sub(1, 4) == "  - " and line:find("@a.txt#L2%-L3") then
        range_row = i
        break
      end
    end
    assert.is_truthy(range_row)
    vim.api.nvim_set_current_win(widget.transcript_win)
    vim.api.nvim_win_set_cursor(widget.transcript_win, { range_row, 0 })

    assert.is_true(widget:jump_context_at_cursor())
    assert.are.equal(abs, vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])

    widget:close()
    vim.cmd("tabclose")
    vim.o.updatecount = old_updatecount
    vim.o.directory = old_directory
    helpers.cleanup(repo)
  end)

  it("keeps trimmed context detail rows inert", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    local repo = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    local abs = repo .. "/a.txt"
    local old_directory = vim.o.directory
    vim.o.directory = "/tmp//"

    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add_user("inspect context", "active", nil, {
      {
        raw = "@a.txt",
        label = "@a.txt",
        type = "file",
        source = "a.txt",
        resolved = true,
        trimmed = true,
        mention = {
          type = "file",
          path = "a.txt",
          absolute_path = abs,
        },
      },
    })
    widget:render()
    vim.api.nvim_win_set_cursor(widget.transcript_win, { 1, 0 })
    assert.is_true(widget:toggle_context_detail_at_cursor())

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local trimmed_row
    for i, line in ipairs(lines) do
      if line:sub(1, 4) == "  - " and line:find("trimmed", 1, true) then
        trimmed_row = i
        break
      end
    end
    assert.is_truthy(trimmed_row)
    vim.api.nvim_set_current_win(widget.transcript_win)
    vim.api.nvim_win_set_cursor(widget.transcript_win, { trimmed_row, 0 })

    assert.is_false(widget:jump_context_at_cursor())
    assert.are.equal(widget.transcript_buf, vim.api.nvim_get_current_buf())

    widget:close()
    vim.cmd("tabclose")
    vim.o.directory = old_directory
    helpers.cleanup(repo)
  end)

  it("opens tool edit hunk rows with <CR>", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    local repo = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "one\ntwo\nthree\n" }))
    local abs = repo .. "/a.txt"
    local old_directory = vim.o.directory
    local old_updatecount = vim.o.updatecount
    vim.o.directory = "/tmp//"
    vim.o.updatecount = 0

    vim.cmd("tabnew")
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add({
      type = "tool_call",
      tool_call_id = "tool-1",
      kind = "edit",
      title = "change file",
      status = "completed",
      edit_events = {
        {
          id = "event-1",
          root = repo,
          path = "a.txt",
          additions = 1,
          deletions = 1,
          hunks = {
            {
              id = "event-1#h1",
              header = "@@ -2,1 +2,1 @@",
              new_start = 2,
              new_count = 1,
              old_start = 2,
              old_count = 1,
            },
          },
        },
      },
    })
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local hunk_row
    for i, line in ipairs(lines) do
      if line:find("hunk 1/1", 1, true) then
        hunk_row = i
        break
      end
    end
    assert.is_truthy(hunk_row)
    vim.api.nvim_set_current_win(widget.transcript_win)
    vim.api.nvim_win_set_cursor(widget.transcript_win, { hunk_row, 0 })

    assert.is_true(widget:jump_tool_at_cursor())
    assert.are.equal(abs, vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])

    widget:close()
    vim.cmd("tabclose")
    vim.o.updatecount = old_updatecount
    vim.o.directory = old_directory
    helpers.cleanup(repo)
  end)

  it("does not treat review or nofile windows as source windows", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = "nofile"
    vim.bo[scratch].filetype = "zxz-review"
    vim.api.nvim_win_set_buf(0, scratch)

    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)
    widget:open()

    assert.is_nil(widget:_source_window())

    widget:close()
    vim.cmd("tabclose")
  end)

  it("routes tool hunk rows to inline ask and edit with the hunk range", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local InlineAsk = require("zxz.edit.inline_ask")
    local InlineEdit = require("zxz.edit.inline_edit")
    local history = History.new()
    local repo = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "one\ntwo\nthree\nfour\n" }))
    local abs = repo .. "/a.txt"
    local old_directory = vim.o.directory
    local old_updatecount = vim.o.updatecount
    local old_ask = InlineAsk.ask
    local old_edit = InlineEdit.start
    local asked
    local edited
    vim.o.directory = "/tmp//"
    vim.o.updatecount = 0
    InlineAsk.ask = function(opts)
      asked = opts
    end
    InlineEdit.start = function(opts)
      edited = opts
    end

    vim.cmd("tabnew")
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add({
      type = "tool_call",
      tool_call_id = "tool-1",
      kind = "edit",
      title = "change file",
      status = "completed",
      edit_events = {
        {
          id = "event-1",
          root = repo,
          path = "a.txt",
          diff = table.concat({
            "diff --git a/a.txt b/a.txt",
            "--- a/a.txt",
            "+++ b/a.txt",
            "@@ -2,1 +2,2 @@",
            "-two",
            "+two",
            "+two again",
            "",
          }, "\n"),
          additions = 2,
          deletions = 1,
          hunks = {
            {
              id = "event-1#h1",
              header = "@@ -2,1 +2,2 @@",
              new_start = 2,
              new_count = 2,
              old_start = 2,
              old_count = 1,
            },
          },
        },
      },
    })
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local hunk_row
    for i, line in ipairs(lines) do
      if line:find("hunk 1/1", 1, true) then
        hunk_row = i
        break
      end
    end
    assert.is_truthy(hunk_row)

    vim.api.nvim_set_current_win(widget.transcript_win)
    vim.api.nvim_win_set_cursor(widget.transcript_win, { hunk_row, 0 })
    assert.is_true(widget:ask_tool_hunk_at_cursor({ question = "why?" }))
    assert.are.equal(abs, vim.api.nvim_buf_get_name(0))
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    assert.are.equal("why?", asked.question)
    assert.are.equal(2, asked.range.start_line)
    assert.are.equal(3, asked.range.end_line)
    assert.is_truthy(asked.hunk_context)
    assert.are.same({ "two" }, asked.hunk_context.old_lines)
    assert.are.same({ "two", "two again" }, asked.hunk_context.new_lines)

    vim.api.nvim_set_current_win(widget.transcript_win)
    vim.api.nvim_win_set_cursor(widget.transcript_win, { hunk_row, 0 })
    assert.is_true(widget:edit_tool_hunk_at_cursor({ instruction = "tighten" }))
    assert.are.equal(abs, vim.api.nvim_buf_get_name(0))
    assert.are.equal("tighten", edited.instruction)
    assert.are.equal(2, edited.range.start_line)
    assert.are.equal(3, edited.range.end_line)
    assert.is_truthy(edited.hunk_context)
    assert.are.same({ "two" }, edited.hunk_context.old_lines)

    InlineAsk.ask = old_ask
    InlineEdit.start = old_edit
    widget:close()
    vim.cmd("tabclose")
    vim.o.updatecount = old_updatecount
    vim.o.directory = old_directory
    helpers.cleanup(repo)
  end)

  it("rerenders tool edit rows when a rendered tool gains edit events", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    history:add({
      type = "tool_call",
      tool_call_id = "tool-1",
      kind = "edit",
      title = "change file",
      status = "pending",
    })
    widget:render()
    history:append_tool_edit_event("tool-1", {
      id = "event-1",
      path = "a.txt",
      additions = 1,
      deletions = 0,
      hunks = {},
    })
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "  ✎ a.txt +1/-0"))

    history.messages[1].edit_events[1].additions = 2
    widget:render()

    lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.is_truthy(vim.tbl_contains(lines, "  ✎ a.txt +2/-0"))
    assert.is_false(vim.tbl_contains(lines, "  ✎ a.txt +1/-0"))

    widget:close()
    vim.cmd("tabclose")
  end)

  it("shows working state in the transcript footer", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    widget:set_activity("responding", "Working")

    local input_winbar = vim.wo[widget.input_win].winbar
    local transcript_winbar = vim.wo[widget.transcript_win].winbar
    assert.is_nil(input_winbar:find("Working", 1, true))
    assert.is_nil(transcript_winbar:find("Working", 1, true))

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.are.equal("⠋ Working", lines[#lines - 1])
    assert.are.equal("", lines[#lines])

    widget:close()
    vim.cmd("tabclose")
  end)

  it("shows compact agent work state in the transcript footer", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(
      vim.api.nvim_get_current_tabpage(),
      history,
      function() end,
      function() end,
      function()
        return {
          running_tool = {
            kind = "edit",
            title = "rewrite parser",
          },
          files_touched = { "a.txt", "nested/b.txt", "c.txt" },
          pending_review = 3,
          conflicts = 1,
          blocked = 2,
        }
      end
    )

    widget:open()
    widget._activity_width = function()
      return nil
    end
    widget:set_activity("waiting", "Working")

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local text = lines[#lines - 1]
    assert.is_truthy(text:find("tool: edit rewrite parser", 1, true))
    assert.is_truthy(text:find("files: a.txt, nested/b.txt +1", 1, true))
    assert.is_truthy(text:find("review: 3", 1, true))
    assert.is_truthy(text:find("conflicts: 1", 1, true))
    assert.is_truthy(text:find("blocked: 2", 1, true))

    widget:close()
    vim.cmd("tabclose")
  end)

  it("keeps compact agent work state within the transcript width", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(
      vim.api.nvim_get_current_tabpage(),
      history,
      function() end,
      function() end,
      function()
        return {
          running_tool = {
            kind = "edit",
            title = "rewrite a deeply nested parser and regenerate several related fixtures",
          },
          files_touched = {
            "lua/zxz/chat/widget.lua",
            "lua/zxz/chat/chat.lua",
            "tests/chat_spec.lua",
          },
          pending_review = 12,
        }
      end
    )

    widget:open()
    vim.api.nvim_win_set_width(widget.transcript_win, 42)
    widget:set_activity("waiting", "Working")

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    local text = lines[#lines - 1]
    assert.is_true(vim.fn.strdisplaywidth(text) <= vim.api.nvim_win_get_width(widget.transcript_win) - 2)
    assert.is_truthy(text:find("...", 1, true))

    widget:close()
    vim.cmd("tabclose")
  end)

  it("scrolls wrapped transcript history to the final visual row above the input", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    vim.api.nvim_win_set_width(widget.transcript_win, 24)
    history:add_agent_chunk("agent", string.rep("wrapped ", 24))
    widget:render()

    local last = vim.api.nvim_buf_line_count(widget.transcript_buf)
    local last_line = vim.api.nvim_buf_get_lines(widget.transcript_buf, last - 1, last, false)[1]
    assert.are.same({ last, math.max(#last_line - 1, 0) }, vim.api.nvim_win_get_cursor(widget.transcript_win))
    assert.is_true(vim.api.nvim_win_get_height(widget.transcript_win) > 0)

    widget:close()
    vim.cmd("tabclose")
  end)

  it("tails through the transient activity footer while chunks stream", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    widget:set_activity("waiting", "Working")
    history:add_agent_chunk("agent", string.rep("first ", 16))
    widget:render()
    history:add_agent_chunk("agent", string.rep("second ", 16))
    widget:render()

    local lines = vim.api.nvim_buf_get_lines(widget.transcript_buf, 0, -1, false)
    assert.are.equal("⠋ Working", lines[#lines - 1])
    assert.are.equal("", lines[#lines])
    assert.are.same({ #lines, 0 }, vim.api.nvim_win_get_cursor(widget.transcript_win))

    widget:close()
    vim.cmd("tabclose")
  end)

  it("keeps the input clean and leaves insert mode plain", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()

    assert.are.equal("", vim.wo[widget.input_win].winbar)
    assert.are.equal(" ", vim.wo[widget.input_win].statusline)
    assert.are.equal(3, vim.api.nvim_win_get_height(widget.input_win))
    assert.is_nil(vim.wo[widget.transcript_win].statusline:find("0x0 Chat", 1, true))
    assert.is_truthy(vim.wo[widget.transcript_win].statusline:find("repeat('─', winwidth(0))", 1, true))
    assert.are.equal("", vim.bo[widget.input_buf].complete)
    assert.is_false(has_buf_map(widget.input_buf, "i", "<C-N>"))
    assert.is_false(has_buf_map(widget.input_buf, "i", "<C-P>"))
    assert.is_false(has_buf_map(widget.input_buf, "i", "<Tab>"))
    assert.is_false(has_buf_map(widget.input_buf, "n", "<C-N>"))
    assert.is_false(has_buf_map(widget.input_buf, "n", "<C-P>"))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("iHello", true, false, true), "xt", false)
    local lines = vim.api.nvim_buf_get_lines(widget.input_buf, 0, -1, false)
    assert.are.equal("Hello", lines[1])

    widget:close()
    vim.cmd("tabclose")
  end)

  it("strips literal control characters from typed input", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)
    widget:open()

    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("iH<C-v><C-n>e<C-v><C-n>l<C-v><C-n>l<C-v><C-n>o<C-v><C-n>", true, false, true),
      "xt",
      false
    )
    vim.wait(100, function()
      return vim.api.nvim_buf_get_lines(widget.input_buf, 0, -1, false)[1] == "Hello"
    end)
    local lines = vim.api.nvim_buf_get_lines(widget.input_buf, 0, -1, false)
    assert.are.equal("Hello", lines[1])

    widget:close()
    vim.cmd("tabclose")
  end)

  it("keeps the cursor stable when sanitizing leaked controls mid-sentence", function()
    local History = require("zxz.core.history")
    local ChatWidget = require("zxz.chat.widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)
    widget:open()

    vim.api.nvim_buf_set_lines(widget.input_buf, 0, -1, false, { "Hello world" })
    vim.api.nvim_win_set_cursor(widget.input_win, { 1, 6 })
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("ib<C-v><C-n>i<C-v><C-n>g<C-v><C-n> <C-v><C-n>", true, false, true),
      "xt",
      false
    )
    vim.wait(100, function()
      return vim.api.nvim_buf_get_lines(widget.input_buf, 0, -1, false)[1] == "Hello big world"
    end)

    local lines = vim.api.nvim_buf_get_lines(widget.input_buf, 0, -1, false)
    assert.are.equal("Hello big world", lines[1])
    assert.are.same({ 1, 10 }, vim.api.nvim_win_get_cursor(widget.input_win))

    widget:close()
    vim.cmd("tabclose")
  end)
end)
