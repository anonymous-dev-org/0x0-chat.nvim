local helpers = require("tests.helpers")
local Worktree = require("zxz.worktree")
local Review = require("zxz.review")

local function run(cmd)
  local out = vim.fn.system(cmd)
  assert(vim.v.shell_error == 0, "command failed: " .. vim.inspect(cmd) .. "\n" .. out)
  return out
end

---Make the agent branch commit `branch_files`; leave worktree at base content.
local function setup_agent_change(repo, branch_files)
  local wt = assert(Worktree.create({ cwd = repo }))
  for path, content in pairs(branch_files) do
    helpers.write_file(wt.path .. "/" .. path, content)
  end
  run({ "git", "-C", wt.path, "add", "-A" })
  run({ "git", "-C", wt.path, "commit", "-q", "-m", "agent change" })
  return wt
end

describe("zxz.review parse_diff", function()
  it("splits multi-file diff and extracts paths", function()
    local diff = table.concat({
      "diff --git a/foo b/foo",
      "index 1111111..2222222 100644",
      "--- a/foo",
      "+++ b/foo",
      "@@ -1,1 +1,1 @@",
      "-old",
      "+new",
      "diff --git a/bar b/bar",
      "new file mode 100644",
      "index 0000000..3333333",
      "--- /dev/null",
      "+++ b/bar",
      "@@ -0,0 +1,1 @@",
      "+hello",
    }, "\n")
    local files = Review._parse_diff(diff)
    assert.equals(2, #files)
    assert.equals("foo", files[1].path)
    assert.equals("modified", files[1].status)
    assert.equals(1, #files[1].hunks)
    assert.equals("bar", files[2].path)
    assert.equals("added", files[2].status)
  end)

  it("detects deleted file", function()
    local diff = table.concat({
      "diff --git a/gone b/gone",
      "deleted file mode 100644",
      "index 4444444..0000000",
      "--- a/gone",
      "+++ /dev/null",
      "@@ -1,1 +0,0 @@",
      "-bye",
    }, "\n")
    local files = Review._parse_diff(diff)
    assert.equals(1, #files)
    assert.equals("deleted", files[1].status)
  end)

  it("returns empty list on empty diff", function()
    assert.equals(0, #Review._parse_diff(""))
  end)
end)

describe("zxz.review hunk apply", function()
  local repo, wt

  before_each(function()
    repo = helpers.make_repo({
      ["a.txt"] = "line1\nline2\nline3\n",
      ["b.txt"] = "x\n",
    })
    vim.fn.chdir(repo)
  end)

  after_each(function()
    if wt then
      pcall(Worktree.remove, wt)
      wt = nil
    end
    helpers.cleanup(repo)
  end)

  it("pending_diff is oriented branch -> worktree", function()
    wt = setup_agent_change(repo, { ["a.txt"] = "line1\nLINE2\nline3\n" })
    local diff = Worktree.pending_diff(wt)
    -- branch -> worktree: '-' is branch (LINE2), '+' is worktree (line2).
    assert.is_truthy(diff:match("\n%-LINE2"))
    assert.is_truthy(diff:match("\n%+line2"))
  end)

  it("accepting a hunk (reverse-apply) lands the agent's change", function()
    wt = setup_agent_change(repo, { ["a.txt"] = "line1\nLINE2\nline3\n" })
    local diff = Worktree.pending_diff(wt)
    local files = Review._parse_diff(diff)
    assert.equals(1, #files)
    local patch = Review._build_hunk_patch(files[1], files[1].hunks[1])
    assert(Worktree.apply_patch(wt, patch, { reverse = true }))
    assert.equals("line1\nLINE2\nline3\n", helpers.read_file(repo .. "/a.txt"))
  end)

  it("accept then reject (forward) restores the original worktree", function()
    wt = setup_agent_change(repo, { ["a.txt"] = "line1\nLINE2\nline3\n" })
    local diff = Worktree.pending_diff(wt)
    local files = Review._parse_diff(diff)
    local patch = Review._build_hunk_patch(files[1], files[1].hunks[1])
    assert(Worktree.apply_patch(wt, patch, { reverse = true }))
    assert(Worktree.apply_patch(wt, patch))
    assert.equals("line1\nline2\nline3\n", helpers.read_file(repo .. "/a.txt"))
  end)

  it("file patch (reverse) lands an added file in the user's worktree", function()
    wt = setup_agent_change(repo, { ["new.txt"] = "fresh\n" })
    local diff = Worktree.pending_diff(wt)
    local files = Review._parse_diff(diff)
    assert.equals(1, #files)
    -- For an added file, status is "deleted" from the worktree's POV since
    -- the worktree lacks it; the agent's branch has it.
    assert.equals("deleted", files[1].status)
    local patch = Review._build_file_patch(files[1])
    assert(Worktree.apply_patch(wt, patch, { reverse = true }))
    assert.equals("fresh\n", helpers.read_file(repo .. "/new.txt"))
  end)
end)

describe("zxz.review open()", function()
  local repo, wt

  before_each(function()
    repo = helpers.make_repo({ ["a.txt"] = "one\ntwo\n" })
    vim.fn.chdir(repo)
    wt = setup_agent_change(repo, { ["a.txt"] = "one\nTWO\n", ["b.txt"] = "b\n" })
  end)

  after_each(function()
    if wt then
      pcall(Worktree.remove, wt)
    end
    -- Wipe any review buffers.
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name:match("^zxz%-review://") then
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
    end
    helpers.cleanup(repo)
  end)

  it("renders Modified and Added sections with the right counts", function()
    local state = Review.open(wt, { split = "current" })
    local lines = vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
    local joined = table.concat(lines, "\n")
    assert.is_truthy(joined:match("Modified %(1%)"))
    assert.is_truthy(joined:match("Added %(1%)"))
    assert.is_truthy(joined:match("M a%.txt"))
    assert.is_truthy(joined:match("A b%.txt"))
  end)

  it("toggle expands the hunk body inline", function()
    local state = Review.open(wt, { split = "current" })
    -- Cursor onto the "  M a.txt" row.
    for row, target in pairs(state.row_map) do
      if target and target.path == "a.txt" and not target.hunk_idx then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        break
      end
    end
    Review.toggle(state)
    local joined = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
    assert.is_truthy(joined:match("@@"))
    -- Diff is branch -> worktree, so branch's TWO appears as '-' and the
    -- worktree's two as '+' in the raw hunk body.
    assert.is_truthy(joined:match("%-TWO"))
    assert.is_truthy(joined:match("%+two"))
  end)

  it("accept on a file header lands the file and removes it from the diff", function()
    local state = Review.open(wt, { split = "current" })
    for row, target in pairs(state.row_map) do
      if target and target.path == "b.txt" and not target.hunk_idx then
        vim.api.nvim_win_set_cursor(0, { row, 0 })
        break
      end
    end
    Review.accept(state)
    -- b.txt should now exist in the worktree.
    assert.equals("b\n", helpers.read_file(repo .. "/b.txt"))
    -- And `Added` count should drop to 0.
    local joined = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
    assert.is_truthy(joined:match("Added %(0%)"))
    assert.is_true(state.touched["b.txt"])
  end)

  it("conflict is detected when the user's worktree edits the same line", function()
    helpers.write_file(repo .. "/a.txt", "one\nLOCAL_TWO\n")
    run({ "git", "-C", repo, "commit", "-am", "user edit" })
    local state = Review.open(wt, { split = "current" })
    local joined = table.concat(vim.api.nvim_buf_get_lines(state.bufnr, 0, -1, false), "\n")
    assert.is_truthy(joined:match("Conflicts %(1%)"))
  end)

  it("re-opening reuses the same buffer", function()
    local s1 = Review.open(wt, { split = "current" })
    local s2 = Review.open(wt, { split = "current" })
    assert.equals(s1.bufnr, s2.bufnr)
  end)
end)
