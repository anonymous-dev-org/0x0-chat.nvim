local helpers = require("tests.helpers")
local Chat = require("zxz.chat")
local Worktree = require("zxz.worktree")
local Review = require("zxz.review")

local function run(cmd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, "command failed: " .. vim.inspect(cmd) .. "\n" .. out)
  return out
end

local function try(cmd)
  local out = vim.fn.system(cmd)
  return vim.v.shell_error, out
end

local function exit_code(cmd)
  local code = try(cmd)
  return code
end

local function show(repo, rev, path)
  return run({ "git", "-C", repo, "show", rev .. ":" .. path })
end

local function lines(count)
  local out = {}
  for i = 1, count do
    out[#out + 1] = ("line %02d"):format(i)
  end
  return out
end

local function agent_a()
  local out = lines(20)
  out[1] = "LINE 01"
  out[20] = "LINE 20"
  return table.concat(out, "\n") .. "\n"
end

local function base_a()
  return table.concat(lines(20), "\n") .. "\n"
end

local function find_file(state, path)
  for i, file in ipairs(state.files) do
    if file.path == path then
      state.selected = i
      return file
    end
  end
  error("file not found in review state: " .. path)
end

describe("zxz.review", function()
  local repo, wt, state
  local orig_notify
  local notifications

  local function cleanup_review_state()
    if state then
      pcall(vim.fn.system, { "git", "-C", repo, "worktree", "remove", "--force", state.review_path })
      pcall(vim.fn.system, { "git", "-C", repo, "branch", "-D", state.review_branch })
      state = nil
    end
  end

  before_each(function()
    repo = helpers.make_repo({
      ["a.txt"] = base_a(),
      ["b.txt"] = "base\n",
    })
    vim.fn.chdir(repo)

    notifications = {}
    orig_notify = vim.notify
    vim.notify = function(msg, lvl)
      notifications[#notifications + 1] = { msg = msg, lvl = lvl }
    end

    wt = assert(Worktree.create({ cwd = repo }))
    helpers.write_file(wt.path .. "/a.txt", agent_a())
    helpers.write_file(wt.path .. "/b.txt", "agent\n")
    run({ "git", "-C", wt.path, "add", "-A" })
    run({ "git", "-C", wt.path, "commit", "-q", "-m", "agent" })
  end)

  after_each(function()
    vim.notify = orig_notify
    while vim.fn.tabpagenr("$") > 1 do
      pcall(vim.cmd, "tabclose")
    end
    cleanup_review_state()
    if wt then
      pcall(Worktree.remove, wt)
      wt = nil
    end
    helpers.cleanup(repo)
  end)

  it("opens a full review tab without starting a merge in main", function()
    local tabs_before = vim.fn.tabpagenr("$")

    state = Review._open_for(wt)

    assert.is_not_nil(state)
    assert.equals(tabs_before + 1, vim.fn.tabpagenr("$"))
    assert.equals(128, exit_code({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" }))
    assert.equals(1, vim.fn.isdirectory(state.review_path))
    assert.is_true(vim.api.nvim_tabpage_is_valid(state.tab))
    assert.equals("zxzreview", vim.bo[state.list_buf].filetype)
    assert.equals("diff", vim.bo[state.diff_buf].filetype)

    vim.api.nvim_set_current_win(state.list_win)
    local close_map = vim.fn.maparg("q", "n", false, true)
    assert.equals(1, close_map.buffer)
    close_map.callback()
    assert.equals(tabs_before, vim.fn.tabpagenr("$"))
    assert.equals(128, exit_code({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" }))
  end)

  it("accepts all proposed changes into the review branch, then merges them into main", function()
    state = assert(Review.create_state(wt))

    Review.accept_all(state)

    assert.equals(agent_a(), show(repo, state.review_branch, "a.txt"))
    assert.equals("agent\n", show(repo, state.review_branch, "b.txt"))
    assert.equals(base_a(), helpers.read_file(repo .. "/a.txt"))
    assert.equals("base\n", helpers.read_file(repo .. "/b.txt"))

    Review.merge(state)

    assert.equals(agent_a(), helpers.read_file(repo .. "/a.txt"))
    assert.equals("agent\n", helpers.read_file(repo .. "/b.txt"))
    assert.equals(128, exit_code({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" }))
    state = nil
  end)

  it("aborts a failed final merge so main is not left blocked", function()
    state = assert(Review.create_state(wt))
    Review.accept_file(state, find_file(state, "a.txt"))

    local main_change = lines(20)
    main_change[1] = "main change"
    helpers.write_file(repo .. "/a.txt", table.concat(main_change, "\n") .. "\n")
    run({ "git", "-C", repo, "commit", "-am", "main change" })

    Review.merge(state)

    local saw_abort_notice = false
    for _, notification in ipairs(notifications) do
      if notification.msg:match("merge failed and was aborted") then
        saw_abort_notice = true
      end
    end
    assert.is_true(saw_abort_notice, vim.inspect(notifications))
    assert.equals(128, exit_code({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" }))
  end)

  it("accepts one file without accepting the rest of the proposal", function()
    state = assert(Review.create_state(wt))
    local file = find_file(state, "b.txt")

    Review.accept_file(state, file)

    assert.equals(base_a(), show(repo, state.review_branch, "a.txt"))
    assert.equals("agent\n", show(repo, state.review_branch, "b.txt"))
  end)

  it("accepts only the hunk under the cursor from the diff pane", function()
    state = assert(Review.create_state(wt))
    find_file(state, "a.txt")
    Review.open_state(state)

    local first_hunk
    for i, line in ipairs(state.diff_lines) do
      if line:match("^@@") then
        first_hunk = i
        break
      end
    end
    assert.is_not_nil(first_hunk)
    vim.api.nvim_win_set_cursor(state.diff_win, { first_hunk, 0 })

    Review.accept_hunk(state)

    local expected = lines(20)
    expected[1] = "LINE 01"
    local accepted = table.concat(expected, "\n") .. "\n"
    assert.equals(accepted, show(repo, state.review_branch, "a.txt"))
  end)

  it("sends feedback to the same agent worktree", function()
    state = assert(Review.create_state(wt))
    find_file(state, "a.txt")

    local orig_input = vim.ui.input
    local orig_open_existing = Chat.open_existing
    local captured
    vim.ui.input = function(_, cb)
      cb("please keep the original ending")
    end
    Chat.open_existing = function(open_wt, opts)
      captured = { worktree = open_wt, opts = opts }
      return open_wt, nil
    end

    Review.feedback(state, false)

    vim.ui.input = orig_input
    Chat.open_existing = orig_open_existing

    assert.is_not_nil(captured)
    assert.equals(wt.branch, captured.worktree.branch)
    assert.truthy(captured.opts.prompt:match("File: a%.txt"))
    assert.truthy(captured.opts.prompt:match("please keep the original ending"))
    assert.truthy(captured.opts.prompt:match("```diff"))
  end)

  it("refuses review while the agent worktree has uncommitted changes", function()
    helpers.write_file(wt.path .. "/b.txt", "dirty\n")

    Review.open({ worktree = wt })

    local saw_dirty_notice = false
    for _, notification in ipairs(notifications) do
      if notification.msg:match("uncommitted changes") then
        saw_dirty_notice = true
      end
    end
    assert.is_true(saw_dirty_notice, vim.inspect(notifications))
    assert.equals(128, exit_code({ "git", "-C", repo, "rev-parse", "MERGE_HEAD" }))
  end)

  it("notifies when there are no agent worktrees to review", function()
    pcall(Worktree.remove, wt)
    wt = nil

    Review.open()

    local saw = false
    for _, notification in ipairs(notifications) do
      if notification.msg:match("no agent worktrees") then
        saw = true
      end
    end
    assert.is_true(saw, vim.inspect(notifications))
  end)
end)
