---Push context from the user's nvim buffers into the active agent terminal.
---No clipboard hop — straight chansend into the agent CLI's stdin.

local Terminal = require("zxz.terminal")

local M = {}

---@param p string absolute or relative
---@param cwd? string defaults to vim.fn.getcwd()
---@return string relative path
local function relpath(p, cwd)
  cwd = cwd or vim.fn.getcwd()
  if p == "" then
    return p
  end
  -- vim.fs.normalize handles ~ and trailing slashes; resolve to handle symlinks
  -- (macOS /var -> /private/var) so cwd-prefix stripping is reliable.
  local abs = vim.fn.fnamemodify(p, ":p")
  local resolved_abs = vim.fn.resolve(abs)
  if resolved_abs ~= "" then
    abs = resolved_abs
  end
  local prefix = vim.fn.fnamemodify(cwd, ":p")
  local resolved_pre = vim.fn.resolve(prefix)
  if resolved_pre ~= "" then
    prefix = resolved_pre
  end
  if prefix:sub(-1) ~= "/" then
    prefix = prefix .. "/"
  end
  if abs:sub(1, #prefix) == prefix then
    return abs:sub(#prefix + 1)
  end
  -- Outside cwd: fall back to absolute (still meaningful).
  return abs
end

---@param term zxz.AgentTerm
---@param text string
---@return boolean ok, string? err
local function send(term, text)
  if not term then
    return false, "no active agent terminal — :ZxzStart first"
  end
  if not Terminal.send(term, text) then
    return false, "chansend failed"
  end
  return true, nil
end

---Format `@<path>` for a buffer; uses the buffer's name relative to cwd.
---@param bufnr? integer defaults to current
---@return string|nil
function M.format_path(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return "@" .. relpath(name)
end

---Send `@<path>` for the current buffer to the active agent term.
---@param opts? { term?: zxz.AgentTerm }
---@return boolean ok, string? err
function M.send_path(opts)
  opts = opts or {}
  local path = M.format_path()
  if not path then
    return false, "current buffer has no file path"
  end
  local term = opts.term or Terminal.current()
  return send(term, path)
end

---Visual-selection variant. Pulls the linewise range, formats as:
---   @<path>:L<start>-<end>
---   ```<filetype>
---   <selected lines>
---   ```
---@param opts? { term?: zxz.AgentTerm }
---@return boolean ok, string? err
function M.send_selection(opts)
  opts = opts or {}
  local bufnr = vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return false, "current buffer has no file path"
  end
  -- Marks '< and '> are set by the visual selection that just exited (e.g. from
  -- a mapping like xnoremap that invokes Lua). They are 1-based.
  local s = vim.api.nvim_buf_get_mark(bufnr, "<")
  local e = vim.api.nvim_buf_get_mark(bufnr, ">")
  if s[1] == 0 or e[1] == 0 then
    return false, "no visual selection"
  end
  local lstart, lend = s[1], e[1]
  if lend < lstart then
    lstart, lend = lend, lstart
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, lstart - 1, lend, false)
  local ft = vim.bo[bufnr].filetype or ""
  local header = ("@%s:L%d-%d"):format(relpath(name), lstart, lend)
  local payload = header .. "\n```" .. ft .. "\n" .. table.concat(lines, "\n") .. "\n```\n"
  local term = opts.term or Terminal.current()
  return send(term, payload)
end

---Multi-select picker over open buffers (or `args` paths). Sends a single
---space-joined `@a @b @c\n` to the agent term.
---@param paths string[] relative or absolute paths
---@param opts? { term?: zxz.AgentTerm }
---@return boolean ok, string? err
function M.send_paths(paths, opts)
  opts = opts or {}
  if not paths or #paths == 0 then
    return false, "no paths to send"
  end
  local refs = {}
  for _, p in ipairs(paths) do
    table.insert(refs, "@" .. relpath(p))
  end
  local term = opts.term or Terminal.current()
  return send(term, table.concat(refs, " "))
end

---vim.ui.select multi-pick fallback. Most users will wire this to their picker
---of choice (telescope, fzf-lua, snacks); this is the zero-dep path.
---@param opts? { term?: zxz.AgentTerm, only_loaded?: boolean }
function M.pick_buffers(opts)
  opts = opts or {}
  local items = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local valid = vim.api.nvim_buf_is_valid(b)
      and (not opts.only_loaded or vim.api.nvim_buf_is_loaded(b))
      and vim.bo[b].buflisted
      and vim.api.nvim_buf_get_name(b) ~= ""
    if valid then
      table.insert(items, vim.api.nvim_buf_get_name(b))
    end
  end
  if #items == 0 then
    vim.notify("zxz: no buffers to share", vim.log.levels.WARN)
    return
  end
  vim.ui.select(items, {
    prompt = "Share with agent (single pick; use a real picker for multi):",
    format_item = function(p)
      return relpath(p)
    end,
  }, function(choice)
    if not choice then
      return
    end
    local ok, err = M.send_paths({ choice }, opts)
    if not ok then
      vim.notify("zxz: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

---Install default keymaps. Idempotent.
---@param opts? { prefix?: string }
function M.setup_keymaps(opts)
  opts = opts or {}
  local p = opts.prefix or "<leader>a"
  vim.keymap.set("n", p, function()
    local ok, err = M.send_path()
    if not ok then
      vim.notify("zxz: " .. tostring(err), vim.log.levels.WARN)
    end
  end, { desc = "zxz: share @<file> with agent" })
  vim.keymap.set("x", p, function()
    -- Exit visual so marks '<,'> are set, then send.
    local key = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
    vim.api.nvim_feedkeys(key, "nx", false)
    vim.schedule(function()
      local ok, err = M.send_selection()
      if not ok then
        vim.notify("zxz: " .. tostring(err), vim.log.levels.WARN)
      end
    end)
  end, { desc = "zxz: share @<file>:Lx-y selection with agent" })
  vim.keymap.set("n", p .. "P", function()
    M.pick_buffers()
  end, { desc = "zxz: pick buffers to share with agent" })
end

return M
