local config = require("zxz.core.config")
local paths = require("zxz.core.paths")

local M = {}

---@param opts? table
function M.setup(opts)
  paths.migrate_legacy()
  config.setup(opts)

  -- Inline ghost-text completion. Reads its config from config.current.complete.
  pcall(function()
    require("zxz.complete").setup(opts and opts.complete)
  end)

  vim.api.nvim_create_user_command("ZxzCompleteSettings", function()
    require("zxz.complete").settings()
  end, { desc = "0x0: inline completion settings" })

  vim.api.nvim_create_user_command("ZxzAgent", function()
    require("zxz.agent").open()
  end, { desc = "0x0: open the AI-first agent command center" })

  vim.api.nvim_create_user_command("ZxzContext", function()
    require("zxz.context.picker").open()
  end, { desc = "0x0: add context to the active agent prompt" })

  vim.api.nvim_create_user_command("ZxzContextTrim", function(args)
    require("zxz.chat.context_trim").open(args.args)
  end, {
    desc = "0x0: toggle which @mentions feed the next turn",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZxzProfile", function()
    require("zxz.core.profiles").open()
  end, { desc = "0x0: switch agent profile" })

  vim.api.nvim_create_user_command("ZxzModel", function()
    require("zxz.core.settings").open()
  end, { desc = "0x0: switch model, mode, thinking, or favorites" })

  vim.api.nvim_create_user_command("ZxzThinkingToggle", function()
    require("zxz.core.settings").option("thinking", "thinking")
  end, { desc = "0x0: toggle provider thinking mode when available" })

  vim.api.nvim_create_user_command("ZxzThinkingEffort", function()
    require("zxz.core.settings").option("effort", "effort")
  end, { desc = "0x0: pick provider thinking effort when available" })

  vim.api.nvim_create_user_command("ZxzQueue", function()
    require("zxz.chat.queue").open()
  end, { desc = "0x0: inspect queued agent messages" })

  vim.api.nvim_create_user_command("ZxzQueueEdit", function()
    require("zxz.chat.queue").edit_first()
  end, { desc = "0x0: edit the next queued agent message" })

  vim.api.nvim_create_user_command("ZxzQueueRemove", function()
    require("zxz.chat.queue").remove_first()
  end, { desc = "0x0: remove the next queued agent message" })

  vim.api.nvim_create_user_command("ZxzQueueClear", function()
    require("zxz.chat.queue").clear()
  end, { desc = "0x0: clear queued agent messages" })

  vim.api.nvim_create_user_command("ZxzQueueSendNext", function()
    require("zxz.chat.queue").send_next()
  end, { desc = "0x0: send the next queued agent message" })

  vim.api.nvim_create_user_command("ZxzChat", function(opts)
    local chat = require("zxz.chat.chat")
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

  vim.api.nvim_create_user_command("ZxzChatNew", function()
    require("zxz.chat.chat").new()
  end, { desc = "Reset the chat session and clear the buffer" })

  vim.api.nvim_create_user_command("ZxzChatSubmit", function()
    require("zxz.chat.chat").submit()
  end, { desc = "Submit the pending prompt to the active session" })

  vim.api.nvim_create_user_command("ZxzChatCancel", function()
    require("zxz.chat.chat").cancel()
  end, { desc = "Cancel the in-flight prompt" })

  vim.api.nvim_create_user_command("ZxzChatChanges", function()
    require("zxz.chat.chat").changes()
  end, { desc = "List files changed since the active 0x0 checkpoint" })

  vim.api.nvim_create_user_command("ZxzChatReview", function()
    require("zxz.chat.chat").review()
  end, { desc = "Review chat changes in the native 0x0 review buffer" })

  vim.api.nvim_create_user_command("ZxzReview", function()
    require("zxz.chat.chat").review()
  end, { desc = "0x0: review current agent changes" })

  vim.api.nvim_create_user_command("ZxzChatRunReview", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zxz.chat.chat").run_review(id)
  end, {
    desc = "Open a finished Run in the native 0x0 review buffer",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZxzAccept", function()
    require("zxz.edit.verbs").accept_current()
  end, { desc = "0x0: accept the current AI suggestion, hunk, or review file" })

  vim.api.nvim_create_user_command("ZxzReject", function()
    require("zxz.edit.verbs").reject_current()
  end, { desc = "0x0: reject the current AI suggestion, hunk, or review file" })

  vim.api.nvim_create_user_command("ZxzAcceptFile", function()
    require("zxz.edit.verbs").accept_file()
  end, { desc = "0x0: accept the current AI-changed file" })

  vim.api.nvim_create_user_command("ZxzRejectFile", function()
    require("zxz.edit.verbs").reject_file()
  end, { desc = "0x0: reject the current AI-changed file" })

  vim.api.nvim_create_user_command("ZxzUndoReject", function()
    require("zxz.edit.verbs").undo_reject()
  end, { desc = "0x0: restore the last rejected AI change" })

  vim.api.nvim_create_user_command("ZxzAcceptRun", function()
    require("zxz.edit.verbs").accept_run()
  end, { desc = "0x0: accept the active review run" })

  vim.api.nvim_create_user_command("ZxzRejectRun", function()
    require("zxz.edit.verbs").reject_run()
  end, { desc = "0x0: reject the active review run" })

  vim.api.nvim_create_user_command("ZxzChatRuns", function(args)
    require("zxz.chat.chat").runs_picker(args.bang)
  end, {
    desc = "Pick an AI task to review; with ! filter to the current chat",
    bang = true,
  })

  vim.api.nvim_create_user_command("ZxzRuns", function(args)
    require("zxz.chat.chat").runs_picker(args.bang)
  end, {
    desc = "0x0: pick an AI task to review",
    bang = true,
  })

  vim.api.nvim_create_user_command("ZxzTasks", function(args)
    require("zxz.chat.chat").tasks_picker(args.bang)
  end, {
    desc = "0x0: pick an AI task to review",
    bang = true,
  })

  vim.api.nvim_create_user_command("ZxzChats", function()
    require("zxz.chat.chat").chats_picker()
  end, { desc = "0x0: pick a saved chat workspace" })

  vim.api.nvim_create_user_command("ZxzChatRunAccept", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zxz.chat.chat").run_accept(id)
  end, {
    desc = "Accept an AI task: restore touched files to the task result",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZxzChatRunReject", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zxz.chat.chat").run_reject(id)
  end, {
    desc = "Reject an AI task: restore touched files to the task start",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZxzChatRun", function(args)
    local prompt = vim.trim(args.args or "")
    if prompt == "" then
      vim.notify("usage: :ZxzChatRun <prompt>", vim.log.levels.WARN)
      return
    end
    require("zxz.chat.chat").run_headless(prompt)
  end, {
    desc = "Submit a one-shot prompt without opening the chat workspace",
    nargs = "+",
  })

  vim.api.nvim_create_user_command("ZxzChatRunTimeline", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zxz.chat.chat").run_timeline(id)
  end, {
    desc = "Pick a tool call from an AI task to inspect its per-tool diff",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZxzChatAddFile", function()
    require("zxz.chat.chat").add_current_file()
  end, { desc = "Add the current file to the pending chat prompt" })

  vim.api.nvim_create_user_command("ZxzChatAddHunk", function()
    require("zxz.chat.chat").add_current_hunk()
  end, { desc = "Add the current 0x0 diff hunk to the pending chat prompt" })

  vim.api.nvim_create_user_command("ZxzChatAddSelection", function()
    require("zxz.chat.chat").add_visual_selection_from_prev()
  end, {
    desc = "Attach the last visual selection from the prior window as a line-range mention",
  })

  vim.api.nvim_create_user_command("ZxzChatDiff", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zxz.chat.chat").diff(id)
  end, { desc = "Show the turn diff (or per-tool diff with an id)", nargs = "?" })

  vim.api.nvim_create_user_command("ZxzChatAcceptAll", function()
    require("zxz.chat.chat").accept_all()
  end, { desc = "Accept all pending chat changes and clear the checkpoint" })

  vim.api.nvim_create_user_command("ZxzChatDiscardAll", function()
    require("zxz.chat.chat").discard_all()
  end, { desc = "Discard all pending chat changes (restore from checkpoint)" })

  vim.api.nvim_create_user_command("ZxzChatStop", function()
    require("zxz.chat.chat").stop()
    vim.notify("acp: stopped", vim.log.levels.INFO)
  end, { desc = "Stop the ACP provider and drop the session" })

  vim.api.nvim_create_user_command("ZxzChatSettings", function()
    require("zxz.core.settings").open()
  end, { desc = "Pick the chat provider / model" })

  vim.api.nvim_create_user_command("ZxzChatHistory", function()
    require("zxz.chat.chat").history_picker()
  end, { desc = "Pick a saved chat thread to restore" })

  vim.api.nvim_create_user_command("ZxzChatLog", function()
    require("zxz.core.log").open()
  end, { desc = "Open the 0x0 chat debug log" })

  vim.api.nvim_create_user_command("ZxzEditInline", function(opts)
    local instruction = vim.trim(opts.args or "")
    local range = nil
    if opts.range and opts.range > 0 then
      range = { start_line = opts.line1, end_line = opts.line2 }
    end
    require("zxz.edit.inline_edit").start({
      range = range,
      instruction = instruction ~= "" and instruction or nil,
    })
  end, {
    desc = "0x0: inline edit at cursor or visual range",
    range = true,
    nargs = "*",
  })

  vim.api.nvim_create_user_command("ZxzAskInline", function(opts)
    local question = vim.trim(opts.args or "")
    require("zxz.edit.inline_ask").ask({
      question = question ~= "" and question or nil,
    })
  end, {
    desc = "0x0: inline read-only ask about code under cursor",
    nargs = "*",
  })

  vim.api.nvim_create_user_command("ZxzCodeAction", function(opts)
    local range = nil
    if opts.range and opts.range > 0 then
      range = { start_line = opts.line1, end_line = opts.line2 }
    end
    require("zxz.edit.code_actions").open({ range = range })
  end, {
    desc = "0x0: code-action menu for the current scope or visual range",
    range = true,
  })

  local context_augroup = vim.api.nvim_create_augroup("zxz_context", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = context_augroup,
    callback = function(args)
      require("zxz.context.recent").push(args.buf)
      -- Lightweight invalidation: drop the repo map cache so the next
      -- @repomap rebuilds with current state.
      require("zxz.context.repo_map").invalidate()
    end,
  })

  vim.api.nvim_create_user_command("ZxzChatRepoMapRefresh", function()
    require("zxz.context.repo_map").invalidate()
    vim.notify("0x0: repo map invalidated", vim.log.levels.INFO)
  end, { desc = "Force a rebuild of the repo map on next @repomap" })

  vim.api.nvim_create_user_command("ZxzChatSpawn", function(opts)
    local prompt = vim.trim(opts.args or "")
    if prompt == "" then
      vim.notify("usage: :ZxzChatSpawn <prompt>", vim.log.levels.WARN)
      return
    end
    local run_id, err = require("zxz.core.run_registry").spawn({
      prompt = prompt,
      cwd = vim.fn.getcwd(),
      on_complete = function(rid, status, files)
        vim.notify(
          ("0x0 background task %s: %s, %d file%s changed. :ZxzChatRunReview %s"):format(
            rid,
            status,
            #files,
            #files == 1 and "" or "s",
            rid
          ),
          vim.log.levels.INFO
        )
      end,
    })
    if not run_id then
      vim.notify("0x0: " .. (err or "spawn failed"), vim.log.levels.ERROR)
      return
    end
    vim.notify("0x0: spawned background task " .. run_id, vim.log.levels.INFO)
  end, {
    desc = "Spawn an autonomous background task without opening chat",
    nargs = "+",
  })

  vim.api.nvim_create_user_command("ZxzSpawn", function(opts)
    local prompt = vim.trim(opts.args or "")
    if prompt == "" then
      vim.notify("usage: :ZxzSpawn <prompt>", vim.log.levels.WARN)
      return
    end
    local run_id, err = require("zxz.core.run_registry").spawn({
      prompt = prompt,
      cwd = vim.fn.getcwd(),
      on_complete = function(rid, status, files)
        vim.notify(
          ("0x0 background task %s: %s, %d file%s changed. :ZxzChatRunReview %s"):format(
            rid,
            status,
            #files,
            #files == 1 and "" or "s",
            rid
          ),
          vim.log.levels.INFO
        )
      end,
    })
    if not run_id then
      vim.notify("0x0: " .. (err or "spawn failed"), vim.log.levels.ERROR)
      return
    end
    vim.notify("0x0: spawned background task " .. run_id, vim.log.levels.INFO)
  end, {
    desc = "0x0: spawn an autonomous background AI task",
    nargs = "+",
  })

  vim.api.nvim_create_user_command("ZxzRunsDashboard", function()
    local Registry = require("zxz.core.run_registry")
    local runs = Registry.list()
    if #runs == 0 then
      vim.notify("0x0: no background tasks in flight", vim.log.levels.INFO)
      return
    end
    vim.ui.select(runs, {
      prompt = "0x0 background tasks",
      format_item = function(r)
        local when = os.date("%H:%M:%S", r.started_at or 0)
        local prompt_summary = (r.current_run and r.current_run.prompt_summary) or ""
        if #prompt_summary > 60 then
          prompt_summary = prompt_summary:sub(1, 57) .. "..."
        end
        local tools = (r.current_run and #(r.current_run.tool_calls or {})) or 0
        return ("%s %s  [%s]  %d tool%s  %s"):format(
          r.state,
          when,
          r.run_id,
          tools,
          tools == 1 and "" or "s",
          prompt_summary
        )
      end,
    }, function(choice)
      if not choice then
        return
      end
      vim.ui.select({ "review", "cancel" }, { prompt = "action for " .. choice.run_id }, function(action)
        if action == "review" then
          require("zxz.chat.chat").run_review(choice.run_id)
        elseif action == "cancel" then
          local ok, cerr = Registry.cancel(choice.run_id)
          if not ok then
            vim.notify("0x0: " .. (cerr or "cancel failed"), vim.log.levels.ERROR)
          end
        end
      end)
    end)
  end, { desc = "List background AI tasks" })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = context_augroup,
    callback = function()
      pcall(function()
        require("zxz.core.run_registry").shutdown_all()
      end)
    end,
  })
end

return M
