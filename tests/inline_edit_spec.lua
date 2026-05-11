local InlineEdit = require("zxz.edit.inline_edit")

describe("inline_edit", function()
  local bufnr

  before_each(function()
    bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
      "line 1",
      "line 2",
      "line 3",
      "line 4",
      "line 5",
    })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vim.bo[bufnr].filetype = "" -- no parser → forces line fallback
  end)

  after_each(function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end
  end)

  it("falls back to current line when no parser is available", function()
    local scope = InlineEdit._resolve_scope(bufnr, "n", nil)
    assert.are.equal("line", scope.scope_kind)
    assert.are.equal(3, scope.start_line)
    assert.are.equal(3, scope.end_line)
    assert.are.equal(1, #scope.lines)
    assert.are.equal("line 3", scope.lines[1])
  end)

  it("uses the visual range when provided", function()
    local scope = InlineEdit._resolve_scope(bufnr, "v", { start_line = 2, end_line = 4 })
    assert.are.equal("selection", scope.scope_kind)
    assert.are.equal(2, scope.start_line)
    assert.are.equal(4, scope.end_line)
    assert.are.equal(3, #scope.lines)
  end)

  it("formats the prompt per the A1 template", function()
    local scope = {
      rel_path = "foo/bar.lua",
      start_line = 10,
      end_line = 12,
      filetype = "lua",
      scope_kind = "function",
      scope_name = "M.greet",
      lines = { "function M.greet(n)", "  return 'hi ' .. n", "end" },
    }
    local prompt = InlineEdit._build_prompt(scope, "make it shout")
    assert.is_truthy(prompt:find("Target file: foo/bar.lua", 1, true))
    assert.is_truthy(prompt:find("Range: lines 10-12 (function: M.greet)", 1, true))
    assert.is_truthy(prompt:find("```lua", 1, true))
    assert.is_truthy(prompt:find("function M.greet(n)", 1, true))
    assert.is_truthy(prompt:find("Constraints:", 1, true))
    assert.is_truthy(prompt:find("Instruction: make it shout", 1, true))
  end)
end)
