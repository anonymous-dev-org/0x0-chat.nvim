local api = require("zeroxzero.api")
local server = require("zeroxzero.server")

local M = {}

---Safely set a buffer name, appending a numeric suffix on collision
---@param buf number
---@param name string
local function set_buf_name(buf, name)
  local ok = pcall(vim.api.nvim_buf_set_name, buf, name)
  if not ok then
    local suffix = 1
    while not pcall(vim.api.nvim_buf_set_name, buf, name .. " (" .. suffix .. ")") do
      suffix = suffix + 1
      if suffix > 100 then
        break
      end
    end
  end
end

---Open a vimdiff split for a single file diff
---@param file_diff {file: string, before: string, after: string, status?: string}
function M.open_diff(file_diff)
  local ft = vim.filetype.match({ filename = file_diff.file }) or ""

  -- Create "before" buffer
  local before_buf = vim.api.nvim_create_buf(false, true)
  local before_lines = vim.split(file_diff.before, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(before_buf, 0, -1, false, before_lines)
  set_buf_name(before_buf, "before: " .. file_diff.file)
  vim.bo[before_buf].buftype = "nofile"
  vim.bo[before_buf].bufhidden = "wipe"
  vim.bo[before_buf].modifiable = false
  if ft ~= "" then
    vim.bo[before_buf].filetype = ft
  end

  -- Create "after" buffer
  local after_buf = vim.api.nvim_create_buf(false, true)
  local after_lines = vim.split(file_diff.after, "\n", { plain = true })
  vim.api.nvim_buf_set_lines(after_buf, 0, -1, false, after_lines)
  set_buf_name(after_buf, "after: " .. file_diff.file)
  vim.bo[after_buf].buftype = "nofile"
  vim.bo[after_buf].bufhidden = "wipe"
  vim.bo[after_buf].modifiable = false
  if ft ~= "" then
    vim.bo[after_buf].filetype = ft
  end

  -- Open before in current window
  vim.api.nvim_set_current_buf(before_buf)
  vim.cmd("diffthis")

  -- Open after in vertical split
  vim.cmd("vsplit")
  vim.api.nvim_set_current_buf(after_buf)
  vim.cmd("diffthis")
end

---Show a quickfix-style list of changed files and let user pick one to diff
---@param diffs {file: string, before: string, after: string, additions: number, deletions: number, status?: string}[]
---@param session_id string
function M.review_all(diffs, session_id)
  local items = {}
  for _, d in ipairs(diffs) do
    local status = d.status or "modified"
    local stats = "+" .. d.additions .. " -" .. d.deletions
    table.insert(items, {
      label = string.format("[%s] %s (%s)", status, d.file, stats),
      diff = d,
    })
  end

  vim.ui.select(items, {
    prompt = "Diff review (" .. session_id:sub(1, 12) .. ")",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end
    M.open_diff(choice.diff)
  end)
end

---Fetch and review diffs for a session's latest assistant message
---@param opts? {session_id?: string}
function M.review(opts)
  opts = opts or {}

  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    if opts.session_id then
      M._review_session(opts.session_id)
      return
    end

    -- No session specified — pick one
    api.get_sessions(function(get_err, response)
      if get_err then
        vim.notify("0x0: " .. get_err, vim.log.levels.ERROR)
        return
      end

      local sessions = response and response.body or {}
      if type(sessions) ~= "table" or #sessions == 0 then
        vim.notify("0x0: no sessions found", vim.log.levels.INFO)
        return
      end

      if #sessions == 1 then
        M._review_session(sessions[1].id)
        return
      end

      local items = {}
      for _, s in ipairs(sessions) do
        table.insert(items, {
          id = s.id,
          title = s.title or s.id,
        })
      end

      vim.ui.select(items, {
        prompt = "Select session to review",
        format_item = function(item)
          return item.title
        end,
      }, function(choice)
        if not choice then
          return
        end
        M._review_session(choice.id)
      end)
    end)
  end)
end

---@param session_id string
function M._review_session(session_id)
  api.get_messages(session_id, function(err, messages)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    -- Find the last completed assistant message
    local target_message_id = nil
    for i = #(messages or {}), 1, -1 do
      local msg = messages[i]
      local info = msg.info
      if info.role == "assistant" and info.time and info.time.completed then
        -- The diff API expects the user message that triggered this response
        -- Look for the preceding user message
        for j = i - 1, 1, -1 do
          if messages[j].info.role == "user" then
            target_message_id = messages[j].info.id
            break
          end
        end
        if not target_message_id then
          target_message_id = info.id
        end
        break
      end
    end

    if not target_message_id then
      vim.notify("0x0: no completed messages found", vim.log.levels.INFO)
      return
    end

    api.get_diff(session_id, target_message_id, function(diff_err, diffs)
      if diff_err then
        vim.notify("0x0: " .. diff_err, vim.log.levels.ERROR)
        return
      end

      diffs = diffs or {}
      if type(diffs) ~= "table" or #diffs == 0 then
        vim.notify("0x0: no file changes found", vim.log.levels.INFO)
        return
      end

      if #diffs == 1 then
        M.open_diff(diffs[1])
      else
        M.review_all(diffs, session_id)
      end
    end)
  end)
end

return M
