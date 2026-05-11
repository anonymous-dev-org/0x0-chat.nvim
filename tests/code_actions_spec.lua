local CodeActions = require("zeroxzero.code_actions")
local config = require("zeroxzero.config")

describe("code_actions", function()
  it("ships the default action set", function()
    local actions = CodeActions._resolve_actions()
    assert.is_not_nil(actions["Explain"])
    assert.is_not_nil(actions["Write tests"])
    assert.is_not_nil(actions["Refactor"])
    assert.is_not_nil(actions["Add docstring"])
    assert.is_not_nil(actions["Find usages"])
    assert.is_not_nil(actions["Summarize file"])
  end)

  it("merges user-defined actions with defaults", function()
    local prev = config.current.code_actions
    config.current.code_actions = {
      ["My custom"] = { sink = "ask", template = "hi" },
    }
    local actions = CodeActions._resolve_actions()
    assert.is_not_nil(actions["Explain"])
    assert.is_not_nil(actions["My custom"])
    config.current.code_actions = prev
  end)

  it("user override of the same key wins", function()
    local prev = config.current.code_actions
    config.current.code_actions = {
      ["Explain"] = { sink = "edit", template = "explained differently" },
    }
    local actions = CodeActions._resolve_actions()
    assert.are.equal("edit", actions["Explain"].sink)
    assert.are.equal("explained differently", actions["Explain"].template)
    config.current.code_actions = prev
  end)
end)
