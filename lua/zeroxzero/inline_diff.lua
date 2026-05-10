local Checkpoint = require("zeroxzero.checkpoint")

local api = vim.api
local M = {}

local ns = api.nvim_create_namespace("zeroxzero_inline_diff")

---@class zeroxzero.InlineHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field old_lines string[]
---@field new_lines string[]
---@field type "modify"|"add"|"delete"

---@class zeroxzero.InlineFile
---@field path string repo-relative
---@field abspath string
---@field type "modify"|"add"|"delete"
---@field hunks zeroxzero.InlineHunk[]

-- Per-buffer state: bufnr -> { file = InlineFile, checkpoint = checkpoint }
local buf_state = {}

-- Active checkpoint set by the chat module so autocmds can refresh on the fly.
local active_checkpoint = nil

local function ensure_highlights()
  local set = vim.api.nvim_set_hl
  pcall(set, 0, "ZeroChatDiffAdd", { default = true, link = "DiffAdd" })
  pcall(set, 0, "ZeroChatDiffDelete", { default = true, link = "DiffDelete" })
  pcall(set, 0, "ZeroChatDiffChange", { default = true, link = "DiffChange" })
  pcall(set, 0, "ZeroChatDiffSign", { default = true, link = "DiffChange" })
  pcall(set, 0, "ZeroChatDiffHint", { default = true, link = "Comment" })
end

ensure_highlights()

---Parse `git diff` unified output into per-path hunks.
---@param text string
---@return table<string, zeroxzero.InlineFile>
function M.parse(text)
  local files = {}
  local current
  local cur_hunk
  for line in (text or ""):gmatch("([^\n]*)\n?") do
    if line:match("^diff %-%-git ") then
      local a, b = line:match("^diff %-%-git a/(.-) b/(.+)$")
      local path = b or a or "?"
      current = { path = path, hunks = {}, type = "modify" }
      files[path] = current
      cur_hunk = nil
    elseif current then
      if line:match("^new file mode") or line:match("^%-%-%- /dev/null") then
        current.type = "add"
      elseif line:match("^deleted file mode") or line:match("^%+%+%+ /dev/null") then
        current.type = "delete"
      elseif line:match("^@@") then
        local os_, oc, ns_, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
        if os_ then
          cur_hunk = {
            old_start = tonumber(os_) or 0,
            old_count = oc == "" and 1 or (tonumber(oc) or 0),
            new_start = tonumber(ns_) or 0,
            new_count = nc == "" and 1 or (tonumber(nc) or 0),
            old_lines = {},
            new_lines = {},
          }
          table.insert(current.hunks, cur_hunk)
        end
      elseif cur_hunk and #line > 0 then
        local p = line:sub(1, 1)
        local body = line:sub(2)
        if p == "-" then
          table.insert(cur_hunk.old_lines, body)
        elseif p == "+" then
          table.insert(cur_hunk.new_lines, body)
        end
      end
    end
  end
  return files
end

local function clear_marks(bufnr)
  if api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  end
end

local function place_marks(bufnr, file)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  clear_marks(bufnr)
  local line_count = api.nvim_buf_line_count(bufnr)
  for hi, hunk in ipairs(file.hunks or {}) do
    -- Render removed lines as virt_lines above the new range.
    if #hunk.old_lines > 0 then
      local anchor = math.max(0, math.min((hunk.new_start or 1) - 1, line_count - 1))
      if hunk.new_count == 0 then
        anchor = math.max(0, math.min(hunk.new_start - 1, line_count - 1))
      end
      local virt_lines = {}
      for _, l in ipairs(hunk.old_lines) do
        table.insert(virt_lines, { { "- " .. l, "ZeroChatDiffDelete" } })
      end
      pcall(api.nvim_buf_set_extmark, bufnr, ns, anchor, 0, {
        virt_lines = virt_lines,
        virt_lines_above = hunk.new_count > 0,
      })
    end

    -- Highlight the added range.
    if hunk.new_count > 0 then
      for i = 0, hunk.new_count - 1 do
        local lnum = (hunk.new_start - 1) + i
        if lnum >= 0 and lnum < line_count then
          pcall(api.nvim_buf_set_extmark, bufnr, ns, lnum, 0, {
            line_hl_group = "ZeroChatDiffAdd",
            sign_text = i == 0 and "▍" or " ",
            sign_hl_group = "ZeroChatDiffSign",
          })
        end
      end
      -- Hint at first line of hunk.
      local hint_line = math.max(0, math.min(hunk.new_start - 1, line_count - 1))
      pcall(api.nvim_buf_set_extmark, bufnr, ns, hint_line, 0, {
        virt_text = {
          {
            (" [%d/%d] %sa accept · %sr reject · %sm add hunk"):format(
              hi,
              #file.hunks,
              vim.g.maplocalleader or "\\",
              vim.g.maplocalleader or "\\",
              vim.g.maplocalleader or "\\"
            ),
            "ZeroChatDiffHint",
          },
        },
        virt_text_pos = "eol",
        hl_mode = "combine",
      })
    end
  end
