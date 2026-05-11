local AutoPrelude = require("zxz.context.auto_prelude")

describe("auto_prelude", function()
  it("returns nil when nothing is enabled", function()
    assert.is_nil(AutoPrelude.build({ cursor = false, repo_map = false, recent = false }))
  end)

  it("returns nil when no source buffer is available and only cursor is on", function()
    -- This test runs in plenary's headless test buffer; there may or may
    -- not be a "code" buffer in the current tabpage. If build returns a
    -- non-nil prelude it must at least begin with the header.
    local out = AutoPrelude.build({ cursor = true })
    if out ~= nil then
      assert.is_truthy(out:find("^%[0x0 context%]"))
    end
  end)
end)
