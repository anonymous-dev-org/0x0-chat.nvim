local Review = require("zeroxzero.review")
local ReviewView = require("zeroxzero.review_view")

local M = {}

local state = {
  bufnr = nil,
  worktree = nil,
  review = nil,
  on_accept_all = nil,
  on_discard_all = nil,
}

local function ensure_message_buffer()
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    return state.bufnr
  end

  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, "[0x0 Chat Review]")
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "markdown"
  state.bufnr = bufnr
  return bufnr
end

local function render_message(message)
  ReviewView.close()
  local bufnr = ensure_message_buffer()
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { message })
  vim.bo[bufnr].modifiable = false
  if vim.fn.bufwinid(bufnr) == -1 then
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, bufnr)
    vim.api.nvim_win_set_height(0, 3)
  end
end

local function refresh(opts)
  opts = opts or {}
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return false
  end
  if not state.worktree:is_valid() then
    state.worktree = nil
    state.review = nil
    render_message("Chat review worktree is no longer available.")
    vim.notify("0x0: chat review worktree is no longer available", vim.log.levels.WARN)
    return false
  end

  state.review = state.review or Review.new(state.worktree)
  state.review:refresh()
  if state.review:is_empty() then
    render_message("No changes in chat worktree.")
    return false
  end

  return ReviewView.open(state.review, {
    focus = opts.focus,
    on_empty = function()
      state.review = nil
      render_message("No changes in chat worktree.")
    end,
  })
end

function M.show_worktree(worktree, opts)
  opts = opts or {}
  if worktree and state.worktree ~= worktree then
    state.review = nil
  end
  state.worktree = worktree or state.worktree
  state.on_accept_all = opts.on_accept_all or state.on_accept_all
  state.on_discard_all = opts.on_discard_all or state.on_discard_all
  return refresh(opts)
end

function M.refresh(opts)
  return refresh(opts)
end

function M.accept_current_hunk()
  return ReviewView.accept_hunk()
end

function M.accept_current_file()
  return ReviewView.accept_file()
end

function M.accept_all()
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return
  end
  if state.on_accept_all then
    return state.on_accept_all()
  end
  state.review = state.review or Review.new(state.worktree)
  local ok, err = state.review:accept_all()
  if not ok then
    vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    return
  end
  state.worktree:discard()
  state.worktree = nil
  state.review = nil
  state.on_accept_all = nil
  state.on_discard_all = nil
  ReviewView.close()
  vim.cmd.checktime()
  render_message("Accepted all chat changes.")
  return true
end

function M.discard_all()
  if not state.worktree then
    vim.notify("0x0: no chat review worktree", vim.log.levels.INFO)
    return
  end
  if state.on_discard_all then
    return state.on_discard_all()
  end
  state.worktree:discard()
  state.worktree = nil
  state.review = nil
  state.on_accept_all = nil
  state.on_discard_all = nil
  ReviewView.close()
  render_message("Discarded all chat changes.")
  return true
end

function M.clear_worktree(worktree)
  if not worktree or state.worktree == worktree then
    state.worktree = nil
    state.review = nil
    state.on_accept_all = nil
    state.on_discard_all = nil
    ReviewView.close()
  end
end

function M.render_message(message)
  render_message(message)
end

return M
