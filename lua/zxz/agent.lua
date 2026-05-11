local M = {}

local function input_prompt(prompt, callback)
  vim.ui.input({ prompt = prompt }, function(value)
    value = value and vim.trim(value) or ""
    if value ~= "" then
      callback(value)
    end
  end)
end

local ACTIONS = {
  {
    label = "Open agent workspace",
    detail = "Open the persistent chat and run surface.",
    run = function()
      require("zxz.chat.chat").open()
    end,
  },
  {
    label = "Add context",
    detail = "Attach files, symbols, diagnostics, diffs, rules, tests, URLs, or threads.",
    run = function()
      require("zxz.context.picker").open()
    end,
  },
  {
    label = "Inline edit",
    detail = "Edit the current symbol or visual selection in-place.",
    run = function()
      require("zxz.edit.inline_edit").start({})
    end,
  },
  {
    label = "Inline ask",
    detail = "Ask about the code under the cursor.",
    run = function()
      require("zxz.edit.inline_ask").ask({})
    end,
  },
  {
    label = "Code actions",
    detail = "Explain, refactor, write tests, add docs, or find usages.",
    run = function()
      require("zxz.edit.code_actions").open({})
    end,
  },
  {
    label = "Submit chat",
    detail = "Send the current agent workspace prompt.",
    run = function()
      require("zxz.chat.chat").submit()
    end,
  },
  {
    label = "Queue",
    detail = "Inspect, edit, send, remove, or clear queued follow-ups.",
    run = function()
      require("zxz.chat.queue").open()
    end,
  },
  {
    label = "Review changes",
    detail = "Review the active turn diff.",
    run = function()
      require("zxz.chat.chat").review()
    end,
  },
  {
    label = "Runs",
    detail = "Review recorded runs.",
    run = function()
      require("zxz.chat.chat").runs_picker(false)
    end,
  },
  {
    label = "Background runs",
    detail = "Inspect live detached agents.",
    run = function()
      vim.cmd("ZxzRunsDashboard")
    end,
  },
  {
    label = "Spawn background agent",
    detail = "Start an autonomous run without opening chat.",
    run = function()
      input_prompt("agent task: ", function(prompt)
        local run_id, err = require("zxz.core.run_registry").spawn({
          prompt = prompt,
          cwd = vim.fn.getcwd(),
          on_complete = function(rid, status, files)
            vim.notify(
              ("0x0 detached run %s: %s, %d file%s changed. :ZxzChatRunReview %s"):format(
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
        end
      end)
    end,
  },
  {
    label = "Profile",
    detail = "Switch ask/write/review/autonomous behavior.",
    run = function()
      require("zxz.core.profiles").open()
    end,
  },
  {
    label = "Model and mode",
    detail = "Switch provider, model, mode, thinking, effort, or favorites.",
    run = function()
      require("zxz.core.settings").open()
    end,
  },
  {
    label = "Cancel current run",
    detail = "Stop the active agent turn.",
    run = function()
      require("zxz.chat.chat").cancel()
    end,
  },
}

function M.actions()
  return vim.deepcopy(ACTIONS)
end

function M.open()
  vim.ui.select(ACTIONS, {
    prompt = "0x0 agent",
    format_item = function(action)
      return action.detail and (action.label .. " - " .. action.detail) or action.label
    end,
  }, function(choice)
    if choice then
      choice.run()
    end
  end)
end

return M
