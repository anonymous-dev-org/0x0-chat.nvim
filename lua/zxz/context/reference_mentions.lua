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

local DIAGNOSTIC_SEVERITY_FILTERS = {
  errors = vim.diagnostic.severity.ERROR,
  error = vim.diagnostic.severity.ERROR,
  warnings = vim.diagnostic.severity.WARN,
  warning = vim.diagnostic.severity.WARN,
  warn = vim.diagnostic.severity.WARN,
  info = vim.diagnostic.severity.INFO,
  hint = vim.diagnostic.severity.HINT,
}

local function diagnostic_token(token)
  local base, sev = token:match("^(diagnostics)%:([%w]+)$")
  if base then
    return sev
  end
  if token == "diagnostics" then
    return ""
  end
  return nil
end

local LSP_MENTION_KINDS = { hover = true, def = true, symbol = true }

local function lsp_token(token)
  if LSP_MENTION_KINDS[token] then
    return token
  end
  return nil
end

---@param char string|nil
---@return boolean
local function is_mention_boundary(char)
  -- An `@` only begins a mention when preceded by whitespace, an opener,
  -- or nothing (start of string). Anything else (a letter/digit/dot) is
  -- treated as mid-word and skipped — e.g. `bob@example.com` produces
  -- no `@example.com` mention.
  if not char or char == "" then
    return true
  end
  return char:match("[%s%(%[%{%<%>%,;\"']") ~= nil
end

---Locate the `@token` that the cursor is currently inside or at the end of.
---Pure over `line`/`col`; no buffer side effects. Used both by the completion
---popup and by chat_widget's `@` auto-trigger so the trigger rule and the
---parser rule agree.
---@param line string
---@param col integer 0-based byte column of the cursor
---@return integer|nil start_col_1based, string|nil token_after_at
function M.cursor_token(line, col)
  local before = line:sub(1, col)
  local start_col, token = before:match(".*()@([^%s`]*)$")
  if not start_col then
    return nil, nil
  end
  local prev = start_col > 1 and before:sub(start_col - 1, start_col - 1) or nil
  if not is_mention_boundary(prev) then
    return nil, nil
  end
  return start_col, token
end

