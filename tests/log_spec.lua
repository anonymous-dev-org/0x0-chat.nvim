local helpers = require("tests.helpers")

describe("log", function()
  local saved_state, tmp

  before_each(function()
    -- Redirect stdpath("state") to a tempdir so we don't pollute the user's
    -- real ~/.local/state.
    tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    saved_state = vim.fn.stdpath("state")
    vim.env.XDG_STATE_HOME = tmp
    -- Reload the module so it re-resolves stdpath.
    package.loaded["zeroxzero.log"] = nil
  end)

  after_each(function()
    helpers.cleanup(tmp)
    vim.env.XDG_STATE_HOME = nil
    package.loaded["zeroxzero.log"] = nil
  end)

  it("appends timestamped lines at each level", function()
    local log = require("zeroxzero.log")
    log.error("boom", { code = 7 })
    log.warn("careful")
    log.info("hi")
    log.debug("trace")
    local content = helpers.read_file(log.path())
    assert.is_truthy(content)
    assert.is_truthy(content:find("%[ERROR%] boom"))
    assert.is_truthy(content:find("%[WARN%] careful"))
    assert.is_truthy(content:find("%[INFO%] hi"))
    assert.is_truthy(content:find("%[DEBUG%] trace"))
    -- inspect-formatted tables get serialized into the line
    assert.is_truthy(content:find("code = 7"))
  end)
end)
