local config = require("zeroxzero.config")

local M = {}

---@param opts? table
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("ZeroChat", function()
    require("zeroxzero.chat").open()
  end, { desc = "Open the 0x0 chat buffer" })

  vim.api.nvim_create_user_command("ZeroChatNew", function()
    require("zeroxzero.chat").new()
  end, { desc = "Reset the chat session and clear the buffer" })

  vim.api.nvim_create_user_command("ZeroChatSubmit", function()
    require("zeroxzero.chat").submit()
  end, { desc = "Submit the pending prompt to the active session" })

  vim.api.nvim_create_user_command("ZeroChatCancel", function()
    require("zeroxzero.chat").cancel()
  end, { desc = "Cancel the in-flight prompt" })

  vim.api.nvim_create_user_command("ZeroChatStop", function()
    require("zeroxzero.chat").stop()
    vim.notify("acp: stopped", vim.log.levels.INFO)
  end, { desc = "Stop the ACP provider and drop the session" })

  vim.api.nvim_create_user_command("ZeroChatSettings", function()
    require("zeroxzero.settings").open()
  end, { desc = "Pick the chat provider / model" })
end

return M
