local helpers = require("tests.helpers")
local Chat = require("zxz.chat")
local Review = require("zxz.review")
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
    package.loaded["agentic.config"] = { provider = nil, hooks = {} }
    Chat._reset_for_tests()
  end)

  after_each(function()
    while vim.fn.tabpagenr("$") > 1 do
      vim.cmd("tabclose")
    end
    package.loaded["agentic"] = orig_loaded_agentic
    package.loaded["agentic.config"] = orig_loaded_config
    Chat._reset_for_tests()
    helpers.cleanup(repo)
  end)

  it("creates a worktree and opens agentic with the worktree as cwd", function()
    local wt, err = Chat.open()
    assert.is_nil(err)
    assert.is_not_nil(wt)
    assert.equals(1, agentic_calls.open)
    assert.equals(vim.fn.resolve(wt.path), vim.fn.resolve(agentic_calls.cwd))
    assert.is_true(vim.fn.tabpagenr("$") >= 2)
    pcall(Worktree.remove, wt)
  end)

  it("propagates the requested provider to agentic.config", function()
    local wt = assert(Chat.open({ provider = "claude" }))
    assert.equals("claude", package.loaded["agentic.config"].provider)
    pcall(Worktree.remove, wt)
  end)

  it("commits each completed agentic turn onto the agent branch", function()
    local wt = assert(Chat.open())
    local Config = package.loaded["agentic.config"]
    assert.is_function(Config.hooks.on_response_complete)

    helpers.write_file(wt.path .. "/a.txt", "turn one\n")
    Config.hooks.on_response_complete({
      tab_page_id = vim.api.nvim_get_current_tabpage(),
      session_id = "s1",
      success = true,
    })

    helpers.write_file(wt.path .. "/b.txt", "turn two\n")
    Config.hooks.on_response_complete({
      tab_page_id = vim.api.nvim_get_current_tabpage(),
      session_id = "s1",
      success = true,
    })

    local count =
      vim.fn.system({ "git", "-C", wt.path, "rev-list", "--count", wt.base_ref .. "..HEAD" }):gsub("\n$", "")
    assert.equals("2", count)

    local status = vim.fn.system({ "git", "-C", wt.path, "status", "--porcelain" })
    assert.equals("", status)
    pcall(Worktree.remove, wt)
  end)

  it("redirects agentic new_session from a managed tab into a fresh worktree", function()
    local wt1 = assert(Chat.open())

    package.loaded["agentic"].new_session({ provider = "codex" })

    assert.equals(2, agentic_calls.open)
    assert.equals("codex", package.loaded["agentic.config"].provider)

    local wts = Worktree.list(repo)
    assert.equals(2, #wts)
    local branches = {}
    for _, wt in ipairs(wts) do
      branches[wt.branch] = true
      pcall(Worktree.remove, wt)
    end
    assert.is_true(branches[wt1.branch])
  end)

  it("errors gracefully when agentic.nvim is not installed", function()
    package.loaded["agentic"] = nil
    package.preload["agentic"] = function()
      error("module 'agentic' not found")
    end
    local wt, err = Chat.open()
    assert.is_nil(wt)
    assert.is_not_nil(err)
    assert.is_truthy(err:match("agentic.nvim is not installed"))
    package.preload["agentic"] = nil
  end)
end)

describe("zxz.review picker", function()
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
