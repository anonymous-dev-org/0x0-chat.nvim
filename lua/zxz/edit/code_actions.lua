-- Code actions: a vim.ui.select menu of templated agent prompts at the
-- cursor or visual selection. Each action routes to inline_edit or
-- inline_ask. Customizable via config.code_actions.

local config = require("zxz.core.config")

local M = {}

---@class zxz.CodeAction
---@field sink "edit"|"ask"
---@field template string
---@field needs_user_input boolean|nil
---@field target_resolver string|nil

---@type table<string, zxz.CodeAction>
M.DEFAULT_ACTIONS = {
  ["Explain"] = {
    sink = "ask",
    template = "Explain what `${scope_name}` does in ${rel_path}. "
      .. "Reference: ${rel_path}:${start_line}-${end_line}.",
  },
  ["Write tests"] = {
    sink = "edit",
    template = "Write tests for `${scope_name}` from ${rel_path}:${start_line}-${end_line}. "
      .. "Create or extend the appropriate test file for this language. "
      .. "Use the project's existing testing framework.",
  },
  ["Refactor"] = {
    sink = "edit",
    template = "Refactor the selected region per: ${user_input}. " .. "Preserve external API; tests must still pass.",
    needs_user_input = true,
  },
  ["Add docstring"] = {
    sink = "edit",
    template = "Add a documentation comment for `${scope_name}` "
      .. "describing parameters, return value, and side effects.",
  },
  ["Find usages"] = {
    sink = "ask",
    template = "Find call sites of `${scope_name}` in this repo and " .. "summarize how each one uses it.",
  },
  ["Summarize file"] = {
    sink = "ask",
    template = "Summarize ${rel_path} in 5 bullet points.",
  },
}

---@return table<string, zxz.CodeAction>
function M._resolve_actions()
  return vim.tbl_extend("force", M.DEFAULT_ACTIONS, config.current.code_actions or {})
end

---@param template string
---@param vars table<string, string>
---@return string
local function interpolate(template, vars)
  return (template:gsub("%${([%w_]+)}", function(key)
    return tostring(vars[key] or "")
  end))
end

---@param scope table  -- from inline_edit._resolve_scope
---@param user_input string|nil
---@return table<string, string>
local function vars_from_scope(scope, user_input)
  return {
    scope_name = scope.scope_name ~= "" and scope.scope_name or scope.scope_kind,
    scope_kind = scope.scope_kind,
    rel_path = scope.rel_path,
    start_line = tostring(scope.start_line),
    end_line = tostring(scope.end_line),
    user_input = user_input or "",
  }
end

---@param action zxz.CodeAction
---@param scope table
---@param user_input string|nil
function M._dispatch(action, scope, user_input)
  local instruction = interpolate(action.template, vars_from_scope(scope, user_input))
  if action.sink == "edit" then
    require("zxz.edit.inline_edit").start({
      range = scope.scope_kind == "selection" and { start_line = scope.start_line, end_line = scope.end_line } or nil,
      instruction = instruction,
    })
  else
    require("zxz.edit.inline_ask").ask({ question = instruction })
  end
end

---@param opts { range?: { start_line: integer, end_line: integer } }
function M.open(opts)
  opts = opts or {}
  local InlineEdit = require("zxz.edit.inline_edit")
  local bufnr = vim.api.nvim_get_current_buf()
  local scope = InlineEdit._resolve_scope(bufnr, opts.range and "v" or "n", opts.range)

  local actions = M._resolve_actions()
  local labels = {}
  for k, _ in pairs(actions) do
    labels[#labels + 1] = k
  end
  table.sort(labels)

  vim.ui.select(labels, { prompt = "0x0 code action" }, function(choice)
    if not choice then
      return
    end
    local action = actions[choice]
    if action.needs_user_input then
      vim.ui.input({ prompt = choice .. ": " }, function(user_input)
        if not user_input or user_input == "" then
          return
        end
        M._dispatch(action, scope, user_input)
      end)
    else
      M._dispatch(action, scope, nil)
    end
  end)
end

return M
