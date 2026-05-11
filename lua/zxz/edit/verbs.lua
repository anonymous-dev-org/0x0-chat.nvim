local M = {}

local function try_complete_accept()
  local ok, complete = pcall(require, "zxz.complete")
  if ok and type(complete.accept) == "function" and complete.accept() then
    return true
  end
  return false
end

local function try_complete_reject()
  local ok, complete = pcall(require, "zxz.complete")
  if
    ok
    and type(complete.dismiss) == "function"
    and type(complete.is_visible) == "function"
    and complete.is_visible()
  then
    complete.dismiss()
    return true
  end
  return false
end

local function review_action(action)
  local ok, review = pcall(require, "zxz.edit.review")
  if ok and type(review.current_action) == "function" then
    return review.current_action(action)
  end
  return false
end

local function inline_action(action)
  local ok, inline = pcall(require, "zxz.edit.inline_diff")
  if not ok or not inline.has_attached or not inline.has_attached() then
    return false
  end
  inline[action]()
  return true
end

function M.accept_current()
  if try_complete_accept() then
    return true
  end
  if review_action("accept_current") then
    return true
  end
  if inline_action("accept_hunk_at_cursor") then
    return true
  end
  vim.notify("0x0: nothing to accept here", vim.log.levels.INFO)
  return false
end

function M.reject_current()
  if review_action("reject_current") then
    return true
  end
  if inline_action("reject_hunk_at_cursor") then
    return true
  end
  if try_complete_reject() then
    return true
  end
  vim.notify("0x0: nothing to reject here", vim.log.levels.INFO)
  return false
end

function M.accept_file()
  if review_action("accept_file") then
    return true
  end
  if inline_action("accept_file") then
    return true
  end
  vim.notify("0x0: no file changes to accept here", vim.log.levels.INFO)
  return false
end

function M.reject_file()
  if review_action("reject_file") then
    return true
  end
  if inline_action("reject_file") then
    return true
  end
  vim.notify("0x0: no file changes to reject here", vim.log.levels.INFO)
  return false
end

function M.undo_reject()
  local ok, err, checkpoint = require("zxz.edit.ledger").undo_last_reject()
  if not ok then
    vim.notify("0x0: " .. (err or "nothing to undo"), vim.log.levels.INFO)
    return false
  end
  vim.cmd.checktime()
  if checkpoint then
    require("zxz.edit.inline_diff").refresh_all(checkpoint)
  end
  vim.notify("0x0: restored last rejected change", vim.log.levels.INFO)
  return true
end

function M.accept_run()
  if review_action("accept_run") then
    return true
  end
  require("zxz.chat.chat").run_accept()
  return true
end

function M.reject_run()
  if review_action("reject_run") then
    return true
  end
  require("zxz.chat.chat").run_reject()
  return true
end

function M.next_hunk()
  if review_action("next_hunk") then
    return true
  end
  return inline_action("next_hunk")
end

function M.prev_hunk()
  if review_action("prev_hunk") then
    return true
  end
  return inline_action("prev_hunk")
end

return M
