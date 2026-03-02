local M = {}

function M.check()
  vim.health.start("zeroxzero")

  -- Check Neovim version
  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim >= 0.10")
  else
    vim.health.error("Neovim >= 0.10 required")
  end

  -- Check curl
  if vim.fn.executable("curl") == 1 then
    vim.health.ok("curl found")
  else
    vim.health.error("curl not found in PATH")
  end

  -- Check server binary
  local config = require("zeroxzero.config")
  local cmd = config.current.cmd
  if vim.fn.executable(cmd) == 1 then
    vim.health.ok(cmd .. " found")
  elseif vim.fn.executable("0x0") == 1 then
    vim.health.ok("0x0 found (fallback)")
  else
    vim.health.error(cmd .. " not found in PATH", {
      "Install 0x0-server: https://github.com/anthropics/0x0",
      "Or set cmd in setup(): require('zeroxzero').setup({ cmd = '/path/to/0x0-server' })",
    })
  end

  -- Check server connectivity
  local server = require("zeroxzero.server")
  if server.connected then
    local port = config.current.port
    vim.health.ok("Connected to 0x0 server on port " .. port)
  else
    vim.health.info("Not connected to 0x0 server (use :ZeroSend or :ZeroInlineEdit to connect)")
  end
end

return M
