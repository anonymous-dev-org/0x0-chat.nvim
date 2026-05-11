-- Inline edit: scope-aware buffer-local "edit this region with this
-- instruction" affordance. Fires a headless turn through the chat
-- session; the existing inline_diff overlay renders the resulting diff
-- and the user accepts/rejects with the existing keymaps.

local Checkpoint = require("zeroxzero.checkpoint")

local M = {}

---@type table<string, string[]>
local LANGUAGE_SCOPE_NODES = {
  lua = {
    "function_declaration",
    "function_definition",
    "local_function",
    "method_definition",
  },
  typescript = {
    "function_declaration",
    "method_definition",
    "arrow_function",
    "class_declaration",
  },
  typescriptreact = {
    "function_declaration",
    "method_definition",
    "arrow_function",
    "class_declaration",
  },
  javascript = {
    "function_declaration",
    "method_definition",
    "arrow_function",
    "class_declaration",
  },
  python = {
    "function_definition",
    "class_definition",
  },
  rust = {
    "function_item",
    "impl_item",
  },
  go = {
    "function_declaration",
    "method_declaration",
  },
}

---@param node TSNode
---@param wanted string[]
---@return TSNode|nil, string|nil
local function find_enclosing(node, wanted)
  while node do
    local t = node:type()
    for _, w in ipairs(wanted) do
      if t == w then
        return node, t
      end
    end
    node = node:parent()
  end
  return nil, nil
end

---@param node TSNode
---@param bufnr integer
---@return string|nil
local function node_name(node, bufnr)
  for child in node:iter_children() do
    local t = child:type()
    if t == "identifier" or t == "name" or t == "property_identifier" or t == "field_identifier" then
      return vim.treesitter.get_node_text(child, bufnr)
    end
  end
  return nil
end

---@param bufnr integer
---@param mode "n"|"v"
---@param range { start_line: integer, end_line: integer }|nil
---@return table scope { rel_path, start_line, end_line, filetype, scope_kind, scope_name, lines[] }
function M._resolve_scope(bufnr, mode, range)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local filetype = vim.bo[bufnr].filetype or ""
  local abs_path = vim.api.nvim_buf_get_name(bufnr)
  local root = Checkpoint.git_root(vim.fn.getcwd())
  local rel_path
  if root and abs_path:sub(1, #root + 1) == root .. "/" then
    rel_path = abs_path:sub(#root + 2)
  else
    rel_path = (abs_path ~= "" and vim.fn.fnamemodify(abs_path, ":~:.")) or "(unnamed)"
  end

  if range then
    local lines = vim.api.nvim_buf_get_lines(bufnr, range.start_line - 1, range.end_line, false)
    return {
      rel_path = rel_path,
      start_line = range.start_line,
      end_line = range.end_line,
      filetype = filetype,
      scope_kind = "selection",
      scope_name = ("lines %d-%d"):format(range.start_line, range.end_line),
      lines = lines,
    }
  end

  local wanted = LANGUAGE_SCOPE_NODES[filetype]
  if wanted then
    local ok_parser = pcall(vim.treesitter.get_parser, bufnr, filetype)
    if ok_parser then
      local cur = vim.api.nvim_win_get_cursor(0)
      local row, col = cur[1] - 1, cur[2]
      local ok_node, cur_node = pcall(vim.treesitter.get_node, { bufnr = bufnr, pos = { row, col } })
      if ok_node and cur_node then
        local found, found_type = find_enclosing(cur_node, wanted)
        if found then
          local sr, _, er, _ = found:range()
          local start_line = sr + 1
          local end_line = er + 1
          local lines = vim.api.nvim_buf_get_lines(bufnr, sr, er + 1, false)
          local name = node_name(found, bufnr) or "(anonymous)"
          local kind = found_type:gsub("_declaration$", ""):gsub("_definition$", ""):gsub("_item$", "")
          return {
            rel_path = rel_path,
            start_line = start_line,
            end_line = end_line,
            filetype = filetype,
            scope_kind = kind,
            scope_name = name,
            lines = lines,
          }
        end
      end
    end
  end

  -- Fallback: current line.
  local cur = vim.api.nvim_win_get_cursor(0)
  local row = cur[1]
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
  return {
    rel_path = rel_path,
    start_line = row,
    end_line = row,
    filetype = filetype,
    scope_kind = "line",
    scope_name = "",
    lines = { line },
  }
end

---@param scope table
---@param instruction string
---@return string
function M._build_prompt(scope, instruction)
  local fence = scope.filetype ~= "" and scope.filetype or ""
  local scope_label = scope.scope_kind
  if scope.scope_name and scope.scope_name ~= "" then
    scope_label = ("%s: %s"):format(scope.scope_kind, scope.scope_name)
  end
  local body = {
    "You are performing a focused inline edit.",
    "",
    ("Target file: %s"):format(scope.rel_path),
    ("Range: lines %d-%d (%s)"):format(scope.start_line, scope.end_line, scope_label),
    "",
    "```" .. fence,
  }
  vim.list_extend(body, scope.lines)
  vim.list_extend(body, {
    "```",
    "",
    "Constraints:",
    "- Edit ONLY the region above unless the instruction explicitly says to expand scope. Other files are off-limits.",
    "- Preserve indentation style (tabs vs spaces, width).",
    "- Keep existing comments unless asked to change them.",
    "- After the edit, the file must still compile / type-check by inspection — do not introduce unresolved identifiers.",
    "",
    ("Instruction: %s"):format(instruction),
  })
  return table.concat(body, "\n")
end

---@param prefill string|nil
---@param on_done fun(text: string|nil)
function M._open_instruction_input(prefill, on_done)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "zeroxzero-inline-edit-input"
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
    title = " 0x0 inline edit ",
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
  end, { buffer = buf, silent = true, desc = "0x0 inline edit: submit" })
  vim.keymap.set({ "n", "i" }, "<Esc>", function()
    finish(nil)
  end, { buffer = buf, silent = true, desc = "0x0 inline edit: cancel" })
  vim.keymap.set("n", "q", function()
    finish(nil)
  end, { buffer = buf, silent = true, desc = "0x0 inline edit: cancel" })
end

---@param opts { range?: { start_line: integer, end_line: integer }, instruction?: string, bufnr?: integer }
function M.start(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local mode = opts.range and "v" or "n"
  local scope = M._resolve_scope(bufnr, mode, opts.range)

  local function dispatch(instruction)
    if not instruction or instruction == "" then
      vim.notify("0x0: inline edit cancelled", vim.log.levels.INFO)
      return
    end
    local prompt = M._build_prompt(scope, instruction)
    require("zeroxzero.chat").run_headless(prompt)
  end

  if opts.instruction and opts.instruction ~= "" then
    dispatch(opts.instruction)
    return
  end
  M._open_instruction_input(nil, dispatch)
end

return M
