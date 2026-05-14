-- Checkpoint + reconcile lifecycle for a chat: each turn begins with a
-- snapshot of the working tree that the inline diff layer can rewind.

local config = require("zxz.core.config")
local Checkpoint = require("zxz.core.checkpoint")
local InlineDiff = require("zxz.edit.inline_diff")
local Ledger = require("zxz.edit.ledger")
local Reconcile = require("zxz.core.reconcile")

local M = {}

---Take a fresh checkpoint snapshot at the start of every turn so the diff
---baseline always reflects the working tree as the user just submitted it.
---@param on_ready fun(checkpoint: table|nil, err: table|nil)
function M:_ensure_checkpoint(on_ready)
  local root = self.repo_root or Checkpoint.git_root(vim.fn.getcwd())
  if not root then
    on_ready(nil, {
      message = "0x0: not in a git repository — run `git init` first.\n"
        .. "Inline diff requires a git tree as the rewind / review baseline.",
    })
    return
  end
  self.repo_root = root
  local cp, err = Checkpoint.snapshot(root)
  if not cp then
    on_ready(nil, { message = err or "checkpoint snapshot failed" })
    return
  end
  self.checkpoint = cp
  if self.reconcile then
    self.reconcile:set_checkpoint(cp)
    self.reconcile:set_mode(config.current.reconcile or "strict")
  else
    self.reconcile = Reconcile.new({
      checkpoint = cp,
      mode = config.current.reconcile or "strict",
    })
  end
  InlineDiff.set_active(cp)
  on_ready(cp, nil)
end

function M:_clear_checkpoint()
  InlineDiff.set_active(nil)
  if self.reconcile then
    self.reconcile:set_checkpoint(nil)
  end
  if self.tool_checkpoints then
    for _, cp in pairs(self.tool_checkpoints) do
      Checkpoint.delete_ref(cp)
    end
  end
  self.tool_checkpoints = {}
  self.tool_call_order = {}
  if not self.checkpoint then
    return
  end
  Checkpoint.delete_ref(self.checkpoint)
  self.checkpoint = nil
end

