---User-command wiring for the Agentic worktree workflow.

local Chat = require("zxz.chat")
local Review = require("zxz.review")
local Worktree = require("zxz.worktree")

local M = {}

function M.review()
  Review.open()
end

---@param opts? { provider?: string }
function M.chat(opts)
  opts = opts or {}
  local wt, err = Chat.open(opts)
  if not wt then
    vim.notify("zxz: " .. tostring(err), vim.log.levels.ERROR)
  end
end

function M.list()
  local wts = Worktree.list()
  if #wts == 0 then
    vim.notify("zxz: no agent worktrees")
    return
  end
  for _, wt in ipairs(wts) do
    print(("  %s  %s"):format(wt.branch, wt.path))
  end
end

---Remove agent worktrees. Defaults to all current zxz agent worktrees.
---@param opts { merged?: boolean }
function M.cleanup(opts)
  opts = opts or {}
  local wts = Worktree.list()
  local removed = 0
  for _, wt in ipairs(wts) do
    local keep = false
    if opts.merged then
      -- Check if branch is fully merged into HEAD.
      local out = vim.fn.system({
        "git",
        "-C",
        wt.repo,
        "branch",
        "--merged",
        "HEAD",
      })
      if not out:match("\n%s*" .. vim.pesc(wt.branch) .. "\n?") then
        keep = true
      end
    end
    if not keep then
      local ok, err = Worktree.remove(wt)
      if ok then
        removed = removed + 1
      else
        vim.notify(("zxz: remove %s failed: %s"):format(wt.id, err or "?"), vim.log.levels.WARN)
      end
    end
  end
  vim.notify(("zxz: cleaned %d worktree(s)"):format(removed))
end

---@param opts? { command_prefix?: string }
function M.setup(opts)
  opts = opts or {}
  local cp = opts.command_prefix or "Zxz"
  local function cmd(name, fn, copts)
    vim.api.nvim_create_user_command(cp .. name, fn, copts or {})
  end

  cmd("Review", function()
    M.review()
  end, { desc = "zxz: review an agent worktree (picker if more than one)" })
  cmd("Chat", function(c)
    local provider = c.fargs and c.fargs[1] or nil
    M.chat({ provider = provider })
  end, {
    nargs = "?",
    desc = "zxz: open agentic.nvim chat in a fresh worktree (optional provider)",
  })
  cmd("List", function()
    M.list()
  end, { desc = "zxz: list agent worktrees" })
  cmd("Cleanup", function(c)
    M.cleanup({ merged = c.args == "merged" })
  end, {
    nargs = "?",
    complete = function()
      return { "merged" }
    end,
    desc = "zxz: remove agent worktrees",
  })
end

return M
