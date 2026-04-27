local Checkpoint = require("zeroxzero.checkpoint")

local M = {}

---@class zeroxzero.Reconcile
---@field checkpoint table|nil
---@field root string|nil
---@field agent_view table<string, string>  abs_path -> content as agent last saw it
---@field mode "strict"|"force"
local Reconcile = {}
Reconcile.__index = Reconcile

---@param opts { checkpoint: table|nil, mode: string|nil }
---@return zeroxzero.Reconcile
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    checkpoint = opts.checkpoint,
    root = opts.checkpoint and opts.checkpoint.root or nil,
    agent_view = {},
    mode = opts.mode == "force" and "force" or "strict",
  }, Reconcile)
end

---@param checkpoint table|nil
function Reconcile:set_checkpoint(checkpoint)
  self.checkpoint = checkpoint
  self.root = checkpoint and checkpoint.root or nil
  -- New checkpoint = new turn boundary; agent's prior reads are stale.
  self.agent_view = {}
end

function Reconcile:set_mode(mode)
  self.mode = mode == "force" and "force" or "strict"
end

local function read_disk(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_disk(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "wb")
  if not f then
    return false, "open failed"
  end
  f:write(content or "")
  f:close()
  return true, nil
end

local function rel_path(root, abs)
  if not root or not abs then
    return abs
  end
  if abs == root then
    return ""
  end
  if abs:sub(1, #root + 1) == root .. "/" then
    return abs:sub(#root + 2)
  end
  return abs
end

---@param abs_path string
---@return string|nil expected, "agent"|"checkpoint"|nil source
function Reconcile:expected_for(abs_path)
  local v = self.agent_view[abs_path]
  if v then
    return v, "agent"
  end
  if self.checkpoint and self.root then
    local rel = rel_path(self.root, abs_path)
    if rel ~= "" then
      local content, existed = Checkpoint.read_file(self.checkpoint, rel)
      if existed and content then
        return content, "checkpoint"
      end
    end
  end
  return nil, nil
end

---Build a unified diff between the agent's expected view and what's now on disk
---so the agent knows how to merge.
local function unified_diff(label_a, a, label_b, b)
  local tmp_a = vim.fn.tempname()
  local tmp_b = vim.fn.tempname()
  vim.fn.writefile(vim.split(a or "", "\n", { plain = true }), tmp_a)
  vim.fn.writefile(vim.split(b or "", "\n", { plain = true }), tmp_b)
  local out = vim.fn.system({
    "diff",
    "-u",
    "--label",
    label_a,
    "--label",
    label_b,
    tmp_a,
    tmp_b,
  })
  vim.fn.delete(tmp_a)
  vim.fn.delete(tmp_b)
  return out or ""
end

---Record what the agent just read (host-mediated read).
---@param abs_path string
---@param content string
function Reconcile:record_read(abs_path, content)
  if abs_path then
    self.agent_view[abs_path] = content or ""
  end
end

---Reconcile a write. Returns nil on success (write may proceed) or an error
---message describing the conflict (in strict mode).
---@param abs_path string
---@param new_content string
---@return string|nil err
function Reconcile:check_write(abs_path, new_content)
  local expected, source = self:expected_for(abs_path)
  if not expected then
    -- New file; nothing to conflict with.
    return nil
  end
  local actual = read_disk(abs_path) or ""
  if actual == expected then
    return nil
  end
  if self.mode == "force" then
    return nil
  end
  local diff = unified_diff(
    ("a/%s (agent's view, from %s)"):format(rel_path(self.root, abs_path), source),
    expected,
    ("b/%s (current on disk)"):format(rel_path(self.root, abs_path)),
    actual
  )
  return ("user has edited %s since you last read it; please re-read or merge.\n%s"):format(
    rel_path(self.root, abs_path),
    diff
  )
end

---Record a successful write so subsequent writes don't see "user-edited" state.
---@param abs_path string
---@param content string
function Reconcile:record_write(abs_path, content)
  if abs_path then
    self.agent_view[abs_path] = content or ""
  end
end

---Read disk content for the agent and record it. Returns content (string) or
---nil + error message.
---@param abs_path string
---@param line? integer 1-based start
---@param limit? integer max number of lines
---@return string|nil content, string|nil err
function Reconcile:read_for_agent(abs_path, line, limit)
  local content = read_disk(abs_path)
  if content == nil then
    return nil, "file not found: " .. tostring(abs_path)
  end
  -- Record the entire file regardless of slice — that's the conflict baseline.
  self:record_read(abs_path, content)
  if line or limit then
    local lines = vim.split(content, "\n", { plain = true })
    local start_idx = math.max(1, line or 1)
    local stop_idx = #lines
    if limit and limit > 0 then
      stop_idx = math.min(#lines, start_idx + limit - 1)
    end
    local slice = {}
    for i = start_idx, stop_idx do
      slice[#slice + 1] = lines[i]
    end
    content = table.concat(slice, "\n")
  end
  return content, nil
end

---Perform a host-mediated write after reconcile. Returns ok, err.
---@param abs_path string
---@param content string
---@return boolean ok, string|nil err
function Reconcile:write_for_agent(abs_path, content)
  local err = self:check_write(abs_path, content)
  if err then
    return false, err
  end
  local ok, werr = write_disk(abs_path, content)
  if not ok then
    return false, werr
  end
  self:record_write(abs_path, content)
  return true, nil
end

return M
