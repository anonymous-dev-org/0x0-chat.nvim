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

  vim.api.nvim_create_user_command("ZeroChatRunReview", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zeroxzero.chat").run_review(id)
  end, {
    desc = "Open a finished Run in diffview (defaults to the most recent run)",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZeroChatRuns", function(args)
    require("zeroxzero.chat").runs_picker(args.bang)
  end, {
    desc = "Pick a Run to review; with ! filter to the current thread",
    bang = true,
  })

  vim.api.nvim_create_user_command("ZeroChatRunAccept", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zeroxzero.chat").run_accept(id)
  end, {
    desc = "Accept a Run: commit files_touched at end_ref to the current branch",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZeroChatRunReject", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zeroxzero.chat").run_reject(id)
  end, {
    desc = "Reject a Run: restore files_touched to the run's start_ref",
    nargs = "?",
  })

  vim.api.nvim_create_user_command("ZeroChatRun", function(args)
    local prompt = vim.trim(args.args or "")
    if prompt == "" then
      vim.notify("usage: :ZeroChatRun <prompt>", vim.log.levels.WARN)
      return
    end
    require("zeroxzero.chat").run_headless(prompt)
  end, {
    desc = "Submit a prompt to the agent without opening the chat sidebar",
    nargs = "+",
  })

  vim.api.nvim_create_user_command("ZeroChatRunTimeline", function(args)
    local id = args.args
    if id == "" then
      id = nil
    end
    require("zeroxzero.chat").run_timeline(id)
  end, {
    desc = "Pick a tool call from a Run to inspect its per-tool diff",
    nargs = "?",
  })

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

  vim.api.nvim_create_user_command("ZeroEditInline", function(opts)
    local instruction = vim.trim(opts.args or "")
    local range = nil
    if opts.range and opts.range > 0 then
      range = { start_line = opts.line1, end_line = opts.line2 }
    end
    require("zeroxzero.inline_edit").start({
      range = range,
      instruction = instruction ~= "" and instruction or nil,
    })
  end, {
    desc = "0x0: inline edit at cursor or visual range",
    range = true,
    nargs = "*",
  })

  vim.api.nvim_create_user_command("ZeroAskInline", function(opts)
    local question = vim.trim(opts.args or "")
    require("zeroxzero.inline_ask").ask({
      question = question ~= "" and question or nil,
    })
  end, {
    desc = "0x0: inline read-only ask about code under cursor",
    nargs = "*",
  })

  vim.api.nvim_create_user_command("ZeroCodeAction", function(opts)
    local range = nil
    if opts.range and opts.range > 0 then
      range = { start_line = opts.line1, end_line = opts.line2 }
    end
    require("zeroxzero.code_actions").open({ range = range })
  end, {
    desc = "0x0: code-action menu for the current scope or visual range",
    range = true,
  })

  local context_augroup = vim.api.nvim_create_augroup("zeroxzero_context", { clear = true })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = context_augroup,
    callback = function(args)
      require("zeroxzero.context.recent").push(args.buf)
      -- Lightweight invalidation: drop the repo map cache so the next
      -- @repomap rebuilds with current state.
      require("zeroxzero.context.repo_map").invalidate()
    end,
  })

  vim.api.nvim_create_user_command("ZeroChatRepoMapRefresh", function()
    require("zeroxzero.context.repo_map").invalidate()
    vim.notify("0x0: repo map invalidated", vim.log.levels.INFO)
  end, { desc = "Force a rebuild of the repo map on next @repomap" })

  vim.api.nvim_create_user_command("ZeroChatSpawn", function(opts)
    local prompt = vim.trim(opts.args or "")
    if prompt == "" then
      vim.notify("usage: :ZeroChatSpawn <prompt>", vim.log.levels.WARN)
      return
    end
    local run_id, err = require("zeroxzero.run_registry").spawn({
      prompt = prompt,
      cwd = vim.fn.getcwd(),
      on_complete = function(rid, status, files)
        vim.notify(
          ("0x0 detached run %s: %s, %d file%s changed. :ZeroChatRunReview %s"):format(
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
    vim.notify("0x0: spawned detached run " .. run_id, vim.log.levels.INFO)
  end, {
    desc = "Spawn a detached autonomous run without opening the chat sidebar",
    nargs = "+",
  })

  vim.api.nvim_create_user_command("ZeroRunsDashboard", function()
    local Registry = require("zeroxzero.run_registry")
    local runs = Registry.list()
    if #runs == 0 then
      vim.notify("0x0: no detached runs in flight", vim.log.levels.INFO)
      return
    end
    vim.ui.select(runs, {
      prompt = "0x0 detached runs",
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
          require("zeroxzero.chat").run_review(choice.run_id)
        elseif action == "cancel" then
          local ok, cerr = Registry.cancel(choice.run_id)
          if not ok then
            vim.notify("0x0: " .. (cerr or "cancel failed"), vim.log.levels.ERROR)
          end
        end
      end)
    end)
  end, { desc = "List detached runs (live)" })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = context_augroup,
    callback = function()
      pcall(function()
        require("zeroxzero.run_registry").shutdown_all()
      end)
    end,
  })
end

return M
