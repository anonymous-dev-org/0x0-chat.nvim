local M = {}

---@param opts? table
function M.setup(opts)
  local config = require("zeroxzero.config")
  config.setup(opts)

  local cfg = config.current
  local km = cfg.keymaps

  -- Statusline setup
  require("zeroxzero.ui.statusline")._setup()

  -- Highlights for inline edit
  vim.api.nvim_set_hl(0, "ZeroInlineWorking", { link = "DiffChange", default = true })
  vim.api.nvim_set_hl(0, "ZeroInlineMarker", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "ZeroInlineOriginal", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "ZeroInlineModified", { link = "DiffAdd", default = true })

  -- Keymaps

  if km.send and km.send ~= "" then
    vim.keymap.set("n", km.send, function()
      M.send()
    end, { desc = "0x0: Send file to TUI" })
    vim.keymap.set("v", km.send, function()
      M.send_visual()
    end, { desc = "0x0: Send selection to TUI" })
  end

  if km.send_message and km.send_message ~= "" then
    vim.keymap.set({ "n", "v" }, km.send_message, function()
      M.send_message()
    end, { desc = "0x0: Send with message to TUI" })
  end

  if km.diff and km.diff ~= "" then
    vim.keymap.set("n", km.diff, function()
      M.diff()
    end, { desc = "0x0: Review diff" })
  end

  if km.interrupt and km.interrupt ~= "" then
    vim.keymap.set("n", km.interrupt, function()
      M.interrupt()
    end, { desc = "0x0: Interrupt" })
  end

  if km.inline_edit and km.inline_edit ~= "" then
    vim.keymap.set("n", km.inline_edit, function()
      M.inline_edit()
    end, { desc = "0x0: Inline edit" })
    vim.keymap.set("v", km.inline_edit, function()
      M.inline_edit_visual()
    end, { desc = "0x0: Inline edit with selection" })
  end

  if km.inline_abort and km.inline_abort ~= "" then
    vim.keymap.set("n", km.inline_abort, function()
      M.inline_abort()
    end, { desc = "0x0: Abort inline edit" })
  end

  -- User commands
  vim.api.nvim_create_user_command("ZeroReview", function(cmd_opts)
    local session_id = cmd_opts.args ~= "" and cmd_opts.args or nil
    require("zeroxzero.diff").review({ session_id = session_id })
  end, {
    nargs = "?",
    desc = "0x0: Review session changes in diffview",
  })

  -- Autocommands
  local group = vim.api.nvim_create_augroup("zeroxzero", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("zeroxzero.server").stop()
    end,
  })
end

-- TUI bridge

function M.send()
  require("zeroxzero.tui").send_file()
end

function M.send_visual()
  require("zeroxzero.tui").send_selection()
end

function M.send_message()
  require("zeroxzero.tui").send_with_message()
end

-- Diff review

function M.diff()
  require("zeroxzero.diff").review()
end

-- Interrupt

function M.interrupt()
  local api = require("zeroxzero.api")
  api.execute_command("session_interrupt", function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    end
  end)
end

-- Inline edit

function M.inline_edit()
  require("zeroxzero.inline_edit").edit()
end

function M.inline_edit_visual()
  require("zeroxzero.inline_edit").edit_visual()
end

function M.inline_abort()
  require("zeroxzero.inline_edit").abort()
end

-- Statusline

---@return string
function M.statusline()
  return require("zeroxzero.ui.statusline").get()
end

return M
