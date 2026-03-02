local M = {}

local _ns = vim.api.nvim_create_namespace("zeroxzero_inline")

---@param ctx {bufnr: integer, file_path: string, cwd: string, start_line: integer, end_line: integer, selection?: string}
---@param instruction string
---@return string
local function _build_prompt(ctx, instruction)
  local rel_path = ctx.file_path:gsub("^" .. vim.pesc(ctx.cwd .. "/"), "")
  if ctx.selection then
    return string.format(
      "File: %s\nLines %d-%d:\n```\n%s\n```\n\nTask: %s\n\nMake surgical, minimal edits to the file. Change only what is necessary.",
      rel_path,
      ctx.start_line,
      ctx.end_line,
      ctx.selection,
      instruction
    )
  else
    return string.format(
      "File: %s\nCursor is on line %d.\n\nTask: %s\n\nMake surgical, minimal edits to the file. Change only what is necessary.",
      rel_path,
      ctx.start_line,
      instruction
    )
  end
end

---@param ctx table
---@param instruction string
local function _run(ctx, instruction)
  local api = require("zeroxzero.api")
  local permission = require("zeroxzero.permission")
  local server = require("zeroxzero.server")

  for line = ctx.start_line - 1, ctx.end_line - 1 do
    vim.api.nvim_buf_add_highlight(ctx.bufnr, _ns, "ZeroInlineWorking", line, 0, -1)
  end

  server.ensure(function(err)
    if err then
      vim.api.nvim_buf_clear_namespace(ctx.bufnr, _ns, 0, -1)
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    api.create_session(function(create_err, session_id)
      if create_err then
        vim.api.nvim_buf_clear_namespace(ctx.bufnr, _ns, 0, -1)
        vim.notify("0x0: " .. create_err, vim.log.levels.ERROR)
        return
      end

      permission.register_inline_session(session_id, ctx.file_path)
      vim.notify("0x0: editing\xe2\x80\xa6", vim.log.levels.INFO)

      api.send_message(session_id, _build_prompt(ctx, instruction), function(send_err)
        if vim.api.nvim_buf_is_valid(ctx.bufnr) then
          vim.api.nvim_buf_clear_namespace(ctx.bufnr, _ns, 0, -1)
        end
        permission.unregister_inline_session(session_id)
        api.delete_session(session_id)
        if send_err then
          vim.notify("0x0: edit failed \xe2\x80\x94 " .. send_err, vim.log.levels.ERROR)
        else
          vim.notify("0x0: done", vim.log.levels.INFO)
          vim.cmd("checktime")
        end
      end)
    end)
  end)
end

---@param ctx table
local function _prompt_and_run(ctx)
  vim.ui.input({ prompt = "> " }, function(instruction)
    if not instruction or instruction == "" then
      return
    end
    _run(ctx, instruction)
  end)
end

---Normal mode entry: uses current cursor line as context
function M.edit()
  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    vim.notify("0x0: no file open", vim.log.levels.WARN)
    return
  end

  local cursor_line = vim.fn.line(".")
  _prompt_and_run({
    bufnr = bufnr,
    file_path = file_path,
    cwd = vim.fn.getcwd(),
    start_line = cursor_line,
    end_line = cursor_line,
  })
end

---Visual mode entry: uses current visual selection as context
function M.edit_visual()
  local bufnr = vim.api.nvim_get_current_buf()
  local file_path = vim.api.nvim_buf_get_name(bufnr)
  if file_path == "" then
    vim.notify("0x0: no file open", vim.log.levels.WARN)
    return
  end

  -- Exit visual mode so marks '<  and '> are updated
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  _prompt_and_run({
    bufnr = bufnr,
    file_path = file_path,
    cwd = vim.fn.getcwd(),
    start_line = start_line,
    end_line = end_line,
    selection = table.concat(lines, "\n"),
  })
end

return M
