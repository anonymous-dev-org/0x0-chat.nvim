-- Post-hoc Run review: open a finished Run in the native 0x0 review buffer.

local RunsStore = require("zxz.core.runs_store")

local M = {}

---@param run_id string|nil
---@return table|nil
local function resolve_run(self, run_id)
  if run_id and run_id ~= "" then
    local run = RunsStore.load(run_id)
    if not run then
      vim.notify("0x0: no run with id " .. run_id, vim.log.levels.WARN)
    end
    return run
  end
  if self.current_run then
    return self.current_run
  end
  local ids = self.run_ids or {}
  for i = #ids, 1, -1 do
    local run = RunsStore.load(ids[i])
    if run then
      return run
    end
  end
  vim.notify("0x0: no runs in this thread yet", vim.log.levels.INFO)
  return nil
end

---@param run_id? string
function M:run_review(run_id)
  local run = resolve_run(self, run_id)
  if not run then
    return
  end
  if not run.start_sha or not run.end_sha then
    vim.notify("0x0: run " .. (run.run_id or "?") .. " has no end snapshot; nothing to review", vim.log.levels.INFO)
    return
  end
  require("zxz.edit.review").open_run(run, { chat = self })
  vim.notify(
    ("0x0: reviewing run %s (%d file%s)"):format(
      run.run_id,
      #(run.files_touched or {}),
      #(run.files_touched or {}) == 1 and "" or "s"
    ),
    vim.log.levels.INFO
  )
end

return M
