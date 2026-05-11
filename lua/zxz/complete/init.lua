--- 0x0-completion: Inline ghost text code completions.
--- Spawns an ACP provider directly over stdio.

local config = require("zxz.core.config")
local context = require("zxz.complete.context")
local client = require("zxz.core.acp_client")
local ghost = require("zxz.complete.ghost")
local debounce = require("zxz.complete.debounce")
local cache = require("zxz.complete.cache")

local M = {}

---@type fun()? Current request abort function
local _abort_fn = nil

---@type string? Last cache key used
local _last_cache_key = nil

---@type string Accumulated completion text from streaming
local _streaming_text = ""

--- Set up the completion plugin.
---@param opts? table
function M.setup(opts)
  if opts then
    config.current.complete = vim.tbl_deep_extend("force", vim.deepcopy(config.current.complete), opts)
  end
  local cfg = config.current.complete

  if cfg.cache.enabled then
    cache.init(cfg.cache.max_entries)
  end

  -- Set up autocommands
  local group = vim.api.nvim_create_augroup("zxz_complete", { clear = true })

  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI" }, {
    group = group,
    callback = function()
      if not cfg.enabled then
        return
      end
      M._on_text_changed()
    end,
  })

  vim.api.nvim_create_autocmd("InsertLeave", {
    group = group,
    callback = function()
      M.dismiss()
    end,
  })

  -- Set up keymaps
  M._setup_keymaps()
end

--- Handle text change in insert mode.
function M._on_text_changed()
  local cfg = config.current.complete
  local bufnr = vim.api.nvim_get_current_buf()
  local ft = vim.bo[bufnr].filetype

  -- Explicit per-buffer opt-out. Set by buffers that don't want ambient AI
  -- completion (e.g. chat input/transcript via disable_ambient_completion).
  if vim.b[bufnr].zxz_complete_disable then
    return
  end

  -- Fallback safety net: only run in regular file buffers. Catches terminal,
  -- prompt, nofile scratch buffers, and anything that forgot to set the flag.
  if vim.bo[bufnr].buftype ~= "" then
    return
  end

  -- Check filetype exclusion
  for _, excluded in ipairs(cfg.filetypes.exclude) do
    if ft == excluded then
      return
    end
  end

  -- Check minimum content on current line
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1]
  local col = cursor[2]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  local before = line:sub(1, col)

  -- Don't trigger on empty lines or very short prefixes
  if before:match("^%s*$") then
    M.dismiss()
    return
  end

  -- Treesitter-gated suppression: skip completion inside comments and string
  -- literals. Best-effort — only runs when a parser is attached.
  if cfg.suppress_in_strings_and_comments ~= false then
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row - 1, math.max(col - 1, 0) } })
    if ok and node then
      local n = node
      while n do
        local t = n:type()
        if t:match("comment") or t == "string" or t:match("string_") or t:match("_string") then
          M.dismiss()
          return
        end
        n = n:parent()
      end
    end
  end

  -- Any keystroke implicitly dismisses the current ghost; a fresh request
  -- is debounced below.
  M._cancel()

  -- Debounce the completion request
  debounce.start(cfg.debounce_ms, function()
    M._request_completion()
  end)
end

--- Request a completion from the server.
function M._request_completion()
  local cfg = config.current.complete
  local bufnr = vim.api.nvim_get_current_buf()

  -- Check we're still in insert mode
  if vim.fn.mode() ~= "i" then
    return
  end

  local ctx = context.gather()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local row = cursor[1] - 1 -- 0-based
  local col = cursor[2] -- 0-based

  -- Check cache
  if cfg.cache.enabled then
    local key = cache.make_key(ctx.prefix, ctx.suffix, ctx.language)
    local cached = cache.get(key)
    if cached then
      ghost.show(bufnr, row, col, cached)
      _last_cache_key = key
      return
    end
  end

  _streaming_text = ""

  _abort_fn = client.stream_completion(cfg.acp, {
    prefix = ctx.prefix,
    suffix = ctx.suffix,
    language = ctx.language,
    filepath = ctx.filepath,
    max_tokens = cfg.max_tokens,
    temperature = cfg.temperature,
    model = cfg.model,
  }, function(chunk)
    -- On each text chunk
    _streaming_text = _streaming_text .. chunk

    -- Check we're still in insert mode at the same position
    if vim.fn.mode() ~= "i" then
      M._cancel()
      return
    end

    local cur = vim.api.nvim_win_get_cursor(0)
    if cur[1] - 1 ~= row or cur[2] ~= col then
      M._cancel()
      return
    end

    ghost.show(bufnr, row, col, _streaming_text)
  end, function(err)
    _abort_fn = nil

    if err then
      return
    end

    -- Cache the result
    if cfg.cache.enabled and _streaming_text ~= "" then
      local key = cache.make_key(ctx.prefix, ctx.suffix, ctx.language)
      cache.set(key, _streaming_text)
      _last_cache_key = key
    end
  end)
