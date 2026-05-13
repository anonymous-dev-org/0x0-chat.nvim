local Registry = require("zxz.core.run_registry")
local config = require("zxz.core.config")
local Checkpoint = require("zxz.core.checkpoint")
local RunActions = require("zxz.chat.run_actions")
local RunsStore = require("zxz.core.runs_store")
local helpers = require("tests.helpers")

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

describe("saved run actions", function()
  local root
  local run_ids = {}
  local saved_runs = {}
  local load_run = RunsStore.load
  local save_run_record = RunsStore.save
  local delete_run = RunsStore.delete

  local function save_run(file_content)
    root = vim.loop.fs_realpath(helpers.make_repo({ ["a.txt"] = "base\n" }))
    local start_cp = assert(Checkpoint.snapshot(root))
    helpers.write_file(root .. "/a.txt", file_content)
    local end_cp = assert(Checkpoint.snapshot(root, { parent_sha = start_cp.sha }))
    local id = ("run-actions-%d-%d"):format(#run_ids + 1, math.random(1, 1000000))
    run_ids[#run_ids + 1] = id
    saved_runs[id] = {
      run_id = id,
      root = root,
      start_sha = start_cp.sha,
      end_sha = end_cp.sha,
      files_touched = { "a.txt" },
      status = "completed",
    }
    return id
  end

  before_each(function()
    saved_runs = {}
    RunsStore.load = function(id)
      return saved_runs[id]
    end
    RunsStore.save = function(run)
      saved_runs[run.run_id] = run
    end
    RunsStore.delete = function(id)
      saved_runs[id] = nil
    end
  end)

  after_each(function()
    for _, id in ipairs(run_ids) do
      RunsStore.delete(id)
    end
    run_ids = {}
    saved_runs = {}
    RunsStore.load = load_run
    RunsStore.save = save_run_record
    RunsStore.delete = delete_run
    helpers.cleanup(root)
    root = nil
  end)

  it("refuses whole-run accept when the worktree changed after the run", function()
    local id = save_run("agent\n")
    helpers.write_file(root .. "/a.txt", "user\n")

    local ok = RunActions.run_accept({}, id)

    assert.is_false(ok)
    assert.are.equal("user\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal("completed", RunsStore.load(id).status)
  end)

  it("refuses whole-run reject when the worktree changed after the run", function()
    local id = save_run("agent\n")
    helpers.write_file(root .. "/a.txt", "user\n")

    local ok = RunActions.run_reject({}, id)

    assert.is_false(ok)
    assert.are.equal("user\n", helpers.read_file(root .. "/a.txt"))
    assert.are.equal("completed", RunsStore.load(id).status)
  end)
end)

describe("fs_bridge.resolve_path", function()
  local FsBridge = require("zxz.chat.fs_bridge")

  it("returns absolute paths inside the repo", function()
    assert.are.equal("/repo/src/file.lua", FsBridge.resolve_path("/repo", "/repo/src/file.lua"))
  end)

  it("joins relative paths onto repo_root", function()
    assert.are.equal("/repo/src/foo.lua", FsBridge.resolve_path("/repo", "src/foo.lua"))
  end)

  it("rejects absolute paths outside repo_root", function()
    assert.is_nil(FsBridge.resolve_path("/repo", "/tmp/file.lua"))
  end)

  it("rejects relative paths that escape repo_root", function()
    assert.is_nil(FsBridge.resolve_path("/repo", "../outside.lua"))
  end)

  it("returns nil when no repo_root and path is relative", function()
    assert.is_nil(FsBridge.resolve_path(nil, "src/foo.lua"))
  end)

  it("returns nil when no repo_root and path is absolute", function()
    assert.is_nil(FsBridge.resolve_path(nil, "/repo/src/foo.lua"))
  end)

  it("returns nil for empty / nil paths", function()
    assert.is_nil(FsBridge.resolve_path("/repo", ""))
    assert.is_nil(FsBridge.resolve_path("/repo", nil))
  end)
end)
