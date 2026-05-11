-- Tool-call policy: classify ACP tool calls into a small set of risk classes
-- and decide whether each class is auto-approved. Pure functions; no state.
--
-- ACP `kind` values come from the spec:
--   read | edit | delete | move | search | execute | think | fetch
--   | switch_mode | other
-- Anything we don't recognise falls into "unknown" and stays gated.

local config = require("zeroxzero.config")

local M = {}

local KIND_TO_CLASS = {
  read = "read",
  search = "read",
  fetch = "read",
  think = "read",
  edit = "write",
  delete = "write",
  move = "write",
  execute = "shell",
}

---@param tool_call table  ACP toolCall payload (kind, title, rawInput, ...)
---@return "read"|"write"|"shell"|"unknown"
function M.classify(tool_call)
  local kind = tool_call and tool_call.kind
  return KIND_TO_CLASS[kind] or "unknown"
end

---@param tool_call table
---@return string|nil
local function tool_call_path(tool_call)
  local raw = tool_call and tool_call.rawInput
  if type(raw) ~= "table" then
    return nil
  end
  return raw.file_path or raw.path or raw.filePath
end

---@param path string|nil
---@param patterns string[]|nil
---@return boolean
local function any_match(path, patterns)
  if not path or not patterns then
    return false
  end
  for _, pat in ipairs(patterns) do
    if path:match(pat) then
      return true
    end
  end
  return false
end

---@param class string
---@return boolean
function M.is_auto_approve(class)
  local policy = config.current.tool_policy or {}
  local allow = policy.auto_approve or { "read" }
  for _, c in ipairs(allow) do
    if c == class then
      return true
    end
  end
  return false
end

---Decide whether a tool call gets auto-approved, considering class AND path.
---deny_paths beats auto_approve_paths beats class membership.
---@param tool_call table
---@param class string
---@return boolean auto_approve
function M.decide(tool_call, class)
  local policy = config.current.tool_policy or {}
  local path = tool_call_path(tool_call)
  if any_match(path, policy.deny_paths) then
    return false
  end
  if any_match(path, policy.auto_approve_paths) then
    return true
  end
  return M.is_auto_approve(class)
end

---@param class string
---@param raw_input table|nil
---@return string|nil
function M.input_preview(class, raw_input)
  if type(raw_input) ~= "table" then
    return nil
  end
  local path = raw_input.file_path or raw_input.path or raw_input.filePath
  if class == "read" then
    if path then
      local rel = vim.fn.fnamemodify(path, ":~:.")
      local offset = raw_input.offset or raw_input.line
      local limit = raw_input.limit
      if offset and limit then
        return ("→ %s:%d-%d"):format(rel, offset, offset + limit - 1)
      elseif offset then
        return ("→ %s:%d"):format(rel, offset)
      end
      return "→ " .. rel
    end
    if raw_input.pattern then
      return ("→ /%s/%s"):format(tostring(raw_input.pattern), raw_input.path and (" in " .. raw_input.path) or "")
    end
  elseif class == "write" then
    if path then
      return "→ " .. vim.fn.fnamemodify(path, ":~:.")
    end
  elseif class == "shell" then
    local cmd = raw_input.command or raw_input.cmd
    if cmd then
      cmd = tostring(cmd):gsub("\n", " ")
      return "$ " .. cmd
    end
  end
  return nil
end

---Walk an ACP content array and collect any text payload.
---@param content table|nil
---@return string text
local function collect_text(content)
  if type(content) ~= "table" then
    return ""
  end
  local parts = {}
  for _, item in ipairs(content) do
    if type(item) == "table" then
      local inner = item.content
      if type(inner) == "table" then
        if inner.type == "text" and type(inner.text) == "string" then
          parts[#parts + 1] = inner.text
        end
      elseif item.type == "diff" then
        parts[#parts + 1] = item.newText or ""
      elseif type(item.text) == "string" then
        parts[#parts + 1] = item.text
      end
    end
  end
  return table.concat(parts, "\n")
end

---@param content table|nil  ACP tool_call_update content array
---@return { summary: string, lines: string[] }|nil
function M.output_summary(content)
  local text = collect_text(content)
  if text == "" then
    return nil
  end
  local lines = vim.split(text, "\n", { plain = true })
  return {
    summary = ("⤷ %d lines"):format(#lines),
    lines = lines,
  }
end

return M
