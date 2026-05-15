-- Minimal init for headless test runs. Bootstraps plenary into a
-- per-checkout cache so CI and local runs are reproducible without a
-- global plugin manager.

local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
local cache_dir = plugin_root .. "/.cache"
local plenary_path = cache_dir .. "/plenary.nvim"
local swap_dir = cache_dir .. "/swap"

if vim.fn.isdirectory(plenary_path) == 0 then
  vim.fn.mkdir(cache_dir, "p")
  local out = vim.fn.system({
    "git",
    "clone",
    "--depth=1",
    "https://github.com/nvim-lua/plenary.nvim",
    plenary_path,
  })
  if vim.v.shell_error ~= 0 then
    error("failed to clone plenary.nvim: " .. tostring(out))
  end
end

vim.opt.runtimepath:prepend(plenary_path)
vim.opt.runtimepath:prepend(plugin_root)
package.path = plugin_root .. "/lua/?.lua;" .. plugin_root .. "/lua/?/init.lua;" .. package.path
vim.fn.mkdir(swap_dir, "p")
vim.opt.directory = swap_dir .. "//"
vim.opt.swapfile = false
vim.opt.updatecount = 0
vim.api.nvim_create_autocmd({ "BufNewFile", "BufReadPre" }, {
  callback = function()
    vim.opt_local.swapfile = false
  end,
})

vim.cmd("runtime plugin/plenary.vim")
require("plenary.busted")
