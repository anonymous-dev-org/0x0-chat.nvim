local M = {}

local _ns = vim.api.nvim_create_namespace("zeroxzero_inline")

---@class InlineEditActive
---@field session_id string
---@field file_path string
---@field bufnr integer source buffer
---@field cwd string
---@field start_line integer 1-based
---@field end_line integer 1-based
---@field selection? string
---@field sse_handler fun(properties: table) stored reference for cleanup
---@field processing boolean re-entrancy guard

---@type InlineEditActive?
local _active = nil

---@param ctx {file_path: string, cwd: string, start_line: integer, end_line: integer, selection?: string}
---@param instruction string
---@return table[] prompt parts
local function build_prompt_parts(ctx, instruction)
  local rel_path = ctx.file_path:gsub("^" .. vim.pesc(ctx.cwd .. "/"), "")
  local text
  if ctx.selection then
    text = string.format(
      "File: %s\nLines %d-%d:\n```\n%s\n```\n\nTask: %s\n\nMake surgical, minimal edits to the file. Change only what is necessary.",
      rel_path, ctx.start_line, ctx.end_line, ctx.selection, instruction
    )
  else
    text = string.format(
      "File: %s\nCursor is on line %d.\n\nTask: %s\n\nMake surgical, minimal edits to the file. Change only what is necessary.",
      rel_path, ctx.start_line, instruction
    )
  end
  return { { type = "text", text = text } }
end

---Clean up SSE handler and working highlights
local function cleanup_sse()
  if not _active then
    return
  end
  local sse = require("zeroxzero.sse")
  sse.off("session.status", _active.sse_handler)
  if vim.api.nvim_buf_is_valid(_active.bufnr) then
    vim.api.nvim_buf_clear_namespace(_active.bufnr, _ns, 0, -1)
  end
end

---Full cleanup: SSE + unregister permission + delete session + nil state
local function cleanup_all()
  if not _active then
    return
  end
  local api = require("zeroxzero.api")
  local permission = require("zeroxzero.permission")
  local session_id = _active.session_id

  cleanup_sse()
  permission.unregister_inline_session(session_id)
  api.delete_session(session_id)
  _active = nil
end

---Find the last user message ID from a messages array
---@param messages table[]
---@return string?
local function find_last_user_message_id(messages)
  for i = #messages, 1, -1 do
    if messages[i].info and messages[i].info.role == "user" then
      return messages[i].info.id
    end
  end
  return nil
end

---Check if the last assistant message had an error
---@param messages table[]
---@return string? error_message
local function check_assistant_error(messages)
  for i = #messages, 1, -1 do
    local msg = messages[i]
    if msg.info and msg.info.role == "assistant" then
      if msg.info.error then
        return msg.info.error.message or "unknown error"
      end
      -- Check parts for error indicators
      if msg.parts then
        for _, part in ipairs(msg.parts) do
          if part.type == "error" then
            return part.error or "unknown error"
          end
        end
      end
      return nil
    end
  end
  return nil
end

-- Forward declarations for mutual recursion
local on_model_complete
local on_review_complete

---Called when SSE reports session is idle after a prompt
function on_model_complete()
  if not _active then
    return
  end
  if _active.processing then
    return
  end
  _active.processing = true

  local api = require("zeroxzero.api")
  local session_id = _active.session_id
  local file_path = _active.file_path
  local bufnr = _active.bufnr

  -- Clear working highlights
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  end

  -- Get messages to find the user message ID for diff + check for errors
  api.get_messages(session_id, function(msg_err, messages)
    -- Stale callback guard
    if not _active or _active.session_id ~= session_id then
      return
    end

    if msg_err then
      vim.notify("0x0: failed to get messages — " .. msg_err, vim.log.levels.ERROR)
      cleanup_all()
      return
    end

    -- Check if model errored
    local assistant_error = check_assistant_error(messages or {})
    if assistant_error then
      vim.notify("0x0: model error — " .. assistant_error, vim.log.levels.ERROR)
      cleanup_all()
      return
    end

    local user_message_id = find_last_user_message_id(messages or {})
    if not user_message_id then
      vim.notify("0x0: no user message found", vim.log.levels.ERROR)
      cleanup_all()
      return
    end

    -- Get diff for the changes
    api.get_diff(session_id, user_message_id, function(diff_err, diffs)
      -- Stale callback guard
      if not _active or _active.session_id ~= session_id then
        return
      end

      if diff_err then
        vim.notify("0x0: failed to get diff — " .. diff_err, vim.log.levels.ERROR)
        cleanup_all()
        return
      end

      diffs = diffs or {}
      if #diffs == 0 then
        vim.notify("0x0: model made no file changes", vim.log.levels.INFO)
        cleanup_all()
        return
      end

      -- Find the diff for our target file (d.file is relative from cwd)
      local cwd = _active and _active.cwd or vim.fn.getcwd()
      local target_diff = nil
      for _, d in ipairs(diffs) do
        local abs = cwd .. "/" .. d.file
        if abs == file_path then
          target_diff = d
          break
        end
      end

      if not target_diff then
        -- Model changed other files, not our target — show info
        local changed = {}
        for _, d in ipairs(diffs) do
          table.insert(changed, d.file)
        end
        vim.notify("0x0: model changed other files: " .. table.concat(changed, ", "), vim.log.levels.INFO)
        cleanup_all()
        return
      end

      -- Revert the changes on disk so we can show the review UI
      api.revert_session(session_id, user_message_id, function(revert_err)
        -- Stale callback guard
        if not _active or _active.session_id ~= session_id then
          return
        end

        if revert_err then
          vim.notify("0x0: failed to revert — " .. revert_err, vim.log.levels.ERROR)
          cleanup_all()
          return
        end

        -- Reload the source buffer to get the reverted content
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.cmd("checktime " .. bufnr)
        end

        _active.processing = false

        -- Open review UI
        local inline_review = require("zeroxzero.inline_review")
        inline_review.open({
          file_path = file_path,
          source_bufnr = bufnr,
          before = target_diff.before,
          after = target_diff.after,
          status = target_diff.status or "modified",
          on_complete = function(accepted)
            on_review_complete(session_id, accepted)
          end,
        })
      end)
    end)
  end)
