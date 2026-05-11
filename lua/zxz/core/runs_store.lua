local log = require("zxz.core.log")
local paths = require("zxz.core.paths")

local M = {}

local function dir()
  local d = paths.runs_dir()
  if vim.fn.isdirectory(d) == 0 then
    vim.fn.mkdir(d, "p")
  end
  return d
end

local function path_for(id)
  return dir() .. "/" .. id .. ".json"
end

---@param run table { run_id, thread_id, agent, prompt_summary, start_ref, end_ref?, tool_refs?, tool_calls?, edit_events?, files_touched?, status, started_at, ended_at? }
function M.save(run)
  if not run or not run.run_id then
    return
  end
  local ok, encoded = pcall(vim.json.encode, run)
  if not ok then
    log.error("runs_store: encode failed for " .. run.run_id .. ": " .. tostring(encoded))
    return
  end
  local p = path_for(run.run_id)
  local file, ferr = io.open(p, "w")
  if not file then
    log.error("runs_store: open(w) failed for " .. p .. ": " .. tostring(ferr))
    return
  end
  file:write(encoded)
  file:close()
end

---@param run_id string
---@return table|nil
function M.load(run_id)
  local p = path_for(run_id)
  local file = io.open(p, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    log.error("runs_store: decode failed for " .. p .. ": " .. tostring(decoded))
    return nil
  end
  return decoded
end

---@return table[] runs (sorted by started_at desc)
function M.list()
  local entries = {}
  local files = vim.fn.glob(dir() .. "/*.json", false, true)
  for _, f in ipairs(files) do
    local file = io.open(f, "r")
    if file then
      local content = file:read("*a")
      file:close()
      local ok, decoded = pcall(vim.json.decode, content)
      if ok and decoded and decoded.run_id then
        entries[#entries + 1] = decoded
      end
    end
  end
  table.sort(entries, function(a, b)
    return (a.started_at or 0) > (b.started_at or 0)
  end)
  return entries
end

---@param thread_id string
---@return table[]
function M.list_for_thread(thread_id)
  local out = {}
  for _, run in ipairs(M.list()) do
    if run.thread_id == thread_id then
      out[#out + 1] = run
    end
  end
  return out
end

---@param run_id string
function M.delete(run_id)
  os.remove(path_for(run_id))
end

return M