function M.parse(input, cwd)
  local mentions = {}
  local seen = {}

  -- Position-based scan so we can check the character before each `@`.
  local pos = 1
  while pos <= #input do
    local s, e, token = input:find("@([^%s`]+)", pos)
    if not s then
      break
    end
    pos = e + 1
    local prev = s > 1 and input:sub(s - 1, s - 1) or nil
    if not is_mention_boundary(prev) then
      goto continue
    end
    token = trim_trailing_punctuation(token)
    local start_byte = s - 1
    local end_byte = s + #token -- exclusive, post-trim

    local function attach_range(mention)
      mention.start_byte = start_byte
      mention.end_byte = end_byte
      return mention
    end

    local diag_sev = diagnostic_token(token)
    if diag_sev ~= nil then
      local severity = diag_sev ~= "" and DIAGNOSTIC_SEVERITY_FILTERS[diag_sev:lower()] or nil
      local key = "diagnostics\0" .. tostring(severity or "all")
      if not seen[key] then
        seen[key] = true
        table.insert(
          mentions,
          attach_range({
            raw = "@" .. token,
            type = "diagnostics",
            severity = severity,
            severity_label = severity and diag_sev:lower() or "all",
          })
        )
      end
      goto continue
    end

    local lsp_kind = lsp_token(token)
    if lsp_kind then
      local key = "lsp\0" .. lsp_kind
      if not seen[key] then
        seen[key] = true
        table.insert(
          mentions,
          attach_range({
            raw = "@" .. token,
            type = "lsp",
            lsp_kind = lsp_kind,
          })
        )
      end
      goto continue
    end

    if token == "recent" or token:match("^recent%:%d+$") then
      local n_str = token:match("^recent%:(%d+)$")
      local n = n_str and tonumber(n_str) or nil
      local key = "recent\0" .. tostring(n or "all")
      if not seen[key] then
        seen[key] = true
        table.insert(mentions, attach_range({ raw = "@" .. token, type = "recent", count = n }))
      end
      goto continue
    end

    if token == "repomap" then
      if not seen["repomap"] then
        seen["repomap"] = true
        table.insert(mentions, attach_range({ raw = "@" .. token, type = "repomap" }))
      end
      goto continue
    end

    if token == "test-output" or token == "test_output" then
      if not seen["test-output"] then
        seen["test-output"] = true
        table.insert(mentions, attach_range({ raw = "@" .. token, type = "test_output" }))
      end
      goto continue
    end

    do
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
          table.insert(mentions, attach_range(mention))
        end
      end
    end

    ::continue::
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
  if ft ~= "zxz-chat-input" and ft ~= "markdown" then
    local name = vim.api.nvim_buf_get_name(cur_buf)
    if name and name ~= "" then
      lines[#lines + 1] = ("<editing>%s</editing>"):format(vim.fn.fnamemodify(name, ":~:."))
    end
  end
  lines[#lines + 1] = "</context>"
  return { type = "text", text = table.concat(lines, "\n") }
end

local SEVERITY_LABEL = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

---Find the buffer + cursor of the most recent non-chat window in the
---current tabpage. Used by @hover / @def / @symbol to capture the user's
---active code position at prompt-submit time.
---@return integer|nil bufnr, integer|nil row (1-based), integer|nil col (0-based)
local function source_position()
  local current_tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(current_tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    local bt = vim.bo[buf].buftype
    if
      ft ~= "zxz-chat-input"
      and ft ~= "zxz-chat-files"
      and ft ~= "zxz-inline-edit-input"
      and ft ~= "zxz-inline-ask-input"
      and bt ~= "nofile"
    then
      local cur = vim.api.nvim_win_get_cursor(win)
      return buf, cur[1], cur[2]
    end
  end
  return nil, nil, nil
end

local function rel_path(cwd, abs)
  cwd = cwd or vim.fn.getcwd()
  if abs and abs ~= "" and abs:sub(1, #cwd + 1) == cwd .. "/" then
    return abs:sub(#cwd + 2)
  end
  return abs and vim.fn.fnamemodify(abs, ":~:.") or "(unnamed buffer)"
end

local function format_lsp_block(mention, cwd)
  local LSP = require("zxz.context.lsp")
  local bufnr, row, col = source_position()
  if not bufnr then
    return { type = "text", text = ("`%s`: no source buffer to inspect."):format(mention.raw) }
  end
  local path = rel_path(cwd, vim.api.nvim_buf_get_name(bufnr))

  if mention.lsp_kind == "hover" then
    local hover = LSP.hover_at(bufnr, row, col)
    if not hover or hover == "" then
      return { type = "text", text = ("`@hover` at %s:%d — no hover info."):format(path, row) }
    end
    return {
      type = "text",
      text = table.concat({
        ("LSP hover at %s:%d:"):format(path, row),
        "```",
        hover,
        "```",
      }, "\n"),
    }
  elseif mention.lsp_kind == "def" then
    local def = LSP.definition_at(bufnr, row, col)
    if not def then
      return { type = "text", text = ("`@def` at %s:%d — no definition found."):format(path, row) }
    end
    return {
      type = "text",
      text = ("LSP definition: %s:%d:%d"):format(rel_path(cwd, def.path), def.line, def.character + 1),
    }
  elseif mention.lsp_kind == "symbol" then
    local sym = LSP.symbol_at(bufnr, row, col)
    if not sym then
      return { type = "text", text = ("`@symbol` at %s:%d — no symbol detected."):format(path, row) }
    end
    return {
      type = "text",
      text = ("Symbol under cursor at %s:%d: `%s` (%s)"):format(path, row, sym.name, sym.kind),
    }
  end
end

local function format_recent_block(mention)
  local Recent = require("zxz.context.recent")
  local entries = Recent.list(mention.count)
  if #entries == 0 then
    return { type = "text", text = "No recent files." }
  end
  local lines = { ("Recently edited files (%d):"):format(#entries) }
  for _, path in ipairs(entries) do
    lines[#lines + 1] = "  - " .. path
  end
  return { type = "text", text = table.concat(lines, "\n") }
end

---@param abs_path string
---@param rel_label string
---@return { type: "text", text: string }|nil
local function maybe_file_summary(abs_path, rel_label)
  local stat = vim.loop.fs_stat(abs_path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  local cfg = require("zxz.core.config").current
  local threshold = (cfg.context and cfg.context.summarize_threshold) or (8 * 1024)
  if stat.size <= threshold then
    return nil
  end
  -- Above threshold → emit a treesitter-backed summary.
  local fd = io.open(abs_path, "rb")
  if not fd then
    return nil
  end
  local source = fd:read("*a") or ""
  fd:close()
  local ft = vim.filetype.match({ filename = abs_path })
  local lines = { ("File %s (%.1f KB, summarized; full body omitted):"):format(rel_label, stat.size / 1024) }
  if ft then
    local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, ft)
    if ok_parser and parser then
      local ok_tree, trees = pcall(function()
        return parser:parse()
      end)
      if ok_tree and trees and trees[1] then
        local root = trees[1]:root()
        local symbols = {}
        for child in root:iter_children() do
          local t = child:type()
          if t:match("function") or t:match("class") or t:match("method") or t:match("struct") or t:match("trait") then
            local name
            for sub in child:iter_children() do
              local st = sub:type()
              if st == "identifier" or st == "name" or st == "property_identifier" or st == "type_identifier" then
                name = vim.treesitter.get_node_text(sub, source)
                break
              end
            end
            local sr, _, er, _ = child:range()
            symbols[#symbols + 1] = ("  - %s `%s` (lines %d-%d)"):format(t, name or "?", sr + 1, er + 1)
            if #symbols >= 30 then
              break
            end
          end
        end
        if #symbols > 0 then
          lines[#lines + 1] = "Symbols:"
          for _, s in ipairs(symbols) do
            lines[#lines + 1] = s
          end
        end
      end
    end
  end
  -- Also include the first ~30 lines for orientation.
  local raw_lines = vim.split(source, "\n", { plain = true })
  local head_limit = math.min(30, #raw_lines)
  if head_limit > 0 then
    lines[#lines + 1] = "Head:"
    lines[#lines + 1] = "```" .. (ft or "")
    for i = 1, head_limit do
      lines[#lines + 1] = raw_lines[i]
    end
    lines[#lines + 1] = "```"
  end
  return { type = "text", text = table.concat(lines, "\n") }
end

local function format_diagnostics_block(mention)
  -- Resolve the source buffer (the code window in the current tab, not
  -- the chat input). Falls back to current buf if no source is found
  -- (e.g. when not invoked from chat).
  local bufnr = source_position() or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  local rel = (name and name ~= "") and vim.fn.fnamemodify(name, ":~:.") or "(unnamed buffer)"
  local opts = mention.severity and { severity = mention.severity } or nil
  local all = vim.diagnostic.get(bufnr, opts)
  local total = #vim.diagnostic.get(bufnr)
  local lines = {}
  for _, d in ipairs(all) do
    local sev = SEVERITY_LABEL[d.severity] or "?"
    local source = d.source and d.source ~= "" and (d.source .. ": ") or ""
    lines[#lines + 1] = ("%-5s %d:%d  %s%s"):format(
      sev,
      (d.lnum or 0) + 1,
      (d.col or 0) + 1,
      source,
      (d.message or ""):gsub("\n", " ")
    )
  end
  if #lines == 0 then
    lines[1] = "(no diagnostics)"
  end
  local header = ("Diagnostics in %s (%d/%d matching %s):"):format(rel, #all, total, mention.severity_label)
  return {
    type = "text",
    text = table.concat({ header, "```", table.concat(lines, "\n"), "```" }, "\n"),
  }
end

function M.to_prompt_blocks(input, cwd)
  local blocks = { metadata_block(cwd), { type = "text", text = input } }

  for _, mention in ipairs(M.parse(input, cwd)) do
    if mention.type == "diagnostics" then
      table.insert(blocks, format_diagnostics_block(mention))
    elseif mention.type == "lsp" then
      table.insert(blocks, format_lsp_block(mention, cwd))
    elseif mention.type == "recent" then
      table.insert(blocks, format_recent_block(mention))
    elseif mention.type == "repomap" then
      local RepoMap = require("zxz.context.repo_map")
      table.insert(blocks, RepoMap.format_block(cwd))
    elseif mention.type == "test_output" then
      local TestCommand = require("zxz.context.test_command")
      local root = require("zxz.core.checkpoint").git_root(cwd or vim.fn.getcwd()) or (cwd or vim.fn.getcwd())
      local cmd, code, stdout, stderr = TestCommand.run(root)
      local body = stdout or ""
      if stderr and stderr ~= "" then
        body = body .. (body == "" and "" or "\n") .. stderr
      end
      local header
      if cmd == "" then
        header = "Test command: (not configured)"
      else
        header = ("Test command: %s   exit: %s"):format(cmd, code or "?")
      end
      table.insert(blocks, {
        type = "text",
        text = table.concat({ header, "```", body, "```" }, "\n"),
      })
    elseif mention.type == "file" then
      local rel = mention.path or vim.fn.fnamemodify(mention.absolute_path, ":~:.")
      local summary = maybe_file_summary(mention.absolute_path, rel)
      if summary then
        table.insert(blocks, summary)
      else
        table.insert(blocks, {
          type = "resource_link",
          uri = "file://" .. mention.absolute_path,
          name = vim.fn.fnamemodify(mention.absolute_path, ":t"),
        })
      end
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
