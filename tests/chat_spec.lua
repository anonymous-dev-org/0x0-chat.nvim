-- Smoke-level coverage of the Chat orchestrator after the chat/* split.
-- Verifies the mixin wires up every method the public API expects so
-- regressions in the split surface immediately.

local helpers = require("tests.helpers")

describe("chat orchestrator", function()
  local M
  local repo

  before_each(function()
    repo = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "alpha\n" }))
    M = require("zeroxzero.chat")
  end)

  after_each(function()
    helpers.cleanup(repo)
  end)

  it("exposes the public M surface used by init.lua", function()
    for _, name in ipairs({
      "open",
      "close",
      "toggle",
      "add_selection",
      "history_picker",
      "new",
      "submit",
      "cancel",
      "changes",
      "review",
      "add_current_file",
      "add_current_hunk",
      "accept_all",
      "discard_all",
      "stop",
      "current_settings",
      "set_provider",
      "set_model",
      "set_mode",
      "discover_options",
      "option_items",
      "has_config_option",
    }) do
      assert.is_function(M[name], "M." .. name .. " missing")
    end
  end)

  it("current_settings runs without raising (mixin wired correctly)", function()
    local ok, err = pcall(M.current_settings)
    assert.is_true(ok, tostring(err))
  end)

  it("submit on an empty input only warns, does not throw", function()
    M.toggle() -- open
    -- Empty input: submit should notify and return without error.
    local ok, err = pcall(M.submit)
    assert.is_true(ok, tostring(err))
    M.close()
  end)

  it("changes/review/accept_all/discard_all/diff are no-ops without an active checkpoint", function()
    for _, name in ipairs({ "changes", "review", "accept_all", "discard_all", "diff" }) do
      local ok, err = pcall(M[name])
      assert.is_true(ok, name .. " threw: " .. tostring(err))
    end
  end)

  it("exposes diff in the public M surface", function()
    assert.is_function(M.diff)
  end)
end)

describe("chat widget rendering", function()
  it("uses one Agent heading for a run across tool loops", function()
    local History = require("zeroxzero.history")
    local ChatWidget = require("zeroxzero.chat_widget")
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

  it("shows working state in the transcript footer", function()
    local History = require("zeroxzero.history")
    local ChatWidget = require("zeroxzero.chat_widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()
    widget:set_activity("responding", "Working")

    local input_winbar = vim.wo[widget.input_win].winbar
    local transcript_winbar = vim.wo[widget.transcript_win].winbar
    assert.is_nil(input_winbar:find("Working", 1, true))
    assert.is_nil(transcript_winbar:find("Working", 1, true))

    local namespaces = vim.api.nvim_get_namespaces()
    local marks = vim.api.nvim_buf_get_extmarks(widget.transcript_buf, namespaces.zeroxzero_chat_widget, 0, -1, {
      details = true,
    })
    local footer = nil
    for _, mark in ipairs(marks) do
      local details = mark[4]
      if details and details.virt_lines then
        footer = details.virt_lines
      end
    end
    assert.is_truthy(footer)
    assert.are.equal("Working", footer[1][2][1])

    widget:close()
    vim.cmd("tabclose")
  end)

  it("keeps the input clean and leaves insert-mode ctrl keys alone", function()
    local History = require("zeroxzero.history")
    local ChatWidget = require("zeroxzero.chat_widget")
    local history = History.new()
    vim.cmd("tabnew")
    local widget = ChatWidget.new(vim.api.nvim_get_current_tabpage(), history, function() end, function() end)

    widget:open()

    assert.are.equal("", vim.wo[widget.input_win].winbar)
    assert.is_nil(vim.fn.maparg("<C-n>", "i", false, true).buffer)
    assert.is_nil(vim.fn.maparg("<C-p>", "i", false, true).buffer)
    assert.are.equal(1, vim.fn.maparg("<C-n>", "n", false, true).buffer)
    assert.are.equal(1, vim.fn.maparg("<C-p>", "n", false, true).buffer)
    assert.not_equal("", vim.bo[widget.input_buf].complete)

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("iabc<C-n>def", true, false, true), "xt", false)
    local lines = vim.api.nvim_buf_get_lines(widget.input_buf, 0, -1, false)
    assert.are.equal("abcdef", lines[1])

    widget:close()
    vim.cmd("tabclose")
  end)
end)
