local helpers = require("tests.helpers")
local Agents = require("zxz.agents")
local Terminal = require("zxz.terminal")
local Share = require("zxz.context_share")

-- Drain the echobot output buffer for substring checks.
local function wait_for(bufnr, pattern, timeout)
  timeout = timeout or 1000
  vim.wait(timeout, function()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for _, l in ipairs(lines) do
      if l:match(pattern) then
        return true
      end
    end
    return false
  end)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

describe("zxz.context_share", function()
  local repo

  before_each(function()
    repo = helpers.make_repo({
      ["src/foo.lua"] = "local M = {}\nfunction M.x() return 1 end\nreturn M\n",
      ["README.md"] = "hi\n",
    })
    vim.fn.chdir(repo)
    Terminal._reset()
    Agents.register("echobot", {
      cmd = { "sh", "-c", "while IFS= read -r line; do echo got:$line; done" },
    })
  end)

  after_each(function()
    for _, t in ipairs(Terminal.list()) do
      Terminal.stop(t)
    end
    helpers.cleanup(repo)
  end)

  it("format_path returns @<relative> for the current buffer", function()
    vim.cmd("edit " .. repo .. "/src/foo.lua")
    assert.equals("@src/foo.lua", Share.format_path())
  end)

  it("format_path returns nil for a [No Name] buffer", function()
    vim.cmd("enew")
    assert.is_nil(Share.format_path())
  end)

  it("send_path chansends @<file> with newline", function()
    local term = assert(Terminal.start("echobot"))
    vim.cmd("edit " .. repo .. "/README.md")
    assert.is_true(Share.send_path({ term = term }))
    local lines = wait_for(term.bufnr, "got:@README.md")
    local ok = false
    for _, l in ipairs(lines) do
      if l:match("got:@README.md") then
        ok = true
      end
    end
    assert.is_true(ok, "did not see @README.md: " .. vim.inspect(lines))
  end)

  it("send_path fails gracefully when no agent term exists", function()
    vim.cmd("edit " .. repo .. "/README.md")
    local ok, err = Share.send_path()
    assert.is_false(ok)
    assert.is_truthy(err:match("no active agent"))
  end)

  it("send_paths joins multiple @refs into one chansend", function()
    local term = assert(Terminal.start("echobot"))
    local ok = Share.send_paths({ repo .. "/README.md", repo .. "/src/foo.lua" }, { term = term })
    assert.is_true(ok)
    vim.wait(800, function()
      local joined = table.concat(vim.api.nvim_buf_get_lines(term.bufnr, 0, -1, false), "")
      return joined:match("got:@README%.md @src/foo%.lua") ~= nil
    end)
    local joined = table.concat(vim.api.nvim_buf_get_lines(term.bufnr, 0, -1, false), "")
    assert.is_truthy(joined:match("got:@README%.md @src/foo%.lua"), "joined buffer was: " .. joined)
  end)

  it("send_selection formats with L<a>-<b> and fenced selection", function()
    local term = assert(Terminal.start("echobot"))
    vim.cmd("edit " .. repo .. "/src/foo.lua")
    -- Simulate a visual selection over lines 2..2.
    vim.api.nvim_buf_set_mark(0, "<", 2, 0, {})
    vim.api.nvim_buf_set_mark(0, ">", 2, 0, {})
    assert.is_true(Share.send_selection({ term = term }))
    local lines = wait_for(term.bufnr, "got:@src/foo%.lua:L2%-2")
    local header_seen, code_seen = false, false
    for _, l in ipairs(lines) do
      if l:match("got:@src/foo%.lua:L2%-2") then
        header_seen = true
      end
      if l:match("got:function M%.x") then
        code_seen = true
      end
    end
    assert.is_true(header_seen, "header missing: " .. vim.inspect(lines))
    assert.is_true(code_seen, "code line missing: " .. vim.inspect(lines))
  end)
end)
