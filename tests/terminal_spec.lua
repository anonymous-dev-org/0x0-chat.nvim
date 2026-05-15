local helpers = require("tests.helpers")
local Agents = require("zxz.agents")
local Terminal = require("zxz.terminal")
local Worktree = require("zxz.worktree")

describe("zxz.agents", function()
  it("ships built-in agents and lists them sorted", function()
    local names = Agents.names()
    assert.is_truthy(vim.tbl_contains(names, "claude"))
    assert.is_truthy(vim.tbl_contains(names, "codex"))
    -- sorted
    local prev = ""
    for _, n in ipairs(names) do
      assert.is_true(n >= prev)
      prev = n
    end
  end)

  it("registers a custom agent", function()
    Agents.register("fakebot", { cmd = { "echo", "hi" } })
    local def = Agents.get("fakebot")
    assert.equals("fakebot", def.name)
    assert.equals("echo", def.cmd[1])
  end)

  it("reports availability based on $PATH", function()
    Agents.register("present", { cmd = { "sh" } })
    Agents.register("absent", { cmd = { "this-binary-does-not-exist-zxz" } })
    assert.is_true(Agents.available("present"))
    assert.is_false(Agents.available("absent"))
  end)
end)

describe("zxz.terminal", function()
  local repo

  before_each(function()
    repo = helpers.make_repo({ ["README.md"] = "hi\n" })
    vim.fn.chdir(repo)
    Terminal._reset()
    -- A fake agent that just echoes stdin so we can observe chansend.
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

  it("start() refuses unknown agents", function()
    local term, err = Terminal.start("does-not-exist")
    assert.is_nil(term)
    assert.is_truthy(err:match("unknown agent"))
  end)

  it("start() refuses agents whose binary is missing", function()
    Agents.register("phantom", { cmd = { "this-binary-does-not-exist-zxz" } })
    local term, err = Terminal.start("phantom")
    assert.is_nil(term)
    assert.is_truthy(err:match("not on PATH"))
  end)

  it("start() spawns a terminal job inside a fresh worktree", function()
    local term = assert(Terminal.start("echobot", { split = "vsplit" }))
    assert.is_truthy(term.job_id > 0)
    assert.is_truthy(vim.api.nvim_buf_is_valid(term.bufnr))
    assert.equals("echobot", term.agent)
    assert.is_truthy(term.worktree.path:match("/%.git/zxz/wt%-"))
    -- The worktree exists on disk and has the seed file.
    assert.equals("hi\n", helpers.read_file(term.worktree.path .. "/README.md"))
  end)

  it("send() chansends text with trailing newline", function()
    local term = assert(Terminal.start("echobot"))
    assert.is_true(Terminal.send(term, "hello"))
    -- give the subprocess a beat to echo back
    vim.wait(500, function()
      local lines = vim.api.nvim_buf_get_lines(term.bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:match("got:hello") then
          return true
        end
      end
      return false
    end)
    local lines = vim.api.nvim_buf_get_lines(term.bufnr, 0, -1, false)
    local ok = false
    for _, l in ipairs(lines) do
      if l:match("got:hello") then
        ok = true
        break
      end
    end
    assert.is_true(ok, "echobot did not echo within timeout: " .. vim.inspect(lines))
  end)

  it("list() returns started terms; current() returns the buffer-matched term", function()
    local t1 = assert(Terminal.start("echobot"))
    local t2 = assert(Terminal.start("echobot"))
    assert.equals(2, #Terminal.list())
    -- Focus t1's buffer; current() should resolve to it.
    vim.api.nvim_set_current_buf(t1.bufnr)
    assert.equals(t1.id, Terminal.current().id)
    vim.api.nvim_set_current_buf(t2.bufnr)
    assert.equals(t2.id, Terminal.current().id)
  end)

  it("stop() removes the term, its buffer, and its worktree by default", function()
    local term = assert(Terminal.start("echobot"))
    local wt_path = term.worktree.path
    Terminal.stop(term)
    assert.is_nil(Terminal.get(term.id))
    -- buffer gone
    assert.is_false(vim.api.nvim_buf_is_valid(term.bufnr))
    -- worktree gone
    assert.is_truthy(vim.fn.isdirectory(wt_path) == 0)
  end)

  it("stop() with keep_worktree leaves the worktree on disk", function()
    local term = assert(Terminal.start("echobot"))
    local wt_path = term.worktree.path
    Terminal.stop(term, { keep_worktree = true })
    assert.is_truthy(vim.fn.isdirectory(wt_path) == 1)
    -- But it's no longer registered as active.
    assert.is_nil(Terminal.get(term.id))
    -- Cleanup leftover worktree manually so the after_each cleanup of repo works.
    local wts = Worktree.list(repo)
    for _, w in ipairs(wts) do
      Worktree.remove(w)
    end
  end)
end)
