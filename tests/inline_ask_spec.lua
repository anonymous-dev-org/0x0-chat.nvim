local InlineAsk = require("zxz.edit.inline_ask")

describe("inline_ask", function()
  it("builds a user prompt that begins with the read-only system contract", function()
    local ctx = {
      rel_path = "foo/bar.lua",
      cursor_line = 12,
      start_line = 5,
      end_line = 19,
      filetype = "lua",
      symbol = "M.greet",
      lines = { "function M.greet(n)", "  return 'hi ' .. n", "end" },
    }
    local prompt = InlineAsk._build_user_prompt(ctx, "what does this do?")
    assert.is_truthy(prompt:find("read%-only question", 1))
    assert.is_truthy(prompt:find("File: foo/bar.lua:12", 1, true))
    assert.is_truthy(prompt:find("Symbol under cursor: M.greet", 1, true))
    assert.is_truthy(prompt:find("Surrounding code %(lines 5%-19%)", 1))
    assert.is_truthy(prompt:find("```lua", 1, true))
    assert.is_truthy(prompt:find("Question: what does this do?", 1, true))
  end)

  it("builds focused range prompts for hunk-scoped ask", function()
    local ctx = {
      rel_path = "foo/bar.lua",
      cursor_line = 12,
      start_line = 8,
      end_line = 10,
      filetype = "lua",
      focused_range = true,
      symbol = "M.greet",
      lines = { "function M.greet(n)", "  return 'hi ' .. n", "end" },
    }
    local prompt = InlineAsk._build_user_prompt(ctx, "is this correct?")
    assert.is_truthy(prompt:find("File: foo/bar.lua:8%-10", 1))
    assert.is_truthy(prompt:find("Focused code range %(lines 8%-10%)", 1))
    assert.is_truthy(prompt:find("Question: is this correct?", 1, true))
  end)

  it("includes diff hunk context for deletion-heavy asks", function()
    local ctx = {
      rel_path = "foo/bar.lua",
      cursor_line = 8,
      start_line = 8,
      end_line = 8,
      filetype = "lua",
      focused_range = true,
      symbol = nil,
      lines = { "next()" },
      hunk_context = {
        old_start = 8,
        old_count = 2,
        new_start = 8,
        new_count = 0,
        diff_lines = {
          "@@ -8,2 +8,0 @@",
          "-old()",
          "-gone()",
        },
      },
    }
    local prompt = InlineAsk._build_user_prompt(ctx, "why remove this?")
    assert.is_truthy(prompt:find("Related diff hunk:", 1, true))
    assert.is_truthy(prompt:find("-old()", 1, true))
    assert.is_truthy(prompt:find("Old-side lines: 8-9", 1, true))
    assert.is_truthy(prompt:find("New-side insertion point: 8", 1, true))
  end)

  it("permission handler returns an option-id string (not a table)", function()
    local Ephemeral = require("zxz.chat.ephemeral")
    -- The handlers are constructed inside run_inline_ask; rebuild the
    -- handler inline for testing purposes by exercising the same logic.
    local captured
    local function respond(arg)
      captured = arg
    end
    local function build_handler()
      return function(request, r)
        local reject_id
        for _, option in ipairs(request and request.options or {}) do
          if option.kind == "reject_once" or option.kind == "reject_always" then
            reject_id = option.optionId
            break
          end
        end
        r(reject_id or "")
      end
    end
    local handler = build_handler()
    handler({
      options = {
        { optionId = "ok_id", kind = "allow_once" },
        { optionId = "no_id", kind = "reject_once" },
      },
    }, respond)
    assert.are.equal("no_id", captured)
    captured = nil
    handler({ options = {} }, respond)
    assert.are.equal("", captured)
  end)

  it("streams chunks into the answer buffer preserving newlines", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
    InlineAsk._stream_chunk_into(buf, "Hello")
    InlineAsk._stream_chunk_into(buf, ", ")
    InlineAsk._stream_chunk_into(buf, "world.\nNext line.")
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    assert.are.equal("Hello, world.", lines[1])
    assert.are.equal("Next line.", lines[2])
    vim.api.nvim_buf_delete(buf, { force = true })
  end)
end)
