---Inline diff overlay: shows a proposed replacement for a buffer range as
---extmark-anchored hunks the user can accept or reject one at a time.
---No persistence, no checkpoints — call `render()`, get a buffer-local state
---back, install keymaps, done. The state goes away when the user accepts all
---hunks or explicitly closes the overlay.

local M = {}

local NS = vim.api.nvim_create_namespace("zxz_inline_diff")

---@class zxz.InlineDiff.Hunk
---@field old_start integer      -- 1-based buffer line where the hunk's old text begins
---@field old_count integer      -- number of old lines (0 for pure insertions)
---@field new_lines string[]     -- replacement lines (empty for pure deletions)
---@field state "pending"|"accepted"|"rejected"
---@field extmark_ids integer[]

---@class zxz.InlineDiff.State
---@field bufnr integer
---@field hunks zxz.InlineDiff.Hunk[]
---@field on_close? fun()

local states_by_buf = {} ---@type table<integer, zxz.InlineDiff.State>

---Compute hunks transforming `old_text` into `new_text` and offset them onto
---the absolute buffer line range starting at `range.start_line` (1-based).
---@param old_text string
---@param new_text string
---@param range { start_line: integer, end_line: integer }
---@return zxz.InlineDiff.Hunk[]
function M.compute_hunks(old_text, new_text, range)
  local indices = vim.diff(old_text, new_text, {
    result_type = "indices",
    algorithm = "histogram",
  })
  ---@cast indices integer[][]
  local new_lines_arr = vim.split(new_text, "\n", { plain = true })
  local hunks = {}
  for _, d in ipairs(indices) do
    local old_start_rel, old_count, new_start_rel, new_count = d[1], d[2], d[3], d[4]
    local abs_old_start
    if old_count == 0 then
      -- Pure insertion: old_start_rel is the 1-based line AFTER which the
      -- insertion happens (vim.diff convention). Map to the next absolute row.
      abs_old_start = range.start_line + old_start_rel
    else
      abs_old_start = range.start_line + old_start_rel - 1
    end
    local new_chunk = {}
    for i = new_start_rel, new_start_rel + new_count - 1 do
      table.insert(new_chunk, new_lines_arr[i] or "")
    end
    table.insert(hunks, {
      old_start = abs_old_start,
      old_count = old_count,
      new_lines = new_chunk,
      state = "pending",
      extmark_ids = {},
    })
  end
  return hunks
end

---Decorate the buffer with extmarks for a hunk.
---@param bufnr integer
---@param h zxz.InlineDiff.Hunk
local function paint_hunk(bufnr, h)
  h.extmark_ids = {}
  -- Highlight deletion lines.
  if h.old_count > 0 then
    local last_line = vim.api.nvim_buf_line_count(bufnr)
    for line = h.old_start, h.old_start + h.old_count - 1 do
      if line >= 1 and line <= last_line then
        local id = vim.api.nvim_buf_set_extmark(bufnr, NS, line - 1, 0, {
          end_row = line - 1,
          end_col = 0,
          hl_group = "DiffDelete",
          hl_eol = true,
          right_gravity = false,
        })
        table.insert(h.extmark_ids, id)
      end
    end
  end
  -- Virtual lines for the additions.
  if #h.new_lines > 0 then
    local virt = {}
    for _, l in ipairs(h.new_lines) do
      table.insert(virt, { { "+ " .. l, "DiffAdd" } })
    end
    -- Anchor: pin to the line ABOVE old_start so the virt_lines render between
    -- the last context line and the deletion. For pure insertions (old_count
    -- == 0), old_start is the line AFTER which we want to insert, so we anchor
    -- to old_start - 1.
    local anchor
    if h.old_count > 0 then
      anchor = h.old_start - 2 -- 0-based: line above the first deletion
    else
      anchor = h.old_start - 1 -- 0-based: anchor on the line we insert below
    end
    anchor = math.max(0, anchor)
    local id = vim.api.nvim_buf_set_extmark(bufnr, NS, anchor, 0, {
      virt_lines = virt,
      virt_lines_above = false,
    })
    table.insert(h.extmark_ids, id)
  end
end

---Strip a hunk's extmarks without otherwise touching the buffer.
---@param bufnr integer
---@param h zxz.InlineDiff.Hunk
local function clear_hunk(bufnr, h)
  for _, id in ipairs(h.extmark_ids) do
    pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, id)
  end
  h.extmark_ids = {}
end

---Find the index of the hunk whose old-range covers `row` (1-based), or the
---one closest below it (so `]h` lands somewhere reasonable from a header row).
---@param state zxz.InlineDiff.State
---@param row integer 1-based
---@return integer|nil idx
local function hunk_at(state, row)
  for i, h in ipairs(state.hunks) do
    if h.state == "pending" then
      local s, e = h.old_start, h.old_start + math.max(h.old_count, 1) - 1
      if row >= s and row <= e then
        return i
      end
    end
  end
  return nil
end

