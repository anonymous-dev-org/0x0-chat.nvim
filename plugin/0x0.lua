if vim.g.loaded_zxz == 1 then
  return
end

vim.g.loaded_zxz = 1

require("zxz").setup()
