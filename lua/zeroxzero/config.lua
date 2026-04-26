local M = {}

---@class zeroxzero.Config
---@field server_url string
---@field provider? string
---@field model? string
---@field chat_buffer_name string
---@field keymaps table<string, string|string[]|false>

---@type zeroxzero.Config
M.defaults = {
  server_url = "http://localhost:4096",
  provider = nil,
  model = nil,
  chat_buffer_name = "[0x0 Chat]",
  keymaps = {
    submit = { "<CR>", "<leader>as" },
  },
}

---@type zeroxzero.Config
M.current = vim.deepcopy(M.defaults)

---@param opts? table
function M.setup(opts)
  M.current = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
