---User-command + keymap wiring for the worktree/terminal/review surfaces.
---Not auto-loaded — call `require("zxz.commands").setup()` to opt in. Phase 6
---demolition will pull this into `zxz.init` and drop the `Wt` prefix.

local Agents = require("zxz.agents")
local Chat = require("zxz.chat")
local Terminal = require("zxz.terminal")
local Review = require("zxz.review")
local Worktree = require("zxz.worktree")
local Share = require("zxz.context_share")

local M = {}

---@param opts? { agent?: string, with?: string[], split?: string }
function M.start(opts)
  opts = opts or {}
  local choose = function(cb)
    if opts.agent then
      return cb(opts.agent)
    end
    local names = Agents.names()
    vim.ui.select(names, {
      prompt = "Agent:",
      format_item = function(n)
        local d = Agents.get(n)
        return d.describe and (n .. "  -  " .. d.describe) or n
      end,
    }, function(choice)
      if choice then
        cb(choice)
      end
    end)
  end
  choose(function(agent)
    local term, err = Terminal.start(agent, { split = opts.split or "vsplit" })
    if not term then
      vim.notify("zxz: " .. tostring(err), vim.log.levels.ERROR)
      return
    end
    if opts.with and #opts.with > 0 then
      -- Wait one tick so the CLI has its prompt up before we send context.
      vim.defer_fn(function()
        Share.send_paths(opts.with, { term = term })
      end, 200)
    end
  end)
end

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
  local terms = Terminal.list()
  if #terms == 0 then
    vim.notify("zxz: no agent terminals")
    return
  end
  for _, t in ipairs(terms) do
    print(("  %s  %s  %s"):format(t.agent, t.id, t.worktree.branch))
  end
end

---Remove stopped or all worktrees. Defaults: prune worktrees with no live job.
---@param opts { all?: boolean, merged?: boolean }
function M.cleanup(opts)
  opts = opts or {}
  local live = {}
  for _, t in ipairs(Terminal.list()) do
    live[t.worktree.path] = true
  end
  local wts = Worktree.list()
  local removed = 0
  for _, wt in ipairs(wts) do
    local keep = false
    if not opts.all and live[wt.path] then
      keep = true
    end
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

---@param opts? { command_prefix?: string, keymap_prefix?: string, install_keymaps?: boolean }
function M.setup(opts)
  opts = opts or {}
  local cp = opts.command_prefix or "Zxz"
  local function cmd(name, fn, copts)
    vim.api.nvim_create_user_command(cp .. name, fn, copts or {})
  end

  cmd("Start", function(c)
    -- :ZxzStart [agent] [path...]
    -- First token: agent name (must match a registered agent); rest: paths
    -- to chansend after the term opens.
    local agent, with = nil, nil
    if c.fargs and #c.fargs > 0 then
      local first = c.fargs[1]
      if Agents.get(first) then
        agent = first
        if #c.fargs > 1 then
          with = { unpack(c.fargs, 2) }
        end
      else
        with = c.fargs
      end
    end
    M.start({ agent = agent, with = with })
  end, {
    nargs = "*",
    complete = function(arglead, cmdline, _)
      -- Complete agent names for the first positional arg, file paths after.
      local before = cmdline:sub(1, #cmdline - #arglead)
      local _, n = before:gsub("%S+", "")
      if n <= 1 then
        local out = {}
        for _, name in ipairs(Agents.names()) do
          if name:sub(1, #arglead) == arglead then
            table.insert(out, name)
          end
        end
        return out
      end
      return vim.fn.getcompletion(arglead, "file")
    end,
    desc = "zxz: spawn agent CLI in a fresh worktree (optional paths seed context)",
  })
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
  end, { desc = "zxz: list agent terminals" })
  cmd("Cleanup", function(c)
    M.cleanup({ all = c.bang, merged = c.args == "merged" })
  end, {
    bang = true,
    nargs = "?",
    complete = function()
      return { "merged" }
    end,
    desc = "zxz: remove stopped agent worktrees (! to remove all)",
  })
  cmd("Edit", function(c)
    local InlineEdit = require("zxz.edit.inline_edit")
    local range
    if c.range == 2 then
      range = { start_line = c.line1, end_line = c.line2 }
    end
    local instruction = c.args ~= "" and c.args or nil
    InlineEdit.start({ range = range, instruction = instruction })
  end, {
    range = true,
    nargs = "*",
    desc = "zxz: one-shot inline edit via agent CLI",
  })
  cmd("Context", function(c)
    -- :ZxzContext path... -> chansend `@a @b @c` directly.
    -- :ZxzContext         -> open vim.ui.select over open buffers.
    if c.fargs and #c.fargs > 0 then
      local ok, err = Share.send_paths(c.fargs)
      if not ok then
        vim.notify("zxz: " .. tostring(err), vim.log.levels.WARN)
      end
    else
      Share.pick_buffers()
    end
  end, {
    nargs = "*",
    complete = "file",
    desc = "zxz: push paths to the active agent term (no args: picker)",
  })

  if opts.install_keymaps ~= false then
    Share.setup_keymaps({ prefix = opts.keymap_prefix })
  end
end

return M
