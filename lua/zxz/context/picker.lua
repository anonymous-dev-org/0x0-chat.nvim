local M = {}

local function chat()
  return require("zxz.chat.chat")
end

local function add_token(token)
  chat().add_context_token(token)
end

local function prompt_token(prompt, prefix)
  vim.ui.input({ prompt = prompt }, function(value)
    if not value or value == "" then
      return
    end
    add_token(prefix .. value)
  end)
end

local ACTIONS = {
  {
    label = "Current file",
    detail = "Attach the current file.",
    run = function()
      chat().add_current_file()
    end,
  },
  {
    label = "Selection",
    detail = "Attach the latest visual selection.",
    run = function()
      chat().add_visual_selection_from_prev()
    end,
  },
  {
    label = "Symbol",
    detail = "Attach the symbol under cursor.",
    run = function()
      add_token("@symbol")
    end,
  },
  {
    label = "Hover",
    detail = "Attach LSP hover at cursor.",
    run = function()
      add_token("@hover")
    end,
  },
  {
    label = "Definition",
    detail = "Attach LSP definition at cursor.",
    run = function()
      add_token("@def")
    end,
  },
  {
    label = "Diagnostics",
    detail = "Attach diagnostics for the current source buffer.",
    run = function()
      vim.ui.select({ "@diagnostics", "@diagnostics:errors", "@diagnostics:warnings" }, {
        prompt = "0x0 diagnostics context",
      }, function(choice)
        if choice then
          add_token(choice)
        end
      end)
    end,
  },
  {
    label = "Branch diff",
    detail = "Attach git diff against a base ref.",
    run = function()
      prompt_token("base ref: ", "@diff:")
    end,
  },
  {
    label = "Repo map",
    detail = "Attach a compact project map.",
    run = function()
      add_token("@repomap")
    end,
  },
  {
    label = "Recent files",
    detail = "Attach recently edited files.",
    run = function()
      add_token("@recent")
    end,
  },
  {
    label = "Rules",
    detail = "Attach project or named rules.",
    run = function()
      prompt_token("rule name: ", "@rule:")
    end,
  },
  {
    label = "Test output",
    detail = "Run the configured test command and attach output.",
    run = function()
      add_token("@test-output")
    end,
  },
  {
    label = "Terminal output",
    detail = "Reserve terminal output context.",
    run = function()
      add_token("@terminal")
    end,
  },
  {
    label = "URL fetch",
    detail = "Attach a URL for the agent to fetch.",
    run = function()
      prompt_token("url: ", "@fetch:")
    end,
  },
  {
    label = "Previous thread",
    detail = "Attach a saved chat thread.",
    run = function()
      local entries = require("zxz.core.history_store").list()
      if #entries == 0 then
        vim.notify("0x0: no saved threads", vim.log.levels.INFO)
        return
      end
      vim.ui.select(entries, {
        prompt = "0x0 thread context",
        format_item = function(entry)
          return ("%s  %s"):format(entry.id, entry.title or "untitled")
        end,
      }, function(choice)
        if choice then
          add_token("@thread:" .. choice.id)
        end
      end)
    end,
  },
}

function M.actions()
  return vim.deepcopy(ACTIONS)
end

function M.open()
  vim.ui.select(ACTIONS, {
    prompt = "0x0 add context",
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
