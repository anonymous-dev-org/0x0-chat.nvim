local helpers = require("tests.helpers")
local Worktree = require("zxz.worktree")

describe("zxz.chat.open", function()
  local repo
  local agentic_calls
  local orig_loaded_agentic
  local orig_loaded_config

  before_each(function()
    repo = helpers.make_repo({ ["a.txt"] = "one\n" })
    vim.fn.chdir(repo)
    agentic_calls = { open = 0 }
    orig_loaded_agentic = package.loaded["agentic"]
    orig_loaded_config = package.loaded["agentic.config"]
    package.loaded["agentic"] = {
      open = function()
        agentic_calls.open = agentic_calls.open + 1
        agentic_calls.cwd = vim.fn.getcwd()
      end,
    }
    package.loaded["agentic.config"] = { provider = nil }
    -- Force a fresh zxz.chat each test so safe_require picks up the stub.
    package.loaded["zxz.chat"] = nil
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
    package.loaded["agentic"] = orig_loaded_agentic
    package.loaded["agentic.config"] = orig_loaded_config
    package.loaded["zxz.chat"] = nil
    helpers.cleanup(repo)
  end)

  it("creates a worktree and opens agentic with the worktree as cwd", function()
    local Chat = require("zxz.chat")
    local wt, err = Chat.open()
    assert.is_nil(err)
    assert.is_not_nil(wt)
    assert.equals(1, agentic_calls.open)
    assert.equals(vim.fn.resolve(wt.path), vim.fn.resolve(agentic_calls.cwd))
    assert.is_true(vim.fn.tabpagenr("$") >= 2)
    pcall(Worktree.remove, wt)
  end)

  it("propagates the requested provider to agentic.config", function()
    local Chat = require("zxz.chat")
    local wt = assert(Chat.open({ provider = "claude" }))
    assert.equals("claude", package.loaded["agentic.config"].provider)
    pcall(Worktree.remove, wt)
  end)

  it("errors gracefully when agentic.nvim is not installed", function()
    package.loaded["agentic"] = nil
    package.preload["agentic"] = function()
      error("module 'agentic' not found")
    end
    local Chat = require("zxz.chat")
    local wt, err = Chat.open()
    assert.is_nil(wt)
    assert.is_not_nil(err)
    assert.is_truthy(err:match("agentic.nvim is not installed"))
    package.preload["agentic"] = nil
  end)
end)

describe("zxz.review picker", function()
  local Review = require("zxz.review")
  local repo

  before_each(function()
    repo = helpers.make_repo({ ["a.txt"] = "one\n" })
    vim.fn.chdir(repo)
  end)

  after_each(function()
    pcall(vim.fn.system, { "git", "-C", repo, "merge", "--abort" })
    for _, wt in ipairs(Worktree.list()) do
      pcall(Worktree.remove, wt)
    end
    helpers.cleanup(repo)
  end)

  it("pick() short-circuits to the only worktree when there is just one", function()
    local wt = assert(Worktree.create({ cwd = repo }))
    local picked
    Review.pick(function(w)
      picked = w
    end)
    assert.is_not_nil(picked)
    assert.equals(wt.branch, picked.branch)
  end)

  it("pick() invokes vim.ui.select when multiple worktrees exist", function()
    local wt1 = assert(Worktree.create({ cwd = repo }))
    local wt2 = assert(Worktree.create({ cwd = repo }))
    local orig_select = vim.ui.select
    local prompted
    vim.ui.select = function(items, _opts, on_choice)
      prompted = items
      on_choice(items[2])
    end
    local picked
    Review.pick(function(w)
      picked = w
    end)
    vim.ui.select = orig_select
    assert.is_not_nil(prompted)
    assert.equals(2, #prompted)
    assert.is_truthy(picked.branch == wt1.branch or picked.branch == wt2.branch)
  end)
end)
