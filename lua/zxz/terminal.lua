---Spawn an agent CLI inside its own git worktree, in a :terminal buffer.
---No JSON-RPC, no ACP. The plugin's only job is launching the process and
---holding a handle for chansend(); review/accept happens via zxz.review.

local Agents = require("zxz.agents")
local Worktree = require("zxz.worktree")

---@class zxz.AgentTerm
---@field id string                 -- matches worktree.id
---@field agent string
---@field worktree zxz.Worktree
---@field bufnr integer
---@field job_id integer
---@field opened_at integer         -- os.time

local M = {}

---@type table<string, zxz.AgentTerm>
local active = {}

local function find_winid(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return win
    end
  end
  return nil
end

---Open the AgentTerm's buffer in a split, focus it, enter insert mode.
---Reuses an existing window if one already shows the buffer.
---@param term zxz.AgentTerm
---@param split? "split"|"vsplit"|"tab"|"current"  defaults to "vsplit"
function M.focus(term, split)
  split = split or "vsplit"
  local win = find_winid(term.bufnr)
  if win then
    vim.api.nvim_set_current_win(win)
  elseif split == "current" then
    vim.api.nvim_win_set_buf(0, term.bufnr)
  else
    local cmd = split == "tab" and "tabnew" or split
    vim.cmd(cmd)
    vim.api.nvim_win_set_buf(0, term.bufnr)
  end
  vim.cmd("startinsert")
end

---@param agent_name string
---@param opts? { cwd?: string, split?: "split"|"vsplit"|"tab"|"current", on_exit?: fun(term: zxz.AgentTerm, code: integer) }
---@return zxz.AgentTerm|nil
---@return string? err
function M.start(agent_name, opts)
  opts = opts or {}
  local def = Agents.get(agent_name)
  if not def then
    return nil, "unknown agent: " .. tostring(agent_name)
  end
  if not Agents.available(agent_name) then
    return nil, ("agent CLI %q not on PATH"):format(def.cmd[1])
  end

  local wt, werr = Worktree.create({ cwd = opts.cwd, agent = agent_name })
  if not wt then
    return nil, werr
  end

  -- Open a buffer first, then start the terminal job in it. This is the
  -- nvim 0.10+ supported path; termopen() still works but is on its way out.
  local split = opts.split or "vsplit"
  if split == "current" then
    -- caller wants the term in the current window; create a scratch buf and swap in.
    local b = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(0, b)
  else
    local cmd = split == "tab" and "tabnew" or split
    vim.cmd(cmd)
    vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  end
  local bufnr = vim.api.nvim_get_current_buf()

  local term_opts = {
    cwd = wt.path,
    env = def.env,
    term = true,
  }
  term_opts.on_exit = function(_, code)
    local t = active[wt.id]
    if t and opts.on_exit then
      opts.on_exit(t, code)
    end
  end

  -- vim.fn.jobstart with term=true is the replacement for termopen() in nvim 0.10+.
  -- It needs to run on a window where the buffer is current.
  local job_id
  local ok, err = pcall(function()
    job_id = vim.fn.jobstart(def.cmd, term_opts)
  end)
  if not ok or not job_id or job_id <= 0 then
    Worktree.remove(wt)
    return nil, "failed to start terminal: " .. tostring(err or job_id)
  end

  local term = {
    id = wt.id,
    agent = agent_name,
    worktree = wt,
    bufnr = bufnr,
    job_id = job_id,
    opened_at = os.time(),
  }
  active[wt.id] = term

  -- Friendly buffer name so :ls and tab-line read well.
  pcall(vim.api.nvim_buf_set_name, bufnr, ("zxz://%s/%s"):format(agent_name, wt.id))

  vim.cmd("startinsert")
  return term, nil
end

---Send text into the AgentTerm's stdin. Appends a newline if not present so the
---agent CLI submits it (Enter). Returns false if the term is gone.
---@param term zxz.AgentTerm
---@param text string
---@param opts? { newline?: boolean }
---@return boolean ok
function M.send(term, text, opts)
  opts = opts or {}
  if not term or not term.job_id then
    return false
  end
  local payload = text
  if opts.newline ~= false and not payload:match("\n$") then
    payload = payload .. "\n"
  end
  local ok, err = pcall(vim.fn.chansend, term.job_id, payload)
  if not ok then
    vim.notify("zxz: chansend failed: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  return true
end

---@return zxz.AgentTerm[]
function M.list()
  local out = {}
  for _, t in pairs(active) do
    table.insert(out, t)
  end
  table.sort(out, function(a, b)
    return a.opened_at < b.opened_at
  end)
  return out
end

---@param id string
---@return zxz.AgentTerm|nil
function M.get(id)
  return active[id]
end

---The "active" term for context-share: the most recently focused agent term,
---falling back to the most recently opened one.
---@return zxz.AgentTerm|nil
function M.current()
  local cur_buf = vim.api.nvim_get_current_buf()
  for _, t in pairs(active) do
    if t.bufnr == cur_buf then
      return t
    end
  end
  local list = M.list()
  return list[#list]
end

---Stop an AgentTerm. By default also removes its worktree (one-worktree-per-
---invocation policy). Set keep_worktree=true to leave it for later cleanup.
---@param term zxz.AgentTerm
---@param opts? { keep_worktree?: boolean }
function M.stop(term, opts)
  opts = opts or {}
  if term.job_id and term.job_id > 0 then
    pcall(vim.fn.jobstop, term.job_id)
  end
  if vim.api.nvim_buf_is_valid(term.bufnr) then
    pcall(vim.api.nvim_buf_delete, term.bufnr, { force = true })
  end
  active[term.id] = nil
  if not opts.keep_worktree then
    Worktree.remove(term.worktree)
  end
end

---For tests only: forget all active terms without touching jobs/buffers/worktrees.
function M._reset()
  active = {}
end

return M
