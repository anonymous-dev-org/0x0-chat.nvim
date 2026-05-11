local Registry = require("zeroxzero.run_registry")
local config = require("zeroxzero.config")

describe("run_registry", function()
  it("rejects spawn with an empty prompt", function()
    local id, err = Registry.spawn({ prompt = "" })
    assert.is_nil(id)
    assert.is_truthy(err)
  end)

  it("rejects spawn when no run is supplied a provider that resolves", function()
    -- A nonexistent provider name short-circuits resolve_provider.
    local prev = config.current.provider
    config.current.provider = "does-not-exist"
    local id, err = Registry.spawn({ prompt = "hi" })
    assert.is_nil(id)
    assert.is_truthy(err)
    config.current.provider = prev
  end)

  it("list() is empty when no detached runs are active", function()
    -- After the failing spawns above, registry should be empty.
    assert.are.equal(0, #Registry.list())
  end)
end)

describe("fs_bridge.resolve_path", function()
  local FsBridge = require("zeroxzero.chat.fs_bridge")

  it("returns absolute paths as-is", function()
    assert.are.equal("/abs/path/file.lua", FsBridge.resolve_path("/repo", "/abs/path/file.lua"))
  end)

  it("joins relative paths onto repo_root", function()
    assert.are.equal("/repo/src/foo.lua", FsBridge.resolve_path("/repo", "src/foo.lua"))
  end)

  it("returns nil when no repo_root and path is relative", function()
    assert.is_nil(FsBridge.resolve_path(nil, "src/foo.lua"))
  end)

  it("returns nil for empty / nil paths", function()
    assert.is_nil(FsBridge.resolve_path("/repo", ""))
    assert.is_nil(FsBridge.resolve_path("/repo", nil))
  end)
end)