end

local function bind_keymaps(bufnr)
  local opts = { buffer = bufnr, silent = true, nowait = true }
  vim.keymap.set("n", "<localleader>a", function()
    M.accept_hunk_at_cursor()
  end, vim.tbl_extend("force", opts, { desc = "0x0: accept hunk" }))
  vim.keymap.set("n", "<localleader>r", function()
    M.reject_hunk_at_cursor()
  end, vim.tbl_extend("force", opts, { desc = "0x0: reject hunk" }))
  vim.keymap.set("n", "]h", function()
    M.next_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: next hunk" }))
  vim.keymap.set("n", "[h", function()
    M.prev_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: prev hunk" }))
  vim.keymap.set("n", "<localleader>m", function()
    require("zeroxzero.chat").add_current_hunk()
  end, vim.tbl_extend("force", opts, { desc = "0x0: add hunk to chat" }))
  vim.keymap.set("n", "<localleader>f", function()
    require("zeroxzero.chat").add_current_file()
  end, vim.tbl_extend("force", opts, { desc = "0x0: add file to chat" }))
end

local function unbind_keymaps(bufnr)
  pcall(vim.keymap.del, "n", "<localleader>a", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "<localleader>r", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "]h", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "[h", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "<localleader>m", { buffer = bufnr })
  pcall(vim.keymap.del, "n", "<localleader>f", { buffer = bufnr })
end

---@param bufnr integer
---@param file zeroxzero.InlineFile|nil
---@param checkpoint table|nil
function M.attach(bufnr, file, checkpoint)
  if not bufnr or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not file or not file.hunks or #file.hunks == 0 then
    M.detach(bufnr)
    return
  end
  buf_state[bufnr] = { file = file, checkpoint = checkpoint }
  place_marks(bufnr, file)
  bind_keymaps(bufnr)
end

---@param bufnr integer
function M.detach(bufnr)
  buf_state[bufnr] = nil
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    clear_marks(bufnr)
    unbind_keymaps(bufnr)
  end
end

---Reload the buffer from disk if unmodified, then re-place the overlay using
---the given checkpoint.
---@param checkpoint table
---@param abs_path string
function M.refresh_path(checkpoint, abs_path)
  if not checkpoint or not abs_path then
    return
  end
  local bufnr = vim.fn.bufnr(abs_path)
  if bufnr == -1 or not api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not vim.bo[bufnr].modified then
    pcall(vim.cmd, "checktime " .. bufnr)
  end
  local rel = abs_path
  if checkpoint.root and abs_path:sub(1, #checkpoint.root + 1) == checkpoint.root .. "/" then
    rel = abs_path:sub(#checkpoint.root + 2)
  end
  local diff_text = Checkpoint.diff_text(checkpoint, { rel }, 0)
  local files = M.parse(diff_text)
  local file = files[rel]
  if file then
    file.abspath = abs_path
  end
  M.attach(bufnr, file, checkpoint)
end

---Refresh every buffer that currently has an attached overlay.
---@param checkpoint table
function M.refresh_all(checkpoint)
  if not checkpoint then
    return
  end
  local diff_text = Checkpoint.diff_text(checkpoint, nil, 0)
  local files = M.parse(diff_text)
  -- Detach files that are no longer changed.
  for bufnr, state in pairs(buf_state) do
    if api.nvim_buf_is_valid(bufnr) then
      local rel = state.file and state.file.path
      if rel and not files[rel] then
        M.detach(bufnr)
      end
    else
      buf_state[bufnr] = nil
    end
  end
  -- Attach for every changed file that has an open buffer.
  for rel, file in pairs(files) do
    local abs = checkpoint.root .. "/" .. rel
    local bufnr = vim.fn.bufnr(abs)
    if bufnr ~= -1 and api.nvim_buf_is_valid(bufnr) then
      if not vim.bo[bufnr].modified then
        pcall(vim.cmd, "checktime " .. bufnr)
      end
      file.abspath = abs
      M.attach(bufnr, file, checkpoint)
    end
  end
end

---Detach every overlay (called when the checkpoint is cleared).
function M.detach_all()
  for bufnr, _ in pairs(buf_state) do
    M.detach(bufnr)
  end
  buf_state = {}
end

---@param checkpoint table|nil
function M.set_active(checkpoint)
  active_checkpoint = checkpoint
  if checkpoint then
    M.refresh_all(checkpoint)
  else
    M.detach_all()
  end
end

local augroup = api.nvim_create_augroup("zeroxzero_inline_diff", { clear = true })
api.nvim_create_autocmd({ "BufReadPost", "BufWritePost" }, {
  group = augroup,
  callback = function(args)
    if not active_checkpoint then
      return
    end
    local path = api.nvim_buf_get_name(args.buf)
    if path == "" then
      return
    end
    M.refresh_path(active_checkpoint, path)
  end,
})

local function find_hunk_at(bufnr)
  local state = buf_state[bufnr]
  if not state or not state.file then
    return nil
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  for i, hunk in ipairs(state.file.hunks) do
    local start = hunk.new_start
    local stop = start + math.max(0, hunk.new_count) - 1
    if hunk.new_count == 0 then
      stop = start
    end
    if cursor >= start and cursor <= stop then
      return state, i, hunk
    end
  end
  return nil
end

local function format_hunk(hunk)
  local old_count = hunk.old_count or #hunk.old_lines
  local new_count = hunk.new_count or #hunk.new_lines
  local lines = {
    ("@@ -%d,%d +%d,%d @@"):format(hunk.old_start or 0, old_count, hunk.new_start or 0, new_count),
  }
  for _, line in ipairs(hunk.old_lines or {}) do
    lines[#lines + 1] = "-" .. line
  end
  for _, line in ipairs(hunk.new_lines or {}) do
    lines[#lines + 1] = "+" .. line
  end
  return lines
end

function M.current_hunk_reference()
  local state, _, hunk = find_hunk_at(api.nvim_get_current_buf())
  if not state or not hunk or not state.file then
    return nil
  end
  return {
    path = state.file.path,
    hunk = hunk,
    lines = format_hunk(hunk),
  }
end

function M.next_hunk()
  local bufnr = api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    return
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  for _, hunk in ipairs(state.file.hunks) do
    if hunk.new_start > cursor then
      api.nvim_win_set_cursor(0, { hunk.new_start, 0 })
      return
    end
  end
  api.nvim_win_set_cursor(0, { state.file.hunks[1].new_start, 0 })
end

function M.prev_hunk()
  local bufnr = api.nvim_get_current_buf()
  local state = buf_state[bufnr]
  if not state or not state.file or #state.file.hunks == 0 then
    return
  end
  local cursor = api.nvim_win_get_cursor(0)[1]
  local prev
  for _, hunk in ipairs(state.file.hunks) do
    if hunk.new_start < cursor then
      prev = hunk
    else
      break
    end
  end
  prev = prev or state.file.hunks[#state.file.hunks]
  api.nvim_win_set_cursor(0, { prev.new_start, 0 })
end

function M.accept_hunk_at_cursor()
  local bufnr = api.nvim_get_current_buf()
  local state, idx = find_hunk_at(bufnr)
  if not state or not idx then
    vim.notify("0x0: no hunk under cursor", vim.log.levels.INFO)
    return
  end
  table.remove(state.file.hunks, idx)
  if #state.file.hunks == 0 then
    M.detach(bufnr)
  else
    place_marks(bufnr, state.file)
  end
end

function M.reject_hunk_at_cursor()
  local bufnr = api.nvim_get_current_buf()
  local state, _, hunk = find_hunk_at(bufnr)
  if not state or not hunk then
    vim.notify("0x0: no hunk under cursor", vim.log.levels.INFO)
    return
  end
  if vim.bo[bufnr].modified then
    vim.notify("0x0: save the buffer before rejecting (it has unsaved edits)", vim.log.levels.WARN)
    return
  end
  -- Replace [new_start, new_start+new_count) with hunk.old_lines.
  local s = hunk.new_start - 1
  local e = s + hunk.new_count
  if hunk.new_count == 0 then
    -- Pure deletion in the new file: insert old lines after `s`.
    s = hunk.new_start
    e = s
  end
  pcall(api.nvim_buf_set_lines, bufnr, s, e, false, hunk.old_lines)
  -- Persist to disk so the next refresh sees the change.
  pcall(function()
    api.nvim_buf_call(bufnr, function()
      vim.cmd("silent! write")
    end)
  end)
  if state.checkpoint then
    M.refresh_path(state.checkpoint, state.file.abspath or vim.api.nvim_buf_get_name(bufnr))
  end
end

---Returns a list of currently-attached buffers.
---@return { bufnr: integer, path: string, hunks: integer }[]
function M.list_attached()
  local out = {}
  for bufnr, state in pairs(buf_state) do
    if api.nvim_buf_is_valid(bufnr) and state.file then
      table.insert(out, {
        bufnr = bufnr,
        path = state.file.path,
        hunks = #state.file.hunks,
      })
    end
  end
  return out
end

return M
