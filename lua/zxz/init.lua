---0x0.nvim: inline ghost-text completion.

local config = require("zxz.core.config")
local paths = require("zxz.core.paths")

local M = {}

---@param opts? table
---  - `complete`: passed through to `zxz.complete.setup`
function M.setup(opts)
  opts = opts or {}
  paths.migrate_legacy()
  config.setup(opts)

  require("zxz.complete").setup(opts.complete)

  vim.api.nvim_create_user_command("ZxzCompleteSettings", function()
    require("zxz.complete").settings()
  end, { desc = "zxz: inline completion settings" })
end

return M
