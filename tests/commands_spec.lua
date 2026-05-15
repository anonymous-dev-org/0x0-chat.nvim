local helpers = require("tests.helpers")
local Commands = require("zxz.commands")
local Terminal = require("zxz.terminal")
local Agents = require("zxz.agents")
local Worktree = require("zxz.worktree")

describe("zxz.commands.setup", function()
  before_each(function()
    -- Wipe any previously registered commands so the suite is order-independent.
    for _, name in ipairs({
      "ZxzWtStart",
      "ZxzWtReview",
      "ZxzWtList",
      "ZxzWtCleanup",
    }) do
      pcall(vim.api.nvim_del_user_command, name)
    end
  end)

  it("registers the worktree commands under the default prefix", function()
    Commands.setup({ install_keymaps = false })
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.ZxzWtStart)
    assert.is_not_nil(cmds.ZxzWtReview)
    assert.is_not_nil(cmds.ZxzWtList)
    assert.is_not_nil(cmds.ZxzWtCleanup)
  end)

  it("honours a custom command_prefix", function()
    Commands.setup({ command_prefix = "Foo", install_keymaps = false })
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.FooStart)
    pcall(vim.api.nvim_del_user_command, "FooStart")
    pcall(vim.api.nvim_del_user_command, "FooReview")
    pcall(vim.api.nvim_del_user_command, "FooList")
    pcall(vim.api.nvim_del_user_command, "FooCleanup")
  end)
end)

describe("zxz.commands.cleanup", function()
  local repo

  before_each(function()
    repo = helpers.make_repo({ ["a.txt"] = "x\n" })
    vim.fn.chdir(repo)
    Terminal._reset()
    Agents.register("echobot", {
      cmd = { "sh", "-c", "while IFS= read -r line; do echo $line; done" },
    })
  end)

  after_each(function()
    for _, t in ipairs(Terminal.list()) do
      Terminal.stop(t)
    end
    for _, w in ipairs(Worktree.list()) do
      pcall(Worktree.remove, w)
    end
    helpers.cleanup(repo)
  end)

  it("preserves live agent worktrees by default", function()
    local term = assert(Terminal.start("echobot"))
    -- Sanity: list shows it as a worktree
    assert.equals(1, #Worktree.list())
    Commands.cleanup({})
    -- Live term: worktree should still be there
    assert.equals(1, #Worktree.list())
    assert.is_not_nil(Terminal.get(term.id))
  end)

  it("with all=true removes even live worktrees", function()
    local term = assert(Terminal.start("echobot"))
    Commands.cleanup({ all = true })
    assert.equals(0, #Worktree.list())
    -- The Terminal entry persists (the term object still references a dead worktree),
    -- but we treat that as the user's problem after a forced cleanup.
    local _ = term
  end)

  it("removes orphaned worktrees (no live job)", function()
    -- Create a worktree without spawning a Terminal.
    local wt = assert(Worktree.create({ cwd = repo, id = "orphan" }))
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 1)
    Commands.cleanup({})
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 0)
  end)
end)