---Replace the old line range of a hunk with its new lines, then shift the
---absolute row of every following pending hunk by the line-count delta.
---@param state zxz.InlineDiff.State
---@param idx integer
local function apply_hunk(state, idx)
  local h = state.hunks[idx]
  if not h or h.state ~= "pending" then
    return
  end
  local end_line_excl = h.old_start - 1 + h.old_count -- 0-based exclusive end for nvim_buf_set_lines
  vim.api.nvim_buf_set_lines(state.bufnr, h.old_start - 1, end_line_excl, false, h.new_lines)
  clear_hunk(state.bufnr, h)
  h.state = "accepted"
  local delta = #h.new_lines - h.old_count
  if delta ~= 0 then
    for j = idx + 1, #state.hunks do
      local other = state.hunks[j]
      if other.state == "pending" then
        other.old_start = other.old_start + delta
      end
    end
  end
end

---Discard a hunk: strip its extmarks but leave the original lines alone.
---@param state zxz.InlineDiff.State
---@param idx integer
local function discard_hunk(state, idx)
  local h = state.hunks[idx]
  if not h or h.state ~= "pending" then
    return
  end
  clear_hunk(state.bufnr, h)
  h.state = "rejected"
end

local function pending_count(state)
  local n = 0
  for _, h in ipairs(state.hunks) do
    if h.state == "pending" then
      n = n + 1
    end
  end
  return n
end

---@param state zxz.InlineDiff.State
local function maybe_close(state)
  if pending_count(state) == 0 then
    M.close(state)
  end
end

---Install buffer-local keymaps; idempotent.
---@param state zxz.InlineDiff.State
local function install_keymaps(state)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, {
      buffer = state.bufnr,
      desc = desc,
      nowait = true,
    })
  end
  map("ga", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local idx = hunk_at(state, row)
    if not idx then
      vim.notify("zxz: cursor not on a hunk", vim.log.levels.WARN)
      return
    end
    apply_hunk(state, idx)
    maybe_close(state)
  end, "zxz.inline_diff: accept hunk")
  map("gr", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local idx = hunk_at(state, row)
    if not idx then
      vim.notify("zxz: cursor not on a hunk", vim.log.levels.WARN)
      return
    end
    discard_hunk(state, idx)
    maybe_close(state)
  end, "zxz.inline_diff: reject hunk")
  map("gA", function()
    for i, h in ipairs(state.hunks) do
      if h.state == "pending" then
        apply_hunk(state, i)
      end
    end
    M.close(state)
  end, "zxz.inline_diff: accept all")
  map("gR", function()
    M.close(state)
  end, "zxz.inline_diff: reject all (close overlay)")
  map("]h", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for _, h in ipairs(state.hunks) do
      if h.state == "pending" and h.old_start > row then
        vim.api.nvim_win_set_cursor(0, { h.old_start, 0 })
        return
      end
    end
  end, "zxz.inline_diff: next hunk")
  map("[h", function()
    local row = vim.api.nvim_win_get_cursor(0)[1]
    local last
    for _, h in ipairs(state.hunks) do
      if h.state == "pending" and h.old_start < row then
        last = h
      end
    end
    if last then
      vim.api.nvim_win_set_cursor(0, { last.old_start, 0 })
    end
  end, "zxz.inline_diff: previous hunk")
end

local function uninstall_keymaps(bufnr)
  for _, lhs in ipairs({ "ga", "gr", "gA", "gR", "]h", "[h" }) do
    pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
  end
end

---Render the proposed replacement of `range` with `new_text` as an inline
---overlay on `bufnr`. Returns the state handle.
---@param bufnr integer
---@param range { start_line: integer, end_line: integer } 1-based inclusive
---@param new_text string
---@param opts? { on_close?: fun() }
---@return zxz.InlineDiff.State
function M.render(bufnr, range, new_text)
  -- Close any existing overlay on this buffer first.
  if states_by_buf[bufnr] then
    M.close(states_by_buf[bufnr])
  end
  local old_lines = vim.api.nvim_buf_get_lines(bufnr, range.start_line - 1, range.end_line, false)
  local old_text = table.concat(old_lines, "\n")
  local hunks = M.compute_hunks(old_text, new_text, range)

  ---@type zxz.InlineDiff.State
  local state = { bufnr = bufnr, hunks = hunks }
  states_by_buf[bufnr] = state

  for _, h in ipairs(hunks) do
    paint_hunk(bufnr, h)
  end
  install_keymaps(state)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      states_by_buf[bufnr] = nil
    end,
  })

  if #hunks == 0 then
    vim.notify("zxz: no changes to apply", vim.log.levels.INFO)
    M.close(state)
  end

  return state
end

---Tear down an overlay: strip every remaining extmark and remove keymaps.
---@param state zxz.InlineDiff.State
function M.close(state)
  if not state or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  for _, h in ipairs(state.hunks) do
    clear_hunk(state.bufnr, h)
  end
  uninstall_keymaps(state.bufnr)
  states_by_buf[state.bufnr] = nil
  if state.on_close then
    pcall(state.on_close)
  end
end

---@param bufnr? integer defaults to current buffer
---@return zxz.InlineDiff.State|nil
function M.get(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  return states_by_buf[bufnr]
end

return M