end

---Handle the result of the review UI
---@param session_id string
---@param accepted boolean
function on_review_complete(session_id, accepted)
  if not _active or _active.session_id ~= session_id then
    return
  end

  local api = require("zeroxzero.api")

  if accepted then
    -- User applied changes via the review buffer — file is already written
    -- Delete the session (unrevert not needed since review wrote the final content)
    vim.notify("0x0: changes applied", vim.log.levels.INFO)
    cleanup_all()
    return
  end

  -- User discarded — offer follow-up conversation
  vim.ui.input({ prompt = "0x0 follow-up (empty to discard): " }, function(followup)
    -- Stale guard
    if not _active or _active.session_id ~= session_id then
      return
    end

    if not followup or followup == "" then
      -- Fully discard — session is already reverted, just clean up
      vim.notify("0x0: changes discarded", vim.log.levels.INFO)
      cleanup_all()
      return
    end

    -- Unrevert so the model sees its previous changes, then send follow-up
    api.unrevert_session(session_id, function(unrevert_err)
      if not _active or _active.session_id ~= session_id then
        return
      end

      if unrevert_err then
        vim.notify("0x0: failed to unrevert — " .. unrevert_err, vim.log.levels.ERROR)
        cleanup_all()
        return
      end

      -- Reload buffer to show the un-reverted state
      if vim.api.nvim_buf_is_valid(_active.bufnr) then
        vim.cmd("checktime " .. _active.bufnr)
      end

      -- Show working highlights again
      local start_line = math.max(0, _active.start_line - 1)
      local end_line = math.min(vim.api.nvim_buf_line_count(_active.bufnr) - 1, _active.end_line - 1)
      for line = start_line, end_line do
        vim.api.nvim_buf_add_highlight(_active.bufnr, _ns, "ZeroInlineWorking", line, 0, -1)
      end

      vim.notify("0x0: sending follow-up…", vim.log.levels.INFO)

      -- Send follow-up prompt
      local parts = { { type = "text", text = followup } }
      api.prompt_async(session_id, parts, function(send_err)
        if not _active or _active.session_id ~= session_id then
          return
        end
        if send_err then
          vim.notify("0x0: follow-up failed — " .. send_err, vim.log.levels.ERROR)
          cleanup_all()
        end
        -- SSE handler will pick up the idle event when model finishes
      end)
    end)
  end)
end

---Start the inline edit flow
---@param ctx {bufnr: integer, file_path: string, cwd: string, start_line: integer, end_line: integer, selection?: string}
---@param instruction string
local function run(ctx, instruction)
  -- Abort any existing inline edit
  if _active then
    cleanup_all()
  end

  local api = require("zeroxzero.api")
  local permission = require("zeroxzero.permission")
  local server = require("zeroxzero.server")
  local sse = require("zeroxzero.sse")

  -- Working highlights
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

      -- Set up SSE handler for idle detection
      local handler = function(props)
        if not _active or _active.session_id ~= session_id then
          return
        end
        if props.sessionID ~= session_id then
          return
        end
        if props.status and props.status.type == "idle" then
          vim.schedule(function()
            on_model_complete()
          end)
        end
      end

      _active = {
        session_id = session_id,
        file_path = ctx.file_path,
        bufnr = ctx.bufnr,
        cwd = ctx.cwd,
        start_line = ctx.start_line,
        end_line = ctx.end_line,
        selection = ctx.selection,
        sse_handler = handler,
        processing = false,
      }

      sse.on("session.status", handler)

      vim.notify("0x0: editing…", vim.log.levels.INFO)

      local parts = build_prompt_parts(ctx, instruction)
      api.prompt_async(session_id, parts, function(send_err)
        if not _active or _active.session_id ~= session_id then
          return
        end
        if send_err then
          vim.notify("0x0: " .. send_err, vim.log.levels.ERROR)
          cleanup_all()
        end
        -- SSE handler will pick up the idle event when model finishes
      end)
    end)
  end)
end

---Prompt for instruction then run
---@param ctx table
local function prompt_and_run(ctx)
  vim.ui.input({ prompt = "> " }, function(instruction)
    if not instruction or instruction == "" then
      return
    end
    run(ctx, instruction)
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
  prompt_and_run({
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

  -- Exit visual mode so marks '< and '> are updated
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_line = start_pos[2]
  local end_line = end_pos[2]
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)

  prompt_and_run({
    bufnr = bufnr,
    file_path = file_path,
    cwd = vim.fn.getcwd(),
    start_line = start_line,
    end_line = end_line,
    selection = table.concat(lines, "\n"),
  })
end

---Abort any active inline edit
function M.abort()
  if not _active then
    vim.notify("0x0: no active inline edit", vim.log.levels.INFO)
    return
  end

  local api = require("zeroxzero.api")
  local session_id = _active.session_id

  -- Abort the running session if it's still busy
  api.abort_session(session_id, function() end)

  -- Close review UI if open
  local inline_review = require("zeroxzero.inline_review")
  if inline_review.is_active() then
    -- Set applying flag so BufWipeout doesn't double-fire
    inline_review.close_review_buffer()
  end

  vim.notify("0x0: inline edit aborted", vim.log.levels.INFO)
  cleanup_all()
end

return M
