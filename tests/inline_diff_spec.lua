local InlineDiff = require("zxz.edit.inline_diff")

local function fixture(diff)
  return InlineDiff.parse(diff)
end

describe("inline_diff.parse", function()
  it("parses a single hunk modification", function()
    local files = fixture([[
diff --git a/src/a.lua b/src/a.lua
index 0000..1111 100644
--- a/src/a.lua
+++ b/src/a.lua
@@ -1,3 +1,3 @@
 keep
-old
+new
 tail
]])
    local f = files["src/a.lua"]
    assert.is_truthy(f)
    assert.are.equal("modify", f.type)
    assert.are.equal(1, #f.hunks)
    local h = f.hunks[1]
    assert.are.same({ "old" }, h.old_lines)
    assert.are.same({ "new" }, h.new_lines)
    assert.are.equal(1, h.old_start)
    assert.are.equal(3, h.old_count)
    assert.are.equal(1, h.new_start)
    assert.are.equal(3, h.new_count)
  end)

  it("parses multi-hunk diffs", function()
    local files = fixture([[
diff --git a/src/a.lua b/src/a.lua
--- a/src/a.lua
+++ b/src/a.lua
@@ -1,2 +1,2 @@
-aa
+AA
 bb
@@ -10,2 +10,2 @@
 cc
-dd
+DD
]])
    local f = files["src/a.lua"]
    assert.are.equal(2, #f.hunks)
    assert.are.same({ "aa" }, f.hunks[1].old_lines)
    assert.are.same({ "AA" }, f.hunks[1].new_lines)
    assert.are.equal(10, f.hunks[2].new_start)
    assert.are.same({ "DD" }, f.hunks[2].new_lines)
  end)

  it("flags new files with /dev/null source", function()
    local files = fixture([[
diff --git a/new.txt b/new.txt
new file mode 100644
--- /dev/null
+++ b/new.txt
@@ -0,0 +1,1 @@
+hello
]])
    local f = files["new.txt"]
    assert.are.equal("add", f.type)
    assert.are.same({}, f.hunks[1].old_lines)
    assert.are.same({ "hello" }, f.hunks[1].new_lines)
  end)

  it("flags deleted files", function()
    local files = fixture([[
diff --git a/gone.txt b/gone.txt
deleted file mode 100644
--- a/gone.txt
+++ /dev/null
@@ -1,1 +0,0 @@
-byebye
]])
    local f = files["gone.txt"]
    assert.are.equal("delete", f.type)
    assert.are.same({ "byebye" }, f.hunks[1].old_lines)
  end)

  it("returns an empty table for blank input", function()
    assert.are.same({}, InlineDiff.parse(""))
    assert.are.same({}, InlineDiff.parse(nil))
  end)

  it("handles single-line counts (omitted ,N form)", function()
    local files = fixture([[
diff --git a/x b/x
--- a/x
+++ b/x
@@ -5 +5 @@
-x
+X
]])
    local h = files["x"].hunks[1]
    assert.are.equal(1, h.old_count)
    assert.are.equal(1, h.new_count)
  end)
end)

describe("inline_diff hunk navigation", function()
  local bufnr

  local function setup_buf(lines, file)
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)
    InlineDiff.attach(bufnr, file, nil)
  end

  after_each(function()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      InlineDiff.detach(bufnr)
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("next_hunk advances to the next hunk's first line", function()
    setup_buf({ "a", "b", "c", "d", "e" }, {
      path = "x",
      type = "modify",
      hunks = {
        { new_start = 2, new_count = 1, old_lines = {}, new_lines = { "b" } },
        { new_start = 4, new_count = 1, old_lines = {}, new_lines = { "d" } },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    InlineDiff.next_hunk()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
    InlineDiff.next_hunk()
    assert.are.equal(4, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("next_hunk wraps around to the first hunk", function()
    setup_buf({ "a", "b", "c" }, {
      path = "x",
      type = "modify",
      hunks = {
        { new_start = 2, new_count = 1, old_lines = {}, new_lines = { "b" } },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    InlineDiff.next_hunk()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("prev_hunk steps back to earlier hunks", function()
    setup_buf({ "a", "b", "c", "d" }, {
      path = "x",
      type = "modify",
      hunks = {
        { new_start = 2, new_count = 1, old_lines = {}, new_lines = { "b" } },
        { new_start = 4, new_count = 1, old_lines = {}, new_lines = { "d" } },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    InlineDiff.prev_hunk()
    assert.are.equal(2, vim.api.nvim_win_get_cursor(0)[1])
  end)

  it("returns a prompt-ready reference for the hunk under cursor", function()
    setup_buf({ "keep", "new", "tail" }, {
      path = "src/a.lua",
      type = "modify",
      hunks = {
        {
          old_start = 1,
          old_count = 3,
          new_start = 1,
          new_count = 3,
          old_lines = { "old" },
          new_lines = { "new" },
        },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local ref = assert(InlineDiff.current_hunk_reference())
    assert.are.equal("src/a.lua", ref.path)
    assert.are.same({ "@@ -1,3 +1,3 @@", "-old", "+new" }, ref.lines)
  end)
end)

describe("inline_diff accept/reject", function()
  local bufnr

  local function setup(lines, file)
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.api.nvim_set_current_buf(bufnr)
    InlineDiff.attach(bufnr, file, nil)
  end

  after_each(function()
    -- detach_all clears the per-path accepted-signature memo so signatures
    -- from one test don't filter out hunks attached by the next.
    InlineDiff.detach_all()
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("accept_hunk_at_cursor removes the hunk from state without mutating buffer", function()
    setup({ "keep", "new", "tail" }, {
      path = "x",
      type = "modify",
      hunks = {
        { new_start = 2, new_count = 1, old_lines = { "old" }, new_lines = { "new" } },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    InlineDiff.accept_hunk_at_cursor()
    assert.are.same({ "keep", "new", "tail" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    -- Detached because the only hunk was accepted.
    assert.are.same({}, InlineDiff.list_attached())
  end)

  it("reject_hunk_at_cursor restores old_lines into the buffer", function()
    setup({ "keep", "new", "tail" }, {
      path = "x",
      type = "modify",
      abspath = "/tmp/zz_inline_reject_test",
      hunks = {
        { new_start = 2, new_count = 1, old_lines = { "old" }, new_lines = { "new" } },
      },
    })
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    -- Avoid the silent! write side effect by clearing the buffer name.
    vim.api.nvim_buf_set_name(bufnr, "")
    vim.bo[bufnr].buftype = "nofile"
    InlineDiff.reject_hunk_at_cursor()
    assert.are.same({ "keep", "old", "tail" }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  end)
end)
