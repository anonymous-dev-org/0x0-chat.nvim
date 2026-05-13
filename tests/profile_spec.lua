local config = require("zxz.core.config")
local profiles = require("zxz.core.profiles")

describe("agent profiles", function()
  before_each(function()
    config.setup()
  end)

  it("applies the default write profile during setup", function()
    assert.are.equal("write", config.current.profile)
    assert.same({ "read" }, config.current.tool_policy.auto_approve)
  end)

  it("switches to read-only ask policy", function()
    local ok, err = profiles.set("ask")
    assert.is_true(ok, tostring(err))
    assert.are.equal("ask", config.current.profile)
    assert.same({ "write", "shell" }, config.current.tool_policy.deny)
  end)

  it("does not overwrite explicit setup tool_policy", function()
    config.setup({
      tool_policy = {
        auto_approve = { "read", "write" },
        auto_approve_paths = { "docs/" },
      },
    })
    assert.same({ "read", "write" }, config.current.tool_policy.auto_approve)
    assert.same({ "docs/" }, config.current.tool_policy.auto_approve_paths)
  end)

  it("rejects unknown profiles", function()
    local ok, err = profiles.set("missing")
    assert.is_false(ok)
    assert.is_truthy(err:find("unknown profile", 1, true))
  end)

  it("resolves completion provider from the shared provider table", function()
    local provider = assert(config.resolve_completion_provider())
    assert.are.equal("codex-acp", provider.command)
    assert.are.same({ "-c", "notify=[]" }, provider.args)
    assert.are.equal("chatgpt", provider.auth_method)
  end)

  it("resolves explicit completion ACP command overrides", function()
    config.setup({
      complete = {
        provider = "codex-acp",
        acp = {
          command = "custom-acp",
          args = { "--stdio" },
        },
      },
    })
    local provider = assert(config.resolve_completion_provider())
    assert.are.equal("custom-acp", provider.command)
    assert.are.same({ "--stdio" }, provider.args)
  end)
end)
