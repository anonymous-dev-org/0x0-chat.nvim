local chat = require("zeroxzero.chat")
local client = require("zeroxzero.client")
local util = require("zeroxzero.util")

local M = {}

local function current_session()
  local session = chat.session()
  if not session then
    util.notify("No 0x0 chat session yet", vim.log.levels.WARN)
    return nil
  end
  return session
end

local function current_changes()
  local changes = chat.changes()
  if not changes or not changes.baseRef or not changes.agentRef then
    util.notify("No agent changes to review yet", vim.log.levels.WARN)
    return nil
  end
  return changes
end

local function refresh_changes(session)
  client.request({
    type = "changes.status",
    sessionId = session.id,
  }, {
    ["changes.updated"] = function(message)
      chat.set_changes({
        files = message.files or {},
        baseRef = message.baseRef,
        agentRef = message.agentRef,
      })
    end,
    on_error = function(err)
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

function M.open()
  local changes = current_changes()
  if not changes then
    local session = current_session()
    if session then
      refresh_changes(session)
    end
    return
  end

  if vim.fn.exists(":DiffviewOpen") == 2 then
    vim.cmd("DiffviewOpen " .. vim.fn.fnameescape(changes.baseRef .. ".." .. changes.agentRef))
    return
  end

  util.notify("DiffviewOpen is not available; showing changed file list")
  vim.cmd("new")
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_name(bufnr, "[0x0 Changes]")
  vim.api.nvim_buf_set_option(bufnr, "buftype", "nofile")
  vim.api.nvim_buf_set_option(bufnr, "bufhidden", "wipe")
  local lines = { "0x0 changes: " .. changes.baseRef .. ".." .. changes.agentRef, "" }
  for _, file in ipairs(changes.files or {}) do
    table.insert(lines, string.format("%s\t%s", file.status or "modified", file.path or ""))
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

local function request_change_action(kind, path)
  local session = current_session()
  if not session then
    return
  end

  local message = {
    type = kind,
    sessionId = session.id,
  }
  if path then
    message.path = path
  end

  client.request(message, {
    ["changes.updated"] = function(response)
      chat.set_changes({
        files = response.files or {},
        baseRef = response.baseRef,
        agentRef = response.agentRef,
      })
      util.notify("Changes updated")
    end,
    on_error = function(err)
      util.notify(err, vim.log.levels.ERROR)
    end,
  })
end

function M.accept_all()
  request_change_action("changes.accept_all")
end

function M.discard_all()
  request_change_action("changes.discard_all")
end

function M.accept_file(path)
  path = path and path:gsub("^@", "") or path
  if not path or path == "" then
    util.notify("Pass a file path to :ZeroAcceptFile", vim.log.levels.WARN)
    return
  end
  request_change_action("changes.accept_file", path)
end

function M.discard_file(path)
  path = path and path:gsub("^@", "") or path
  if not path or path == "" then
    util.notify("Pass a file path to :ZeroDiscardFile", vim.log.levels.WARN)
    return
  end
  request_change_action("changes.discard_file", path)
end

function M.status()
  local session = current_session()
  if session then
    refresh_changes(session)
  end
end

return M
