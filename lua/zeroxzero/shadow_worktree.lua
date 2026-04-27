local M = {}

local function systemlist(cmd, input)
  local output = input and vim.fn.systemlist(cmd, input) or vim.fn.systemlist(cmd)
  return output, vim.v.shell_error
end

local function system(cmd, input)
  local output = input and vim.fn.system(cmd, input) or vim.fn.system(cmd)
  return output, vim.v.shell_error
end

local function git_root(cwd)
  local output, code = systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if code ~= 0 or not output[1] or output[1] == "" then
    return nil
  end
  return output[1]
end

local function relative_path(root, path)
  local abs = vim.fn.fnamemodify(path, ":p"):gsub("/$", "")
  local prefix = root:gsub("/$", "") .. "/"
  if abs:sub(1, #prefix) == prefix then
    return abs:sub(#prefix + 1)
  end
  return "."
end

local function mkdir_parent(path)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
end

local function copy_file(src, dst)
  mkdir_parent(dst)
  local lines = vim.fn.readfile(src, "b")
  vim.fn.writefile(lines, dst, "b")
end

local function copy_untracked_files(root, worktree)
  local files, code = systemlist({ "git", "-C", root, "ls-files", "--others", "--exclude-standard" })
  if code ~= 0 then
    return
  end
  for _, file in ipairs(files) do
    if file ~= "" then
      local src = root .. "/" .. file
      local stat = vim.loop.fs_stat(src)
      if stat and stat.type == "file" then
        copy_file(src, worktree .. "/" .. file)
      end
    end
  end
end

local function path_filter(paths)
  local filter = {}
  for _, path in ipairs(paths or {}) do
    filter[path] = true
  end
  return filter
end

local function commit_baseline(worktree)
  systemlist({ "git", "-C", worktree, "add", "-A" })
  local status, status_code = systemlist({ "git", "-C", worktree, "status", "--porcelain" })
  if status_code ~= 0 or #status == 0 then
    return true
  end
  local _, commit_code = systemlist({
    "git",
    "-C",
    worktree,
    "-c",
    "user.name=0x0 chat",
    "-c",
    "user.email=0x0-chat@example.invalid",
    "commit",
    "--no-verify",
    "-m",
    "0x0 chat baseline",
  })
  return commit_code == 0
end

local function cache_dir()
  local dir = (vim.env.TMPDIR or "/tmp") .. "/0x0-chat-worktrees"
  vim.fn.mkdir(dir, "p")
  return dir
end

---@class zeroxzero.ShadowWorktree
---@field root string
---@field path string
---@field cwd string
---@field rel_cwd string
local ShadowWorktree = {}
ShadowWorktree.__index = ShadowWorktree

function ShadowWorktree:is_valid()
  local stat = vim.loop.fs_stat(self.path)
  if not stat or stat.type ~= "directory" then
    return false
  end
  local _, code = systemlist({ "git", "-C", self.path, "rev-parse", "--show-toplevel" })
  return code == 0
end

function ShadowWorktree:diff(paths)
  local args = { "git", "-C", self.path, "diff", "--no-ext-diff", "--unified=0" }
  if paths and #paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, paths)
  end
  local output = systemlist(args)
  local filter = path_filter(paths)
  for _, file in ipairs(self:untracked_files()) do
    if not paths or #paths == 0 or filter[file] then
      if #output > 0 then
        table.insert(output, "")
      end
      local untracked =
        systemlist({ "git", "-C", self.path, "diff", "--no-index", "--unified=0", "--", "/dev/null", file })
      vim.list_extend(output, untracked)
    end
  end
  return output
end

function ShadowWorktree:patch(paths)
  local args = { "git", "-C", self.path, "diff", "--binary", "--unified=0" }
  if paths and #paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, paths)
  end
  local output = system(args)
  local filter = path_filter(paths)
  for _, file in ipairs(self:untracked_files()) do
    if not paths or #paths == 0 or filter[file] then
      local untracked =
        system({ "git", "-C", self.path, "diff", "--no-index", "--binary", "--unified=0", "--", "/dev/null", file })
      if untracked ~= "" then
        output = output .. (output ~= "" and "\n" or "") .. untracked
      end
    end
  end
  return output
end

function ShadowWorktree:untracked_files()
  local output, code = systemlist({ "git", "-C", self.path, "ls-files", "--others", "--exclude-standard" })
  if code ~= 0 then
    return {}
  end
  return output
end

function ShadowWorktree:changed_files()
  local output, code = systemlist({ "git", "-C", self.path, "diff", "--name-only" })
  if code ~= 0 then
    return {}
  end
  local files = {}
  for _, file in ipairs(output) do
    if file ~= "" then
      table.insert(files, file)
    end
  end
  vim.list_extend(files, self:untracked_files())
  return files
end

function ShadowWorktree:accept_all()
  local patch = self:patch()
  if patch == "" then
    return false, "no diff to accept"
  end
  local _, code = system({ "git", "-C", self.root, "apply", "--unidiff-zero", "--whitespace=nowarn", "-" }, patch)
  if code ~= 0 then
    return false, "failed to apply chat diff"
  end
  return true, nil
end

function ShadowWorktree:accept_files(files)
  local patch = self:patch(files)
  if patch == "" then
    return false, "no diff to accept"
  end
  local _, code = system({ "git", "-C", self.root, "apply", "--unidiff-zero", "--whitespace=nowarn", "-" }, patch)
  if code ~= 0 then
    return false, "failed to apply chat diff"
  end
  return true, nil
end

function ShadowWorktree:accept_patch(patch)
  if not patch or patch == "" then
    return false, "no hunk to accept"
  end
  local _, code = system({ "git", "-C", self.root, "apply", "--unidiff-zero", "--whitespace=nowarn", "-" }, patch)
  if code ~= 0 then
    return false, "failed to apply chat hunk"
  end
  return true, nil
end

function ShadowWorktree:discard_files(files)
  for _, file in ipairs(files or {}) do
    local _, tracked_code = systemlist({ "git", "-C", self.path, "ls-files", "--error-unmatch", "--", file })
    if tracked_code == 0 then
      systemlist({ "git", "-C", self.path, "checkout", "--", file })
    else
      vim.fn.delete(self.path .. "/" .. file, "rf")
    end
  end
end

function ShadowWorktree:mark_patch_accepted(patch)
  if not patch or patch == "" then
    return false, "no hunk to mark accepted"
  end
  local _, apply_code =
    system({ "git", "-C", self.path, "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn", "-" }, patch)
  if apply_code ~= 0 then
    return false, "failed to update chat review baseline"
  end
  local status, status_code = systemlist({ "git", "-C", self.path, "diff", "--cached", "--name-only" })
  if status_code ~= 0 or #status == 0 then
    return true, nil
  end
  local _, code = systemlist({
    "git",
    "-C",
    self.path,
    "-c",
    "user.name=0x0 chat",
    "-c",
    "user.email=0x0-chat@example.invalid",
    "commit",
    "--no-verify",
    "-m",
    "0x0 chat accepted hunk",
  })
  if code ~= 0 then
    return false, "failed to commit accepted hunk"
  end
  return true, nil
end

function ShadowWorktree:mark_accepted(files)
  local args = { "git", "-C", self.path, "add", "--" }
  vim.list_extend(args, files or {})
  systemlist(args)
  local status = systemlist({ "git", "-C", self.path, "status", "--porcelain", "--", unpack(files or {}) })
  if #status == 0 then
    return true
  end
  local _, code = systemlist({
    "git",
    "-C",
    self.path,
    "-c",
    "user.name=0x0 chat",
    "-c",
    "user.email=0x0-chat@example.invalid",
    "commit",
    "--no-verify",
    "-m",
    "0x0 chat accepted changes",
    "--",
    unpack(files or {}),
  })
  return code == 0
end

function ShadowWorktree:discard()
  if not self:is_valid() then
    return
  end
  local _, code = systemlist({ "git", "-C", self.root, "worktree", "remove", "--force", self.path })
  if code ~= 0 then
    vim.fn.delete(self.path, "rf")
  end
end

function M.create(cwd)
  cwd = cwd or vim.fn.getcwd()
  local root = git_root(cwd)
  if not root then
    return nil, "not inside a git repository"
  end

  local rel_cwd = relative_path(root, cwd)
  local name = vim.fn.fnamemodify(root, ":t") .. "-" .. vim.loop.hrtime()
  local path = cache_dir() .. "/" .. name
  local _, add_code = systemlist({ "git", "-C", root, "worktree", "add", "--detach", path, "HEAD" })
  if add_code ~= 0 then
    return nil, "failed to create chat worktree"
  end

  local dirty_patch = system({ "git", "-C", root, "diff", "--binary", "HEAD" })
  if dirty_patch ~= "" then
    local _, apply_code = system({ "git", "-C", path, "apply", "--whitespace=nowarn", "-" }, dirty_patch)
    if apply_code ~= 0 then
      systemlist({ "git", "-C", root, "worktree", "remove", "--force", path })
      return nil, "failed to copy local changes into chat worktree"
    end
  end
  copy_untracked_files(root, path)
  if not commit_baseline(path) then
    systemlist({ "git", "-C", root, "worktree", "remove", "--force", path })
    return nil, "failed to create chat baseline"
  end

  local worktree = setmetatable({
    root = root,
    path = path,
    rel_cwd = rel_cwd,
    cwd = rel_cwd == "." and path or (path .. "/" .. rel_cwd),
  }, ShadowWorktree)

  return worktree, nil
end

return M
