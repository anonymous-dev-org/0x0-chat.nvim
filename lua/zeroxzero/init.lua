local config = require("zeroxzero.config")

local M = {}

---@param opts? table
function M.setup(opts)
  config.setup(opts)

  vim.api.nvim_create_user_command("ZeroChat", function(opts)
    local chat = require("zeroxzero.chat")
    if opts.range and opts.range > 0 then
      local bufnr = vim.api.nvim_get_current_buf()
      local start_line = opts.line1
      local end_line = opts.line2
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
      local path = vim.api.nvim_buf_get_name(bufnr)
      if path ~= "" then
        path = vim.fn.fnamemodify(path, ":~:.")
      end
      chat.add_selection({
        path = path,
        filetype = vim.bo[bufnr].filetype,
        start_line = start_line,
        end_line = end_line,
        lines = lines,
      })
      return
    end
    chat.toggle()
  end, {
    desc = "Toggle the 0x0 chat panel; with a range, attach the selection to the prompt",
    range = true,
  })

  vim.api.nvim_create_user_command("ZeroChatNew", function()
    require("zeroxzero.chat").new()
  end, { desc = "Reset the chat session and clear the buffer" })

  vim.api.nvim_create_user_command("ZeroChatSubmit", function()
    require("zeroxzero.chat").submit()
  end, { desc = "Submit the pending prompt to the active session" })

  vim.api.nvim_create_user_command("ZeroChatCancel", function()
    require("zeroxzero.chat").cancel()
  end, { desc = "Cancel the in-flight prompt" })

  vim.api.nvim_create_user_command("ZeroChatChanges", function()
    require("zeroxzero.chat").changes()
  end, { desc = "List files changed since the active 0x0 checkpoint" })

  vim.api.nvim_create_user_command("ZeroChatReview", function()
    require("zeroxzero.chat").review()
  end, { desc = "Review chat changes in vimdiff against the turn checkpoint" })

  vim.api.nvim_create_user_command("ZeroChatAddFile", function()
    require("zeroxzero.chat").add_current_file()
  end, { desc = "Add the current file to the pending chat prompt" })

  vim.api.nvim_create_user_command("ZeroChatAddHunk", function()
    require("zeroxzero.chat").add_current_hunk()
  end, { desc = "Add the current 0x0 diff hunk to the pending chat prompt" })

  vim.api.nvim_create_user_command("ZeroChatAddSelection", function()
    require("zeroxzero.chat").add_visual_selection_from_prev()
  end, { desc = "Attach the last visual selection from the prior window as a line-range mention" })

  vim.api.nvim_create_user_command("ZeroChatDiff", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zeroxzero.chat").diff(id)
  end, { desc = "Show the turn diff (or per-tool diff with an id)", nargs = "?" })

  vim.api.nvim_create_user_command("ZeroChatAcceptAll", function()
    require("zeroxzero.chat").accept_all()
  end, { desc = "Accept all pending chat changes and clear the checkpoint" })

  vim.api.nvim_create_user_command("ZeroChatDiscardAll", function()
    require("zeroxzero.chat").discard_all()
  end, { desc = "Discard all pending chat changes (restore from checkpoint)" })

  vim.api.nvim_create_user_command("ZeroChatStop", function()
    require("zeroxzero.chat").stop()
    vim.notify("acp: stopped", vim.log.levels.INFO)
  end, { desc = "Stop the ACP provider and drop the session" })

  vim.api.nvim_create_user_command("ZeroChatSettings", function()
    require("zeroxzero.settings").open()
  end, { desc = "Pick the chat provider / model" })

  vim.api.nvim_create_user_command("ZeroChatHistory", function()
    require("zeroxzero.chat").history_picker()
  end, { desc = "Pick a saved chat thread to restore" })

  vim.api.nvim_create_user_command("ZeroChatLog", function()
    require("zeroxzero.log").open()
  end, { desc = "Open the 0x0 chat debug log" })
end

return M
