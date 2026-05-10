-- Live highlighting of @mentions in the chat input buffer.
-- Resolved mentions (paths that exist) are highlighted as Special; tokens that
-- look like mentions but don't resolve get a DiagnosticError link, so the user
-- sees immediately whether their attachment will be picked up.

local ReferenceMentions = require("zeroxzero.reference_mentions")

local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("zeroxzero_mention_hl")

pcall(api.nvim_set_hl, 0, "ZeroChatMentionResolved", { default = true, link = "Special" })
pcall(api.nvim_set_hl, 0, "ZeroChatMentionInvalid", { default = true, link = "DiagnosticError" })

-- bufnr -> { timer = uv_timer_t, cwd = string, on_update = fun(summary) }
local state = {}

---Find the byte range of an @-token in `line` starting at `from`.
---Returns 0-indexed start, end-exclusive, and the token text.
local function next_mention(line, from)
  local s, e = line:find("@[^%s`]+", from)
  if not s then
    return nil
  end
  -- Strip trailing punctuation the parser would also strip.
  local token = line:sub(s, e)
  local trimmed = token
  while #trimmed > 1 and trimmed:sub(-1):match("[%.%,%;%:%)%]%}]") do
    trimmed = trimmed:sub(1, -2)
  end
  return s - 1, s - 1 + #trimmed, trimmed
end

---Render highlight extmarks for the given input buffer using the supplied
---resolved-mention list (already parsed by reference_mentions).
local function render(bufnr, resolved_set)
  api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for row, line in ipairs(lines) do
    local from = 1
    while true do
      local s, e, token = next_mention(line, from)
      if not s then
        break
      end
      local hl = resolved_set[token] and "ZeroChatMentionResolved" or "ZeroChatMentionInvalid"
      pcall(api.nvim_buf_set_extmark, bufnr, ns, row - 1, s, {
        end_col = e,
        hl_group = hl,
      })
      from = e + 1
    end
  end
end

---Recompute highlights and a short summary, calling `on_update` with
---{ paths = string[], total = integer }.
local function recompute(bufnr, cwd, on_update)
  if not api.nvim_buf_is_valid(bufnr) then
    return
  end
  local text = table.concat(api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local mentions = ReferenceMentions.parse(text, cwd)
  local resolved_set = {}
  local labels = {}
  for _, m in ipairs(mentions) do
    resolved_set[m.raw] = true
    if m.type == "range" then
      labels[#labels + 1] = ("%s#L%d-L%d"):format(m.path, m.start_line, m.end_line)
    else
      labels[#labels + 1] = m.path
    end
  end
  render(bufnr, resolved_set)
  if on_update then
    on_update({ paths = labels, total = #labels })
  end
end

---Attach live mention highlighting + summary to a buffer.
---@param bufnr integer
---@param cwd string|nil
---@param on_update fun({ paths: string[], total: integer })|nil
function M.attach(bufnr, cwd, on_update)
  if not api.nvim_buf_is_valid(bufnr) or state[bufnr] then
    return
  end
  state[bufnr] = { cwd = cwd, on_update = on_update }

  local timer = vim.loop.new_timer()
  state[bufnr].timer = timer

  local function schedule()
    timer:stop()
    timer:start(
      80,
      0,
      vim.schedule_wrap(function()
        local s = state[bufnr]
        if not s or not api.nvim_buf_is_valid(bufnr) then
          return
        end
        recompute(bufnr, s.cwd, s.on_update)
      end)
    )
  end

  api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if not state[bufnr] then
        return true
      end
      schedule()
    end,
    on_detach = function()
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
  if s.timer then
    pcall(function()
      s.timer:stop()
      s.timer:close()
    end)
  end
  state[bufnr] = nil
  if api.nvim_buf_is_valid(bufnr) then
    pcall(api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
  end
end

return M
