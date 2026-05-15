---One-shot inline edit: ask the agent CLI to rewrite a selection or motion.
---No chat session, no history — fork the CLI in headless mode, pipe a prompt
---over stdin, collect stdout, render the result through inline_diff.

local Agents = require("zxz.agents")
local Diff = require("zxz.edit.inline_diff")

local M = {}

---Pick an agent for the inline edit. Preference order: explicit name → user
---config (`vim.g.zxz_inline_agent`) → first available registered agent.
---@param explicit? string
---@return string|nil agent_name, string? err
local function pick_agent(explicit)
  if explicit and Agents.get(explicit) then
    return explicit
  end
  local preferred = vim.g.zxz_inline_agent
  if preferred and Agents.available(preferred) then
    return preferred
  end
  for _, name in ipairs(Agents.names()) do
    if Agents.available(name) then
      return name
    end
  end
  return nil, "no available agent CLI on PATH"
end

---Build a single-string prompt for the agent. The contract is "return ONLY the
---replacement text" — we keep this short and unambiguous because tiny CLIs are
---bad at following long meta-instructions.
---@param ctx { filename: string, filetype: string, region: string, range: {start_line:integer,end_line:integer}, instruction: string }
---@return string
function M.build_prompt(ctx)
  return table.concat({
    ("You are editing %s (language: %s)."):format(
      ctx.filename ~= "" and ctx.filename or "<scratch>",
      ctx.filetype ~= "" and ctx.filetype or "plain"
    ),
    "",
    ("Region to edit (lines %d-%d):"):format(ctx.range.start_line, ctx.range.end_line),
    "```" .. (ctx.filetype or ""),
    ctx.region,
    "```",
    "",
    "Instruction: " .. ctx.instruction,
    "",
    "Respond with ONLY the replacement text for the region. "
      .. "No markdown fences, no commentary, no explanation. "
      .. "Preserve the original indentation style.",
  }, "\n")
end

---Strip the agent's wrapping artifacts: leading/trailing blank lines, a single
---``` ```...``` ``` fence around the whole reply, "Here's the updated code:"
---preambles. Aggressive but safe — we own the contract by prompt.
---@param text string
---@return string
function M.clean_response(text)
  text = text:gsub("\r\n", "\n")
  -- Strip a single full fenced block if the entire response is one.
  local fence_pat = "^%s*```[%w_-]*\n(.-)\n```%s*$"
  local stripped = text:match(fence_pat)
  if stripped then
    text = stripped
  end
  -- Trim leading/trailing blank lines.
  text = text:gsub("^%s*\n", "")
  text = text:gsub("\n%s*$", "")
  return text
end

---Spawn the agent CLI in headless mode, pipe `prompt` on stdin, collect stdout
---until exit, then call `cb(new_text, err)` on the main loop.
---@param agent string
---@param prompt string
---@param cb fun(new_text?: string, err?: string)
function M.invoke_agent(agent, prompt, cb)
  local argv = Agents.headless_argv(agent)
  if not argv then
    return cb(nil, "unknown agent: " .. agent)
  end
  if vim.fn.executable(argv[1]) ~= 1 then
    return cb(nil, ("agent %q not on PATH"):format(argv[1]))
  end

  local stdout_chunks = {}
  local stderr_chunks = {}
  local job_id = vim.fn.jobstart(argv, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(stdout_chunks, chunk)
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          table.insert(stderr_chunks, chunk)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          cb(nil, ("agent exited with %d: %s"):format(code, table.concat(stderr_chunks, "\n")))
          return
        end
        local raw = table.concat(stdout_chunks, "\n")
        cb(M.clean_response(raw), nil)
      end)
    end,
  })
  if job_id <= 0 then
    return cb(nil, "failed to spawn agent (job_id=" .. tostring(job_id) .. ")")
  end
  pcall(vim.fn.chansend, job_id, prompt)
  pcall(vim.fn.chanclose, job_id, "stdin")
end

---@class zxz.InlineEdit.Opts
---@field range? { start_line: integer, end_line: integer }  1-based inclusive; defaults to whole buffer
---@field instruction? string                                 if nil, prompts the user
---@field agent? string                                       overrides default
---@field bufnr? integer                                      defaults to current

---Entry point.
---@param opts? zxz.InlineEdit.Opts
function M.start(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local total = vim.api.nvim_buf_line_count(bufnr)
  local range = opts.range or { start_line = 1, end_line = total }
  range.start_line = math.max(1, range.start_line)
  range.end_line = math.min(total, range.end_line)

  local agent, err = pick_agent(opts.agent)
  if not agent then
    vim.notify("zxz: " .. tostring(err), vim.log.levels.ERROR)
    return
  end

  local function with_instruction(instruction)
    if not instruction or instruction == "" then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(bufnr, range.start_line - 1, range.end_line, false)
    local prompt = M.build_prompt({
      filename = vim.api.nvim_buf_get_name(bufnr),
      filetype = vim.bo[bufnr].filetype,
      region = table.concat(lines, "\n"),
      range = range,
      instruction = instruction,
    })
    vim.notify(("zxz.edit: asking %s…"):format(agent))
    M.invoke_agent(agent, prompt, function(new_text, run_err)
      if run_err then
        vim.notify("zxz.edit: " .. run_err, vim.log.levels.ERROR)
        return
      end
      if not new_text or new_text == "" then
        vim.notify("zxz.edit: agent returned no text", vim.log.levels.WARN)
        return
      end
      Diff.render(bufnr, range, new_text)
    end)
  end

  if opts.instruction then
    with_instruction(opts.instruction)
  else
    vim.ui.input({ prompt = "Edit instruction: " }, with_instruction)
  end
end

return M
