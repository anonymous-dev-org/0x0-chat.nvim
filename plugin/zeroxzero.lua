if vim.g.loaded_zeroxzero == 1 then
  return
end

vim.g.loaded_zeroxzero = 1

require("zeroxzero").setup()
