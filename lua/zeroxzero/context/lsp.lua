-- Shared LSP / diagnostics helpers. Used by inline-ask, code-actions,
-- auto-prelude, and the @hover/@def/@symbol mentions. All functions are
-- best-effort: they return nil if no LSP server is attached or no
-- response arrives in the timeout window.

local M = {}

local DEFAULT_TIMEOUT_MS = 800

local SEVERITY_LABEL = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

---@param bufnr integer
---@return boolean
local function has_lsp(bufnr)
  local clients = vim.lsp.get_clients and vim.lsp.get_clients({ bufnr = bufnr }) or vim.lsp.buf_get_clients(bufnr)
  return clients and next(clients) ~= nil
end

---@param bufnr integer
---@param row integer  -- 0-based
---@param col integer  -- 0-based
---@return table
local function make_position_params(bufnr, row, col)
  return {
    textDocument = { uri = vim.uri_from_bufnr(bufnr) },
    position = { line = row, character = col },
  }
end

---@param bufnr integer
---@param row integer  -- 1-based
---@param col integer  -- 0-based
---@return string|nil
function M.hover_at(bufnr, row, col)
  if not has_lsp(bufnr) then
    return nil
  end
  local params = make_position_params(bufnr, row - 1, col)
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/hover", params, DEFAULT_TIMEOUT_MS)
  if not results then
    return nil
  end
  local parts = {}
  for _, r in pairs(results) do
    local contents = r.result and r.result.contents
    if contents then
      if type(contents) == "string" then
        parts[#parts + 1] = contents
      elseif contents.value then
        parts[#parts + 1] = contents.value
      elseif type(contents) == "table" then
        for _, c in ipairs(contents) do
          if type(c) == "string" then
            parts[#parts + 1] = c
          elseif c.value then
            parts[#parts + 1] = c.value
          end
        end
      end
    end
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "\n\n")
end

---@param bufnr integer
---@param row integer  -- 1-based
---@param col integer  -- 0-based
---@return { path: string, line: integer, character: integer }|nil
function M.definition_at(bufnr, row, col)
  if not has_lsp(bufnr) then
    return nil
  end
  local params = make_position_params(bufnr, row - 1, col)
  local results = vim.lsp.buf_request_sync(bufnr, "textDocument/definition", params, DEFAULT_TIMEOUT_MS)
  if not results then
    return nil
  end
  for _, r in pairs(results) do
    local res = r.result
    if res then
      local item = vim.islist and vim.islist(res) and res[1] or res
      if item then
        local uri = item.uri or item.targetUri
        local range = item.range or item.targetSelectionRange
        if uri and range then
          return {
            path = vim.uri_to_fname(uri),
            line = (range.start and range.start.line or 0) + 1,
            character = range.start and range.start.character or 0,
          }
        end
      end
    end
  end
  return nil
end

---@param bufnr integer
---@param row integer 1-based
---@param col integer 0-based
---@return { name: string, kind: string }|nil
function M.symbol_at(bufnr, row, col)
  -- Treesitter-based; LSP doesn't have a symbol-at-point primitive that
  -- works without a documentSymbol pass.
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row - 1, col } })
  if not ok or not node then
    return nil
  end
  local t = node:type()
  if t == "identifier" or t == "name" or t == "property_identifier" or t == "field_identifier" then
    return { name = vim.treesitter.get_node_text(node, bufnr), kind = t }
  end
  return nil
end

---@param bufnr integer
---@param severity integer|nil
---@return { severity: integer, severity_label: string, message: string, lnum: integer, col: integer, source: string|nil }[]
function M.diagnostics_for(bufnr, severity)
  local opts = severity and { severity = severity } or nil
  local list = vim.diagnostic.get(bufnr, opts)
  local out = {}
  for _, d in ipairs(list) do
    out[#out + 1] = {
      severity = d.severity,
      severity_label = SEVERITY_LABEL[d.severity] or "?",
      message = (d.message or ""):gsub("\n", " "),
      lnum = (d.lnum or 0) + 1,
      col = (d.col or 0) + 1,
      source = d.source,
    }
  end
  return out
end

M.SEVERITY_LABEL = SEVERITY_LABEL

return M
