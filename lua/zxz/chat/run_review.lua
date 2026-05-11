-- Post-hoc Run review: open a finished Run in diffview.nvim and bind
-- per-file accept/reject to the same checkpoint primitives the live
-- inline overlay uses.

local Checkpoint = require("zxz.core.checkpoint")
local RunsStore = require("zxz.core.runs_store")

local M = {}

---@return boolean ok, table|nil module
local function require_diffview()
  local ok, mod = pcall(require, "diffview")
  if not ok then
    vim.notify("0x0: diffview.nvim is required for run review. Install sindrets/diffview.nvim.", vim.log.levels.ERROR)
    return false, nil
  end
  return true, mod
end

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

---@param path string
---@param run table
local function accept_file(run, path)
  if not run.start_sha or not path or path == "" then
    return
  end
  -- Accepting = keep the agent's version. After a run finishes the working
  -- tree IS the agent's version, but the user may have moved on since;
  -- restoring from end_ref pins it to what the agent wrote.
  if not run.end_sha then
    vim.notify("0x0: run has no end_ref to accept from", vim.log.levels.WARN)
    return
  end
  -- Prefer the run's recorded root over current cwd (T1.12). Older runs
  -- without a `root` field fall back to git_root for compatibility.
  local root = run.root or Checkpoint.git_root(vim.fn.getcwd())
  if not root then
    return
  end
  local args = { "git", "-C", root, "checkout", run.end_sha, "--", path }
  local out = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    vim.notify("0x0: accept failed: " .. (out or ""), vim.log.levels.ERROR)
    return
  end
  vim.cmd.checktime()
  vim.notify("0x0: accepted " .. path, vim.log.levels.INFO)
end

---@param path string
---@param run table
local function reject_file(run, path)
  if not run.start_sha or not path or path == "" then
    return
  end
  -- Prefer run.root (T1.12).
  local root = run.root or Checkpoint.git_root(vim.fn.getcwd())
  if not root then
    return
  end
  -- Was the file present at start_ref? Use cat-file to check.
  local check = vim.fn.system({ "git", "-C", root, "cat-file", "-e", run.start_sha .. ":" .. path })
  if vim.v.shell_error == 0 then
    local out = vim.fn.system({ "git", "-C", root, "checkout", run.start_sha, "--", path })
    if vim.v.shell_error ~= 0 then
      vim.notify("0x0: reject failed: " .. (out or ""), vim.log.levels.ERROR)
      return
    end
  else
    -- File was created by the run; remove it.
    local abs = root .. "/" .. path
    if vim.fn.filereadable(abs) == 1 then
      os.remove(abs)
    end
  end
  vim.cmd.checktime()
  vim.notify("0x0: rejected " .. path, vim.log.levels.INFO)
end

---@param run table
---@param bufnr integer
local function bind_buffer(run, bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if vim.b[bufnr].zxz_run_review_bound then
    return
  end
  vim.b[bufnr].zxz_run_review_bound = true

  local function current_path()
    local name = vim.api.nvim_buf_get_name(bufnr)
    if name == "" then
      return nil
    end
    -- Use the run's root so the buffer path is correctly relativized
    -- against the repo the run touched (T1.12).
    local root = run.root or Checkpoint.git_root(vim.fn.getcwd())
    if root and name:sub(1, #root + 1) == root .. "/" then
      return name:sub(#root + 2)
    end
    return vim.fn.fnamemodify(name, ":.")
  end

  vim.keymap.set("n", "<localleader>a", function()
    local p = current_path()
    if p then
      accept_file(run, p)
    end
  end, { buffer = bufnr, silent = true, desc = "0x0: accept this file in run" })

  vim.keymap.set("n", "<localleader>r", function()
    local p = current_path()
    if p then
      reject_file(run, p)
    end
  end, { buffer = bufnr, silent = true, desc = "0x0: reject this file in run" })
end

---@param run table
local function attach_diffview_keymaps(run)
  local group = vim.api.nvim_create_augroup("zxz_run_review_" .. run.run_id, { clear = true })
  vim.api.nvim_create_autocmd("BufWinEnter", {
    group = group,
    callback = function(args)
      local buf = args.buf
      local ft = vim.bo[buf].filetype
      -- Diffview marks its panels with these filetypes; the diff buffers
      -- themselves have the source filetype, so we bind on any buffer
      -- entered during a diffview session and gate by extmark name.
      if ft == "DiffviewFiles" or ft == "DiffviewFileHistory" then
        return
      end
      bind_buffer(run, buf)
    end,
  })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "DiffviewViewClosed",
    callback = function()
      pcall(vim.api.nvim_del_augroup_by_id, group)
    end,
  })
end

---@param run_id? string
function M:run_review(run_id)
  local ok = require_diffview()
  if not ok then
    return
  end
  local run = resolve_run(self, run_id)
  if not run then
    return
  end
  if not run.start_sha or not run.end_sha then
    vim.notify("0x0: run " .. (run.run_id or "?") .. " has no end snapshot; nothing to review", vim.log.levels.INFO)
    return
  end
  attach_diffview_keymaps(run)
  vim.cmd(("DiffviewOpen %s..%s"):format(run.start_sha, run.end_sha))
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
