local api = require("zeroxzero.api")
local server = require("zeroxzero.server")
local context = require("zeroxzero.context")

local M = {}

---Send file reference for current buffer to the TUI prompt
function M.send_file()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    local ref = context.file_ref()
    if not ref then
      vim.notify("0x0: no file open", vim.log.levels.WARN)
      return
    end

    api.append_prompt(ref, function(api_err)
      if api_err then
        vim.notify("0x0: " .. api_err, vim.log.levels.ERROR)
        return
      end
      vim.notify("0x0: sent " .. ref, vim.log.levels.INFO)
    end)
  end)
end

---Send visual selection with file reference to the TUI prompt
function M.send_selection()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "x", false)

    local ref = context.file_ref(nil, { include_selection = true })
    if not ref then
      vim.notify("0x0: no file open", vim.log.levels.WARN)
      return
    end

    local selection = context.selection_text()
    local text = ref
    if selection then
      text = text .. "\n```\n" .. selection .. "\n```"
    end

    api.append_prompt(text, function(api_err)
      if api_err then
        vim.notify("0x0: " .. api_err, vim.log.levels.ERROR)
        return
      end
      vim.notify("0x0: sent " .. ref, vim.log.levels.INFO)
    end)
  end)
end

---Send file/selection context with a user-typed message to the TUI prompt
function M.send_with_message()
  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    local ref = context.file_ref(nil, { include_selection = true })
    local selection = context.selection_text()

    vim.ui.input({ prompt = "0x0> " }, function(message)
      if not message or message == "" then
        return
      end

      local parts = {}
      if ref then
        table.insert(parts, ref)
        if selection then
          table.insert(parts, "```\n" .. selection .. "\n```")
        end
      end
      table.insert(parts, message)

      local text = table.concat(parts, "\n")
      api.append_prompt(text, function(api_err)
        if api_err then
          vim.notify("0x0: " .. api_err, vim.log.levels.ERROR)
          return
        end
        vim.notify("0x0: sent to TUI", vim.log.levels.INFO)
      end)
    end)
  end)
end

---Select a session in the TUI
---@param session_id string
function M.select_session(session_id)
  api.select_session(session_id, function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    end
  end)
end

---Execute a command in the TUI
---@param command string
function M.execute_command(command)
  api.execute_command(command, function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
    end
  end)
end

return M
