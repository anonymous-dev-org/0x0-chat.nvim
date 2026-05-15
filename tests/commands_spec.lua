local helpers = require("tests.helpers")
local Commands = require("zxz.commands")
local Worktree = require("zxz.worktree")

describe("zxz.commands.setup", function()
  local DEFAULT_CMDS = {
    "ZxzReview",
    "ZxzChat",
    "ZxzList",
    "ZxzCleanup",
  }

  before_each(function()
    -- Wipe any previously registered commands so the suite is order-independent.
    for _, name in ipairs(DEFAULT_CMDS) do
      pcall(vim.api.nvim_del_user_command, name)
    end
  end)

  it("registers the agent commands under the default prefix", function()
    Commands.setup({ install_keymaps = false })
    local cmds = vim.api.nvim_get_commands({})
    for _, name in ipairs(DEFAULT_CMDS) do
      assert.is_not_nil(cmds[name], "missing :" .. name)
    end
  end)

  it("honours a custom command_prefix", function()
    Commands.setup({ command_prefix = "Foo" })
    local cmds = vim.api.nvim_get_commands({})
    assert.is_not_nil(cmds.FooChat)
    for _, n in ipairs({
      "FooChat",
      "FooReview",
      "FooList",
      "FooCleanup",
    }) do
      pcall(vim.api.nvim_del_user_command, n)
    end
  end)
end)

describe("zxz.commands.cleanup", function()
  local repo

  before_each(function()
    repo = helpers.make_repo({ ["a.txt"] = "x\n" })
    vim.fn.chdir(repo)
  end)

  after_each(function()
    for _, w in ipairs(Worktree.list()) do
      pcall(Worktree.remove, w)
    end
    helpers.cleanup(repo)
  end)

  it("removes agent worktrees by default", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "orphan" }))
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 1)
    Commands.cleanup({})
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 0)
  end)

  it("keeps unmerged branches when cleaning only merged worktrees", function()
    local wt = assert(Worktree.create({ cwd = repo, id = "active" }))
    Commands.cleanup({ merged = true })
    assert.is_truthy(vim.fn.isdirectory(wt.path) == 1)
  end)
end)
