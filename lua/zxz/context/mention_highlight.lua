-- Live highlighting of @mentions in the chat input buffer.
-- Resolved mentions (those that survive `reference_mentions.parse`) are
-- painted Special; tokens that look like a mention but don't resolve get
-- a DiagnosticError link, so the user sees immediately whether their
-- attachment will be picked up.

local ReferenceMentions = require("zxz.context.reference_mentions")

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("zxz_mention_hl")
local augroup_prefix = "zxz_mention_hl_"

pcall(api.nvim_set_hl, 0, "ZxzChatMentionResolved", { default = true, link = "Special" })
pcall(api.nvim_set_hl, 0, "ZxzChatMentionInvalid", { default = true, link = "DiagnosticError" })

-- bufnr -> { cwd, on_update, augroup, pending, last_text, last_summary }
local state = {}

local function summaries_equal(a, b)
  if not a or not b then
    return false
  end
  if a.total ~= b.total then
    return false
  end
  if #(a.paths or {}) ~= #(b.paths or {}) then
    return false
  end
  for i = 1, #a.paths do
    if a.paths[i] ~= b.paths[i] then
      return false
    end
  end
  return true
end

local function recompute(bufnr, cwd, on_update)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")

  -- Fast-path: when the buffer hasn't changed since the last recompute,
  -- skip everything. (TextChangedI can fire for whitespace/cursor edits.)
  local s = state[bufnr]
  if s and s.last_text == text then
    return
  end

  -- Fast-path: buffer contains no '@' anywhere → no mentions to mark.
  -- Just clear extmarks once, emit an empty summary on transition, return.
  if not text:find("@", 1, true) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    local empty = { paths = {}, total = 0 }
    if s then
      s.last_text = text
      if on_update and not summaries_equal(s.last_summary, empty) then
        s.last_summary = empty
        on_update(empty)
      else
        s.last_summary = empty
      end
    end
    return
  end

  local mentions = ReferenceMentions.parse(text, cwd)

  -- Line/col offsets for each newline so we can map a byte offset in `text`
  -- back to (row, col) for extmarks.
  local line_starts = { 0 }
  do
    local offset = 0
    for i = 1, #lines - 1 do
      offset = offset + #lines[i] + 1 -- +1 for the inserted "\n"
      line_starts[i + 1] = offset
    end
  end

  local function offset_to_pos(byte)
    -- linear scan is fine — input buffer is small
    for row = #line_starts, 1, -1 do
      if byte >= line_starts[row] then
        return row - 1, byte - line_starts[row]
      end
    end
    return 0, byte
  end

  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

  -- Mark resolved spans.
  local labels = {}
  local covered = {}
  for _, m in ipairs(mentions) do
    if m.start_byte and m.end_byte then
      local row, col = offset_to_pos(m.start_byte)
      local end_row, end_col = offset_to_pos(m.end_byte)
      pcall(api.nvim_buf_set_extmark, bufnr, ns, row, col, {
        end_row = end_row,
        end_col = end_col,
        hl_group = "ZxzChatMentionResolved",
      })
      covered[m.start_byte] = true
    end
    if m.type == "range" then
      labels[#labels + 1] = ("%s#L%d-L%d"):format(m.path, m.start_line, m.end_line)
    elseif m.path then
      labels[#labels + 1] = m.path
    else
      labels[#labels + 1] = m.raw:sub(2)
    end
  end

  -- Mark invalid spans: every `@token` at a mention boundary that parse()
  -- didn't accept. Reuse cursor_token by passing the cursor at the end of
  -- the candidate token, so the boundary rule stays in sync with parse().
  for row_idx, line in ipairs(lines) do
    local from = 1
    while true do
      local s, e = line:find("@[^%s`]+", from)
      if not s then
        break
      end
      from = e + 1
      local start_col, token = ReferenceMentions.cursor_token(line, e)
      if start_col and token and token ~= "" then
        -- Match parse()'s trailing-punctuation trim so the underline doesn't
        -- extend past what the parser would consider the mention text.
        while #token > 0 and token:sub(-1):match("[%.%,%;%:%)%]%}]") do
          token = token:sub(1, -2)
        end
        local byte = line_starts[row_idx] + (start_col - 1)
        if token ~= "" and not covered[byte] then
          pcall(api.nvim_buf_set_extmark, bufnr, ns, row_idx - 1, start_col - 1, {
            end_col = (start_col - 1) + 1 + #token,
            hl_group = "ZxzChatMentionInvalid",
          })
        end
      end
    end
  end

  local summary = { paths = labels, total = #labels }
  if s then
    s.last_text = text
    if on_update and not summaries_equal(s.last_summary, summary) then
      s.last_summary = summary
      on_update(summary)
    else
      s.last_summary = summary
    end
  elseif on_update then
    on_update(summary)
  end
end

local function schedule(bufnr)
  local s = state[bufnr]
  if not s or s.pending then
    return
  end
  s.pending = true
  vim.defer_fn(function()
    local cur = state[bufnr]
    if not cur then
      return
    end
    cur.pending = false
    recompute(bufnr, cur.cwd, cur.on_update)
  end, 80)
end

---Attach live mention highlighting + summary to a buffer.
---@param bufnr integer
---@param cwd string|nil
---@param on_update fun({ paths: string[], total: integer })|nil
function M.attach(bufnr, cwd, on_update)
  if not api.nvim_buf_is_valid(bufnr) or state[bufnr] then
    return
  end
  local augroup = api.nvim_create_augroup(augroup_prefix .. bufnr, { clear = true })
  state[bufnr] = {
    cwd = cwd,
    on_update = on_update,
    augroup = augroup,
    pending = false,
    last_text = nil,
    last_summary = nil,
  }

  api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "TextChangedP" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      schedule(bufnr)
    end,
  })
  api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })

  -- First render synchronously so callers see the initial summary immediately.
  recompute(bufnr, cwd, on_update)
end

function M.detach(bufnr)
  local s = state[bufnr]
  if not s then
    return
  end
  pcall(api.nvim_del_augroup_by_id, s.augroup)
  state[bufnr] = nil
  if api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end
end

return M
