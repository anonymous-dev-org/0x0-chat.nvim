local Checkpoint = require("zxz.core.checkpoint")
local EditEvents = require("zxz.core.edit_events")
local InlineDiff = require("zxz.edit.inline_diff")
local Ledger = require("zxz.edit.ledger")

local M = {}

local NS = vim.api.nvim_create_namespace("zxz_review")
local states = {}

local STATUS_LABEL = {
  add = "A",
  delete = "D",
  modify = "M",
}

local function run_root(run)
  return run and (run.root or Checkpoint.git_root(vim.fn.getcwd()))
end

---@param root string
---@param sha string
---@param path string
---@return boolean
local function exists_in_ref(root, sha, path)
  vim.fn.system({ "git", "-C", root, "cat-file", "-e", sha .. ":" .. path })
  return vim.v.shell_error == 0
end

local function write_disk_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(content or "")
  f:close()
  return true
end

---@param root string
---@param sha string
---@param path string
---@return boolean ok, string|nil err
local function restore_path_from(root, sha, path)
  if exists_in_ref(root, sha, path) then
    local out = vim.fn.system({ "git", "-C", root, "show", sha .. ":" .. path })
    if vim.v.shell_error ~= 0 then
      return false, out
    end
    if not write_disk_file(root .. "/" .. path, out or "") then
      return false, "write failed for " .. path
    end
    return true, nil
  end
  local abs = root .. "/" .. path
  if vim.fn.filereadable(abs) == 1 then
    os.remove(abs)
  end
  return true, nil
end

