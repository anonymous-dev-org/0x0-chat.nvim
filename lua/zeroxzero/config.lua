local M = {}

---@class zeroxzero.Config
---@field cmd string server binary name or path
---@field port number server port (0 = auto-detect running server)
---@field hostname string
---@field auto_start boolean start server if not running
---@field keymaps zeroxzero.KeymapConfig
---@field auth? {username: string, password: string}

---@class zeroxzero.KeymapConfig
---@field send string
---@field send_message string
---@field diff string
---@field interrupt string
---@field inline_edit string
---@field inline_abort string

---@type zeroxzero.Config
M.defaults = {
  cmd = "0x0-server",
  port = 4096,
  hostname = "127.0.0.1",
  auto_start = true,
  keymaps = {
    send = "",
    send_message = "",
    diff = "",
    interrupt = "",
    inline_edit = "",
    inline_abort = "",
  },
  auth = nil,
}

---@type zeroxzero.Config
M.current = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
