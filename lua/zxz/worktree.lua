---@class zxz.Worktree
---@field id string              -- unique session id
---@field path string            -- absolute path to the worktree checkout
---@field branch string          -- "zxz/agent-<id>"
---@field base_ref string        -- SHA of the commit the branch was created from
---@field repo string            -- absolute path to the main worktree (where the user works)
---@field agent? string          -- optional agent label (claude, codex, ...)

local M = {}

local function run(cmd, opts)
  opts = opts or {}
  local out = vim.fn.system(cmd)
  local code = vim.v.shell_error
  if code ~= 0 then
    local err = opts.silent and (out or "") or ("command failed (%d): %s\n%s"):format(code, table.concat(cmd, " "), out)
    return nil, err
  end
  return out, nil
end

local function trim(s)
  return (s:gsub("%s+$", ""))
end

---Resolve the main worktree root for a given path inside the repo.
---@param cwd? string defaults to vim.fn.getcwd()
---@return string|nil repo absolute path, nil err
---@return string? err
function M.repo_root(cwd)
  cwd = cwd or vim.fn.getcwd()
  -- --show-toplevel returns the current worktree; --git-common-dir + ../ gives the
  -- main worktree's root. We use the common dir trick so that calling from inside
  -- an agent worktree still resolves to the original repo.
  local common, err = run({ "git", "-C", cwd, "rev-parse", "--git-common-dir" })
  if not common then
    return nil, err
  end
  common = trim(common)
  -- git-common-dir is usually <repo>/.git; the main worktree is its parent.
  local main_git = common
  if not main_git:match("^/") then
    main_git = cwd .. "/" .. main_git
  end
  local repo = vim.fn.fnamemodify(main_git, ":h")
  -- Canonicalise so callers from inside a worktree (where realpath may differ via
  -- symlinks like macOS /var -> /private/var) compare equal.
  local resolved = vim.fn.resolve(repo)
  if resolved ~= "" then
    repo = resolved
  end
  return repo, nil
end

local function gen_id()
  local stamp = os.date("%Y%m%d-%H%M%S")
  local rand = string.format("%04x", math.random(0, 0xffff))
  return tostring(stamp) .. "-" .. rand
end

local function worktree_dir(repo, id)
  return repo .. "/.git/zxz/wt-" .. id
end

---@param opts? { cwd?: string, base?: string, agent?: string, id?: string }
---@return zxz.Worktree|nil wt
---@return string? err
function M.create(opts)
  opts = opts or {}
  local repo, err = M.repo_root(opts.cwd)
  if not repo then
    return nil, err
  end
  local base = opts.base or "HEAD"
  local sha, err2 = run({ "git", "-C", repo, "rev-parse", base })
  if not sha then
    return nil, err2
  end
  sha = trim(sha)
  local id = opts.id or gen_id()
  local branch = "zxz/agent-" .. id
  local path = worktree_dir(repo, id)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local _, werr = run({ "git", "-C", repo, "worktree", "add", "-b", branch, path, sha })
  if werr then
    return nil, werr
  end
  return {
    id = id,
    path = path,
    branch = branch,
    base_ref = sha,
    repo = repo,
    agent = opts.agent,
  },
    nil
end

---@param cwd? string
---@return zxz.Worktree[]
function M.list(cwd)
  local repo = M.repo_root(cwd)
  if not repo then
    return {}
  end
  local out = run({ "git", "-C", repo, "worktree", "list", "--porcelain" }) or ""
  local results = {}
  local cur = {}
  local function flush()
    if cur.branch and cur.branch:match("^zxz/agent%-") and cur.worktree then
      local id = cur.branch:gsub("^zxz/agent%-", "")
      local p = vim.fn.resolve(cur.worktree)
      if p == "" then
        p = cur.worktree
      end
      table.insert(results, {
        id = id,
        path = p,
        branch = cur.branch,
        base_ref = cur.HEAD or "",
        repo = repo,
      })
    end
    cur = {}
  end
  for line in (out .. "\n"):gmatch("([^\n]*)\n") do
    if line == "" then
      flush()
    else
      local key, val = line:match("^(%S+)%s+(.+)$")
      if key == "worktree" then
        cur.worktree = val
      elseif key == "HEAD" then
        cur.HEAD = val
      elseif key == "branch" then
        -- value is like "refs/heads/zxz/agent-<id>"
        cur.branch = (val:gsub("^refs/heads/", ""))
      end
    end
  end
  flush()
  return results
end

---@param wt zxz.Worktree
---@return boolean ok
---@return string? err
function M.remove(wt)
  local _, err = run({ "git", "-C", wt.repo, "worktree", "remove", "--force", wt.path })
  if err then
    return false, err
  end
  -- Delete the branch too; ignore failure (already gone, or has unmerged changes user wants kept).
  run({ "git", "-C", wt.repo, "branch", "-D", wt.branch }, { silent = true })
  return true, nil
end

---@param wt zxz.Worktree
---@return string diff "" if no changes
---@return string? err
function M.diff(wt)
  -- Three-dot: diff against the merge base, so unrelated advances on main don't pollute.
  local out, err = run({ "git", "-C", wt.repo, "diff", wt.base_ref .. "..." .. wt.branch })
  if err then
    return "", err
  end
  return out or "", nil
end

return M
