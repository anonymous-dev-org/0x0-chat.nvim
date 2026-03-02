local M = {}

---@param opts? table
function M.setup(opts)
  local config = require("zeroxzero.config")
  config.setup(opts)

  local cfg = config.current
  local km = cfg.keymaps

  -- Statusline setup
  require("zeroxzero.ui.statusline")._setup()

  -- Highlights
  require("zeroxzero.render").setup_highlights()
  vim.api.nvim_set_hl(0, "ZeroInlineWorking", { link = "DiffChange", default = true })

  -- Keymaps
  if km.toggle and km.toggle ~= "" then
    vim.keymap.set("n", km.toggle, function()
      M.toggle()
    end, { desc = "0x0: Toggle chat" })
  end

  if km.context and km.context ~= "" then
    vim.keymap.set("n", km.context, function()
      M.context()
    end, { desc = "0x0: Add file to context" })
    vim.keymap.set("v", km.context, function()
      M.context_visual()
    end, { desc = "0x0: Add selection to context" })
  end

  if km.session and km.session ~= "" then
    vim.keymap.set("n", km.session, function()
      M.session()
    end, { desc = "0x0: Session picker" })
  end

  if km.interrupt and km.interrupt ~= "" then
    vim.keymap.set("n", km.interrupt, function()
      M.interrupt()
    end, { desc = "0x0: Interrupt" })
  end

  if km.model and km.model ~= "" then
    vim.keymap.set("n", km.model, function()
      M.model()
    end, { desc = "0x0: Model picker" })
  end

  if km.inline_edit and km.inline_edit ~= "" then
    vim.keymap.set("n", km.inline_edit, function()
      M.inline_edit()
    end, { desc = "0x0: Inline edit" })
    vim.keymap.set("v", km.inline_edit, function()
      M.inline_edit_visual()
    end, { desc = "0x0: Inline edit with selection" })
  end

  -- Autocommands
  local group = vim.api.nvim_create_augroup("zeroxzero", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      require("zeroxzero.server").stop()
    end,
  })
end

-- Chat

function M.toggle()
  require("zeroxzero.chat").toggle()
end

-- Context

function M.context()
  local context = require("zeroxzero.context")
  local ref = context.file_ref()
  if not ref then
    vim.notify("0x0: no file open", vim.log.levels.WARN)
    return
  end
  require("zeroxzero.chat").add_context(ref)
end

function M.context_visual()
  local context = require("zeroxzero.context")
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)
  local ref = context.file_ref(nil, { include_selection = true })
  if not ref then
    vim.notify("0x0: no file open", vim.log.levels.WARN)
    return
  end
  require("zeroxzero.chat").add_context(ref)
end

-- Session

function M.session()
  require("zeroxzero.ui.picker").session_picker()
end

function M.interrupt()
  require("zeroxzero.chat").interrupt()
end

-- Model

function M.model()
  require("zeroxzero.ui.picker").model_picker()
end

-- Inline edit

function M.inline_edit()
  require("zeroxzero.inline_edit").edit()
end

function M.inline_edit_visual()
  require("zeroxzero.inline_edit").edit_visual()
end

-- Statusline

---@return string
function M.statusline()
  return require("zeroxzero.ui.statusline").get()
end

return M
