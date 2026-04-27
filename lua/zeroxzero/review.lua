local M = {}

local Review = {}
Review.__index = Review

local function parse_range(start, count)
  local parsed_start = tonumber(start) or 0
  local parsed_count = count == "" and 1 or (tonumber(count) or 0)
  return parsed_start, parsed_count
end

local function parse_hunks(file, patch)
  local lines = vim.split(patch or "", "\n", { plain = true })
  local header = {}
  local hunks = {}
  local current

  for _, line in ipairs(lines) do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      if current then
        current.patch = table.concat(current.patch_lines, "\n") .. "\n"
        current.patch_lines = nil
        table.insert(hunks, current)
      end
      local parsed_old_start, parsed_old_count = parse_range(old_start, old_count)
      local parsed_new_start, parsed_new_count = parse_range(new_start, new_count)
      current = {
        id = ("%s:%d"):format(file, #hunks + 1),
        file = file,
        old_start = parsed_old_start,
        old_count = parsed_old_count,
        new_start = parsed_new_start,
        new_count = parsed_new_count,
        patch_lines = vim.deepcopy(header),
      }
      table.insert(current.patch_lines, line)
    elseif current then
      table.insert(current.patch_lines, line)
    elseif line ~= "" then
      table.insert(header, line)
    end
  end

  if current then
    current.patch = table.concat(current.patch_lines, "\n") .. "\n"
    current.patch_lines = nil
    table.insert(hunks, current)
  end

  return hunks
end

local function file_kind(patch)
  if patch:match("\nnew file mode ") or patch:match("^new file mode ") then
    return "added"
  end
  if patch:match("\ndeleted file mode ") or patch:match("^deleted file mode ") then
    return "deleted"
  end
  return "modified"
end

function Review.new(worktree)
  local self = setmetatable({
    worktree = worktree,
    files = {},
    file_index = 1,
    hunk_index = 1,
  }, Review)
  self:refresh()
  return self
end

function Review:is_valid()
  return self.worktree and self.worktree:is_valid()
end

function Review:refresh()
  if not self:is_valid() then
    self.files = {}
    return false
  end

  local previous_file = self:current_file()
  local previous_path = previous_file and previous_file.path
  local files = {}
  for _, path in ipairs(self.worktree:changed_files()) do
    local patch = self.worktree:patch({ path })
    if patch ~= "" then
      table.insert(files, {
        path = path,
        kind = file_kind(patch),
        patch = patch,
        hunks = parse_hunks(path, patch),
      })
    end
  end
  table.sort(files, function(left, right)
    return left.path < right.path
  end)

  self.files = files
  self.file_index = math.min(self.file_index, math.max(#self.files, 1))
  self.hunk_index = math.max(self.hunk_index, 1)

  if previous_path then
    for index, file in ipairs(self.files) do
      if file.path == previous_path then
        self.file_index = index
        break
      end
    end
  end

  local file = self:current_file()
  if file then
    self.hunk_index = math.min(self.hunk_index, math.max(#file.hunks, 1))
  else
    self.hunk_index = 1
  end

  return #self.files > 0
end

function Review:is_empty()
  return #self.files == 0
end

function Review:summary()
  local hunk_count = 0
  for _, file in ipairs(self.files) do
    hunk_count = hunk_count + #file.hunks
  end
  return {
    files = #self.files,
    hunks = hunk_count,
  }
end

function Review:current_file()
  return self.files[self.file_index]
end

function Review:current_hunk()
  local file = self:current_file()
  if not file then
    return nil
  end
  return file.hunks[self.hunk_index]
end

function Review:select_file(index)
  if #self.files == 0 then
    return nil
  end
  self.file_index = math.max(1, math.min(index, #self.files))
  self.hunk_index = 1
  return self:current_file()
end

function Review:next_hunk()
  local file = self:current_file()
  if not file then
    return nil
  end
  if self.hunk_index < #file.hunks then
    self.hunk_index = self.hunk_index + 1
    return self:current_hunk()
  end
  for file_index = self.file_index + 1, #self.files do
    if #self.files[file_index].hunks > 0 then
      self.file_index = file_index
      self.hunk_index = 1
      return self:current_hunk()
    end
  end
  for file_index = 1, #self.files do
    if #self.files[file_index].hunks > 0 then
      self.file_index = file_index
      self.hunk_index = 1
      return self:current_hunk()
    end
  end
  return nil
end

function Review:previous_hunk()
  local file = self:current_file()
  if not file then
    return nil
  end
  if self.hunk_index > 1 then
    self.hunk_index = self.hunk_index - 1
    return self:current_hunk()
  end
  for file_index = self.file_index - 1, 1, -1 do
    local hunks = self.files[file_index].hunks
    if #hunks > 0 then
      self.file_index = file_index
      self.hunk_index = #hunks
      return self:current_hunk()
    end
  end
  for file_index = #self.files, 1, -1 do
    local hunks = self.files[file_index].hunks
    if #hunks > 0 then
      self.file_index = file_index
      self.hunk_index = #hunks
      return self:current_hunk()
    end
  end
  return nil
end

function Review:accept_current_hunk()
  local hunk = self:current_hunk()
  if not hunk then
    return false, "no hunk selected"
  end
  local ok, err = self.worktree:accept_patch(hunk.patch)
  if not ok then
    return false, err
  end
  ok, err = self.worktree:mark_patch_accepted(hunk.patch)
  if not ok then
    return false, err
  end
  self:refresh()
  return true, nil
end

function Review:reject_current_hunk()
  local hunk = self:current_hunk()
  if not hunk then
    return false, "no hunk selected"
  end
  local ok, err = self.worktree:reject_patch(hunk.patch)
  if not ok then
    return false, err
  end
  self:refresh()
  return true, nil
end

function Review:accept_current_file()
  local file = self:current_file()
  if not file then
    return false, "no file selected"
  end
  local ok, err = self.worktree:accept_files({ file.path })
  if not ok then
    return false, err
  end
  if not self.worktree:mark_accepted({ file.path }) then
    return false, "failed to update chat review baseline"
  end
  self:refresh()
  return true, nil
end

function Review:reject_current_file()
  local file = self:current_file()
  if not file then
    return false, "no file selected"
  end
  self.worktree:discard_files({ file.path })
  self:refresh()
  return true, nil
end

function Review:accept_all()
  local ok, err = self.worktree:accept_all()
  if not ok then
    return false, err
  end
  self.files = {}
  return true, nil
end

function Review:reject_all()
  self.files = {}
  return true, nil
end

M.new = Review.new
M._parse_hunks = parse_hunks

return M
