local config = require("zeroxzero.config")

local M = {}

local _ns = vim.api.nvim_create_namespace("zeroxzero_chat")

---@class zeroxzero.RenderState
---@field buf integer buffer number
---@field parts table<string, {start_line: integer, end_line: integer, type: string}> part_id → line range
---@field message_lines table<string, integer> message_id → header line
---@field last_text_part_id string? the part_id currently receiving text deltas

---Setup highlight groups (idempotent)
function M.setup_highlights()
  vim.api.nvim_set_hl(0, "ZeroChatUser", { bold = true, fg = "#7aa2f7", default = true })
  vim.api.nvim_set_hl(0, "ZeroChatAssistant", { bold = true, fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "ZeroChatSeparator", { fg = "#565f89", default = true })
  vim.api.nvim_set_hl(0, "ZeroChatToolRunning", { fg = "#e0af68", italic = true, default = true })
  vim.api.nvim_set_hl(0, "ZeroChatToolSuccess", { fg = "#9ece6a", default = true })
  vim.api.nvim_set_hl(0, "ZeroChatToolError", { fg = "#f7768e", default = true })
  vim.api.nvim_set_hl(0, "ZeroChatThinking", { fg = "#565f89", italic = true, default = true })
  vim.api.nvim_set_hl(0, "ZeroChatError", { fg = "#f7768e", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ZeroChatFoldLine", { fg = "#565f89", default = true })
end

---Create a new render state for a buffer
---@param buf integer
---@return zeroxzero.RenderState
function M.new_state(buf)
  return {
    buf = buf,
    parts = {},
    message_lines = {},
    last_text_part_id = nil,
  }
end

---@param state zeroxzero.RenderState
local function line_count(state)
  return vim.api.nvim_buf_line_count(state.buf)
end

---@param state zeroxzero.RenderState
---@param lines string[]
---@param hl_group? string
local function append_lines(state, lines, hl_group)
  local start = line_count(state)
  -- If the buffer only has one empty line, replace it
  if start == 1 then
    local first = vim.api.nvim_buf_get_lines(state.buf, 0, 1, false)
    if first[1] == "" then
      vim.api.nvim_buf_set_lines(state.buf, 0, 1, false, lines)
      if hl_group then
        for i = 0, #lines - 1 do
          vim.api.nvim_buf_add_highlight(state.buf, _ns, hl_group, i, 0, -1)
        end
      end
      return
    end
  end
  vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, lines)
  if hl_group then
    for i = start, start + #lines - 1 do
      vim.api.nvim_buf_add_highlight(state.buf, _ns, hl_group, i, 0, -1)
    end
  end
end

---Render a separator + user message header
---@param state zeroxzero.RenderState
function M.user_header(state)
  local sep = string.rep("\u{2500}", 50)
  append_lines(state, { "", sep, " You", sep }, "ZeroChatSeparator")
end

---Render user message text
---@param state zeroxzero.RenderState
---@param text string
function M.user_text(state, text)
  local lines = vim.split(text, "\n", { plain = true })
  append_lines(state, lines)
end

---Render assistant message header
---@param state zeroxzero.RenderState
---@param message_id string
---@param model_id? string
function M.assistant_header(state, message_id, model_id)
  local sep = string.rep("\u{2500}", 50)
  local label = " Assistant"
  if model_id then
    label = label .. " (" .. model_id .. ")"
  end
  append_lines(state, { "", sep, label, sep, "" }, "ZeroChatAssistant")
  state.message_lines[message_id] = line_count(state)
  state.last_text_part_id = nil
end

---Append streaming text delta to the buffer
---@param state zeroxzero.RenderState
---@param part table the text part from SSE
---@param delta? string incremental text
function M.text_delta(state, part, delta)
  local part_id = part.id
  if not part_id then
    return
  end

  if not state.parts[part_id] then
    -- Add spacer if previous line is non-empty (e.g. tool fold body)
    -- to prevent text merging into the last fold line
    local count = line_count(state)
    local prev_line = vim.api.nvim_buf_get_lines(state.buf, count - 1, count, false)[1] or ""
    if prev_line ~= "" then
      append_lines(state, { "" })
    end
    -- First delta for this part — mark start line
    state.parts[part_id] = {
      start_line = line_count(state),
      end_line = line_count(state),
      type = "text",
    }
    state.last_text_part_id = part_id
  end

  if delta and delta ~= "" then
    local info = state.parts[part_id]
    local last_line_idx = info.end_line - 1
    local current_lines = vim.api.nvim_buf_get_lines(state.buf, last_line_idx, last_line_idx + 1, false)
    local current_text = current_lines[1] or ""

    local delta_lines = vim.split(delta, "\n", { plain = true })

    if #delta_lines == 1 then
      -- Append to current line
      vim.api.nvim_buf_set_lines(state.buf, last_line_idx, last_line_idx + 1, false, { current_text .. delta_lines[1] })
    else
      -- First part appends to current line, rest are new lines
      local new_lines = { current_text .. delta_lines[1] }
      for i = 2, #delta_lines do
        table.insert(new_lines, delta_lines[i])
      end
      vim.api.nvim_buf_set_lines(state.buf, last_line_idx, last_line_idx + 1, false, new_lines)
      info.end_line = info.end_line + #delta_lines - 1
    end
  elseif not delta and part.text and part.text ~= "" then
    -- Full text replacement (no delta, just the complete text)
    local info = state.parts[part_id]
    local text_lines = vim.split(part.text, "\n", { plain = true })
    vim.api.nvim_buf_set_lines(state.buf, info.start_line - 1, info.end_line, false, text_lines)
    info.end_line = info.start_line + #text_lines - 1
  end
end

---Adjust line numbers for all parts and message headers after a line count change
---@param state zeroxzero.RenderState
---@param exclude_part_id string part to skip (the one being updated)
---@param after_line integer 0-based line index; parts starting after this line are shifted
---@param delta integer number of lines added (positive) or removed (negative)
local function adjust_line_numbers(state, exclude_part_id, after_line, delta)
  if delta == 0 then
    return
  end
  for pid, info in pairs(state.parts) do
    if pid ~= exclude_part_id then
      if info.start_line > after_line then
        info.start_line = info.start_line + delta
      end
      if info.end_line > after_line then
        info.end_line = info.end_line + delta
      end
    end
  end
  for mid, ml in pairs(state.message_lines) do
    if ml > after_line then
      state.message_lines[mid] = ml + delta
    end
  end
end

---Render or update a tool part
---@param state zeroxzero.RenderState
---@param part table the tool part from SSE
function M.tool_update(state, part)
  local part_id = part.id
  if not part_id or not part.state then
    return
  end

  local tool_name = part.tool or "unknown"
  local tool_state = part.state
  local status = tool_state.status or "pending"

  -- Build the header line
  local icon, hl_group
  if status == "completed" then
    icon = "\u{2714}"
    hl_group = "ZeroChatToolSuccess"
  elseif status == "error" then
    icon = "\u{2718}"
    hl_group = "ZeroChatToolError"
  else
    icon = "\u{25b6}"
    hl_group = "ZeroChatToolRunning"
  end

  local title = tool_state.title or tool_name
  local header = icon .. " " .. title

  if not state.parts[part_id] then
    -- New tool — append spacer + header
    state.last_text_part_id = nil
    local start = line_count(state)
    append_lines(state, { "", header })
    vim.api.nvim_buf_add_highlight(state.buf, _ns, hl_group, line_count(state) - 1, 0, -1)

    state.parts[part_id] = {
      start_line = start + 1, -- 0-based index of the header line
      end_line = start + 2,   -- past-the-end (header only, no body yet)
      type = "tool",
    }
  else
    -- Update existing tool
    local info = state.parts[part_id]

    -- Replace the header line (start_line is the 0-based index of the header)
    vim.api.nvim_buf_set_lines(state.buf, info.start_line, info.start_line + 1, false, { header })
    vim.api.nvim_buf_clear_namespace(state.buf, _ns, info.start_line, info.start_line + 1)
    vim.api.nvim_buf_add_highlight(state.buf, _ns, hl_group, info.start_line, 0, -1)

    if status == "completed" or status == "error" then
      -- Add output as fold body
      local output = tool_state.output or tool_state.error or ""
      if output ~= "" then
        local output_lines = vim.split(output, "\n", { plain = true })
        -- Prefix with fold markers
        local fold_lines = {}
        for _, line in ipairs(output_lines) do
          table.insert(fold_lines, "\u{2502} " .. line)
        end
        -- Count old body lines (everything between header and end_line)
        local old_body_count = info.end_line - info.start_line - 1
        -- Remove old body lines if any
        if old_body_count > 0 then
          vim.api.nvim_buf_set_lines(state.buf, info.start_line + 1, info.end_line, false, {})
        end
        -- Insert new body after the header
        vim.api.nvim_buf_set_lines(state.buf, info.start_line + 1, info.start_line + 1, false, fold_lines)
        for i = info.start_line + 1, info.start_line + #fold_lines do
          vim.api.nvim_buf_add_highlight(state.buf, _ns, "ZeroChatFoldLine", i, 0, -1)
        end
        local new_end = info.start_line + 1 + #fold_lines
        local delta = new_end - info.end_line
        info.end_line = new_end
        adjust_line_numbers(state, part_id, info.start_line, delta)
      end
    end
  end
end

---Render a reasoning/thinking block
---@param state zeroxzero.RenderState
---@param part table the reasoning part
---@param delta? string
function M.reasoning_delta(state, part, delta)
  if not config.current.chat.show_thinking then
    return
  end

  local part_id = part.id
  if not part_id then
    return
  end

  if not state.parts[part_id] then
    state.last_text_part_id = nil
    local start = line_count(state)
    append_lines(state, { "", "[thinking]" }, "ZeroChatThinking")
    state.parts[part_id] = {
      start_line = start + 2,
      end_line = start + 2,
      type = "reasoning",
    }
  end

  if delta and delta ~= "" then
    local info = state.parts[part_id]
    local last_line_idx = info.end_line - 1
    local current = vim.api.nvim_buf_get_lines(state.buf, last_line_idx, last_line_idx + 1, false)
    local current_text = current[1] or ""
    local delta_lines = vim.split(delta, "\n", { plain = true })

    if #delta_lines == 1 then
      local new_text = current_text .. delta_lines[1]
      vim.api.nvim_buf_set_lines(state.buf, last_line_idx, last_line_idx + 1, false, { new_text })
      vim.api.nvim_buf_add_highlight(state.buf, _ns, "ZeroChatThinking", last_line_idx, 0, -1)
    else
      local new_lines = { current_text .. delta_lines[1] }
      for i = 2, #delta_lines do
        table.insert(new_lines, delta_lines[i])
      end
      vim.api.nvim_buf_set_lines(state.buf, last_line_idx, last_line_idx + 1, false, new_lines)
      for i = last_line_idx, last_line_idx + #new_lines - 1 do
        vim.api.nvim_buf_add_highlight(state.buf, _ns, "ZeroChatThinking", i, 0, -1)
      end
      info.end_line = info.end_line + #delta_lines - 1
    end
  end
end

---Render an error message
---@param state zeroxzero.RenderState
---@param message string
function M.error_message(state, message)
  append_lines(state, { "", "[error] " .. message }, "ZeroChatError")
end

---Setup fold expression for the chat buffer
---@param buf integer
function M.setup_folds(buf)
  vim.wo[0].foldmethod = "expr"
  vim.wo[0].foldexpr = "v:lua.require('zeroxzero.render')._foldexpr(v:lnum)"
  vim.wo[0].foldlevel = 99
  vim.wo[0].foldenable = true
  vim.bo[buf].filetype = "zeroxzero"
end

---Fold expression: lines starting with tool icons start a fold, │ lines continue
---@param lnum integer
---@return string
function M._foldexpr(lnum)
  local line = vim.fn.getline(lnum)
  -- Tool header lines (✔, ✘, ▶) start a fold
  if line:match("^[\u{2714}\u{2718}\u{25b6}] ") then
    return ">1"
  end
  -- Fold body lines (│)
  if line:match("^\u{2502} ") then
    return "1"
  end
  return "0"
end

return M
