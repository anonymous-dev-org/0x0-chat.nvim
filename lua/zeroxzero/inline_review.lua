local M = {}

local _ns = vim.api.nvim_create_namespace("zeroxzero_inline_review")

---@class InlineReviewState
---@field bufnr integer the review buffer
---@field source_bufnr? integer the original source buffer (nil if file not open)
---@field file_path string absolute path of the file
---@field original_lines string[] lines before model changes
---@field modified_lines string[] lines after model changes
---@field hunk_count integer
---@field resolved_count integer
---@field on_complete fun(accepted: boolean) callback when review finishes
---@field trailing_newline boolean whether the after text ended with newline
---@field applying boolean guard against BufWipeout firing on intentional close

---@type InlineReviewState?
local _state = nil

---Split text into lines, trimming phantom trailing empty line
---@param text string
---@return string[]
local function split_lines(text)
  local lines = vim.split(text, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

---Build conflict marker buffer content from before/after text using vim.diff
---@param before_lines string[]
---@param after_lines string[]
---@return string[] merged_lines
---@return integer hunk_count
local function build_conflict_markers(before_lines, after_lines)
  local before_text = table.concat(before_lines, "\n") .. "\n"
  local after_text = table.concat(after_lines, "\n") .. "\n"

  local hunks = vim.diff(before_text, after_text, { result_type = "indices" })
  if not hunks or #hunks == 0 then
    return vim.deepcopy(after_lines), 0
  end

  local result = {}
  local before_pos = 1
  local hunk_count = 0

  for _, hunk in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]

    -- Copy unchanged lines before this hunk
    for i = before_pos, start_a - 1 do
      table.insert(result, before_lines[i])
    end

    hunk_count = hunk_count + 1

    table.insert(result, "<<<<<<< Original")
    for i = start_a, start_a + count_a - 1 do
      table.insert(result, before_lines[i])
    end
    table.insert(result, "=======")
    for i = start_b, start_b + count_b - 1 do
      table.insert(result, after_lines[i])
    end
    table.insert(result, ">>>>>>> Modified")

    before_pos = start_a + count_a
  end

  -- Copy remaining unchanged lines after last hunk
  for i = before_pos, #before_lines do
    table.insert(result, before_lines[i])
  end

  return result, hunk_count
end

---Apply highlight extmarks to conflict markers in the buffer
---@param bufnr integer
local function apply_highlights(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, _ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_original = false
  local in_modified = false

  for i, line in ipairs(lines) do
    local lnum = i - 1
    if line:match("^<<<<<<< ") then
      vim.api.nvim_buf_set_extmark(bufnr, _ns, lnum, 0, { line_hl_group = "ZeroInlineMarker" })
      in_original = true
    elseif line == "=======" and in_original then
      vim.api.nvim_buf_set_extmark(bufnr, _ns, lnum, 0, { line_hl_group = "ZeroInlineMarker" })
      in_original = false
      in_modified = true
    elseif line:match("^>>>>>>> ") and in_modified then
      vim.api.nvim_buf_set_extmark(bufnr, _ns, lnum, 0, { line_hl_group = "ZeroInlineMarker" })
      in_modified = false
    elseif in_original then
      vim.api.nvim_buf_set_extmark(bufnr, _ns, lnum, 0, { line_hl_group = "ZeroInlineOriginal" })
    elseif in_modified then
      vim.api.nvim_buf_set_extmark(bufnr, _ns, lnum, 0, { line_hl_group = "ZeroInlineModified" })
    end
  end
end

---Find the conflict block surrounding the cursor
---@param bufnr integer
---@param cursor_line integer 0-based
---@return integer? start_line
---@return integer? separator_line
---@return integer? end_line
local function find_conflict_at_cursor(bufnr, cursor_line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  -- Search backward for <<<<<<< from cursor
  local start_line = nil
  for i = cursor_line, 0, -1 do
    if lines[i + 1]:match("^<<<<<<< ") then
      start_line = i
      break
    end
    if lines[i + 1]:match("^>>>>>>> ") and i ~= cursor_line then
      return nil, nil, nil
    end
  end

  if not start_line then
    return nil, nil, nil
  end

  -- Search forward for ======= and >>>>>>>
  local total = #lines
  local separator_line = nil
  local end_line = nil
  for i = start_line + 1, total - 1 do
    if not separator_line and lines[i + 1] == "=======" then
      separator_line = i
    elseif separator_line and lines[i + 1]:match("^>>>>>>> ") then
      end_line = i
      break
    end
  end

  if not separator_line or not end_line then
    return nil, nil, nil
  end

  return start_line, separator_line, end_line
end

---Resolve a single conflict block — keep "theirs" (modified) lines
---@param bufnr integer
---@param start_line integer 0-based
---@param separator_line integer 0-based
---@param end_line integer 0-based
local function accept_theirs(bufnr, start_line, separator_line, end_line)
  local modified = vim.api.nvim_buf_get_lines(bufnr, separator_line + 1, end_line, false)
  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line + 1, false, modified)
end

---Resolve a single conflict block — keep "ours" (original) lines
---@param bufnr integer
---@param start_line integer 0-based
---@param separator_line integer 0-based
---@param end_line integer 0-based
local function accept_ours(bufnr, start_line, separator_line, end_line)
  local original = vim.api.nvim_buf_get_lines(bufnr, start_line + 1, separator_line, false)
  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line + 1, false, original)
