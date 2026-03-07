local api = require("zeroxzero.api")
local server = require("zeroxzero.server")

local M = {}

---Open diffview for a session's branch changes
---@param branch {name: string, base: string, worktree: string}
function M._open_diffview(branch)
  local cmd = string.format("DiffviewOpen %s...%s", branch.base, branch.name)
  local ok, err = pcall(vim.cmd, cmd)
  if not ok then
    vim.notify("0x0: Failed to open diffview: " .. tostring(err), vim.log.levels.ERROR)
    vim.notify("0x0: Make sure diffview.nvim is installed", vim.log.levels.INFO)
  end
end

---Review changes for a session via diffview
---@param opts? {session_id?: string}
function M.review(opts)
  opts = opts or {}

  server.ensure(function(err)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end

    if opts.session_id then
      M._review_branch(opts.session_id)
      return
    end

    -- No session specified - pick one
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
        M._review_branch(sessions[1].id)
        return
      end

      local items = {}
      for _, s in ipairs(sessions) do
        table.insert(items, {
          id = s.id,
          title = s.title or s.id,
          has_branch = s.branch ~= nil,
        })
      end

      vim.ui.select(items, {
        prompt = "Select session to review",
        format_item = function(item)
          local prefix = item.has_branch and "[branch] " or "[direct] "
          return prefix .. item.title
        end,
      }, function(choice)
        if not choice then
          return
        end
        M._review_branch(choice.id)
      end)
    end)
  end)
end

---@param session_id string
function M._review_branch(session_id)
  api.get_branch(session_id, function(err, branch)
    if err then
      vim.notify("0x0: " .. err, vim.log.levels.ERROR)
      return
    end
    if not branch then
      vim.notify("0x0: session has no git branch (not a git project?)", vim.log.levels.INFO)
      return
    end
    M._open_diffview(branch)
  end)
end

return M
