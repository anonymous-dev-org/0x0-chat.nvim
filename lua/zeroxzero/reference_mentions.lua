local M = {}

local TRAILING_PUNCTUATION = {
  ["."] = true,
  [","] = true,
  [";"] = true,
  [":"] = true,
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
}

local function to_absolute_path(path, cwd)
  if vim.fn.fnamemodify(path, ":p") == path then
    return vim.fn.fnamemodify(path, ":p")
  end
  return vim.fn.fnamemodify((cwd or vim.fn.getcwd()) .. "/" .. path, ":p")
end

local function trim_trailing_punctuation(token)
  while #token > 0 and TRAILING_PUNCTUATION[token:sub(-1)] do
    token = token:sub(1, -2)
  end
  return token
end

local function is_readable_file(path, cwd)
  local stat = vim.loop.fs_stat(to_absolute_path(path, cwd))
  return stat ~= nil and stat.type == "file"
end

local function read_lines(path, start_line, end_line, cwd)
  local lines = vim.fn.readfile(to_absolute_path(path, cwd))
  if not start_line then
    return lines
  end
  return vim.list_slice(lines, start_line, end_line)
end

function M.parse(input, cwd)
  local mentions = {}
  local seen = {}

  for token in input:gmatch("@([^%s`]+)") do
    token = trim_trailing_punctuation(token)

    local range_path, start_line, end_line = token:match("^(.-)#L(%d+)%s*%-L?(%d+)$")
    if not range_path then
      range_path, start_line = token:match("^(.-)#L(%d+)$")
      end_line = start_line
    end

    local mention
    if range_path and range_path ~= "" then
      local start_number = tonumber(start_line)
      local end_number = tonumber(end_line)
      if
        start_number
        and end_number
        and start_number > 0
        and end_number >= start_number
        and is_readable_file(range_path, cwd)
      then
        mention = {
          raw = "@" .. token,
          path = range_path,
          absolute_path = to_absolute_path(range_path, cwd),
          type = "range",
          start_line = start_number,
          end_line = end_number,
        }
      end
    elseif is_readable_file(token, cwd) then
      mention = {
        raw = "@" .. token,
        path = token,
        absolute_path = to_absolute_path(token, cwd),
        type = "file",
      }
    end

    if mention then
      local key = table.concat({
        mention.type,
        mention.absolute_path,
        tostring(mention.start_line or ""),
        tostring(mention.end_line or ""),
      }, "\0")
      if not seen[key] then
        seen[key] = true
        table.insert(mentions, mention)
      end
    end
  end

  return mentions
end

local function git_branch(cwd)
  local out = vim.fn.systemlist({ "git", "-C", cwd or vim.fn.getcwd(), "symbolic-ref", "--quiet", "--short", "HEAD" })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  return out[1]
end

local function metadata_block(cwd)
  cwd = cwd or vim.fn.getcwd()
  local lines = { "<context>", ("<cwd>%s</cwd>"):format(cwd) }
  local branch = git_branch(cwd)
  if branch and branch ~= "" then
    lines[#lines + 1] = ("<branch>%s</branch>"):format(branch)
  end
  -- Best-effort: previously-focused buffer (the last non-chat-input window).
  local cur_buf = vim.api.nvim_get_current_buf()
  local ft = vim.bo[cur_buf].filetype
  if ft ~= "zeroxzero-chat-input" and ft ~= "markdown" then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    if name and name ~= "" then
      lines[#lines + 1] = ("<editing>%s</editing>"):format(vim.fn.fnamemodify(name, ":~:."))
    end
  end
  lines[#lines + 1] = "</context>"
  return { type = "text", text = table.concat(lines, "\n") }
end

function M.to_prompt_blocks(input, cwd)
  local blocks = { metadata_block(cwd), { type = "text", text = input } }

  for _, mention in ipairs(M.parse(input, cwd)) do
    if mention.type == "file" then
      table.insert(blocks, {
        type = "resource_link",
        uri = "file://" .. mention.absolute_path,
        name = vim.fn.fnamemodify(mention.absolute_path, ":t"),
      })
    elseif mention.type == "range" then
      local lines = read_lines(mention.absolute_path, mention.start_line, mention.end_line, cwd)
      local numbered = {}
      for i, line in ipairs(lines) do
        table.insert(numbered, ("Line %d: %s"):format(mention.start_line + i - 1, line))
      end
      table.insert(blocks, {
        type = "text",
        text = table.concat({
          "<selected_code>",
          ("<path>%s</path>"):format(mention.absolute_path),
          ("<line_start>%d</line_start>"):format(mention.start_line),
          ("<line_end>%d</line_end>"):format(mention.end_line),
          "<snippet>",
          table.concat(numbered, "\n"),
          "</snippet>",
          "</selected_code>",
        }, "\n"),
      })
    end
  end

  return blocks
end

return M
