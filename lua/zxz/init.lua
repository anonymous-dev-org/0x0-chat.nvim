---0x0.nvim: thin facade.
---
---Two products live here:
---  1. Inline ghost-text completion  (lua/zxz/complete/)
---  2. Agent-in-a-worktree workflow  (lua/zxz/{worktree,terminal,review,
---     context_share,commands,agents}.lua)
---
---Everything else (chat UI, ACP-as-chat, runs registry, edit-action palette,
---context picker, repo map, profiles, etc.) was deleted in the
---terminal+worktree refactor; the agent CLI provides those surfaces inside its
---own `:terminal` window now.

local config = require("zxz.core.config")
local paths = require("zxz.core.paths")

local M = {}

---@param opts? table
---  - `complete`: passed through to `zxz.complete.setup`
---  - `commands`: passed through to `zxz.commands.setup` (set to `false` to
---    skip user-command + keymap registration)
function M.setup(opts)
  opts = opts or {}
  paths.migrate_legacy()
  config.setup(opts)

  -- Inline ghost-text completion. Reads its config from config.current.complete.
  pcall(function()
    require("zxz.complete").setup(opts.complete)
  end)
  vim.api.nvim_create_user_command("ZxzCompleteSettings", function()
    require("zxz.complete").settings()
  end, { desc = "zxz: inline completion settings" })

  -- Agent-in-a-worktree commands + context-share keymaps.
  if opts.commands ~= false then
    require("zxz.commands").setup(opts.commands or {})
  end
end

return M
