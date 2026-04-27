local config = require("zeroxzero.config")

local M = {}

---@param opts? table
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("ZeroChat", function()
    require("zeroxzero.chat").toggle()
  end, { desc = "Toggle the 0x0 chat panel for the current tab" })

  vim.api.nvim_create_user_command("ZeroChatNew", function()
    require("zeroxzero.chat").new()
  end, { desc = "Reset the chat session and clear the buffer" })

  vim.api.nvim_create_user_command("ZeroChatSubmit", function()
    require("zeroxzero.chat").submit()
  end, { desc = "Submit the pending prompt to the active session" })

  vim.api.nvim_create_user_command("ZeroChatCancel", function()
    require("zeroxzero.chat").cancel()
  end, { desc = "Cancel the in-flight prompt" })

  vim.api.nvim_create_user_command("ZeroChatDiff", function()
    require("zeroxzero.chat").diff()
  end, { desc = "Show the full diff for the latest 0x0 chat turn" })

  vim.api.nvim_create_user_command("ZeroChatAcceptAll", function()
    require("zeroxzero.chat").accept_all()
  end, { desc = "Accept all changes from the 0x0 chat worktree" })

  vim.api.nvim_create_user_command("ZeroChatDiscardAll", function()
    require("zeroxzero.chat").discard_all()
  end, { desc = "Discard all changes from the 0x0 chat worktree" })

  vim.api.nvim_create_user_command("ZeroChatStop", function()
    require("zeroxzero.chat").stop()
    vim.notify("acp: stopped", vim.log.levels.INFO)
  end, { desc = "Stop the ACP provider and drop the session" })

  vim.api.nvim_create_user_command("ZeroChatSettings", function()
    require("zeroxzero.settings").open()
  end, { desc = "Pick the chat provider / model" })
end

return M
