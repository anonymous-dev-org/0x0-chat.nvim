local Attribution = require("zxz.core.tool_attribution")

describe("tool attribution", function()
  it("uses top-level protocol tool ids", function()
    local id, source = Attribution.resolve({ toolCallId = "tool-protocol" }, "tool-active", {
      tool_calls = {
        { tool_call_id = "tool-active", status = "pending" },
      },
    })

    assert.are.equal("tool-protocol", id)
    assert.are.equal("protocol:toolCallId", source)
  end)

  it("uses nested protocol tool ids", function()
    local id, source = Attribution.resolve({ toolCall = { toolCallId = "tool-nested" } }, nil, nil)

    assert.are.equal("tool-nested", id)
    assert.are.equal("protocol:toolCall.toolCallId", source)
  end)

  it("falls back to the active tool only when exactly one live tool is attachable", function()
    local id, source = Attribution.resolve({}, "tool-active", {
      tool_calls = {
        { tool_call_id = "tool-active", status = "in_progress" },
        { tool_call_id = "tool-done", status = "completed" },
      },
    })

    assert.are.equal("tool-active", id)
    assert.are.equal("active", source)
  end)

  it("does not fall back when multiple live tools are attachable", function()
    local id, source = Attribution.resolve({}, "tool-active", {
      tool_calls = {
        { tool_call_id = "tool-active", status = "in_progress" },
        { tool_call_id = "tool-other", status = "pending" },
      },
    })

    assert.is_nil(id)
    assert.are.equal("ambiguous_active", source)
  end)

  it("does not fall back to terminal active tools", function()
    local id, source = Attribution.resolve({}, "tool-done", {
      tool_calls = {
        { tool_call_id = "tool-done", status = "completed" },
      },
    })

    assert.is_nil(id)
    assert.are.equal("unattributed", source)
  end)
end)