---Snapshot the working tree onto a per-tool-call ref so /diff can show
---exactly what a single tool changed. Parent points at the previous
---checkpoint (turn or prior tool) so the per-call diff is minimal.
---@param tool_call_id string
function M:_snapshot_for_tool(tool_call_id)
  if not tool_call_id or tool_call_id == "" or not self.checkpoint then
    return
  end
  self.tool_checkpoints = self.tool_checkpoints or {}
  self.tool_call_order = self.tool_call_order or {}
  if self.tool_checkpoints[tool_call_id] then
    -- Tool emitted a second `completed` update; refresh the snapshot in place.
    Checkpoint.delete_ref(self.tool_checkpoints[tool_call_id])
  end
  local prev_sha
  if #self.tool_call_order > 0 then
    local last_id = self.tool_call_order[#self.tool_call_order]
    if last_id ~= tool_call_id and self.tool_checkpoints[last_id] then
      prev_sha = self.tool_checkpoints[last_id].sha
    end
  end
  prev_sha = prev_sha or self.checkpoint.sha
  -- Use `__` rather than `/` to avoid git's ref D/F conflict (the turn ref
  -- itself lives at `refs/0x0/checkpoints/<turn_id>` — a *leaf* — so
  -- nesting under it isn't allowed).
  local safe_id = tool_call_id:gsub("[^%w%-_]", "_")
  local suffix = ("%s__%s"):format(self.checkpoint.turn_id, safe_id)
  local cp, err = Checkpoint.snapshot(self.checkpoint.root, {
    ref_suffix = suffix,
    parent_sha = prev_sha,
    label = ("0x0 tool checkpoint %s"):format(tool_call_id),
  })
  if not cp then
    require("zxz.core.log").warn("checkpoint: per-tool snapshot failed for " .. tool_call_id .. ": " .. tostring(err))
    return
  end
  cp.parent_sha = prev_sha
  cp.tool_call_id = tool_call_id
  self.tool_checkpoints[tool_call_id] = cp
  if not vim.tbl_contains(self.tool_call_order, tool_call_id) then
    table.insert(self.tool_call_order, tool_call_id)
  end
end

function M:accept_all()
  if not self.checkpoint then
    vim.notify("0x0: no checkpoint to accept against", vim.log.levels.INFO)
    return
  end
  local files = Checkpoint.changed_files(self.checkpoint)
  if #files == 0 then
    vim.notify("0x0: no pending changes", vim.log.levels.INFO)
    return
  end
  local ok, err = Ledger.accept_all(self.checkpoint)
  if not ok then
    vim.notify("0x0: " .. (err or "accept failed"), vim.log.levels.ERROR)
    return
  end
  self:_clear_checkpoint()
  vim.notify(("0x0: accepted %d file%s"):format(#files, #files == 1 and "" or "s"), vim.log.levels.INFO)
  return true
end

function M:discard_all()
  if not self.checkpoint then
    vim.notify("0x0: no checkpoint to discard against", vim.log.levels.INFO)
    return
  end
  local ok, err = Ledger.reject_all(self.checkpoint)
  if not ok then
    vim.notify("0x0: " .. (err or "discard failed"), vim.log.levels.ERROR)
    return
  end
  self:_clear_checkpoint()
  vim.cmd.checktime()
  vim.notify("0x0: discarded chat changes", vim.log.levels.INFO)
  return true
end

---Open a scratch buffer showing the full turn diff (or a per-tool diff if
---tool_call_id is given). Surfaces the work done in the active turn.
---@param tool_call_id? string
function M:diff(tool_call_id)
  if not self.checkpoint then
    vim.notify("0x0: no active checkpoint", vim.log.levels.INFO)
    return
  end

  local title, diff_text
  if tool_call_id and tool_call_id ~= "" then
    local cp = self.tool_checkpoints and self.tool_checkpoints[tool_call_id]
    if not cp then
      vim.notify("0x0: no checkpoint for tool " .. tool_call_id, vim.log.levels.INFO)
      return
    end
    local args = {
      "git",
      "-C",
      cp.root,
      "diff",
      "--no-ext-diff",
      "--unified=3",
      cp.parent_sha or self.checkpoint.sha,
      cp.sha,
    }
    diff_text = vim.fn.system(args) or ""
    title = ("0x0 diff (tool %s)"):format(tool_call_id)
  else
    diff_text = Checkpoint.diff_text(self.checkpoint, nil, 3)
    title = ("0x0 turn diff (%s)"):format(self.checkpoint.turn_id)
  end

  if diff_text == "" then
    vim.notify("0x0: no changes to display", vim.log.levels.INFO)
    return
  end

  vim.cmd("tabnew")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, title)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "diff"
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(diff_text, "\n", { plain = true }))
  vim.bo[bufnr].modifiable = false
end

function M:review()
  if not self.checkpoint then
    vim.notify("0x0: no active checkpoint", vim.log.levels.INFO)
    return
  end
  local files = Checkpoint.changed_files(self.checkpoint)
  if #files == 0 then
    vim.notify("0x0: no changes since checkpoint", vim.log.levels.INFO)
    return
  end
  require("zxz.edit.review").open_checkpoint(self.checkpoint, { chat = self })
end

---Build a row label combining attached-overlay hunk counts and any files
---changed since the checkpoint that don't currently have an open buffer.
---@return { path: string, abs: string, hunks: integer|nil, bufnr: integer|nil }[]
local function changes_rows(self)
  local rows = {}
  local seen = {}
  for _, e in ipairs(InlineDiff.list_attached()) do
    rows[#rows + 1] = {
      path = e.path,
      abs = self.checkpoint.root .. "/" .. e.path,
      hunks = e.hunks,
      bufnr = e.bufnr,
    }
    seen[e.path] = true
  end
  for _, p in ipairs(Checkpoint.changed_files(self.checkpoint)) do
    if not seen[p] then
      rows[#rows + 1] = {
        path = p,
        abs = self.checkpoint.root .. "/" .. p,
        hunks = nil,
        bufnr = nil,
      }
    end
  end
  table.sort(rows, function(a, b)
    return a.path < b.path
  end)
  return rows
end

local function row_label(row)
  if row.hunks then
    return ("%-40s  %d hunk%s"):format(row.path, row.hunks, row.hunks == 1 and "" or "s")
  end
  return ("%-40s  (no open buffer)"):format(row.path)
end

function M:show_changes()
  if not self.checkpoint then
    vim.notify("0x0: no active checkpoint", vim.log.levels.INFO)
    return
  end
  local rows = changes_rows(self)
  if #rows == 0 then
    vim.notify("0x0: no changes since checkpoint", vim.log.levels.INFO)
    return
  end

  local lines = {}
  for i, r in ipairs(rows) do
    lines[i] = row_label(r)
  end

  local width = math.min(vim.o.columns - 6, 80)
  local height = math.min(#lines + 1, math.floor(vim.o.lines * 0.4))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = (" 0x0 changes (%d file%s) "):format(#rows, #rows == 1 and "" or "s"),
    title_pos = "center",
  })
  vim.wo[win].cursorline = true

  local self_ref = self
  local closed = false

  local function close()
    if closed then
      return
    end
    closed = true
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end

  local function refresh()
    rows = changes_rows(self_ref)
    if #rows == 0 then
      close()
      return
    end
    local new_lines = {}
    for i, r in ipairs(rows) do
      new_lines[i] = row_label(r)
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    vim.bo[buf].modifiable = false
  end

  local function current_row()
    local idx = vim.api.nvim_win_get_cursor(win)[1]
    return rows[idx], idx
  end

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close, vim.tbl_extend("force", opts, { desc = "0x0 changes: close" }))
  vim.keymap.set("n", "<Esc>", close, vim.tbl_extend("force", opts, { desc = "0x0 changes: close" }))
  vim.keymap.set("n", "<CR>", function()
    local r = current_row()
    if not r then
      return
    end
    close()
    vim.cmd("edit " .. vim.fn.fnameescape(r.abs))
    if r.hunks and r.hunks > 0 then
      pcall(InlineDiff.next_hunk)
    end
  end, vim.tbl_extend("force", opts, { desc = "0x0 changes: open file" }))
  vim.keymap.set("n", "a", function()
    local r = current_row()
    if not r or not r.bufnr then
      vim.notify("0x0: file is not open in a buffer", vim.log.levels.INFO)
      return
    end
    local cur_win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_set_current_buf, r.bufnr)
    InlineDiff.accept_file()
    if vim.api.nvim_win_is_valid(cur_win) then
      pcall(vim.api.nvim_set_current_win, cur_win)
    end
    refresh()
  end, vim.tbl_extend("force", opts, { desc = "0x0 changes: accept file" }))
  vim.keymap.set("n", "r", function()
    local r = current_row()
    if not r or not r.bufnr then
      vim.notify("0x0: file is not open in a buffer", vim.log.levels.INFO)
      return
    end
    local cur_win = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_set_current_buf, r.bufnr)
    InlineDiff.reject_file()
    if vim.api.nvim_win_is_valid(cur_win) then
      pcall(vim.api.nvim_set_current_win, cur_win)
    end
    refresh()
  end, vim.tbl_extend("force", opts, { desc = "0x0 changes: reject file" }))
end

function M:new_session()
  if self.on_new_chat then
    self.on_new_chat(self)
    return
  end
  self:_persist_now()
  self:_reset_session()
  self.history:clear()
  self.widget:reset()
  self.persist_id = require("zxz.core.history_store").new_id()
  self.title = nil
  self.title_requested = false
  self.title_pending = false
  self.persist_created_at = os.time()
  self.run_ids = {}
  self.current_run = nil
  self:open()
end

function M:stop()
  self:_reset_session()
end

function M:_reset_session()
  self.widget:unbind_permission_keys()
  if self.client and self.session_id then
    self.client:cancel(self.session_id)
    self.client:unsubscribe(self.session_id)
  end
  if self.client then
    self.client:stop()
  end
  self.client = nil
  self.session_id = nil
  self.in_flight = false
  self.response_started = false
  self.cancel_requested = false
  self.queued_prompts = {}
  self.pending_trim = {}
  if self.permission_queue then
    for _, entry in ipairs(self.permission_queue) do
      pcall(entry.respond, "reject_once")
    end
    self.permission_queue = {}
  end
  self:_set_activity(nil)
  self.config_options = {}
  if self.current_run then
    self:_finalize_run("cancelled")
  end
  self:_clear_checkpoint()
end

return M
