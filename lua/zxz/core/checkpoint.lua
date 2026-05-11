local M = {}

local function systemlist(cmd, input)
  local output = input and vim.fn.systemlist(cmd, input) or vim.fn.systemlist(cmd)
  return output, vim.v.shell_error
end

local function system(cmd, input)
  local output = input and vim.fn.system(cmd, input) or vim.fn.system(cmd)
  return output, vim.v.shell_error
end

local function chomp(s)
  return (s or ""):gsub("[\r\n]+$", "")
end

local function shellescape(s)
  return vim.fn.shellescape(s)
end

---Run git in `root` with a temporary GIT_INDEX_FILE.
---@param root string
---@param index string path to the temp index file
---@param args string[]
local function git_with_index(root, index, args)
  local quoted = { "git", "-C", shellescape(root) }
  for _, a in ipairs(args) do
    table.insert(quoted, shellescape(a))
  end
  local cmd = "GIT_INDEX_FILE=" .. shellescape(index) .. " " .. table.concat(quoted, " ")
  local out = vim.fn.system(cmd)
  return out, vim.v.shell_error
end

---Build a tree-ish representing the current working tree (tracked + untracked,
---excluding .gitignore entries) using a temp index. Returns the tree SHA or nil.
---@param root string
---@return string|nil
local function working_tree_tree(root)
  local tmp_index = vim.fn.tempname()
  local _, add_code = git_with_index(root, tmp_index, { "add", "-A" })
  if add_code ~= 0 then
    vim.fn.delete(tmp_index)
    return nil
  end
  local tree, tree_code = git_with_index(root, tmp_index, { "write-tree" })
  vim.fn.delete(tmp_index)
  if tree_code ~= 0 then
    return nil
  end
  tree = chomp(tree)
  if tree == "" then
    return nil
  end
  return tree
end

local function read_disk_file(path)
  local f = io.open(path, "rb")
  if not f then
    return nil
  end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_disk_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
  local f = io.open(path, "wb")
  if not f then
    return false
  end
  f:write(content or "")
  f:close()
  return true
end

local function file_mode_at(root, sha, path)
  local out, code = systemlist({ "git", "-C", root, "ls-tree", sha, "--", path })
  if code ~= 0 or not out[1] or out[1] == "" then
    return nil
  end
  return out[1]:match("^(%d+)%s+blob%s+")
end

---@param checkpoint table
---@param path string
---@param content string|nil nil removes the path from the checkpoint tree
---@return boolean ok, string|nil err
local function replace_file_in_checkpoint(checkpoint, path, content)
  if not M.is_valid(checkpoint) then
    return false, "checkpoint invalid"
  end
  local tmp_index = vim.fn.tempname()
  local _, read_code = git_with_index(checkpoint.root, tmp_index, { "read-tree", checkpoint.sha })
  if read_code ~= 0 then
    vim.fn.delete(tmp_index)
    return false, "failed to read checkpoint tree"
  end

  if content == nil then
    local _, remove_code = git_with_index(checkpoint.root, tmp_index, { "update-index", "--force-remove", "--", path })
    if remove_code ~= 0 then
      vim.fn.delete(tmp_index)
      return false, "failed to remove " .. path .. " from checkpoint"
    end
  else
    local blob = chomp(system({ "git", "-C", checkpoint.root, "hash-object", "-w", "--stdin" }, content))
    if vim.v.shell_error ~= 0 or blob == "" then
      vim.fn.delete(tmp_index)
      return false, "failed to write blob for " .. path
    end
    local mode = file_mode_at(checkpoint.root, checkpoint.sha, path) or "100644"
    local _, update_code = git_with_index(checkpoint.root, tmp_index, {
      "update-index",
      "--add",
      "--cacheinfo",
      mode,
      blob,
      path,
    })
    if update_code ~= 0 then
      vim.fn.delete(tmp_index)
      return false, "failed to update checkpoint index for " .. path
    end
  end

  local tree = chomp(select(1, git_with_index(checkpoint.root, tmp_index, { "write-tree" })))
  vim.fn.delete(tmp_index)
  if tree == "" then
    return false, "failed to write checkpoint tree"
  end
  local sha = chomp(system({
    "git",
    "-C",
    checkpoint.root,
    "commit-tree",
    tree,
    "-p",
    checkpoint.sha,
    "-m",
    "0x0 checkpoint review update",
  }))
  if vim.v.shell_error ~= 0 or sha == "" then
    return false, "failed to commit checkpoint update"
  end
  local _, ref_code = systemlist({ "git", "-C", checkpoint.root, "update-ref", checkpoint.ref, sha })
  if ref_code ~= 0 then
    return false, "failed to update checkpoint ref"
  end
  checkpoint.sha = sha
  return true, nil
