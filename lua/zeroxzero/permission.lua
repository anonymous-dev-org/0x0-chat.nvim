local M = {}
local api = vim.api

local KEY_TO_KIND = {
  a = "allow_once",
  A = "allow_always",
  r = "reject_once",
  R = "reject_always",
}

local OPTIONS_HINT = "[a] allow once  [A] allow always  [r] reject once  [R] reject always"

local function describe_tool(tool_call)
  local kind = tool_call.kind or "tool"
  local title = tool_call.title
  if not title or title == "" then
    title = tool_call.toolCallId or "?"
  end
  return ("`%s` %s"):format(kind, title)
end

local function find_option(options, kind)
  for _, option in ipairs(options or {}) do
    if option.kind == kind then
      return option.optionId, option.name
    end
  end
end

local function with_modifiable(bufnr, fn)
  vim.bo[bufnr].modifiable = true
  fn()
  vim.bo[bufnr].modifiable = false
end

---@class zeroxzero.permission.Pending
---@field unmap fun()

---@param bufnr integer
---@param request table
---@param respond fun(option_id: string|nil)
---@return zeroxzero.permission.Pending|nil
function M.render(bufnr, request, respond)
  if not api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local description = describe_tool(request.toolCall or {})
  local options = request.options or {}
  local prompt_text = ("> tool request: %s"):format(description)

  local prompt_line, options_line
  with_modifiable(bufnr, function()
    local last = api.nvim_buf_line_count(bufnr)
    api.nvim_buf_set_lines(bufnr, last, last, false, { "", prompt_text, OPTIONS_HINT, "" })
    prompt_line = last + 1
    options_line = last + 2
  end)

  local pending = { unmap = function() end }

  local function resolve(decision_kind)
    pending.unmap()
    if not api.nvim_buf_is_valid(bufnr) then
      return
    end

    local option_id, option_name = find_option(options, decision_kind)
    if not option_id then
      option_id, option_name = find_option(options, "reject_once")
      vim.notify(
        ("acp: agent did not offer '%s'; %s"):format(decision_kind, option_id and "rejecting once" or "cancelling"),
        vim.log.levels.WARN
      )
    end

    with_modifiable(bufnr, function()
      local resolved = ("> tool request: %s — %s"):format(description, option_name or decision_kind)
      api.nvim_buf_set_lines(bufnr, prompt_line, options_line + 1, false, { resolved })
    end)

    respond(option_id)
  end

  local opts = { buffer = bufnr, nowait = true, silent = true, desc = "ACP permission decision" }
  for key, kind in pairs(KEY_TO_KIND) do
    vim.keymap.set("n", key, function()
      resolve(kind)
    end, opts)
  end

  pending.unmap = function()
    for key in pairs(KEY_TO_KIND) do
      pcall(vim.keymap.del, "n", key, { buffer = bufnr })
    end
  end

  return pending
end

return M