end

---Resolve a single conflict block — keep both sides
---@param bufnr integer
---@param start_line integer 0-based
---@param separator_line integer 0-based
---@param end_line integer 0-based
local function accept_both(bufnr, start_line, separator_line, end_line)
  local original = vim.api.nvim_buf_get_lines(bufnr, start_line + 1, separator_line, false)
  local modified = vim.api.nvim_buf_get_lines(bufnr, separator_line + 1, end_line, false)
  local combined = {}
  vim.list_extend(combined, original)
  vim.list_extend(combined, modified)
  vim.api.nvim_buf_set_lines(bufnr, start_line, end_line + 1, false, combined)
end

---Count remaining conflict markers in the buffer
---@param bufnr integer
---@return integer
local function count_remaining_conflicts(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local count = 0
  for _, line in ipairs(lines) do
    if line:match("^<<<<<<< ") then
      count = count + 1
    end
  end
  return count
end

---Jump to next conflict marker from cursor position
---@param bufnr integer
---@param direction integer 1 for next, -1 for previous
local function jump_to_conflict(bufnr, direction)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local cursor = vim.api.nvim_win_get_cursor(0)
  local current_line = cursor[1] -- 1-based

  if direction == 1 then
    for i = current_line + 1, #lines do
      if lines[i]:match("^<<<<<<< ") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    for i = 1, current_line do
      if lines[i]:match("^<<<<<<< ") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  else
    for i = current_line - 1, 1, -1 do
      if lines[i]:match("^<<<<<<< ") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
    for i = #lines, current_line, -1 do
      if lines[i]:match("^<<<<<<< ") then
        vim.api.nvim_win_set_cursor(0, { i, 0 })
        return
      end
    end
  end
end

---Resolve the conflict at cursor, then check if all hunks are resolved
---@param bufnr integer
---@param resolve_fn fun(bufnr: integer, start_line: integer, separator_line: integer, end_line: integer)
---@param label string
local function resolve_at_cursor(bufnr, resolve_fn, label)
  if not _state or _state.bufnr ~= bufnr then
    return
  end

  local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1
  local start_line, separator_line, end_line = find_conflict_at_cursor(bufnr, cursor_line)
  if not start_line then
    vim.notify("0x0: cursor not inside a conflict block", vim.log.levels.WARN)
    return
  end

  resolve_fn(bufnr, start_line, separator_line, end_line)
  apply_highlights(bufnr)

  local remaining = count_remaining_conflicts(bufnr)
  if remaining == 0 then
    vim.notify("0x0: all hunks resolved — press <CR> to apply or q to discard", vim.log.levels.INFO)
  else
    vim.notify(string.format("0x0: %s — %d conflict(s) remaining", label, remaining), vim.log.levels.INFO)
  end
end

---Close the review buffer and clean up state (defined early for use by apply/discard)
function M.close_review_buffer()
  if not _state then
    return
  end
  local bufnr = _state.bufnr
  _state = nil

  if vim.api.nvim_buf_is_valid(bufnr) then
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
        local alt = vim.fn.bufnr("#")
        if alt ~= -1 and alt ~= bufnr and vim.api.nvim_buf_is_valid(alt) then
          vim.api.nvim_win_set_buf(win, alt)
        elseif #vim.api.nvim_list_wins() > 1 then
          pcall(vim.api.nvim_win_close, win, true)
        else
          -- Last window: create empty buffer instead of closing
          vim.api.nvim_win_set_buf(win, vim.api.nvim_create_buf(true, false))
        end
      end
    end
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

---Apply the resolved buffer content to disk
local function apply_changes()
  if not _state then
    return
  end
  _state.applying = true

  local remaining = count_remaining_conflicts(_state.bufnr)
  if remaining > 0 then
    vim.notify(string.format("0x0: %d unresolved conflict(s) — resolve all before applying", remaining), vim.log.levels.WARN)
    _state.applying = false
    return
  end

  local final_lines = vim.api.nvim_buf_get_lines(_state.bufnr, 0, -1, false)
  local final_content = table.concat(final_lines, "\n")
  if _state.trailing_newline then
    final_content = final_content .. "\n"
  end

  local file = io.open(_state.file_path, "w")
  if not file then
    vim.notify("0x0: failed to write " .. _state.file_path, vim.log.levels.ERROR)
    _state.applying = false
    return
  end
  file:write(final_content)
  file:close()

  if _state.source_bufnr and vim.api.nvim_buf_is_valid(_state.source_bufnr) then
    vim.cmd("checktime " .. _state.source_bufnr)
  end

  local on_complete = _state.on_complete
  M.close_review_buffer()
  on_complete(true)
end

---Discard the review and abort
local function discard_changes()
  if not _state then
    return
  end
  _state.applying = true

  local on_complete = _state.on_complete
  M.close_review_buffer()
  on_complete(false)
end

---Set up keymaps on the review buffer
---@param bufnr integer
local function setup_keymaps(bufnr)
  local buf_opts = { buffer = bufnr, nowait = true }

  vim.keymap.set("n", "co", function()
    resolve_at_cursor(bufnr, accept_ours, "kept original")
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Keep original" }))

  vim.keymap.set("n", "ct", function()
    resolve_at_cursor(bufnr, accept_theirs, "accepted change")
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Accept change" }))

  vim.keymap.set("n", "cb", function()
    resolve_at_cursor(bufnr, accept_both, "kept both")
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Keep both" }))

  vim.keymap.set("n", "ca", function()
    if not _state or _state.bufnr ~= bufnr then return end
    -- Collect all conflict positions, then resolve bottom-up so indices stay stable
    local conflicts = {}
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    for i = 1, #lines do
      if lines[i]:match("^<<<<<<< ") then
        local s, sep, e = find_conflict_at_cursor(bufnr, i - 1)
        if s then
          table.insert(conflicts, { s = s, sep = sep, e = e })
        end
      end
    end
    for i = #conflicts, 1, -1 do
      accept_theirs(bufnr, conflicts[i].s, conflicts[i].sep, conflicts[i].e)
    end
    apply_highlights(bufnr)
    vim.notify("0x0: accepted all changes — press <CR> to apply", vim.log.levels.INFO)
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Accept all changes" }))

  vim.keymap.set("n", "]x", function()
    jump_to_conflict(bufnr, 1)
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Next conflict" }))

  vim.keymap.set("n", "[x", function()
    jump_to_conflict(bufnr, -1)
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Previous conflict" }))

  vim.keymap.set("n", "<CR>", function()
    apply_changes()
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Apply resolved changes" }))

  vim.keymap.set("n", "q", function()
    discard_changes()
  end, vim.tbl_extend("force", buf_opts, { desc = "0x0: Discard changes" }))
end

---Open the conflict review UI for a file diff
---@param opts {file_path: string, source_bufnr?: integer, before: string, after: string, status?: string, on_complete: fun(accepted: boolean)}
function M.open(opts)
  if _state then
    M.close_review_buffer()
  end

  local status = opts.status or "modified"

  -- Handle deleted files: no conflict markers, just confirm deletion
  if status == "deleted" then
    vim.ui.select({ "Delete file", "Keep file" }, {
      prompt = "0x0: Model wants to delete " .. opts.file_path,
    }, function(choice)
      if choice == "Delete file" then
        os.remove(opts.file_path)
        if opts.source_bufnr and vim.api.nvim_buf_is_valid(opts.source_bufnr) then
          vim.cmd("checktime " .. opts.source_bufnr)
        end
        opts.on_complete(true)
      else
        opts.on_complete(false)
      end
    end)
    return
  end

  local trailing_newline = opts.after:sub(-1) == "\n"
  local before_lines = split_lines(opts.before)
  local after_lines = split_lines(opts.after)

  local merged_lines, hunk_count = build_conflict_markers(before_lines, after_lines)

  if hunk_count == 0 then
    vim.notify("0x0: no changes detected", vim.log.levels.INFO)
    opts.on_complete(false)
    return
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, merged_lines)

  local ft = vim.filetype.match({ filename = opts.file_path }) or ""
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].modifiable = true
  if ft ~= "" then
    vim.bo[bufnr].filetype = ft
  end

  local rel_path = opts.file_path:gsub("^" .. vim.pesc(vim.fn.getcwd() .. "/"), "")
  pcall(vim.api.nvim_buf_set_name, bufnr, "review: " .. rel_path)

  _state = {
    bufnr = bufnr,
    source_bufnr = opts.source_bufnr,
    file_path = opts.file_path,
    original_lines = before_lines,
    modified_lines = after_lines,
    hunk_count = hunk_count,
    resolved_count = 0,
    trailing_newline = trailing_newline,
    on_complete = opts.on_complete,
    applying = false,
  }

  setup_keymaps(bufnr)
  apply_highlights(bufnr)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      if _state and _state.bufnr == bufnr and not _state.applying then
        local on_complete = _state.on_complete
        _state = nil
        on_complete(false)
      end
    end,
  })

  vim.api.nvim_set_current_buf(bufnr)
  jump_to_conflict(bufnr, 1)

  vim.notify(
    string.format("0x0: %d conflict(s) — co=original ct=change cb=both ca=all ]x/[x=nav <CR>=apply q=discard", hunk_count),
    vim.log.levels.INFO
  )
end

---Check if a review is currently active
---@return boolean
function M.is_active()
  return _state ~= nil
end

---Get the current review buffer number
---@return integer?
function M.get_bufnr()
  return _state and _state.bufnr
end

return M