end

---@param cwd string
---@return string|nil
function M.git_root(cwd)
  local out, code = systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if code ~= 0 or not out[1] or out[1] == "" then
    return nil
  end
  return out[1]
end

local function new_turn_id()
  return string.format("%d-%d", os.time(), math.random(1, 1e9))
end

---Take a snapshot of the working tree (including untracked, excluding gitignored)
---onto a hidden ref. Falls back to HEAD when the working tree is clean.
---
---Pass `opts.ref_suffix` to nest the ref under a parent (e.g. a tool-call
---checkpoint under a turn). Pass `opts.parent_sha` so the snapshot commit
---chains onto a specific parent rather than HEAD.
---@param root string repo root
---@param opts? { ref_suffix?: string, parent_sha?: string, label?: string }
---@return table|nil checkpoint, string|nil err
function M.snapshot(root, opts)
  if not root then
    return nil, "checkpoint: no root"
  end
  opts = opts or {}
  local turn_id = new_turn_id()
  local ref
  if opts.ref_suffix and opts.ref_suffix ~= "" then
    ref = "refs/0x0/checkpoints/" .. opts.ref_suffix
  else
    ref = "refs/0x0/checkpoints/" .. turn_id
  end

  local tree = working_tree_tree(root)
  if not tree then
    return nil, "git write-tree failed during checkpoint snapshot"
  end

  local parent_sha = opts.parent_sha
  if not parent_sha then
    local head = chomp(system({ "git", "-C", root, "rev-parse", "--verify", "HEAD" }))
    if vim.v.shell_error == 0 and head ~= "" then
      parent_sha = head
    end
  end

  local label = opts.label or ("0x0 chat checkpoint " .. turn_id)
  local commit_args = { "git", "-C", root, "commit-tree", tree, "-m", label }
  if parent_sha and parent_sha ~= "" then
    table.insert(commit_args, "-p")
    table.insert(commit_args, parent_sha)
  end

  local sha = chomp(system(commit_args))
  if vim.v.shell_error ~= 0 or sha == "" then
    return nil, "git commit-tree failed during checkpoint snapshot"
  end

  local _, ref_code = systemlist({ "git", "-C", root, "update-ref", ref, sha })
  if ref_code ~= 0 then
    return nil, "failed to write checkpoint ref"
  end
  return { sha = sha, ref = ref, turn_id = turn_id, root = root }, nil
end

---@param checkpoint table
---@return boolean
function M.is_valid(checkpoint)
  if not checkpoint or not checkpoint.ref or not checkpoint.root then
    return false
  end
  local _, code = systemlist({ "git", "-C", checkpoint.root, "rev-parse", "--verify", checkpoint.ref })
  return code == 0
end

---Build a tree from the current working tree so callers can diff a checkpoint
---against tracked + untracked files in one shot.
---@param root string
---@return string|nil
function M.working_tree_tree(root)
  return working_tree_tree(root)
end

---@param checkpoint table
---@param paths? string[]
---@return string[]
function M.changed_files(checkpoint, paths)
  if not M.is_valid(checkpoint) then
    return {}
  end
  local current = working_tree_tree(checkpoint.root)
  if not current then
    return {}
  end
  local args = { "git", "-C", checkpoint.root, "diff-tree", "-r", "--name-only", checkpoint.ref, current }
  if paths and #paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, paths)
  end
  local out, code = systemlist(args)
  if code ~= 0 then
    return {}
  end
  local files = {}
  for _, line in ipairs(out) do
    if line ~= "" then
      table.insert(files, line)
    end
  end
  return files
end

