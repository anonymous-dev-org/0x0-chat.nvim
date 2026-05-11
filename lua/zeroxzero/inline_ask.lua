-- Inline ask: buffer-local "what does this do?" affordance. Opens a
-- floating question prompt anchored at the cursor; on submit, fires a
-- read-only ephemeral session and streams the answer into a separate
-- answer popup. Does NOT write to the buffer.

local Checkpoint = require("zeroxzero.checkpoint")

local M = {}

local SYSTEM_PROMPT = table.concat({
  "You are answering a read-only question about code.",
  "Do not call any tool that writes files or runs shell commands.",
  "If you need to look at code, quote it inline from what is provided",
  "rather than reading additional files.",
  "Respond in concise prose. Use code blocks for any code snippets.",
}, " ")

local DEFAULT_CONTEXT_LINES = 20

---@param bufnr integer
---@return string|nil
local function symbol_under_cursor(bufnr)
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local ok, node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
  if not ok or not node then
    return nil
  end
  local t = node:type()
  if t == "identifier" or t == "name" or t == "property_identifier" or t == "field_identifier" then
    return vim.treesitter.get_node_text(node, bufnr)
  end
  return nil
end

---@param bufnr integer
---@param context_lines integer
---@return table
local function gather_context(bufnr, context_lines)
  local abs_path = vim.api.nvim_buf_get_name(bufnr)
  local root = Checkpoint.git_root(vim.fn.getcwd())
  local rel
  if root and abs_path:sub(1, #root + 1) == root .. "/" then
    rel = abs_path:sub(#root + 2)
  elseif abs_path and abs_path ~= "" then
    rel = vim.fn.fnamemodify(abs_path, ":~:.")
  else
    rel = "(unnamed buffer)"
  end
  local cur = vim.api.nvim_win_get_cursor(0)
  local cursor_line = cur[1]
  local total = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, cursor_line - context_lines)
  local end_line = math.min(total, cursor_line + context_lines)
  local lines = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  return {
    rel_path = rel,
    cursor_line = cursor_line,
    start_line = start_line,
    end_line = end_line,
    filetype = vim.bo[bufnr].filetype or "",
    symbol = symbol_under_cursor(bufnr),
    lines = lines,
  }
end

---@param ctx table
---@param question string
---@return string
function M._build_user_prompt(ctx, question)
  local fence = ctx.filetype ~= "" and ctx.filetype or ""
  local body = {
    SYSTEM_PROMPT,
    "",
    ("File: %s:%d"):format(ctx.rel_path, ctx.cursor_line),
    ("Symbol under cursor: %s"):format(ctx.symbol or "(none)"),
    "",
    ("Surrounding code (lines %d-%d):"):format(ctx.start_line, ctx.end_line),
    "```" .. fence,
  }
  vim.list_extend(body, ctx.lines)
  vim.list_extend(body, {
    "```",
    "",
    ("Question: %s"):format(question),
  })
  return table.concat(body, "\n")
end

---@return integer bufnr, integer winid
function M._open_answer_popup()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "" })
  local width = math.min(vim.o.columns - 10, 96)
  local height = math.min(math.floor(vim.o.lines * 0.5), 24)
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " 0x0 inline ask ",
    title_pos = "center",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
  end, { buffer = buf, silent = true, desc = "0x0 inline ask: close" })
  return buf, win
end

---@param prefill string|nil
---@param on_done fun(text: string|nil)
local function open_question_input(prefill, on_done)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "zeroxzero-inline-ask-input"
  if prefill and prefill ~= "" then
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { prefill })
  end
  local width = math.min(vim.o.columns - 6, 80)
  local row = math.floor(vim.o.lines / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = " 0x0 ask ",
    title_pos = "center",
  })
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.cmd("startinsert!")

  local function finish(text)
    if vim.api.nvim_win_is_valid(win) then
      pcall(vim.api.nvim_win_close, win, true)
    end
    on_done(text)
  end

  vim.keymap.set({ "n", "i" }, "<CR>", function()
    local text = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ""
    finish(vim.trim(text))
  end, { buffer = buf, silent = true, desc = "0x0 inline ask: submit" })
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    finish(nil)
  end, { buffer = buf, silent = true, desc = "0x0 inline ask: cancel" })
end

---@param buf integer
---@param chunk string
function M._stream_chunk_into(buf, chunk)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local last = lines[#lines] or ""
  local new_chunk_lines = vim.split(chunk, "\n", { plain = true })
  lines[#lines] = last .. new_chunk_lines[1]
  for i = 2, #new_chunk_lines do
    lines[#lines + 1] = new_chunk_lines[i]
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

---@param opts { question?: string, context_lines?: integer, bufnr?: integer }
function M.ask(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local context_lines = opts.context_lines or DEFAULT_CONTEXT_LINES
  local ctx = gather_context(bufnr, context_lines)

  local function dispatch(question)
    if not question or question == "" then
      vim.notify("0x0: inline ask cancelled", vim.log.levels.INFO)
      return
    end
    local prompt = M._build_user_prompt(ctx, question)
    local answer_buf, answer_win = M._open_answer_popup()
    local prompt_blocks = { { type = "text", text = prompt } }
    local last_chunk_at = vim.loop.now()
    local idle_timer
    local cancel
    cancel = require("zeroxzero.chat").run_inline_ask({
      prompt_blocks = prompt_blocks,
      on_chunk = function(text)
        last_chunk_at = vim.loop.now()
        M._stream_chunk_into(answer_buf, text)
      end,
      on_done = function(err)
        if idle_timer then
          pcall(function()
            idle_timer:stop()
            idle_timer:close()
          end)
          idle_timer = nil
        end
        if err and vim.api.nvim_buf_is_valid(answer_buf) then
          M._stream_chunk_into(answer_buf, "\n\n_error: " .. err .. "_")
        end
      end,
    })
    -- T2.3: idle timer — if no chunk for 30s, cancel and surface timeout.
    idle_timer = vim.loop.new_timer()
    idle_timer:start(
      5000,
      5000,
      vim.schedule_wrap(function()
        if vim.loop.now() - last_chunk_at > 30000 then
          pcall(cancel)
          if vim.api.nvim_buf_is_valid(answer_buf) then
            M._stream_chunk_into(answer_buf, "\n\n_(idle timeout — aborted)_")
          end
        end
      end)
    )
    -- T2.3: q/<Esc> cancel from the answer popup.
    if vim.api.nvim_buf_is_valid(answer_buf) then
      local cancel_keymap = function()
        pcall(cancel)
        if vim.api.nvim_win_is_valid(answer_win) then
          pcall(vim.api.nvim_win_close, answer_win, true)
        end
      end
      vim.keymap.set("n", "q", cancel_keymap, { buffer = answer_buf, silent = true })
      vim.keymap.set("n", "<Esc>", cancel_keymap, { buffer = answer_buf, silent = true })
    end
  end

  if opts.question and opts.question ~= "" then
    dispatch(opts.question)
    return
  end
  open_question_input(nil, dispatch)
end

return M
