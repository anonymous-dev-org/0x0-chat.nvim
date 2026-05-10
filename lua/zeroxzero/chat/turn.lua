-- Turn lifecycle: prompt submission, slash dispatch, streaming updates,
-- queueing, cancellation.

local InlineDiff = require("zeroxzero.inline_diff")
local ReferenceMentions = require("zeroxzero.reference_mentions")
local Title = require("zeroxzero.chat.title")
local config = require("zeroxzero.config")
local util = require("zeroxzero.chat.util")

local M = {}

function M:_handle_update(update)
  local kind = update.sessionUpdate
  if kind == "agent_message_chunk" or kind == "agent_thought_chunk" then
    local text = update.content and update.content.text or ""
    if text == "" then
      return
    end
    self:_mark_responding("Working")
    local msg_kind = kind == "agent_thought_chunk" and "thought" or "agent"
    self.history:add_agent_chunk(msg_kind, text)
    self:_render()
  elseif kind == "tool_call" then
    if not update.toolCallId then
      return
    end
    if self.in_flight then
      self:_set_turn_activity("waiting", "Working")
    end
    self.history:add({
      type = "tool_call",
      tool_call_id = update.toolCallId,
      kind = update.kind or "tool",
      title = update.title or "",
      status = update.status or "pending",
      raw_input = update.rawInput,
      content = update.content,
      locations = update.locations,
    })
    self:_render()
  elseif kind == "tool_call_update" then
    if not update.toolCallId then
      return
    end
    if self.in_flight then
      if update.status == "completed" or update.status == "failed" then
        self:_set_turn_activity("waiting", "Working")
      else
        self:_set_turn_activity("waiting", "Working")
      end
    end
    local patch = util.tool_patch(update)
    self.history:update_tool_call(update.toolCallId, patch)
    if update.status == "completed" and self.checkpoint then
      local tool_call_id = update.toolCallId
      vim.schedule(function()
        self:_snapshot_for_tool(tool_call_id)
        InlineDiff.refresh_all(self.checkpoint)
      end)
    end
    self:_render()
  elseif kind == "config_option_update" then
    self:_set_config_options(update.configOptions)
  end
end

local SLASH_COMMANDS = {
  clear = "new_session",
  new = "new_session",
  changes = "show_changes",
  accept = "accept_all",
  discard = "discard_all",
  stop = "stop",
  cancel = "cancel",
  diff = "diff",
}

local SLASH_HELP = [[Slash commands:
  /clear        start a new session
  /changes      list files changed since checkpoint
  /diff [id]    open the turn diff (or per-tool diff with id)
  /accept       accept all pending changes
  /discard      discard all pending changes
  /cancel       cancel the in-flight turn
  /stop         reset the session]]

---@param prompt string
---@return boolean handled
function M:_dispatch_slash(prompt)
  local cmd, rest = prompt:match("^/([%w_-]+)%s*(.*)$")
  if not cmd then
    return false
  end
  if cmd == "help" then
    vim.notify(SLASH_HELP, vim.log.levels.INFO)
    self.widget:clear_input()
    return true
  end
  local method = SLASH_COMMANDS[cmd]
  if not method then
    return false
  end
  self.widget:clear_input()
  if rest and rest ~= "" then
    rest = vim.trim(rest)
    self[method](self, rest)
  else
    self[method](self)
  end
  return true
end

function M:submit()
  local prompt = self.widget:read_input()
  if prompt == "" then
    vim.notify("acp: empty prompt", vim.log.levels.WARN)
    return
  end
  if self:_dispatch_slash(prompt) then
    return
  end
  self.widget:push_history(prompt)
  if self.in_flight then
    local id = self.history:add_user(prompt, "queued")
    table.insert(self.queued_prompts, { id = id, text = prompt })
    self.widget:clear_input()
    self:_set_turn_activity(self.widget.activity_state or "waiting", self.widget.activity_label or "Working")
    self.widget:render()
    return
  end
  local id = self.history:add_user(prompt, "active")
  self:_maybe_generate_title(prompt)
  self:_submit_prompt(prompt, id)
end

---@param prompt string
function M:_maybe_generate_title(prompt)
  if self.title_requested or self.title_pending then
    return
  end
  self.title_requested = true
  self.title_pending = true
  local provider_name = self.provider_name or config.current.provider
  local cwd = self.repo_root or vim.fn.getcwd()
  Title.generate(provider_name, cwd, prompt, function(title)
    vim.schedule(function()
      self.title_pending = false
      if title and title ~= "" then
        self.title = title
        self:_schedule_persist()
      end
    end)
  end)
end

---@param prompt string
---@param user_id string
---@param retried_session? boolean
function M:_submit_prompt(prompt, user_id, retried_session)
  self.in_flight = true
  self.response_started = false
  self.cancel_requested = false
  self.history:set_user_status(user_id, "active")
  self.widget:clear_input()
  self:_set_turn_activity("waiting", "Working")
  self.widget:render()

  self:_ensure_session(function(client, session_id, sess_err)
    if sess_err or not client or not session_id then
      vim.schedule(function()
        local msg = sess_err and (sess_err.message or vim.inspect(sess_err)) or "failed to start session"
        self.history:add_agent_chunk("agent", "_error: " .. msg .. "_")
        self:_set_activity(nil)
        self.widget:render()
        self.in_flight = false
        self.response_started = false
        self:_notify_or_continue()
      end)
      return
    end
    self:_set_turn_activity("waiting", "Working")
    client:prompt(session_id, ReferenceMentions.to_prompt_blocks(prompt, self:_session_cwd()), function(result, err)
      vim.schedule(function()
        if self.client ~= client or self.session_id ~= session_id then
          return
        end
        local was_cancelled = self.cancel_requested or util.is_cancel_result(result)
        if err and util.is_session_missing(err) and not retried_session then
          self.client = nil
          self.session_id = nil
          self:_set_turn_activity("waiting", "Restarting session")
          self.widget:render()
          self:_submit_prompt(prompt, user_id, true)
          return
        end
        if err and not (was_cancelled and util.is_transport_disconnected(err)) then
          local m = util.error_message(err)
          self.history:add_agent_chunk("agent", "\n_error: " .. m .. "_")
        elseif
          result
          and result.stopReason
          and result.stopReason ~= "end_turn"
          and result.stopReason ~= "cancelled"
        then
          self.history:add_agent_chunk("agent", "\n_stopped: " .. tostring(result.stopReason) .. "_")
        end
        if err and util.is_transport_disconnected(err) then
          self.client = nil
          self.session_id = nil
        end
        self:_set_activity(nil)
        self.widget:render()
        self.in_flight = false
        self.response_started = false
        self.cancel_requested = false
        self:_notify_or_continue()
      end)
    end)
  end)
end

function M:_notify_or_continue()
  local next_prompt = table.remove(self.queued_prompts, 1)
  if next_prompt then
    self:_submit_prompt(next_prompt.text, next_prompt.id)
    return
  end
  util.notify_user("ZeroChatTurnEnd")
end

function M:cancel()
  if self.client and self.session_id and self.in_flight then
    self.cancel_requested = true
    self:_set_turn_activity("waiting", "Cancelling")
    self.client:cancel(self.session_id)
  end
end

---@return string|nil
function M:_session_cwd()
  return self.repo_root
end

return M
