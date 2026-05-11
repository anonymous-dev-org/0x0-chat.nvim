local helpers = require("tests.helpers")
local TestCommand = require("zeroxzero.context.test_command")
local config = require("zeroxzero.config")

describe("test_command detection", function()
  local root

  after_each(function()
    if root then
      helpers.cleanup(root)
      root = nil
    end
    config.current.test_command = nil
  end)

  it("respects an explicit config.test_command override", function()
    config.current.test_command = "my-custom-test"
    root = vim.loop.fs_realpath(helpers.make_repo({ ["foo.txt"] = "x" }))
    assert.are.equal("my-custom-test", TestCommand.resolve(root))
  end)

  it("detects bun test from package.json with a test script", function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["package.json"] = '{"name":"x","scripts":{"test":"echo hi"}}',
    }))
    assert.are.equal("bun run test", TestCommand.resolve(root))
  end)

  it("detects make test from a Makefile with a test target", function()
    root = vim.loop.fs_realpath(helpers.make_repo({
      ["Makefile"] = "test:\n\techo hi\n",
    }))
    assert.are.equal("make test", TestCommand.resolve(root))
  end)

  it("returns nil for a repo with no recognizable test config", function()
    root = vim.loop.fs_realpath(helpers.make_repo({ ["foo.txt"] = "x" }))
    assert.is_nil(TestCommand.resolve(root))
  end)
end)
