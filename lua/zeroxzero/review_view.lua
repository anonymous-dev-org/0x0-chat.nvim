local M = {}

local state = {
  review = nil,
  original_winid = nil,
  proposal_winid = nil,
  original_bufnr = nil,
  proposal_bufnr = nil,
  previous_bufnr = nil,
  created_original_win = false,
  original_statusline = nil,
  original_wrap = nil,
  on_empty = nil,
}

local REVIEW_KEYS = { "]c", "[c", "a", "r", "A", "R", "ga", "gr", "q" }

local function buf_valid(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function win_valid(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function has_buffer_keymap(bufnr, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
    if map.lhs == lhs then
      return true
    end
  end
  return false
end

local function cleanup_buffer(bufnr)
  if not buf_valid(bufnr) then
    return
  end
  for _, winid in ipairs(vim.fn.win_findbuf(bufnr)) do
    if win_valid(winid) then
      pcall(vim.api.nvim_win_call, winid, function()
        vim.cmd("diffoff")
      end)
      pcall(vim.api.nvim_win_close, winid, true)
    end
  end
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end

function M.close()
  if buf_valid(state.original_bufnr) then
    for _, key in ipairs(REVIEW_KEYS) do
      pcall(vim.keymap.del, "n", key, { buffer = state.original_bufnr })
    end
  end
  if buf_valid(state.proposal_bufnr) then
    for _, key in ipairs(REVIEW_KEYS) do
      pcall(vim.keymap.del, "n", key, { buffer = state.proposal_bufnr })
    end
  end
  if win_valid(state.original_winid) then
    pcall(vim.api.nvim_win_call, state.original_winid, function()
      vim.cmd("diffoff")
    end)
    if state.original_statusline then
      vim.wo[state.original_winid].statusline = state.original_statusline
    end
    if state.original_wrap ~= nil then
      vim.wo[state.original_winid].wrap = state.original_wrap
    end
    if state.created_original_win then
      pcall(vim.api.nvim_win_close, state.original_winid, true)
    elseif buf_valid(state.previous_bufnr) then
      pcall(vim.api.nvim_win_set_buf, state.original_winid, state.previous_bufnr)
    end
  end
  if win_valid(state.proposal_winid) then
    pcall(vim.api.nvim_win_call, state.proposal_winid, function()
      vim.cmd("diffoff")
    end)
    pcall(vim.api.nvim_win_close, state.proposal_winid, true)
  end
  cleanup_buffer(state.original_bufnr)
  cleanup_buffer(state.proposal_bufnr)
  state.original_winid = nil
  state.proposal_winid = nil
  state.original_bufnr = nil
  state.proposal_bufnr = nil
  state.previous_bufnr = nil
  state.created_original_win = false
  state.original_statusline = nil
  state.original_wrap = nil
end

local function find_editor_window()
  local current = vim.api.nvim_get_current_win()
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.bo[bufnr].buftype ~= "nofile" and not name:match("%[0x0 Chat") then
      return winid, false
    end
  end
  vim.cmd("leftabove vsplit")
  return vim.api.nvim_get_current_win(), true
end

local function scratch_buffer(name, lines, filetype)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modifiable = false
  if filetype and filetype ~= "" then
    vim.bo[bufnr].filetype = filetype
  end
  return bufnr
end

local function place_cursor()
  local review = state.review
  local hunk = review and review:current_hunk()
  if not hunk then
    return
  end

  local target_win = state.proposal_winid
  local target_line = hunk.new_start
  if hunk.new_count == 0 then
    target_win = state.original_winid
    target_line = hunk.old_start
  end

  if win_valid(target_win) then
    vim.api.nvim_set_current_win(target_win)
    pcall(vim.api.nvim_win_set_cursor, target_win, { math.max(target_line, 1), 0 })
    pcall(vim.cmd, "normal! zz")
  end
end

local function notify_error(err)
  vim.notify("0x0: " .. tostring(err), vim.log.levels.ERROR)
end

local function after_change()
  if not state.review or state.review:is_empty() then
    M.close()
    if state.on_empty then
      state.on_empty()
    end
    return
  end
  M.render({ focus = true })
end

function M.next_hunk()
  if not state.review then
    return
  end
  if not state.review:next_hunk() then
    vim.notify("0x0: no next hunk", vim.log.levels.INFO)
    return
  end
  M.render({ focus = true })
end

function M.previous_hunk()
  if not state.review then
    return
  end
  if not state.review:previous_hunk() then
    vim.notify("0x0: no previous hunk", vim.log.levels.INFO)
    return
  end
  M.render({ focus = true })
end

function M.accept_hunk()
  if not state.review then
    return
  end
  local ok, err = state.review:accept_current_hunk()
  if not ok then
    notify_error(err)
    return
  end
  vim.cmd.checktime()
  after_change()
end

function M.reject_hunk()
  if not state.review then
    return
  end
  local ok, err = state.review:reject_current_hunk()
  if not ok then
    notify_error(err)
    return
  end
  after_change()
end

function M.accept_file()
  if not state.review then
    return
  end
  local ok, err = state.review:accept_current_file()
  if not ok then
    notify_error(err)
    return
  end
  vim.cmd.checktime()
  after_change()
end

function M.reject_file()
  if not state.review then
    return
  end
  local ok, err = state.review:reject_current_file()
  if not ok then
    notify_error(err)
    return
  end
  after_change()
end

local function setup_keymaps(bufnr)
  local opts = { buffer = bufnr, nowait = true, silent = true }
  local maps = {
    { "]c", M.next_hunk, "0x0 next review hunk" },
    { "[c", M.previous_hunk, "0x0 previous review hunk" },
    { "a", M.accept_hunk, "0x0 accept review hunk" },
    { "r", M.reject_hunk, "0x0 reject review hunk" },
    { "A", M.accept_file, "0x0 accept review file" },
    { "R", M.reject_file, "0x0 reject review file" },
    {
      "ga",
      function()
        require("zeroxzero.diff_preview").accept_all()
      end,
      "0x0 accept all review changes",
    },
    {
      "gr",
      function()
        require("zeroxzero.diff_preview").discard_all()
      end,
      "0x0 reject all review changes",
    },
    { "q", M.close, "0x0 close review" },
  }
  for _, map in ipairs(maps) do
    if not has_buffer_keymap(bufnr, map[1]) then
      vim.keymap.set("n", map[1], map[2], vim.tbl_extend("force", opts, { desc = map[3] }))
    end
  end
end

local function statusline(review, file)
  local summary = review:summary()
  return ("0x0 review: %s (%d/%d) | %d files, %d hunks | a/r hunk A/R file ]c/[c navigate"):format(
    file.path,
    review.file_index,
    math.max(summary.files, 1),
    summary.files,
    summary.hunks
  )
end

function M.render(opts)
  opts = opts or {}
  local review = state.review
  if not review or review:is_empty() then
    return false
  end

  local file = review:current_file()
  if not file then
    return false
  end

  local previous_win = vim.api.nvim_get_current_win()
  M.close()

  local root_path = review.worktree:root_path(file.path)
  local original_lines = review.worktree:read_root_file(file.path)
  local proposal_lines = review.worktree:read_proposal_file(file.path)
  local filetype = vim.filetype and vim.filetype.match({ filename = root_path }) or nil

  local original_bufnr = scratch_buffer("[0x0 Original] " .. file.path, original_lines, filetype)
  local proposal_bufnr = scratch_buffer("[0x0 Proposal] " .. file.path, proposal_lines, filetype)
  local original_win, created_original_win = find_editor_window()
  local previous_bufnr = vim.api.nvim_win_get_buf(original_win)
  vim.api.nvim_win_set_buf(original_win, original_bufnr)
  local proposal_win = vim.api.nvim_open_win(proposal_bufnr, false, {
    split = "right",
    win = original_win,
  })

  state.original_winid = original_win
  state.proposal_winid = proposal_win
  state.original_bufnr = original_bufnr
  state.proposal_bufnr = proposal_bufnr
  state.previous_bufnr = previous_bufnr
  state.created_original_win = created_original_win
  state.original_statusline = vim.wo[original_win].statusline
  state.original_wrap = vim.wo[original_win].wrap

  vim.wo[original_win].wrap = false
  vim.wo[proposal_win].wrap = false
  vim.wo[original_win].statusline = statusline(review, file)
  vim.wo[proposal_win].statusline = statusline(review, file)

  vim.api.nvim_win_call(original_win, function()
    vim.cmd("diffthis")
  end)
  vim.api.nvim_win_call(proposal_win, function()
    vim.cmd("diffthis")
  end)

  setup_keymaps(original_bufnr)
  setup_keymaps(proposal_bufnr)
  place_cursor()

  if not opts.focus and win_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  return true
end

function M.open(review, opts)
  opts = opts or {}
  state.review = review
  state.on_empty = opts.on_empty
  return M.render(opts)
end

function M.review()
  return state.review
end

return M
