local M = {}

local function join(...)
  if vim.fs and vim.fs.joinpath then
    return vim.fs.joinpath(...)
  end
  return table.concat({ ... }, "/")
end

function M.state_dir()
  return join(vim.fn.stdpath("state"), "0x0")
end

function M.history_dir()
  return join(M.state_dir(), "history")
end

function M.runs_dir()
  return join(M.state_dir(), "runs")
end

function M.log_path()
  return join(M.state_dir(), "debug.log")
end

function M.complete_dir()
  return join(M.state_dir(), "complete")
end

function M.chat_db_path()
  return join(M.state_dir(), "chat.sqlite")
end

function M.git_ref_prefix()
  return "refs/0x0/checkpoints/"
end

local _migrated = false

function M.migrate_legacy()
  if _migrated then
    return
  end
  _migrated = true
  local legacy = join(vim.fn.stdpath("state"), "zeroxzero")
  local target = M.state_dir()
  if vim.fn.isdirectory(legacy) ~= 1 then
    return
  end
  if vim.fn.isdirectory(target) == 1 then
    return
  end
  local parent = vim.fn.fnamemodify(target, ":h")
  vim.fn.mkdir(parent, "p")
  local ok, err = pcall(vim.fn.rename, legacy, target)
  if not ok then
    vim.notify("0x0: state migration failed: " .. tostring(err), vim.log.levels.WARN)
  end
end

return M
