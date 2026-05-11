-- Auto-prelude: an invisible context block prepended to outgoing
-- prompts when config.auto_prelude.* is enabled. Lightweight — no LSP
-- requests, no treesitter walks beyond what's already done elsewhere.

local Checkpoint = require("zxz.core.checkpoint")
local LSP = require("zxz.context.lsp")
local Recent = require("zxz.context.recent")

local M = {}

---@return integer|nil bufnr, integer|nil row
local function source_buffer_and_row()
  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    local bt = vim.bo[buf].buftype
    if
      ft ~= "zxz-chat-input"
      and ft ~= "zxz-chat-files"
      and ft ~= "zxz-inline-edit-input"
      and ft ~= "zxz-inline-ask-input"
      and bt == ""
    then
      local cur = vim.api.nvim_win_get_cursor(win)
      return buf, cur[1]
    end
  end
  return nil, nil
end

---@param cfg table { cursor: boolean, repo_map: boolean, recent: boolean }
---@param cwd string|nil
---@return string|nil
function M.build(cfg, cwd)
  cfg = cfg or {}
  if not (cfg.cursor or cfg.repo_map or cfg.recent) then
    return nil
  end
  local lines = { "[0x0 context]" }

  if cfg.cursor then
    local bufnr, row = source_buffer_and_row()
    if bufnr then
      local name = vim.api.nvim_buf_get_name(bufnr)
      local rel
      cwd = cwd or vim.fn.getcwd()
      local root = Checkpoint.git_root(cwd) or cwd
      if name and name ~= "" and name:sub(1, #root + 1) == root .. "/" then
        rel = name:sub(#root + 2)
      elseif name and name ~= "" then
        rel = vim.fn.fnamemodify(name, ":~:.")
      else
        rel = "(unnamed)"
      end
      lines[#lines + 1] = ("Cursor: %s:%d"):format(rel, row)
      local diags = LSP.diagnostics_for(bufnr)
      local errs, warns = 0, 0
      for _, d in ipairs(diags) do
        if d.severity == vim.diagnostic.severity.ERROR then
          errs = errs + 1
        elseif d.severity == vim.diagnostic.severity.WARN then
          warns = warns + 1
        end
      end
      lines[#lines + 1] = ("Diagnostics on this buffer: %d error%s, %d warning%s"):format(
        errs,
        errs == 1 and "" or "s",
        warns,
        warns == 1 and "" or "s"
      )
    end
  end

  if cfg.recent then
    local list = Recent.list(5)
    if #list > 0 then
      lines[#lines + 1] = "Recent files: " .. table.concat(list, ", ")
    end
  end

  if cfg.repo_map then
    local RepoMap = require("zxz.context.repo_map")
    local root = Checkpoint.git_root(cwd or vim.fn.getcwd()) or (cwd or vim.fn.getcwd())
    lines[#lines + 1] = ""
    lines[#lines + 1] = RepoMap.get_serialized(root)
  end

  if #lines == 1 then
    return nil
  end
  return table.concat(lines, "\n")
end

return M
