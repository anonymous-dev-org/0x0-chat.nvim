local client = require("zeroxzero.client")
local config = require("zeroxzero.config")
local util = require("zeroxzero.util")

local M = {}

local api = vim.api

local state = {
  bufnr = nil,
  session = nil,
  changes = nil,
  active_request = nil,
}

local function is_chat_buf(bufnr)
  return bufnr and api.nvim_buf_is_valid(bufnr)
end

local function set_modifiable(bufnr, value)
  api.nvim_buf_set_option(bufnr, "modifiable", value)
end

local function append(bufnr, lines)
  set_modifiable(bufnr, true)
  util.append_lines(bufnr, lines)
  set_modifiable(bufnr, true)
  api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(bufnr), 0 })
end

local function assistant_heading()
  if state.session then
    return string.format("## Model: %s/%s", state.session.provider or "provider", state.session.model or "model")
  end
  return "## Model"
end

local function is_model_heading(line)
  return line == "## Assistant" or line == "## Model" or line:match("^## Model:") ~= nil
end

local function ensure_buffer()
  if is_chat_buf(state.bufnr) then
    return state.bufnr
  end

  local bufnr = api.nvim_create_buf(false, true)
  state.bufnr = bufnr
  api.nvim_buf_set_name(bufnr, config.current.chat_buffer_name)
  api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  api.nvim_buf_set_option(bufnr, "bufhidden", "hide")
  api.nvim_buf_set_option(bufnr, "swapfile", false)
  api.nvim_buf_set_option(bufnr, "filetype", "zeroxzero-chat")

  api.nvim_buf_set_lines(bufnr, 0, -1, false, {
    "# 0x0 Chat",
    "",
    "## User",
    "",
  })

  vim.keymap.set("n", "<CR>", M.submit, { buffer = bufnr, silent = true, desc = "0x0 submit chat turn" })
  vim.keymap.set("n", "<leader>as", M.submit, { buffer = bufnr, silent = true, desc = "0x0 submit chat turn" })
  vim.keymap.set("i", "<C-x><C-f>", function()
    local line = api.nvim_get_current_line()
    local col = api.nvim_win_get_cursor(0)[2]
    local prefix = line:sub(1, col):match("@[%w%._%-%/%~]*$")
    if not prefix then
      return
    end
    vim.fn.complete(col - #prefix + 1, util.file_candidates(prefix))
  end, { buffer = bufnr, silent = true, desc = "0x0 complete file reference" })

  return bufnr
end

local function current_prompt(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start = nil

  for i = #lines, 1, -1 do
    if lines[i] == "## User" then
      start = i + 1
      break
    end
    if is_model_heading(lines[i]) then
      break
    end
  end

  if not start then
    return nil
  end

  local prompt_lines = {}
  for i = start, #lines do
    table.insert(prompt_lines, lines[i])
  end

  local prompt = table.concat(prompt_lines, "\n"):gsub("^%s+", ""):gsub("%s+$", "")
  if prompt == "" then
    return nil
  end
  return prompt
end

local function append_change_summary(message)
  state.changes = {
    files = message.files or {},
    baseRef = message.baseRef,
    agentRef = message.agentRef,
  }

  if not is_chat_buf(state.bufnr) then
    return
  end

  local existing = api.nvim_buf_get_lines(state.bufnr, 0, -1, false)
  if existing[#existing - 1] == "## User" and existing[#existing] == "" then
    set_modifiable(state.bufnr, true)
    api.nvim_buf_set_lines(state.bufnr, #existing - 2, #existing, false, {})
  elseif existing[#existing] == "## User" then
    set_modifiable(state.bufnr, true)
    api.nvim_buf_set_lines(state.bufnr, #existing - 1, #existing, false, {})
  end

  local lines = { "", "## Changes" }
  if #state.changes.files == 0 then
    table.insert(lines, "No file changes.")
  else
    for _, file in ipairs(state.changes.files) do
      table.insert(lines, string.format("- %s %s", file.status or "modified", file.path or ""))
    end
  end
  table.insert(lines, "")
  table.insert(lines, "Actions: :ZeroReview, :ZeroAcceptAll, :ZeroDiscardAll")
  table.insert(lines, "")
  table.insert(lines, "## User")
  table.insert(lines, "")
  append(state.bufnr, lines)
end

local function ensure_next_prompt(bufnr)
  local lines = api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i = #lines, math.max(1, #lines - 3), -1 do
    if lines[i] == "## User" then
      return
    end
  end
  append(bufnr, { "", "## User", "" })
end

local function send_turn(prompt)
  local bufnr = ensure_buffer()

  append(bufnr, { "", assistant_heading(), "" })

  state.active_request = client.request({
    type = "chat.turn",
    sessionId = state.session.id,
    prompt = prompt,
  }, {
    keep = true,
    done_grace_ms = 5000,
    close_on_changes = true,
    ["assistant.delta"] = function(message)
      set_modifiable(bufnr, true)
      local last = api.nvim_buf_line_count(bufnr)
      local current = api.nvim_buf_get_lines(bufnr, last - 1, last, false)[1] or ""
      local chunks = util.split_lines(message.text or "")
      if #chunks == 0 then
        return
      end
      chunks[1] = current .. chunks[1]
      api.nvim_buf_set_lines(bufnr, last - 1, last, false, chunks)
      api.nvim_win_set_cursor(0, { api.nvim_buf_line_count(bufnr), 0 })
    end,
    ["assistant.done"] = function(message)
      state.active_request = nil
      if message.summary and message.summary ~= "" then
        append(bufnr, { "", "_Summary: " .. message.summary .. "_" })
      end
      vim.defer_fn(function()
        if is_chat_buf(bufnr) then
          ensure_next_prompt(bufnr)
        end
      end, 100)
    end,
    ["changes.updated"] = append_change_summary,
    ["run.status"] = function(message)
      vim.b[bufnr].zeroxzero_status = message.status
    end,
    on_error = function(err)
      state.active_request = nil
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

local function create_session(prompt)
  local root = util.repo_root(0)
  client.request({
    type = "session.create",
    repoRoot = root,
    provider = config.current.provider,
    model = config.current.model,
  }, {
    ["session.created"] = function(message)
      state.session = message.session
      send_turn(prompt)
    end,
    on_error = function(err)
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

function M.open()
  local bufnr = ensure_buffer()
  vim.cmd("botright split")
  api.nvim_win_set_buf(0, bufnr)
  api.nvim_win_set_height(0, math.max(12, math.floor(vim.o.lines * 0.35)))
  api.nvim_buf_call(bufnr, function()
    vim.cmd("normal! G")
  end)
end

function M.new()
  state.session = nil
  state.changes = nil
  state.active_request = nil
  if is_chat_buf(state.bufnr) then
    api.nvim_buf_delete(state.bufnr, { force = true })
  end
  state.bufnr = nil
  M.open()
end

function M.open_session(session_id)
  if not session_id or session_id == "" then
    util.notify("Pass a session id to :ZeroChatOpen", vim.log.levels.WARN)
    return
  end

  client.request({
    type = "session.open",
    sessionId = session_id,
  }, {
    keep = true,
    done_grace_ms = 5000,
    close_on_changes = true,
    ["session.created"] = function(message)
      state.session = message.session
      local bufnr = ensure_buffer()
      append(bufnr, {
        "",
        string.format(
          "_Opened session %s (%s/%s)._",
          state.session.id,
          state.session.provider or "provider",
          state.session.model or "model"
        ),
        "",
        "## User",
        "",
      })
      M.open()
    end,
    ["changes.updated"] = append_change_summary,
    on_error = function(err)
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

function M.submit()
  local bufnr = ensure_buffer()
  local prompt = current_prompt(bufnr)
  if not prompt then
    util.notify("Write a prompt under the last ## User heading first", vim.log.levels.WARN)
    return
  end

  if state.session then
    send_turn(prompt)
  else
    create_session(prompt)
  end
end

function M.cancel()
  if not state.session then
    return
  end
  client.request({
    type = "run.cancel",
    sessionId = state.session.id,
  })
end

function M.session()
  return state.session
end

function M.changes()
  return state.changes
end

function M.set_changes(changes)
  state.changes = changes
end

return M
