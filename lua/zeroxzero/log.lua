-- Persistent debug log for chat-nvim. Writes timestamped lines into
-- ~/.local/state/nvim/zeroxzero/debug.log (or vim.fn.stdpath("state")).
-- Rotates when the file exceeds MAX_BYTES so we don't fill the user's disk.

local M = {}

local MAX_BYTES = 5 * 1024 * 1024
local LEVELS = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }

local function log_path()
  local state = vim.fn.stdpath("state")
  local dir = state .. "/zeroxzero"
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  return dir .. "/debug.log"
end

local function rotate(path)
  local stat = vim.loop.fs_stat(path)
  if stat and stat.size > MAX_BYTES then
    pcall(os.rename, path, path .. ".1")
  end
end

---@param level "ERROR"|"WARN"|"INFO"|"DEBUG"
---@param msg string
local function write(level, msg)
  local path = log_path()
  rotate(path)
  local f = io.open(path, "a")
  if not f then
    return
  end
  local stamp = os.date("%Y-%m-%dT%H:%M:%S")
  f:write(("%s [%s] %s\n"):format(stamp, level, msg))
  f:close()
end

local function format_arg(a)
  if type(a) == "string" then
    return a
  end
  return vim.inspect(a)
end

local function joined(...)
  local n = select("#", ...)
  local parts = {}
  for i = 1, n do
    parts[i] = format_arg(select(i, ...))
  end
  return table.concat(parts, " ")
end

function M.error(...)
  write("ERROR", joined(...))
end

function M.warn(...)
  write("WARN", joined(...))
end

function M.info(...)
  write("INFO", joined(...))
end

function M.debug(...)
  write("DEBUG", joined(...))
end

---@return string path
function M.path()
  return log_path()
end

---Open the log file in a split for inspection.
function M.open()
  local path = log_path()
  if vim.fn.filereadable(path) == 0 then
    vim.notify("0x0: log is empty (" .. path .. ")", vim.log.levels.INFO)
    return
  end
  vim.cmd("tabnew " .. vim.fn.fnameescape(path))
  vim.bo.filetype = "log"
end

return M