---@param diff_text string
---@return table[]
local function file_chunks(diff_text)
  local parsed = InlineDiff.parse(diff_text)
  local chunks = {}
  local current
  for line in (diff_text or ""):gmatch("([^\n]*)\n?") do
    if line == "" and not current then
      goto continue
    end
    local path = line:match("^diff %-%-git a/.- b/(.+)$")
    if path then
      current = {
        path = path,
        lines = { line },
        parsed = parsed[path],
      }
      chunks[#chunks + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = line
    end
    ::continue::
  end
  return chunks
end

local function build_checkpoint_state(checkpoint, chat)
  local diff_text = Checkpoint.diff_text(checkpoint, nil, 3)
  if diff_text == "" then
    return nil, "no changes since checkpoint"
  end
  local files = EditEvents.pending_chunks(checkpoint.turn_id)
  if #files == 0 then
    files = file_chunks(diff_text)
    EditEvents.annotate_chunks(files, checkpoint.turn_id)
  end
  return {
    kind = "checkpoint",
    checkpoint = checkpoint,
    chat = chat,
    root = checkpoint.root,
    title = ("0x0 Review | checkpoint %s"):format(checkpoint.turn_id or "?"),
    files = files,
    statuses = {},
  }
end

local function refresh_checkpoint_state(state)
  if not state or state.kind ~= "checkpoint" then
    return
  end
  local diff_text = Checkpoint.diff_text(state.checkpoint, nil, 3)
  state.files = EditEvents.pending_chunks(state.checkpoint.turn_id)
  if #state.files == 0 then
    state.files = file_chunks(diff_text)
    EditEvents.annotate_chunks(state.files, state.checkpoint.turn_id)
  end
  state.statuses = {}
end

local function build_run_state(run, chat)
  if not run or not run.start_sha or not run.end_sha then
    return nil, "run has no end snapshot; nothing to review"
  end
  local root = run_root(run)
  if not root then
    return nil, "not in a git repository"
  end
  local args = {
    "git",
    "-C",
    root,
    "diff",
    "--no-ext-diff",
    "--unified=3",
    run.start_sha,
    run.end_sha,
  }
  if run.files_touched and #run.files_touched > 0 then
    args[#args + 1] = "--"
    vim.list_extend(args, run.files_touched)
  end
  local diff_text = vim.fn.system(args)
  if vim.v.shell_error ~= 0 then
    return nil, diff_text or "git diff failed"
  end
  if diff_text == "" then
    return nil, "run touched no files"
  end
  local files = EditEvents.pending_chunks(run)
  if #files == 0 then
    files = file_chunks(diff_text)
    EditEvents.annotate_chunks(files, run)
  end
  return {
    kind = "run",
    run = run,
    chat = chat,
    root = root,
    title = ("0x0 Review | run %s"):format(run.run_id or "?"),
    files = files,
    statuses = {},
  }
end

local function file_label(state, file)
  local parsed = file.parsed or {}
  local kind = STATUS_LABEL[parsed.type or "modify"] or "M"
  local status = state.statuses[file.path]
  local prefix = status and ("[" .. status:sub(1, 1) .. "]") or "[ ]"
  local hunks = parsed.hunks and #parsed.hunks or 0
  return ("%s %s %s (%d hunk%s)"):format(prefix, kind, file.path, hunks, hunks == 1 and "" or "s")
end

local function file_header(file)
  local parsed = file.parsed or {}
  local kind = STATUS_LABEL[parsed.type or "modify"] or "M"
  local hunks = parsed.hunks and #parsed.hunks or 0
  return ("%s %s (%d hunk%s)"):format(kind, file.path, hunks, hunks == 1 and "" or "s")
end

local function hunk_label(state, file, hunk, idx, total)
  local status = state.statuses[file.path]
  local prefix = status and ("[" .. status:sub(1, 1) .. "]") or "[ ]"
  local header = hunk.diff_lines and hunk.diff_lines[1]
  if not header or header == "" then
    header = ("@@ -%d,%d +%d,%d @@"):format(
      hunk.old_start or 0,
      hunk.old_count or #(hunk.old_lines or {}),
      hunk.new_start or 0,
      hunk.new_count or #(hunk.new_lines or {})
    )
  end
  local provenance = hunk.tool_call_id and (" · " .. hunk.tool_call_id) or ""
  return ("%s hunk %d/%d %s%s"):format(prefix, idx, total, header, provenance)
end

local function render(bufnr)
  local state = states[bufnr]
  if not state then
    return
  end
  local lines = {
    "# 0x0 Review",
    state.title,
    "Keys: a/r hunk | A/R file | ga/gr all | u undo reject | <CR> open file | q close",
    "",
  }
  local line_file = {}
  local line_item = {}
  if #(state.files or {}) == 0 then
    lines[#lines + 1] = "No unresolved changes."
  end
  for _, file in ipairs(state.files or {}) do
    local row = #lines + 1
    lines[row] = file_header(file)
    line_file[row] = file
    line_item[row] = { kind = "file", file = file }
    local hunks = file.parsed and file.parsed.hunks or {}
    for idx, hunk in ipairs(hunks) do
      local n = #lines + 1
      lines[n] = hunk_label(state, file, hunk, idx, #hunks)
      line_file[n] = file
      line_item[n] = { kind = "hunk_header", file = file, hunk = hunk, hunk_index = idx }
      for _, line in ipairs(hunk.diff_lines or {}) do
        if not line:match("^@@") then
          local diff_row = #lines + 1
          lines[diff_row] = line
          line_file[diff_row] = file
          line_item[diff_row] = { kind = "hunk_line", file = file, hunk = hunk, hunk_index = idx }
        end
      end
      lines[#lines + 1] = ""
    end
    if #hunks == 0 then
      local n = #lines + 1
      lines[n] = file_label(state, file)
      line_file[n] = file
      line_item[n] = { kind = "file", file = file }
    end
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  for row, item in pairs(line_item) do
    local file = item.file
    if item.kind == "hunk_header" then
      vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, { line_hl_group = "CursorLine" })
    elseif item.kind == "file" then
      vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, { line_hl_group = "Title" })
    elseif file then
      local line = lines[row] or ""
      local hl = line:sub(1, 1) == "+" and "DiffAdd" or (line:sub(1, 1) == "-" and "DiffDelete" or nil)
      if hl then
        vim.api.nvim_buf_set_extmark(bufnr, NS, row - 1, 0, { line_hl_group = hl })
      end
    end
  end
  vim.bo[bufnr].modifiable = false
  state.line_file = line_file
  state.line_item = line_item
end

local function current_state()
  local bufnr = vim.api.nvim_get_current_buf()
  return states[bufnr], bufnr
end

local function current_file(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row, 1, -1 do
    local item = state.line_item and state.line_item[i]
    local file = item and item.file or (state.line_file and state.line_file[i])
    if file then
      return file
    end
  end
  return nil
end

local function current_hunk(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for i = row, 1, -1 do
    local item = state.line_item and state.line_item[i]
    if item and item.hunk then
      return item.file, item.hunk, item.hunk_index
    end
    if item and item.kind == "file" then
      return nil
    end
  end
  return nil
end

local function hunk_target_line(hunk)
  local offset = 0
  for _, line in ipairs(hunk.diff_lines or {}) do
    local prefix = line:sub(1, 1)
    if prefix == " " then
      offset = offset + 1
    elseif prefix == "+" or prefix == "-" then
      break
    end
  end
  return math.max(1, (hunk.new_start or 1) + offset)
end

local accept_file
local reject_file

local function refresh_run_file(state, action, file)
  local run = state.run
  local root = state.root
  if action == "accept" then
    if not run.end_sha then
      return false, "run has no end snapshot"
    end
    return restore_path_from(root, run.end_sha, file.path)
  end
  return restore_path_from(root, run.start_sha, file.path)
end

local function accept_hunk(state, bufnr)
  local file, hunk = current_hunk(state)
  if not file or not hunk then
    return false
  end
  if state.kind ~= "checkpoint" then
    return accept_file(state, bufnr)
  end
  local ok, err = Ledger.accept_hunk(state.checkpoint, file.path, hunk)
  if not ok then
    vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
    return true
  end
  refresh_checkpoint_state(state)
  InlineDiff.refresh_path(state.checkpoint, state.root .. "/" .. file.path)
  render(bufnr)
  vim.notify("0x0: accepted hunk in " .. file.path, vim.log.levels.INFO)
  return true
end

local function reject_hunk(state, bufnr)
  local file, hunk = current_hunk(state)
  if not file or not hunk then
    return false
  end
  if state.kind ~= "checkpoint" then
    return reject_file(state, bufnr)
  end
  local ok, err = Ledger.reject_hunk(state.checkpoint, file.path, hunk)
  if not ok then
    vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
    return true
  end
  refresh_checkpoint_state(state)
  InlineDiff.refresh_path(state.checkpoint, state.root .. "/" .. file.path)
  vim.cmd.checktime()
  render(bufnr)
  vim.notify("0x0: rejected hunk in " .. file.path, vim.log.levels.INFO)
  return true
end

accept_file = function(state, bufnr)
  local file = current_file(state)
  if not file then
    return false
  end
  if state.kind == "checkpoint" then
    local ok, err = Ledger.accept_file(state.checkpoint, file.path)
    if not ok then
      vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    refresh_checkpoint_state(state)
    InlineDiff.refresh_path(state.checkpoint, state.root .. "/" .. file.path)
  else
    local ok, err = refresh_run_file(state, "accept", file)
    if not ok then
      vim.notify("0x0: accept failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    vim.cmd.checktime()
  end
  if state.kind ~= "checkpoint" then
    if state.run and state.run.run_id then
      EditEvents.set_path_status(state.run.run_id, file.path, "accepted")
    end
    state.statuses[file.path] = "accepted"
  end
  render(bufnr)
  vim.notify("0x0: accepted " .. file.path, vim.log.levels.INFO)
  return true
end

reject_file = function(state, bufnr)
  local file = current_file(state)
  if not file then
    return false
  end
  if state.kind == "checkpoint" then
    local ok, err = Ledger.reject_file(state.checkpoint, file.path)
    if not ok then
      vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
    refresh_checkpoint_state(state)
    InlineDiff.refresh_path(state.checkpoint, state.root .. "/" .. file.path)
  else
    local ok, err = refresh_run_file(state, "reject", file)
    if not ok then
      vim.notify("0x0: reject failed: " .. (err or "?"), vim.log.levels.ERROR)
      return true
    end
  end
  vim.cmd.checktime()
  if state.kind ~= "checkpoint" then
    if state.run and state.run.run_id then
      EditEvents.set_path_status(state.run.run_id, file.path, "rejected")
    end
    state.statuses[file.path] = "rejected"
  end
  render(bufnr)
  vim.notify("0x0: rejected " .. file.path, vim.log.levels.INFO)
  return true
end

local function accept_all(state)
  if state.kind == "checkpoint" then
    if state.chat and state.chat.accept_all then
      state.chat:accept_all()
    else
      require("zxz.chat.chat").accept_all()
    end
  elseif state.chat and state.chat.run_accept then
    state.chat:run_accept(state.run.run_id)
  else
    require("zxz.chat.chat").run_accept(state.run.run_id)
  end
  return true
end

local function reject_all(state)
  if state.kind == "checkpoint" then
    if state.chat and state.chat.discard_all then
      state.chat:discard_all()
    else
      require("zxz.chat.chat").discard_all()
    end
  elseif state.chat and state.chat.run_reject then
    state.chat:run_reject(state.run.run_id)
  else
    require("zxz.chat.chat").run_reject(state.run.run_id)
  end
  return true
end

local function open_file(state)
  local file = current_file(state)
  if not file then
    return false
  end
  local _, hunk = current_hunk(state)
  local abs = state.root .. "/" .. file.path
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.api.nvim_buf_get_name(buf) == abs then
      vim.api.nvim_set_current_win(win)
      if hunk then
        pcall(vim.api.nvim_win_set_cursor, win, { hunk_target_line(hunk), 0 })
      end
      return true
    end
  end
  vim.cmd("rightbelow vertical noswapfile split " .. vim.fn.fnameescape(abs))
  if hunk then
    pcall(vim.api.nvim_win_set_cursor, 0, { hunk_target_line(hunk), 0 })
  end
  return true
end

local function jump_hunk(direction)
  local state = select(1, current_state())
  if not state or not state.line_item then
    return false
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local rows = {}
  for r, item in pairs(state.line_item) do
    if item.kind == "hunk_header" then
      rows[#rows + 1] = r
    end
  end
  table.sort(rows)
  local target
  if direction > 0 then
    for _, r in ipairs(rows) do
      if r > row then
        target = r
        break
      end
    end
    target = target or rows[1]
  else
    for i = #rows, 1, -1 do
      local r = rows[i]
      if r < row then
        target = r
        break
      end
    end
    target = target or rows[#rows]
  end
  if target then
    vim.api.nvim_win_set_cursor(0, { target, 0 })
    return true
  end
  return false
end

local ACTIONS = {
  accept_current = accept_hunk,
  accept_file = accept_file,
  reject_current = reject_hunk,
  reject_file = reject_file,
  accept_run = accept_all,
  reject_run = reject_all,
}

function M.current_action(action)
  local state, bufnr = current_state()
  if not state then
    return false
  end
  if action == "next_hunk" then
    return jump_hunk(1)
  elseif action == "prev_hunk" then
    return jump_hunk(-1)
  elseif action == "open_file" then
    return open_file(state)
  end
  local fn = ACTIONS[action]
  if not fn then
    return false
  end
  return fn(state, bufnr)
end

local function bind(bufnr)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "a", function()
    require("zxz.edit.verbs").accept_current()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: accept hunk" }))
  vim.keymap.set("n", "r", function()
    require("zxz.edit.verbs").reject_current()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: reject hunk" }))
  vim.keymap.set("n", "u", function()
    require("zxz.edit.verbs").undo_reject()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: undo last reject" }))
  vim.keymap.set("n", "A", function()
    require("zxz.edit.verbs").accept_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: accept file" }))
  vim.keymap.set("n", "R", function()
    require("zxz.edit.verbs").reject_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: reject file" }))
  vim.keymap.set("n", "ga", function()
    require("zxz.edit.verbs").accept_run()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: accept all" }))
  vim.keymap.set("n", "gr", function()
    require("zxz.edit.verbs").reject_run()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: reject all" }))
  vim.keymap.set("n", "<CR>", function()
    local state = states[bufnr]
    if state then
      open_file(state)
    end
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: open file" }))
  vim.keymap.set("n", "]h", function()
    require("zxz.edit.verbs").next_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: next hunk" }))
  vim.keymap.set("n", "[h", function()
    require("zxz.edit.verbs").prev_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: previous hunk" }))
  vim.keymap.set("n", "q", function()
    pcall(vim.cmd, "bdelete")
  end, vim.tbl_extend("force", opts, { desc = "0x0 review: close" }))
end

local function open_state(state)
  vim.cmd("tabnew")
  local bufnr = vim.api.nvim_get_current_buf()
  states[bufnr] = state
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_name(bufnr, state.title)
  vim.bo[bufnr].filetype = "zxz-review"
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.cursorline = true
  render(bufnr)
  bind(bufnr)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      states[bufnr] = nil
    end,
  })
end

function M.open_checkpoint(checkpoint, opts)
  local state, err = build_checkpoint_state(checkpoint, opts and opts.chat)
  if not state then
    vim.notify("0x0: " .. (err or "nothing to review"), vim.log.levels.INFO)
    return
  end
  open_state(state)
end

function M.open_run(run, opts)
  local state, err = build_run_state(run, opts and opts.chat)
  if not state then
    vim.notify("0x0: " .. (err or "nothing to review"), vim.log.levels.INFO)
    return
  end
  open_state(state)
end

function M.refresh_checkpoint(checkpoint)
  if not checkpoint then
    return
  end
  for bufnr, state in pairs(states) do
    if vim.api.nvim_buf_is_valid(bufnr) and state.kind == "checkpoint" and state.checkpoint == checkpoint then
      refresh_checkpoint_state(state)
      render(bufnr)
    end
  end
end

Ledger.on_change(function(checkpoint)
  vim.schedule(function()
    M.refresh_checkpoint(checkpoint)
  end)
end)

function M._state(bufnr)
  return states[bufnr]
end

return M