end

--- Cancel pending request and clear ghost text.
function M._cancel()
  debounce.stop()
  if _abort_fn then
    _abort_fn()
    _abort_fn = nil
  end
  ghost.clear()
  _streaming_text = ""
end

--- Dismiss the current completion suggestion.
function M.dismiss()
  if ghost.is_visible() and _last_cache_key then
    cache.log_outcome("dismiss", _last_cache_key)
  end
  M._cancel()
end

--- Accept the current completion.
---@return boolean
function M.accept()
  if ghost.is_visible() then
    M._cancel_request_only()
    if _last_cache_key then
      cache.log_outcome("accept", _last_cache_key)
    end
    return ghost.accept()
  end
  return false
end

--- Cancel request without clearing ghost text.
function M._cancel_request_only()
  debounce.stop()
  if _abort_fn then
    _abort_fn()
    _abort_fn = nil
  end
end

--- Toggle completion on/off.
function M.toggle()
  config.current.complete.enabled = not config.current.complete.enabled
  if not config.current.complete.enabled then
    M.dismiss()
  end
end

local function choose_model()
  vim.ui.input({
    prompt = "0x0 completion model",
    default = tostring(config.current.complete.model or ""),
  }, function(value)
    if value == nil then
      return
    end
    if value == "" then
      config.current.complete.model = nil
      return
    end
    config.current.complete.model = value
  end)
end

local function choose_temperature()
  vim.ui.input({
    prompt = "0x0 completion temperature",
    default = tostring(config.current.complete.temperature or 0),
  }, function(value)
    local temperature = tonumber(value)
    if not temperature then
      return
    end
    config.current.complete.temperature = math.max(0, math.min(2, temperature))
  end)
end

local function choose_max_tokens()
  vim.ui.input({
    prompt = "0x0 completion max tokens",
    default = tostring(config.current.complete.max_tokens or 128),
  }, function(value)
    local max_tokens = tonumber(value)
    if not max_tokens then
      return
    end
    config.current.complete.max_tokens = math.max(1, math.floor(max_tokens))
  end)
end

function M.settings()
  local actions = {
    {
      label = "Enabled: " .. tostring(config.current.complete.enabled),
      run = M.toggle,
    },
    {
      label = "ACP provider: " .. tostring(config.current.complete.acp.command),
      run = function() end,
    },
    {
      label = "Model: " .. tostring(config.current.complete.model or "provider default"),
      run = choose_model,
    },
    {
      label = "Max tokens: " .. tostring(config.current.complete.max_tokens),
      run = choose_max_tokens,
    },
    {
      label = "Temperature: " .. tostring(config.current.complete.temperature),
      run = choose_temperature,
    },
  }

  vim.ui.select(actions, {
    prompt = "0x0 completion settings",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
      action.run()
    end
  end)
end

--- Set up insert-mode keymaps.
function M._setup_keymaps()
  local cfg = config.current.complete
  local km = cfg.keymaps

  local function fall_through(key)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(key, true, false, true), "n", false)
  end

  if km.accept and km.accept ~= "" then
    vim.keymap.set("i", km.accept, function()
      if not M.accept() then
        fall_through(km.accept)
      end
    end, { silent = true, desc = "0x0: Accept completion" })
  end

  if km.dismiss and km.dismiss ~= "" then
    vim.keymap.set("i", km.dismiss, function()
      if ghost.is_visible() then
        M.dismiss()
        return
      end
      fall_through(km.dismiss)
    end, { silent = true, desc = "0x0: Dismiss completion" })
  end
end

return M
