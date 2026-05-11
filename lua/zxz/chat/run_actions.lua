-- Run-granularity accept/reject. Accept commits the run's end state to
-- the current branch; reject restores files_touched to the run's start
-- state without committing.

local Checkpoint = require("zxz.core.checkpoint")
local RunsStore = require("zxz.core.runs_store")

local M = {}

---@param run_id string|nil
---@param self table
---@return table|nil
local function resolve_run(self, run_id)
  if run_id and run_id ~= "" then
    local run = RunsStore.load(run_id)
    if not run then
      vim.notify("0x0: no run with id " .. run_id, vim.log.levels.WARN)
    end
    return run
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

---@param root string
---@param sha string
---@param path string
---@return boolean
local function exists_in_ref(root, sha, path)
  vim.fn.system({ "git", "-C", root, "cat-file", "-e", sha .. ":" .. path })
  return vim.v.shell_error == 0
end

---@param root string
---@param sha string
---@param paths string[]
---@return boolean ok, string|nil err
local function restore_paths_from(root, sha, paths)
  for _, path in ipairs(paths) do
    if exists_in_ref(root, sha, path) then
      local out = vim.fn.system({ "git", "-C", root, "checkout", sha, "--", path })
      if vim.v.shell_error ~= 0 then
        return false, out
      end
    else
      local abs = root .. "/" .. path
      if vim.fn.filereadable(abs) == 1 then
        os.remove(abs)
      end
      pcall(vim.fn.system, { "git", "-C", root, "rm", "--quiet", "--cached", "--", path })
    end
  end
  return true, nil
end

---@param run table
---@param status string
local function persist_status(run, status)
  run.status = status
  run.finalized_at = os.time()
  RunsStore.save(run)
end

---@param run_id? string
function M:run_accept(run_id)
  local run = resolve_run(self, run_id)
  if not run then
    return
  end
  if not run.start_sha or not run.end_sha then
    vim.notify("0x0: run is missing snapshots; nothing to accept", vim.log.levels.WARN)
    return
  end
  local files = run.files_touched or {}
  if #files == 0 then
    vim.notify("0x0: run touched no files", vim.log.levels.INFO)
    return
  end
  -- Prefer the run's recorded root (works for detached + older runs); fall
  -- back to self.repo_root, then current cwd (T1.12).
  local root = run.root or self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
  if not root then
    vim.notify("0x0: not in a git repository", vim.log.levels.ERROR)
    return
  end

  local ok, err = restore_paths_from(root, run.end_sha, files)
  if not ok then
    vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end

  local add_args = { "git", "-C", root, "add", "--" }
  for _, p in ipairs(files) do
    add_args[#add_args + 1] = p
  end
  local add_out = vim.fn.system(add_args)
  if vim.v.shell_error ~= 0 then
    vim.notify("0x0: git add failed: " .. (add_out or ""), vim.log.levels.ERROR)
    return
  end

  local summary = run.prompt_summary or "0x0 run"
  if #summary > 72 then
    summary = summary:sub(1, 69) .. "..."
  end
  local msg = ("0x0: %s\n\nrun-id: %s"):format(summary, run.run_id)
  local commit_out = vim.fn.system({ "git", "-C", root, "commit", "-m", msg })
  if vim.v.shell_error ~= 0 then
    -- Empty commits (working tree already matches HEAD) are fine — fall
    -- through and still flip the status so the user has a record.
    if not commit_out:lower():match("nothing to commit") then
      vim.notify("0x0: commit failed: " .. commit_out, vim.log.levels.ERROR)
      return
    end
  end

  vim.cmd.checktime()
  persist_status(run, "accepted")
  vim.notify(
    ("0x0: accepted run %s (%d file%s)"):format(run.run_id, #files, #files == 1 and "" or "s"),
    vim.log.levels.INFO
  )
end

---@param run_id? string
function M:run_reject(run_id)
  local run = resolve_run(self, run_id)
  if not run then
    return
  end
  if not run.start_sha then
    vim.notify("0x0: run is missing start snapshot", vim.log.levels.WARN)
    return
  end
  local files = run.files_touched or {}
  if #files == 0 then
    vim.notify("0x0: run touched no files", vim.log.levels.INFO)
    return
  end
  -- Prefer the run's recorded root (works for detached + older runs); fall
  -- back to self.repo_root, then current cwd (T1.12).
  local root = run.root or self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
  if not root then
    vim.notify("0x0: not in a git repository", vim.log.levels.ERROR)
    return
  end

  local ok, err = restore_paths_from(root, run.start_sha, files)
  if not ok then
    vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
    return
  end

  vim.cmd.checktime()
  persist_status(run, "rejected")
  vim.notify(
    ("0x0: rejected run %s (%d file%s)"):format(run.run_id, #files, #files == 1 and "" or "s"),
    vim.log.levels.INFO
  )
end

return M
