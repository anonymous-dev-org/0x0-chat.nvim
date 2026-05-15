local InlineEdit = require("zxz.edit.inline_edit")
local Agents = require("zxz.agents")

describe("zxz.edit.inline_edit.build_prompt", function()
  it("emits a single-string prompt with fenced region and instruction", function()
    local p = InlineEdit.build_prompt({
      filename = "/tmp/foo.lua",
      filetype = "lua",
      region = "local x = 1",
      range = { start_line = 5, end_line = 5 },
      instruction = "rename x to count",
    })
    assert.is_truthy(p:match("/tmp/foo%.lua"))
    assert.is_truthy(p:match("lua"))
    assert.is_truthy(p:match("Region to edit %(lines 5%-5%)"))
    assert.is_truthy(p:match("rename x to count"))
    assert.is_truthy(p:match("```lua\nlocal x = 1\n```"))
    assert.is_truthy(p:match("ONLY"))
  end)

  it("handles missing filetype/filename gracefully", function()
    local p = InlineEdit.build_prompt({
      filename = "",
      filetype = "",
      region = "hi",
      range = { start_line = 1, end_line = 1 },
      instruction = "make it loud",
    })
    assert.is_truthy(p:match("<scratch>"))
    assert.is_truthy(p:match("plain"))
  end)
end)

describe("zxz.edit.inline_edit.clean_response", function()
  it("strips a wrapping ```lang ... ``` fence", function()
    local cleaned = InlineEdit.clean_response("```lua\nlocal x = 2\nreturn x\n```\n")
    assert.equals("local x = 2\nreturn x", cleaned)
  end)

  it("leaves nested fences intact", function()
    local input = "outer\n```\ninner\n```\ntail"
    assert.equals(input, InlineEdit.clean_response(input))
  end)

  it("trims surrounding blank lines", function()
    assert.equals("hello", InlineEdit.clean_response("\n\nhello\n\n"))
  end)
end)

describe("zxz.edit.inline_edit.invoke_agent", function()
  before_each(function()
    -- Fake "agent" that just cats stdin → stdout. Verifies the prompt round-trips.
    Agents.register("echobot", {
      cmd = { "cat" },
      headless_cmd = { "cat" },
    })
  end)

  it("captures stdout from the headless agent and runs the callback", function()
    local got_text, got_err
    InlineEdit.invoke_agent("echobot", "hello\nworld", function(text, err)
      got_text = text
      got_err = err
    end)
    vim.wait(2000, function()
      return got_text ~= nil or got_err ~= nil
    end)
    assert.is_nil(got_err)
    assert.equals("hello\nworld", got_text)
  end)

  it("reports an error when the agent CLI is missing", function()
    Agents.register("nope", {
      cmd = { "does-not-exist-zxz" },
      headless_cmd = { "does-not-exist-zxz" },
    })
    local got_err
    InlineEdit.invoke_agent("nope", "x", function(_, err)
      got_err = err
    end)
    vim.wait(200, function()
      return got_err ~= nil
    end)
    assert.is_truthy(got_err)
    assert.is_truthy(got_err:match("not on PATH"))
  end)
end)
