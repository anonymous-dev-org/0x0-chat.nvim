local client = require("zeroxzero.client")
local config = require("zeroxzero.config")
local util = require("zeroxzero.util")

local M = {}

local api = vim.api

local function close_preview(state)
  if state.preview_win and api.nvim_win_is_valid(state.preview_win) then
    pcall(api.nvim_win_close, state.preview_win, true)
  end
  if state.preview_buf and api.nvim_buf_is_valid(state.preview_buf) then
    pcall(api.nvim_buf_delete, state.preview_buf, { force = true })
  end
  if state.source_win and api.nvim_win_is_valid(state.source_win) then
    vim.api.nvim_set_current_win(state.source_win)
    pcall(vim.cmd, "diffoff")
  end
end

local function build_preview_lines(state)
  local lines = api.nvim_buf_get_lines(state.source_buf, 0, -1, false)
  local replacement = util.split_lines(state.replacement)
  local preview = {}

  for i = 1, state.start_line - 1 do
    table.insert(preview, lines[i])
  end
  for _, line in ipairs(replacement) do
    table.insert(preview, line)
  end
  for i = state.end_line + 1, #lines do
    table.insert(preview, lines[i])
  end

  return preview
end

local function show_preview(state)
  if not api.nvim_buf_is_valid(state.source_buf) then
    util.notify("Source buffer no longer exists", vim.log.levels.ERROR)
    return
  end

  state.source_win = api.nvim_get_current_win()
  state.preview_buf = api.nvim_create_buf(false, true)
  api.nvim_buf_set_name(state.preview_buf, "[0x0 Inline Preview]")
  api.nvim_buf_set_option(state.preview_buf, "bufhidden", "wipe")
  api.nvim_buf_set_option(state.preview_buf, "filetype", api.nvim_buf_get_option(state.source_buf, "filetype"))
  api.nvim_buf_set_lines(state.preview_buf, 0, -1, false, build_preview_lines(state))

  vim.cmd("vsplit")
  state.preview_win = api.nvim_get_current_win()
  api.nvim_win_set_buf(state.preview_win, state.preview_buf)
  api.nvim_buf_set_option(state.preview_buf, "modifiable", false)

  vim.cmd("diffthis")
  api.nvim_set_current_win(state.source_win)
  vim.cmd("diffthis")
  api.nvim_set_current_win(state.preview_win)

  local function accept()
    util.replace_line_range(state.source_buf, state.start_line, state.end_line, state.replacement)
    close_preview(state)
    util.notify("Inline edit accepted")
  end

  local function reject()
    close_preview(state)
    util.notify("Inline edit discarded")
  end

  vim.keymap.set("n", "<CR>", accept, { buffer = state.preview_buf, silent = true, desc = "0x0 accept inline edit" })
  vim.keymap.set("n", "a", accept, { buffer = state.preview_buf, silent = true, desc = "0x0 accept inline edit" })
  vim.keymap.set("n", "q", reject, { buffer = state.preview_buf, silent = true, desc = "0x0 discard inline edit" })
  vim.keymap.set("n", "r", reject, { buffer = state.preview_buf, silent = true, desc = "0x0 discard inline edit" })
  util.notify("Inline preview: <CR>/a accept, q/r discard")
end

---@param opts table
function M.edit(opts)
  local selection = util.range_from_command(opts)
  local root = util.repo_root(selection.bufnr)
  local file = util.relative_path(selection.bufnr, root)

  if not file then
    util.notify("Inline edit requires a named file buffer", vim.log.levels.ERROR)
    return
  end

  vim.ui.input({ prompt = "0x0 inline edit: " }, function(prompt)
    if not prompt or prompt == "" then
      return
    end

    client.request({
      type = "inline.edit",
      repoRoot = root,
      file = file,
      range = selection.range,
      prompt = prompt,
      text = selection.text,
      provider = config.current.provider,
      model = config.current.model,
    }, {
      ["inline.result"] = function(message)
        show_preview({
          source_buf = selection.bufnr,
          start_line = selection.start_line,
          end_line = selection.end_line,
          replacement = message.replacementText or "",
        })
      end,
      on_error = function(err)
        util.notify(err, vim.log.levels.ERROR)
      end,
    })
  end)
end

return M
