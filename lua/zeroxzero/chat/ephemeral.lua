-- Ephemeral session helper: opens a one-shot ACP session, sends a prompt
-- with a read-only system contract, streams text chunks to a callback,
-- and tears the session down on completion. Used by inline-ask.
--
-- Mirrors the lifecycle of chat/session.lua:discover_options but adds a
-- prompt send.

local M = {}

---@param opts {
---   prompt_blocks: table[],
---   on_chunk: fun(text: string),
---   on_done: fun(err: string|nil),
--- }
---@return fun() cancel  call to abort the ephemeral session (T2.3)
function M:run_inline_ask(opts)
  opts = opts or {}
  local on_chunk = opts.on_chunk or function() end
  local on_done = opts.on_done or function() end
  local prompt_blocks = opts.prompt_blocks or {}

  local handle = { client = nil, session_id = nil, cancelled = false, done = false }
  local function cancel()
    if handle.done then
      return
    end
    handle.cancelled = true
    if handle.client and handle.session_id then
      pcall(function()
        handle.client:cancel(handle.session_id)
      end)
      pcall(function()
        handle.client:unsubscribe(handle.session_id)
      end)
    end
    if not handle.done then
      handle.done = true
      vim.schedule(function()
        on_done("cancelled")
      end)
    end
  end

  self:_ensure_client(function(client, cerr)
    if cerr or not client then
      local msg = cerr and (cerr.message or vim.inspect(cerr)) or "client unavailable"
      vim.schedule(function()
        on_done(msg)
      end)
      return
    end
    handle.client = client
    if handle.cancelled then
      return
    end
    client:new_session(self.repo_root or vim.fn.getcwd(), function(result, err)
      if err or not result or not result.sessionId then
        vim.schedule(function()
          on_done((err and (err.message or vim.inspect(err))) or "session/new failed")
        end)
        return
      end
      local session_id = result.sessionId
      handle.session_id = session_id

      -- Strict read-only: subscribe to updates ONLY. No fs_write handler,
      -- no permission handler (writes will fail at the provider, which is
      -- the intended behavior).
      client:subscribe(session_id, {
        on_update = function(update)
          if update.sessionUpdate == "agent_message_chunk" or update.sessionUpdate == "agent_thought_chunk" then
            local text = update.content and update.content.text or ""
            if text ~= "" then
              vim.schedule(function()
                on_chunk(text)
              end)
            end
          end
        end,
        on_request_permission = function(request, respond)
          -- Read-only mode: pick a reject option from request.options if
          -- offered, else respond with empty string which acp_client maps
          -- to a cancelled outcome.
          local reject_id
          for _, option in ipairs(request and request.options or {}) do
            if option.kind == "reject_once" or option.kind == "reject_always" then
              reject_id = option.optionId
              break
            end
          end
          respond(reject_id or "")
        end,
        on_fs_read_text_file = function(params, respond)
          -- Allow reads via reconcile if available, else best-effort disk read.
          if self.reconcile then
            local content, rerr = self.reconcile:read_for_agent(params.path, params.line, params.limit)
            if rerr then
              respond(nil, { code = -32000, message = rerr })
              return
            end
            respond(content, nil)
            return
          end
          local f = io.open(params.path, "rb")
          if not f then
            respond(nil, { code = -32000, message = "file not found" })
            return
          end
          local content = f:read("*a")
          f:close()
          respond(content, nil)
        end,
        on_fs_write_text_file = function(_, respond)
          respond({ code = -32000, message = "read-only inline ask: writes not allowed" })
        end,
      })

      client:prompt(session_id, prompt_blocks, function(_, perr)
        vim.schedule(function()
          pcall(function()
            client:cancel(session_id)
          end)
          pcall(function()
            client:unsubscribe(session_id)
          end)
          if not handle.done then
            handle.done = true
            on_done(perr and (perr.message or vim.inspect(perr)) or nil)
          end
        end)
      end)
    end)
  end)

  return cancel
end

return M
