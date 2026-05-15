---Small, non-blocking notification sound helper.

local M = {}

M.default_sound = "/System/Library/Sounds/Glass.aiff"

---@param _reason? string
function M.play(_reason)
  if vim.g.zxz_notification_sound == false then
    return
  end

  local sound = vim.g.zxz_notification_sound_path or M.default_sound
  if vim.fn.executable("afplay") == 1 and vim.fn.filereadable(sound) == 1 then
    vim.fn.jobstart({ "afplay", sound }, { detach = true })
  else
    vim.api.nvim_echo({ { "\a", "None" } }, false, {})
  end
end

return M
