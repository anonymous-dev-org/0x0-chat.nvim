-- Per-Run tool-call timeline: list every tool the agent invoked during a
-- Run, with kind/status/duration. Selection opens that tool's diff in
-- diffview at its tool-checkpoint range.

local Checkpoint = require("zxz.core.checkpoint")
local RunsStore = require("zxz.core.runs_store")

local M = {}

local STATUS_ICON = {
  pending = "·",
  in_progress = "…",
  completed = "✓",
  failed = "✗",
}

local KIND_ICON = {
  read = "📖",
  write = "✎",
  shell = "$",
  search = "?",
  fetch = "↓",
  think = "•",
  tool = "·",
}

---@param self table
---@param run_id string|nil
---@return table|nil
local function resolve_run(self, run_id)
  if run_id and run_id ~= "" then
    return RunsStore.load(run_id)
  end
  if self.current_run then
    return self.current_run
  end
  local ids = self.run_ids or {}
  for i = #ids, 1, -1 do
    local r = RunsStore.load(ids[i])
    if r then
      return r
    end
  end
  return nil
end

---@param root string
---@param ref string|nil
---@return string|nil sha
local function ref_to_sha(root, ref)
  if not ref or ref == "" then
    return nil
  end
  local out = vim.fn.system({ "git", "-C", root, "rev-parse", ref })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return (out:gsub("%s+$", ""))
end

---@param tool table
---@return string
local function format_tool(tool)
  local icon = STATUS_ICON[tool.status or ""] or "·"
  local kind_icon = KIND_ICON[tool.kind or ""] or KIND_ICON.tool
  local title = (tool.title and tool.title ~= "") and tool.title or "(no title)"
  local duration = ""
  if tool.started_at and tool.ended_at then
    local d = tool.ended_at - tool.started_at
    if d >= 1 then
      duration = (" %ds"):format(d)
    end
  end
  return ("%s %s %-9s %s%s"):format(icon, kind_icon, tool.kind or "tool", title, duration)
end

---@param run_id? string
function M:run_timeline(run_id)
  local run = resolve_run(self, run_id)
  if not run then
    vim.notify("0x0: no run to show timeline for", vim.log.levels.INFO)
    return
  end
  local tools = run.tool_calls or {}
  if #tools == 0 then
    vim.notify("0x0: run " .. (run.run_id or "?") .. " has no tool calls", vim.log.levels.INFO)
    return
  end

  vim.ui.select(tools, {
    prompt = ("0x0 run %s — tool timeline"):format(run.run_id or "?"),
    format_item = format_tool,
  }, function(choice, idx)
    if not choice then
      return
    end
    local tool_ref = (run.tool_refs or {})[choice.tool_call_id]
    if not tool_ref then
      vim.notify("0x0: no checkpoint recorded for this tool call", vim.log.levels.INFO)
      return
    end
    local root = self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
    if not root then
      vim.notify("0x0: not in a git repository", vim.log.levels.ERROR)
      return
    end
    local tool_sha = ref_to_sha(root, tool_ref)
    if not tool_sha then
      vim.notify("0x0: tool checkpoint ref is missing", vim.log.levels.WARN)
      return
    end
    -- Parent = previous tool's sha if any, else the run's start_sha.
    local parent_sha = run.start_sha
    for i = idx - 1, 1, -1 do
      local prev = tools[i]
      local prev_ref = (run.tool_refs or {})[prev.tool_call_id]
      if prev_ref then
        local s = ref_to_sha(root, prev_ref)
        if s then
          parent_sha = s
          break
        end
      end
    end
    if not parent_sha then
      vim.notify("0x0: no parent snapshot for tool diff", vim.log.levels.WARN)
      return
    end
    local ok = pcall(require, "diffview")
    if not ok then
      -- Fallback: scratch buffer with unified diff text.
      local diff = vim.fn.system({ "git", "-C", root, "diff", parent_sha, tool_sha })
      if diff == "" then
        vim.notify("0x0: this tool call produced no diff", vim.log.levels.INFO)
        return
      end
      vim.cmd("tabnew")
      local buf = vim.api.nvim_get_current_buf()
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].filetype = "diff"
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(diff, "\n", { plain = true }))
      vim.bo[buf].modifiable = false
      return
    end
    vim.cmd(("DiffviewOpen %s..%s"):format(parent_sha, tool_sha))
  end)
end

return M
