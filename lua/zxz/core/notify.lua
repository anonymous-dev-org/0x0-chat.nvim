-- Cross-platform notify helper. Sound config can be:
--   false / "off" / nil  → no sound
--   "bell"               → terminal bell only
--   "notification"       → platform default chime
--   "/abs/path/to.aiff"  → custom audio file (macOS afplay only)

local M = {}

local function platform()
  if vim.fn.has("mac") == 1 then
    return "mac"
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
    return "win"
  end
  return "linux"
end

local function exec(cmd)
  pcall(vim.fn.jobstart, cmd, { detach = true })
end

local PLATFORM_DEFAULTS = {
  mac = "/System/Library/Sounds/Blow.aiff",
  linux = nil,
  win = nil,
}

local function play_file(path)
  local p = platform()
  if p == "mac" and vim.fn.executable("afplay") == 1 then
    exec({ "afplay", path })
  elseif p == "linux" then
    if vim.fn.executable("paplay") == 1 then
      exec({ "paplay", path })
    elseif vim.fn.executable("aplay") == 1 then
      exec({ "aplay", "-q", path })
    end
  elseif p == "win" and vim.fn.executable("powershell") == 1 then
    exec({
      "powershell",
      "-NoProfile",
      "-Command",
      ("(New-Object Media.SoundPlayer '%s').PlaySync()"):format(path),
    })
  end
end

local function play_default()
  local p = platform()
  if p == "mac" then
    play_file(PLATFORM_DEFAULTS.mac)
  elseif p == "linux" then
    if vim.fn.executable("paplay") == 1 then
      exec({ "paplay", "/usr/share/sounds/freedesktop/stereo/message.oga" })
    end
  elseif p == "win" and vim.fn.executable("powershell") == 1 then
    exec({ "powershell", "-NoProfile", "-Command", "[console]::beep(800,200)" })
  end
end

local function ring_tty()
  pcall(function()
    local f = io.open("/dev/tty", "w")
    if f then
      f:write("\a")
      f:close()
    end
  end)
end

---@param sound string|false|nil  sound config (see file header)
---@param pattern string  autocmd User pattern to fire
function M.notify(sound, pattern)
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern })
  if sound == nil or sound == false or sound == "off" then
    return
  end
  if sound == "bell" then
    ring_tty()
    return
  end
  if sound == "notification" then
    play_default()
    ring_tty()
    return
  end
  if type(sound) == "string" and sound ~= "" then
    play_file(sound)
  end
  ring_tty()
end

return M
