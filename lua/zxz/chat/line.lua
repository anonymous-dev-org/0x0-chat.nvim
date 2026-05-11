---@alias zxz.LineSection table
---
---@class zxz.Line
---@field sections zxz.LineSection[]
local M = {}
M.__index = M

---@param sections zxz.LineSection[]
function M:new(sections)
  local this = setmetatable({}, M)
  this.sections = sections
  return this
end

---@param ns_id number
---@param bufnr number
---@param line number
---@param offset number | nil
function M:set_highlights(ns_id, bufnr, line, offset)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local col_start = offset or 0
  for _, section in ipairs(self.sections) do
    local text = section[1]
    local highlight = section[2]
    if type(highlight) == "function" then
      highlight = highlight()
    end
    if highlight then
      vim.highlight.range(bufnr, ns_id, highlight, { line, col_start }, { line, col_start + #text })
    end
    col_start = col_start + #text
  end
end

function M:__tostring()
  local content = {}
  for _, section in ipairs(self.sections) do
    table.insert(content, section[1])
  end
  return table.concat(content, "")
end

function M:__eq(other)
  if not other or type(other) ~= "table" or not other.sections then
    return false
  end
  return vim.deep_equal(self.sections, other.sections)
end

return M
