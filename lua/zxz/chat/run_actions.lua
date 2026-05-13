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

---@param path string
---@return boolean
local function safe_repo_path(path)
  if type(path) ~= "string" or path == "" then
    return false
  end
  if path:sub(1, 1) == "/" then
    return false
  end
  for part in path:gmatch("[^/]+") do
    if part == ".." then
      return false
    end
  end
  return true
end

---@param root string
---@param sha string
---@param path string
---@return string|nil content
local function content_in_ref(root, sha, path)
  if not exists_in_ref(root, sha, path) then
    return nil
  end
  local out = vim.fn.system({ "git", "-C", root, "show", sha .. ":" .. path })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out
end

---@param path string
---@return string|nil content
local function read_disk_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

---@param root string
---@param path string
---@return boolean
local function modified_open_buffer(root, path)
  local bufnr = vim.fn.bufnr(root .. "/" .. path)
  if bufnr == -1 or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  return vim.bo[bufnr].modified == true
end

---@param root string
---@param run table
---@param files string[]
---@return boolean ok, string|nil err
local function validate_run_restore(root, run, files)
  for _, path in ipairs(files) do
    if not safe_repo_path(path) then
      return false, "unsafe run path " .. tostring(path)
    end
    if modified_open_buffer(root, path) then
      return false, "source buffer has unsaved edits; save or revert it before applying run"
    end
    local current = read_disk_file(root .. "/" .. path)
    local start = run.start_sha and content_in_ref(root, run.start_sha, path) or nil
    local finish = run.end_sha and content_in_ref(root, run.end_sha, path) or nil
    if current ~= start and current ~= finish then
      return false, ("worktree changed since run finished; review %s before applying run"):format(path)
    end
  end
  return true, nil
end

---@param path string
---@param content string
---@return boolean ok, string|nil err
local function write_disk_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f, err = io.open(path, "wb")
  if not f then
    return false, err
  end
  f:write(content or "")
  f:close()
  return true, nil
end

---@param root string
---@param sha string
---@param paths string[]
---@return boolean ok, string|nil err
local function restore_paths_from(root, sha, paths)
  for _, path in ipairs(paths) do
    if exists_in_ref(root, sha, path) then
      local out = vim.fn.system({ "git", "-C", root, "show", sha .. ":" .. path })
      if vim.v.shell_error ~= 0 then
        return false, out
      end
      local ok, err = write_disk_file(root .. "/" .. path, out)
      if not ok then
        return false, err
      end
    else
      local abs = root .. "/" .. path
      if vim.fn.filereadable(abs) == 1 then
        os.remove(abs)
      end
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
    return false
  end

  local valid, verr = validate_run_restore(root, run, files)
  if not valid then
    vim.notify("0x0: accept failed: " .. (verr or "?"), vim.log.levels.ERROR)
    return false
  end

  local ok, err = restore_paths_from(root, run.end_sha, files)
  if not ok then
    vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
    return false
  end

  local add_args = { "git", "-C", root, "add", "--" }
  for _, p in ipairs(files) do
    add_args[#add_args + 1] = p
  end
  local add_out = vim.fn.system(add_args)
  if vim.v.shell_error ~= 0 then
    vim.notify("0x0: git add failed: " .. (add_out or ""), vim.log.levels.ERROR)
    return false
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
      return false
    end
  end

  vim.cmd.checktime()
  persist_status(run, "accepted")
  vim.notify(
    ("0x0: accepted run %s (%d file%s)"):format(run.run_id, #files, #files == 1 and "" or "s"),
    vim.log.levels.INFO
  )
  return true
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
    return false
  end

  local valid, verr = validate_run_restore(root, run, files)
  if not valid then
    vim.notify("0x0: reject failed: " .. (verr or "?"), vim.log.levels.ERROR)
    return false
  end

  local ok, err = restore_paths_from(root, run.start_sha, files)
  if not ok then
    vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
    return false
  end

  vim.cmd.checktime()
  persist_status(run, "rejected")
  vim.notify(
    ("0x0: rejected run %s (%d file%s)"):format(run.run_id, #files, #files == 1 and "" or "s"),
    vim.log.levels.INFO
  )
  return true
end

return M
