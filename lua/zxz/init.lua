---0x0.nvim: workflow shell around agentic.nvim + vim-fugitive.

local M = {}

---@param opts? table
---  - `commands`: passed through to `zxz.commands.setup` (set to `false` to
---    skip user-command + keymap registration)
function M.setup(opts)
  opts = opts or {}

  if opts.commands ~= false then
    require("zxz.commands").setup(opts.commands or {})
  end
end

return M
