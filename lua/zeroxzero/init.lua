local config = require("zeroxzero.config")

local M = {}

local function complete_files(arglead)
  return require("zeroxzero.util").file_candidates(arglead)
end

---@param opts? table
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("ZeroChat", function()
    require("zeroxzero.chat").open()
  end, { desc = "Open 0x0 chat" })

  vim.api.nvim_create_user_command("ZeroChatNew", function()
    require("zeroxzero.chat").new()
  end, { desc = "Start a new 0x0 chat" })

  vim.api.nvim_create_user_command("ZeroChatOpen", function(command_opts)
    require("zeroxzero.chat").open_session(command_opts.args)
  end, { nargs = 1, desc = "Open an existing 0x0 chat session" })

  vim.api.nvim_create_user_command("ZeroChatSubmit", function()
    require("zeroxzero.chat").submit()
  end, { desc = "Submit current 0x0 chat prompt" })

  vim.api.nvim_create_user_command("ZeroChatSettings", function()
    require("zeroxzero.settings").open()
  end, { desc = "Configure 0x0 chat" })

  vim.api.nvim_create_user_command("ZeroInlineEdit", function(command_opts)
    require("zeroxzero.inline").edit(command_opts)
  end, { range = true, desc = "Ask 0x0 for a one-shot inline edit" })

  vim.api.nvim_create_user_command("ZeroReview", function()
    require("zeroxzero.review").open()
  end, { desc = "Review 0x0 agent changes" })

  vim.api.nvim_create_user_command("ZeroAcceptAll", function()
    require("zeroxzero.review").accept_all()
  end, { desc = "Accept all 0x0 agent changes" })

  vim.api.nvim_create_user_command("ZeroDiscardAll", function()
    require("zeroxzero.review").discard_all()
  end, { desc = "Discard all 0x0 agent changes" })

  vim.api.nvim_create_user_command("ZeroAcceptFile", function(command_opts)
    require("zeroxzero.review").accept_file(command_opts.args)
  end, { nargs = 1, complete = complete_files, desc = "Accept a 0x0 agent file change" })

  vim.api.nvim_create_user_command("ZeroDiscardFile", function(command_opts)
    require("zeroxzero.review").discard_file(command_opts.args)
  end, { nargs = 1, complete = complete_files, desc = "Discard a 0x0 agent file change" })

  vim.api.nvim_create_user_command("ZeroChangesStatus", function()
    require("zeroxzero.review").status()
  end, { desc = "Refresh 0x0 agent change status" })

  vim.api.nvim_create_user_command("ZeroCancel", function()
    require("zeroxzero.chat").cancel()
  end, { desc = "Cancel the active 0x0 run" })

  vim.api.nvim_create_user_command("ZeroClose", function()
    require("zeroxzero.client").close()
  end, { desc = "Close the 0x0 websocket" })
end

return M
