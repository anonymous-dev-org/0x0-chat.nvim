-- Checkpoint + reconcile lifecycle for a chat: each turn begins with a
-- snapshot of the working tree that the inline diff layer can rewind.

local config = require("zeroxzero.config")
local Checkpoint = require("zeroxzero.checkpoint")
local InlineDiff = require("zeroxzero.inline_diff")
local Reconcile = require("zeroxzero.reconcile")

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
    self.reconcile = Reconcile.new({ checkpoint = cp, mode = config.current.reconcile or "strict" })
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
  -- itself lives at `refs/zeroxzero/checkpoints/<turn_id>` — a *leaf* — so
  -- nesting under it isn't allowed).
  local safe_id = tool_call_id:gsub("[^%w%-_]", "_")
  local suffix = ("%s__%s"):format(self.checkpoint.turn_id, safe_id)
  local cp, err = Checkpoint.snapshot(self.checkpoint.root, {
    ref_suffix = suffix,
    parent_sha = prev_sha,
    label = ("0x0 tool checkpoint %s"):format(tool_call_id),
  })
  if not cp then
    require("zeroxzero.log").warn("checkpoint: per-tool snapshot failed for " .. tool_call_id .. ": " .. tostring(err))
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
  self:_clear_checkpoint()
  vim.notify(("0x0: accepted %d file%s"):format(#files, #files == 1 and "" or "s"), vim.log.levels.INFO)
  return true
end

function M:discard_all()
  if not self.checkpoint then
    vim.notify("0x0: no checkpoint to discard against", vim.log.levels.INFO)
    return
  end
  local ok, err = Checkpoint.restore_all(self.checkpoint)
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

local REVIEW_STATUS = {
  added = "A",
  modified = "M",
  deleted = "D",
}

---@param checkpoint table
---@param files string[]
---@return table[]
local function review_entries(checkpoint, files)
  local entries = {}
  for _, path in ipairs(files) do
    local _, existed = Checkpoint.read_file(checkpoint, path)
    local exists_now = vim.fn.filereadable(checkpoint.root .. "/" .. path) == 1
    local kind = "modified"
    if not existed and exists_now then
      kind = "added"
    elseif existed and not exists_now then
      kind = "deleted"
    end
    entries[#entries + 1] = {
      path = path,
      kind = kind,
      label = ("%s %s"):format(REVIEW_STATUS[kind] or "M", path),
    }
  end
  table.sort(entries, function(a, b)
    return a.path < b.path
  end)
  return entries
end

local function set_scratch_lines(bufnr, name, lines, filetype)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or ""
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

---@param review table
---@param idx integer
function M:_open_review_entry(review, idx)
  local entry = review.entries[idx]
  if not entry or not self.checkpoint then
    return
  end

  if review.opening then
    return
  end
  review.opening = true

  local ok, err = pcall(function()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(review.tabpage)) do
      if win ~= review.list_win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end

    vim.api.nvim_set_current_win(review.list_win)
    vim.api.nvim_win_set_cursor(review.list_win, { idx, 0 })
    vim.api.nvim_buf_clear_namespace(review.list_buf, review.ns, 0, -1)
    vim.api.nvim_buf_set_extmark(review.list_buf, review.ns, idx - 1, 0, {
      line_hl_group = "Visual",
    })

    local path = entry.path
    local abs = self.checkpoint.root .. "/" .. path
    local base, existed = Checkpoint.read_file(self.checkpoint, path)
    local base_lines = vim.split(base or "", "\n", { plain = true })
    if base_lines[#base_lines] == "" then
      table.remove(base_lines)
    end
    if not existed then
      base_lines = {}
    end

    vim.cmd("rightbelow vertical new")
    local base_win = vim.api.nvim_get_current_win()
    local base_buf = vim.api.nvim_get_current_buf()
    set_scratch_lines(
      base_buf,
      ("0x0 checkpoint: %s"):format(path),
      base_lines,
      vim.filetype.match({ filename = path }) or ""
    )

    local work_win
    if entry.kind == "deleted" then
      vim.cmd("rightbelow vertical new")
      work_win = vim.api.nvim_get_current_win()
      local work_buf = vim.api.nvim_get_current_buf()
      set_scratch_lines(work_buf, ("0x0 deleted: %s"):format(path), {}, vim.bo[base_buf].filetype)
    else
      vim.cmd("rightbelow vertical edit " .. vim.fn.fnameescape(abs))
      work_win = vim.api.nvim_get_current_win()
    end

    vim.api.nvim_set_current_win(base_win)
    pcall(vim.cmd, "diffthis")
    vim.api.nvim_set_current_win(work_win)
    pcall(vim.cmd, "diffthis")
    vim.api.nvim_set_current_win(review.list_win)
  end)
  review.opening = false
  if not ok then
    vim.notify("0x0: review failed: " .. tostring(err):gsub("\n.*", ""), vim.log.levels.ERROR)
  end
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

  local entries = review_entries(self.checkpoint, files)
  local ns = vim.api.nvim_create_namespace("zeroxzero_review")

  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local list_win = vim.api.nvim_get_current_win()
  local list_buf = vim.api.nvim_get_current_buf()
  set_scratch_lines(
    list_buf,
    "0x0 review",
    vim.tbl_map(function(entry)
      return entry.label
    end, entries),
    ""
  )
  vim.bo[list_buf].filetype = "zeroxzero-review"
  vim.wo[list_win].number = false
  vim.wo[list_win].relativenumber = false
  vim.wo[list_win].signcolumn = "no"
  vim.api.nvim_win_set_width(list_win, 36)

  local review = {
    tabpage = tabpage,
    list_win = list_win,
    list_buf = list_buf,
    entries = entries,
    ns = ns,
  }

  local open_selected = function()
    local row = vim.api.nvim_win_get_cursor(list_win)[1]
    self:_open_review_entry(review, row)
  end

  vim.keymap.set("n", "<CR>", open_selected, { buffer = list_buf, silent = true, desc = "0x0: review file" })
  vim.keymap.set("n", "q", function()
    pcall(vim.cmd, "tabclose")
  end, { buffer = list_buf, silent = true, desc = "0x0: close review" })

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = list_buf,
    callback = function()
      if vim.api.nvim_get_current_win() == list_win then
        open_selected()
      end
    end,
  })

  self:_open_review_entry(review, 1)
end

function M:show_changes()
  if not self.checkpoint then
    vim.notify("0x0: no active checkpoint", vim.log.levels.INFO)
    return
  end
  local files = Checkpoint.changed_files(self.checkpoint)
  if #files == 0 then
    vim.notify("0x0: no changes since checkpoint", vim.log.levels.INFO)
    return
  end
  vim.ui.select(files, {
    prompt = ("0x0: %d changed file%s"):format(#files, #files == 1 and "" or "s"),
    format_item = function(p)
      return p
    end,
  }, function(choice)
    if not choice then
      return
    end
    local abs = self.checkpoint.root .. "/" .. choice
    vim.cmd("edit " .. vim.fn.fnameescape(abs))
  end)
end

function M:new_session()
  self:_persist_now()
  self:_reset_session()
  self.history:clear()
  self.widget:reset()
  self.persist_id = require("zeroxzero.history_store").new_id()
  self.title = nil
  self.title_requested = false
  self.title_pending = false
  self.persist_created_at = os.time()
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
  self:_set_activity(nil)
  self.config_options = {}
  self:_clear_checkpoint()
end

return M
