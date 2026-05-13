local ReferenceMentions = require("zxz.context.reference_mentions")

local M = {}

local cache = {
  cwd = nil,
  files = nil,
}

local state = {
  bufnr = nil,
  winid = nil,
  menu_buf = nil,
  matches = {},
  selected = 1,
  start_col = nil,
}

local ns = vim.api.nvim_create_namespace("zxz_file_completion")

local function buf_valid(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function win_valid(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function list_files()
  local cwd = vim.fn.getcwd()
  if cache.cwd == cwd and cache.files then
    return cache.files
  end

  local files = {}
  local output = {}
  if vim.fn.executable("rg") == 1 then
    output = vim.fn.systemlist({ "rg", "--files", "--hidden", "-g", "!**/.git/**" })
  end
  if vim.v.shell_error == 0 and #output > 0 then
    files = output
  elseif vim.fn.executable("find") == 1 then
    output = vim.fn.systemlist({
      "find",
      ".",
      "-type",
      "f",
      "-not",
      "-path",
      "*/.git/*",
    })
    for _, path in ipairs(output) do
      table.insert(files, (path:gsub("^%./", "")))
    end
  end

  table.sort(files)
  cache.cwd = cwd
  cache.files = files
  return files
end

local function current_mention_prefix()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  return ReferenceMentions.cursor_token(line, col)
end

local function is_supported_path(path)
  return not path:find("[%s`]")
end

local SPECIAL_MENTIONS = {
  { label = "@diagnostics", path = "diagnostics" },
  { label = "@diagnostics:errors", path = "diagnostics" },
  { label = "@diagnostics:warnings", path = "diagnostics" },
  { label = "@hover", path = "hover" },
  { label = "@def", path = "def" },
  { label = "@symbol", path = "symbol" },
  { label = "@recent", path = "recent" },
  { label = "@repomap", path = "repomap" },
  { label = "@test-output", path = "test-output" },
  { label = "@fetch:", path = "fetch" },
  { label = "@diff:main", path = "diff" },
  { label = "@rule:project", path = "rule" },
  { label = "@thread:", path = "thread" },
  { label = "@terminal", path = "terminal" },
}

local function matches_for_token(token)
  token = token or ""
  local lower = token:lower()
  local prefix = {}
  local contains = {}
  -- Inject special mentions ahead of file matches when the token shape suggests one.
  for _, item in ipairs(SPECIAL_MENTIONS) do
    local label_lower = item.label:sub(2):lower()
    if lower == "" then
      table.insert(prefix, item)
    elseif label_lower:sub(1, #lower) == lower then
      table.insert(prefix, item)
    elseif label_lower:find(lower, 1, true) then
      table.insert(contains, item)
    end
  end
  for _, file in ipairs(list_files()) do
    if is_supported_path(file) then
      local file_lower = file:lower()
      if lower == "" or file_lower:find(lower, 1, true) then
        local item = {
          path = file,
          label = "@" .. file,
        }
        if lower == "" or file_lower:sub(1, #lower) == lower then
          table.insert(prefix, item)
        else
          table.insert(contains, item)
        end
      end
    end
    if #prefix + #contains >= 100 then
      break
    end
  end
  vim.list_extend(prefix, contains)
  return prefix
end

local function ensure_menu_buf()
  if buf_valid(state.menu_buf) then
    return state.menu_buf
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = "zxz-chat-files"
  state.menu_buf = bufnr
  return bufnr
end

local function render_menu()
  if not buf_valid(state.menu_buf) then
    return
  end
  local lines = {}
  for i, item in ipairs(state.matches) do
    lines[i] = item.label
  end
  vim.bo[state.menu_buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.menu_buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(state.menu_buf, ns, 0, -1)
  if lines[state.selected] then
    vim.api.nvim_buf_set_extmark(state.menu_buf, ns, state.selected - 1, 0, {
      end_col = #lines[state.selected],
      hl_group = "PmenuSel",
    })
  end
  vim.bo[state.menu_buf].modifiable = false
end

local function open_menu()
  local menu_buf = ensure_menu_buf()
  render_menu()
  local width = 20
  for _, item in ipairs(state.matches) do
    width = math.max(width, math.min(#item.label, 80))
  end
  local height = math.min(#state.matches, 10)
  if win_valid(state.winid) then
    vim.api.nvim_win_set_config(state.winid, {
      relative = "cursor",
      row = 1,
      col = 0,
      width = width,
      height = height,
    })
    return
  end
  state.winid = vim.api.nvim_open_win(menu_buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = height,
    style = "minimal",
    border = "single",
    focusable = false,
    noautocmd = true,
  })
  vim.wo[state.winid].wrap = false
  vim.wo[state.winid].cursorline = false
end

function M.close()
  if win_valid(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
  state.winid = nil
  state.matches = {}
  state.selected = 1
  state.start_col = nil
end

function M.refresh()
  local start_col, token = current_mention_prefix()
  if not start_col then
    M.close()
    return
  end
  state.start_col = start_col
  state.matches = matches_for_token(token)
  state.selected = math.min(state.selected, #state.matches)
  if state.selected < 1 then
    state.selected = 1
  end
  if #state.matches == 0 then
    M.close()
    return
  end
  open_menu()
end

function M.select_next(delta)
  if not win_valid(state.winid) or #state.matches == 0 then
    return false
  end
  state.selected = ((state.selected - 1 + delta) % #state.matches) + 1
  render_menu()
  return true
end

function M.accept()
  if not win_valid(state.winid) or #state.matches == 0 then
    return false
  end
  local item = state.matches[state.selected]
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  if vim.api.nvim_get_mode().mode ~= "i" then
    col = math.min(col + 1, #vim.api.nvim_get_current_line())
  end
  local start_col = state.start_col or current_mention_prefix()
  if not start_col or not item then
    M.close()
    return false
  end
  vim.api.nvim_buf_set_text(0, row - 1, start_col - 1, row - 1, col, { item.label .. " " })
  M.close()
  return true
end

function M.trigger()
  local start_col = current_mention_prefix()
  if not start_col then
    return
  end
  state.start_col = start_col
  state.selected = 1
  M.refresh()
end

function M.attach(bufnr)
  state.bufnr = bufnr
  vim.api.nvim_create_autocmd({ "TextChangedI", "CursorMovedI", "InsertLeave", "BufLeave" }, {
    buffer = bufnr,
    callback = function(event)
      if event.event == "TextChangedI" or event.event == "CursorMovedI" then
        if win_valid(state.winid) then
          M.refresh()
        end
      else
        M.close()
      end
    end,
  })
end

return M