---@param checkpoint table
---@param paths? string[]
---@param context? integer
---@return string
function M.diff_text(checkpoint, paths, context)
  if not M.is_valid(checkpoint) then
    return ""
  end
  local current = working_tree_tree(checkpoint.root)
  if not current then
    return ""
  end
  local args = {
    "git",
    "-C",
    checkpoint.root,
    "diff",
    "--no-ext-diff",
    "--unified=" .. (context or 3),
    checkpoint.ref,
    current,
  }
  if paths and #paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, paths)
  end
  local out = system(args)
  return out or ""
end

---@param checkpoint table
---@param path string repo-relative path
---@return string|nil contents, boolean existed
function M.read_file(checkpoint, path)
  if not M.is_valid(checkpoint) then
    return nil, false
  end
  local out, code = system({ "git", "-C", checkpoint.root, "show", checkpoint.ref .. ":" .. path })
  if code ~= 0 then
    return nil, false
  end
  return out, true
end

---@param checkpoint table
---@param path string repo-relative path
---@param content string|nil nil removes the path from the checkpoint tree
---@return boolean ok, string|nil err
function M.replace_file(checkpoint, path, content)
  return replace_file_in_checkpoint(checkpoint, path, content)
end

---@param checkpoint table
---@param path string repo-relative path
---@return boolean ok, string|nil err
function M.accept_file(checkpoint, path)
  if not M.is_valid(checkpoint) then
    return false, "checkpoint invalid"
  end
  local abs = checkpoint.root .. "/" .. path
  local stat = vim.loop.fs_stat(abs)
  if not stat then
    return replace_file_in_checkpoint(checkpoint, path, nil)
  end
  if stat.type ~= "file" then
    return false, "cannot accept non-file path " .. path
  end
  return replace_file_in_checkpoint(checkpoint, path, read_disk_file(abs) or "")
end

---@param checkpoint table
---@param path string repo-relative path
---@return boolean ok, string|nil err
function M.restore_file(checkpoint, path)
  if not M.is_valid(checkpoint) then
    return false, "checkpoint invalid"
  end
  local _, exists = systemlist({ "git", "-C", checkpoint.root, "cat-file", "-e", checkpoint.ref .. ":" .. path })
  local abs = checkpoint.root .. "/" .. path
  if exists ~= 0 then
    vim.fn.delete(abs)
    return true, nil
  end
  local content, code = system({ "git", "-C", checkpoint.root, "show", checkpoint.ref .. ":" .. path })
  if code ~= 0 then
    return false, "git show failed for " .. path
  end
  if not write_disk_file(abs, content or "") then
    return false, "write failed for " .. path
  end
  return true, nil
end

---Restore the entire working tree to the checkpoint state.
---@param checkpoint table
---@return boolean ok, string|nil err
function M.restore_all(checkpoint)
  if not M.is_valid(checkpoint) then
    return false, "checkpoint invalid"
  end
  local files = M.changed_files(checkpoint)
  for _, file in ipairs(files) do
    local ok, err = M.restore_file(checkpoint, file)
    if not ok then
      return false, err
    end
  end
  return true, nil
end

---Check whether a path is excluded from the working tree by .gitignore.
---@param root string
---@param path string absolute or repo-relative path
---@return boolean
function M.is_ignored(root, path)
  if not root or not path or path == "" then
    return false
  end
  systemlist({ "git", "-C", root, "check-ignore", "--quiet", "--", path })
  return vim.v.shell_error == 0
end

---@param checkpoint table
function M.delete_ref(checkpoint)
  if not checkpoint or not checkpoint.ref or not checkpoint.root then
    return
  end
  systemlist({ "git", "-C", checkpoint.root, "update-ref", "-d", checkpoint.ref })
end

---Prune old checkpoint refs, keeping the newest `keep_n`.
---@param root string
---@param keep_n integer
function M.gc(root, keep_n)
  if not root then
    return
  end
  keep_n = keep_n or 20
  local refs, code = systemlist({
    "git",
    "-C",
    root,
    "for-each-ref",
    "--sort=-creatordate",
    "--format=%(refname)",
    "refs/0x0/checkpoints/",
  })
  if code ~= 0 then
    return
  end
  for i = keep_n + 1, #refs do
    if refs[i] and refs[i] ~= "" then
      systemlist({ "git", "-C", root, "update-ref", "-d", refs[i] })
    end
  end
end

return M
