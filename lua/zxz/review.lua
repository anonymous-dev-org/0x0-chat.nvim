---Fugitive-style review buffer for an agent worktree.
---Shows the diff between the user's working tree and the agent branch tip,
---grouped into sections. Per-hunk and per-file accept/reject land changes
---into the user's working tree via `git apply` (the Fugitive splice trick).

local Worktree = require("zxz.worktree")
local Terminal = require("zxz.terminal")

local M = {}

local NS = vim.api.nvim_create_namespace("zxz_review")

---@class zxz.review.Hunk
---@field header string                 -- "@@ -a,b +c,d @@..."
---@field body string[]                 -- raw body lines (' ', '+', '-', '\')

---@class zxz.review.File
---@field path string                   -- relative
---@field status "modified"|"added"|"deleted"
---@field diff_header string[]          -- diff --git ... +++ ... lines
---@field hunks zxz.review.Hunk[]
---@field conflict boolean              -- git apply --check failed

---@class zxz.review.State
---@field worktree zxz.Worktree
---@field bufnr integer
---@field files zxz.review.File[]
---@field by_path table<string, zxz.review.File>
---@field expanded table<string, boolean>            -- file path -> inline expanded
---@field touched table<string, boolean>             -- files we've applied hunks for
---@field row_map table<integer, { path: string, hunk_idx?: integer }>
---@field section_headers table<string, integer>    -- section name -> row

local states_by_buf = {} ---@type table<integer, zxz.review.State>

-- ---------------------------------------------------------------------------
-- Diff parsing
-- ---------------------------------------------------------------------------

---@param text string raw `git diff` output
---@return zxz.review.File[]
local function parse_diff(text)
  local files = {}
  if text == "" then
    return files
  end

  local cur = nil
  local in_hunk = false
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line:sub(1, 11) == "diff --git " then
      if cur then
        table.insert(files, cur)
      end
      local a, b = line:match("^diff %-%-git a/(.+) b/(.+)$")
      cur = {
        path = b or a or "",
        status = "modified",
        diff_header = { line },
        hunks = {},
        conflict = false,
      }
      in_hunk = false
    elseif cur and not in_hunk then
      table.insert(cur.diff_header, line)
      if line:sub(1, 14) == "new file mode " then
        cur.status = "added"
      elseif line:sub(1, 18) == "deleted file mode " then
        cur.status = "deleted"
      elseif line:sub(1, 4) == "--- " then
        -- Track for added: --- /dev/null
        if line == "--- /dev/null" then
          cur.status = "added"
        end
      elseif line:sub(1, 4) == "+++ " then
        if line == "+++ /dev/null" then
          cur.status = "deleted"
        else
          local p = line:match("^%+%+%+ b/(.+)$")
          if p then
            cur.path = p
          end
        end
      elseif line:sub(1, 2) == "@@" then
        in_hunk = true
        -- pop the @@ line back off the header; it belongs to the first hunk.
        cur.diff_header[#cur.diff_header] = nil
        table.insert(cur.hunks, { header = line, body = {} })
      end
    elseif cur and in_hunk then
      if line:sub(1, 11) == "diff --git " then
        -- shouldn't happen because the outer branch catches this, but defensive.
        table.insert(files, cur)
        cur = nil
        in_hunk = false
      elseif line:sub(1, 2) == "@@" then
        table.insert(cur.hunks, { header = line, body = {} })
      else
        -- Hunk body lines must start with ' ', '+', '-', or '\' ("\ No newline
        -- at end of file"). Anything else (typically the trailing empty line
        -- from the diff's terminating newline) is not part of the hunk and
        -- would corrupt the patch if we kept it.
        local c = line:sub(1, 1)
        if c == " " or c == "+" or c == "-" or c == "\\" then
          local h = cur.hunks[#cur.hunks]
          if h then
            table.insert(h.body, line)
          end
        end
      end
    end
  end
  if cur then
    table.insert(files, cur)
  end
  return files
end

---Reassemble a single-hunk patch (file header + one hunk body) suitable for
---`git apply`.
---@param file zxz.review.File
---@param hunk zxz.review.Hunk
---@return string
local function build_hunk_patch(file, hunk)
  local lines = {}
  for _, l in ipairs(file.diff_header) do
    table.insert(lines, l)
  end
  table.insert(lines, hunk.header)
  for _, l in ipairs(hunk.body) do
    table.insert(lines, l)
  end
  return table.concat(lines, "\n") .. "\n"
end

---Reassemble the whole-file patch.
---@param file zxz.review.File
---@return string
local function build_file_patch(file)
  local lines = {}
  for _, l in ipairs(file.diff_header) do
    table.insert(lines, l)
  end
  for _, h in ipairs(file.hunks) do
    table.insert(lines, h.header)
    for _, l in ipairs(h.body) do
      table.insert(lines, l)
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- ---------------------------------------------------------------------------
-- Conflict detection
-- ---------------------------------------------------------------------------

---A file is "in conflict" when the user's worktree has diverged from base_ref
---on a path the agent also modified. Accepting would silently clobber the
---user's local edits, so we surface it explicitly and require dv to resolve.
---@param wt zxz.Worktree
---@param file zxz.review.File
local function detect_conflict(wt, file)
  local out = vim.fn.system({
    "git",
    "-C",
    wt.repo,
    "diff",
    "--quiet",
    wt.base_ref,
    "--",
    file.path,
  })
  -- --quiet exits 1 when there are differences, 0 when there are none.
  file.conflict = (vim.v.shell_error ~= 0)
  -- Swallow stderr noise.
  local _ = out
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- The parser tags status from the worktree's POV (what git diff <branch> says).
-- The agent-facing UI inverts: an "added" file in worktree-POV means the agent
-- DELETED it; "deleted" in worktree-POV means the agent ADDED it.
local UI_LABEL = { modified = "Modified", deleted = "Added", added = "Deleted" }
local STATUS_GLYPH = { modified = "M", deleted = "A", added = "D" }
local SECTION_ORDER = { "modified", "deleted", "added" }

---@param state zxz.review.State
local function render(state)
  local lines = {}
  local row_map = {}
  local section_headers = {}

  local function add(line, target)
    table.insert(lines, line)
    row_map[#lines] = target -- target is nil for plain lines, table for actionable
  end

  add(("Worktree: %s"):format(state.worktree.path), nil)
  add(("Branch:   %s"):format(state.worktree.branch), nil)
  add(("Base:     %s"):format(state.worktree.base_ref:sub(1, 12)), nil)
  add("", nil)

  -- bucket files by section
  local buckets = { conflicts = {}, modified = {}, added = {}, deleted = {} }
  for _, f in ipairs(state.files) do
    if f.conflict then
      table.insert(buckets.conflicts, f)
    else
      table.insert(buckets[f.status], f)
    end
  end

  local function render_section(name, label, list)
    section_headers[name] = #lines + 1
    add(("%s (%d)"):format(label, #list), { section = name })
    for _, f in ipairs(list) do
      local glyph = STATUS_GLYPH[f.status] or "?"
      add(("  %s %s"):format(glyph, f.path), { path = f.path })
      if state.expanded[f.path] then
        for i, h in ipairs(f.hunks) do
          add("    " .. h.header, { path = f.path, hunk_idx = i })
          for _, body in ipairs(h.body) do
            add("    " .. body, { path = f.path, hunk_idx = i })
          end
        end
      end
    end
    add("", nil)
  end

  render_section("conflicts", "Conflicts", buckets.conflicts)
  for _, status in ipairs(SECTION_ORDER) do
    render_section(status, UI_LABEL[status], buckets[status])
  end

  add("", nil)
  add("[s=stage X=reject = toggle hunk dv=3-way cc=commit R=refresh q=close]", nil)

  vim.bo[state.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, lines)
  vim.bo[state.bufnr].modifiable = false
  vim.bo[state.bufnr].modified = false

  -- Section header highlight.
  vim.api.nvim_buf_clear_namespace(state.bufnr, NS, 0, -1)
  for _, row in pairs(section_headers) do
    vim.api.nvim_buf_set_extmark(state.bufnr, NS, row - 1, 0, {
      end_row = row - 1,
      end_col = 0,
      hl_group = "Title",
      hl_eol = true,
    })
  end
  -- Per-line +/- highlighting for expanded hunks.
  for row, body_line in ipairs(lines) do
    local stripped = body_line:match("^    (.+)$")
    if stripped then
      local hl
      if stripped:sub(1, 1) == "+" then
        hl = "DiffAdd"
      elseif stripped:sub(1, 1) == "-" then
        hl = "DiffDelete"
      elseif stripped:sub(1, 2) == "@@" then
        hl = "Identifier"
      end
      if hl then
        vim.api.nvim_buf_set_extmark(state.bufnr, NS, row - 1, 0, {
          end_row = row - 1,
          end_col = 0,
          hl_group = hl,
          hl_eol = true,
        })
      end
    end
  end

  state.row_map = row_map
  state.section_headers = section_headers
end

-- ---------------------------------------------------------------------------
-- State refresh
-- ---------------------------------------------------------------------------

---@param state zxz.review.State
function M.refresh(state)
  local diff = Worktree.pending_diff(state.worktree)
  state.files = parse_diff(diff)
  state.by_path = {}
  for _, f in ipairs(state.files) do
    state.by_path[f.path] = f
    detect_conflict(state.worktree, f)
  end
  render(state)
end

-- ---------------------------------------------------------------------------
-- Cursor → target dispatch
-- ---------------------------------------------------------------------------

---@param state zxz.review.State
---@return { path?: string, hunk_idx?: integer, section?: string }|nil
local function cursor_target(state)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.row_map[row]
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

---@param state zxz.review.State
---@param mode "accept"|"reject"
local function dispatch_apply(state, mode)
  local tgt = cursor_target(state)
  if not tgt or (not tgt.path and not tgt.section) then
    vim.notify("zxz.review: cursor not on a file or hunk", vim.log.levels.WARN)
    return
  end

  -- Orientation: pending diff is branch -> worktree. To accept (worktree
  -- becomes branch) we apply with --reverse. Reject is the forward direction,
  -- which would only succeed if the agent's change had already been applied
  -- and we want to roll it back.
  local reverse = (mode == "accept")

  local function stage(path)
    -- `git diff <branch>` ignores untracked files in the working tree, so an
    -- accept that created a new file still shows up as "missing" until we
    -- record it in the index. `git add -A -- <path>` handles add/modify/delete
    -- uniformly and prepares the file for `cc` (commit accepted).
    vim.fn.system({
      "git",
      "-C",
      state.worktree.repo,
      "add",
      "-A",
      "--",
      path,
    })
  end

  local function apply_patch(patch, label)
    local ok, err = Worktree.apply_patch(state.worktree, patch, { reverse = reverse })
    if not ok then
      vim.notify(("zxz.review: %s %s failed: %s"):format(mode, label, err or "?"), vim.log.levels.ERROR)
      return false
    end
    return true
  end

  if tgt.section and not tgt.path then
    -- Section header: act on the whole section's files.
    local applied = 0
    for _, f in ipairs(state.files) do
      local bucket = f.conflict and "conflicts" or f.status
      if bucket == tgt.section and not f.conflict then
        if apply_patch(build_file_patch(f), f.path) then
          state.touched[f.path] = true
          stage(f.path)
          applied = applied + 1
        end
      end
    end
    if applied > 0 then
      vim.notify(("zxz.review: %s %d files"):format(mode .. "ed", applied))
    end
  elseif tgt.hunk_idx then
    local f = state.by_path[tgt.path]
    if not f then
      return
    end
    local h = f.hunks[tgt.hunk_idx]
    if not h then
      return
    end
    if apply_patch(build_hunk_patch(f, h), tgt.path) then
      state.touched[f.path] = true
      stage(f.path)
    end
  else
    -- File header.
    local f = state.by_path[tgt.path]
    if not f then
      return
    end
    if f.conflict then
      vim.notify("zxz.review: file in conflict — resolve via dv first", vim.log.levels.WARN)
      return
    end
    if apply_patch(build_file_patch(f), f.path) then
      state.touched[f.path] = true
      stage(f.path)
    end
  end

  M.refresh(state)
end

---@param state zxz.review.State
function M.accept(state)
  dispatch_apply(state, "accept")
end

---@param state zxz.review.State
function M.reject(state)
  dispatch_apply(state, "reject")
end

---@param state zxz.review.State
function M.toggle(state)
  local tgt = cursor_target(state)
  if not tgt or not tgt.path then
    return
  end
  state.expanded[tgt.path] = not state.expanded[tgt.path]
  render(state)
end

---@param state zxz.review.State
function M.diffview(state)
  local tgt = cursor_target(state)
  if not tgt or not tgt.path then
    vim.notify("zxz.review: cursor not on a file", vim.log.levels.WARN)
    return
  end
  local rel = tgt.path
  local abs = state.worktree.repo .. "/" .. rel
  local branch_content = Worktree.show_file(state.worktree, rel) or ""

  -- Right-hand scratch: agent's version on the branch.
  vim.cmd("tabnew")
  local right = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(right, 0, -1, false, vim.split(branch_content, "\n"))
  vim.bo[right].buftype = "nofile"
  vim.bo[right].bufhidden = "wipe"
  vim.bo[right].filetype = vim.filetype.match({ filename = rel }) or ""
  pcall(vim.api.nvim_buf_set_name, right, ("zxz-branch://%s/%s"):format(state.worktree.id, rel))
  vim.api.nvim_win_set_buf(0, right)
  vim.cmd("diffthis")

  -- Left split: user's worktree version.
  vim.cmd("leftabove vsplit " .. vim.fn.fnameescape(abs))
  vim.cmd("diffthis")
end

---@param state zxz.review.State
function M.commit_accepted(state)
  local touched = {}
  for p in pairs(state.touched) do
    table.insert(touched, p)
  end
  if #touched == 0 then
    vim.notify("zxz.review: no accepted files to commit", vim.log.levels.WARN)
    return
  end
  local default_msg = ("zxz: accept from %s\n\n%s"):format(
    state.worktree.branch,
    table.concat(
      vim.tbl_map(function(p)
        return "- " .. p
      end, touched),
      "\n"
    )
  )
  vim.ui.input({
    prompt = "Commit message: ",
    default = default_msg:match("^([^\n]+)"),
  }, function(msg)
    if not msg or msg == "" then
      return
    end
    local add_cmd = { "git", "-C", state.worktree.repo, "add", "--" }
    for _, p in ipairs(touched) do
      table.insert(add_cmd, p)
    end
    local out = vim.fn.system(add_cmd)
    if vim.v.shell_error ~= 0 then
      vim.notify("zxz: git add failed: " .. out, vim.log.levels.ERROR)
      return
    end
    out = vim.fn.system({
      "git",
      "-C",
      state.worktree.repo,
      "commit",
      "-m",
      msg,
      "--",
      unpack(touched),
    })
    if vim.v.shell_error ~= 0 then
      vim.notify("zxz: git commit failed: " .. out, vim.log.levels.ERROR)
      return
    end
    state.touched = {}
    M.refresh(state)
    vim.notify(("zxz.review: committed %d files"):format(#touched))
  end)
end

-- ---------------------------------------------------------------------------
-- Buffer / state lifecycle
-- ---------------------------------------------------------------------------

local function buffer_name(wt)
  return ("zxz-review://%s"):format(wt.id)
end

local function find_existing(wt)
  local name = buffer_name(wt)
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(b) and vim.api.nvim_buf_get_name(b) == name then
      return b
    end
  end
  return nil
end

---@param state zxz.review.State
local function install_keymaps(state)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = state.bufnr, desc = desc, nowait = true })
  end
  map("=", function()
    M.toggle(state)
  end, "zxz.review: toggle hunk view")
  map("s", function()
    M.accept(state)
  end, "zxz.review: stage/accept")
  map("X", function()
    M.reject(state)
  end, "zxz.review: reject (reverse-apply)")
  map("dv", function()
    M.diffview(state)
  end, "zxz.review: 3-way diff")
  map("cc", function()
    M.commit_accepted(state)
  end, "zxz.review: commit accepted")
  map("R", function()
    M.refresh(state)
  end, "zxz.review: refresh")
  map("q", function()
    vim.api.nvim_buf_delete(state.bufnr, { force = true })
  end, "zxz.review: close")
  map("<CR>", function()
    M.toggle(state)
  end, "zxz.review: toggle hunk view")
end

---@param wt zxz.Worktree
---@param opts? { split?: "split"|"vsplit"|"tab"|"current" }
---@return zxz.review.State
function M.open(wt, opts)
  opts = opts or {}
  assert(wt, "zxz.review.open requires a Worktree")
  local existing = find_existing(wt)
  if existing then
    local state = states_by_buf[existing]
    -- Surface the existing buffer.
    local split = opts.split or "current"
    if split ~= "current" then
      vim.cmd(split == "tab" and "tabnew" or split)
    end
    vim.api.nvim_set_current_buf(existing)
    if state then
      M.refresh(state)
    end
    return state
  end

  local split = opts.split or "vsplit"
  if split ~= "current" then
    vim.cmd(split == "tab" and "tabnew" or split)
  end
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  pcall(vim.api.nvim_buf_set_name, bufnr, buffer_name(wt))
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].filetype = "zxz-review"
  vim.bo[bufnr].modifiable = false
  vim.wo[0][0].wrap = false

  ---@type zxz.review.State
  local state = {
    worktree = wt,
    bufnr = bufnr,
    files = {},
    by_path = {},
    expanded = {},
    touched = {},
    row_map = {},
    section_headers = {},
  }
  states_by_buf[bufnr] = state

  install_keymaps(state)

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      states_by_buf[bufnr] = nil
    end,
  })

  M.refresh(state)
  return state
end

---Open review for the currently-active agent term, if any.
function M.open_current()
  local term = Terminal.current()
  if not term then
    vim.notify("zxz.review: no active agent terminal", vim.log.levels.WARN)
    return
  end
  return M.open(term.worktree)
end

---For tests: state-by-bufnr lookup.
function M._state(bufnr)
  return states_by_buf[bufnr]
end

---Exposed for tests.
M._parse_diff = parse_diff
M._build_hunk_patch = build_hunk_patch
M._build_file_patch = build_file_patch

return M
