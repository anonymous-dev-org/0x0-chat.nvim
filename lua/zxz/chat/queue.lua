local M = {}

local function chat()
  return require("zxz.chat.chat")
end

local function format_item(item)
  local text = (item.text or ""):gsub("%s+", " ")
  if #text > 80 then
    text = text:sub(1, 77) .. "..."
  end
  return ("%d. %s"):format(item.index, text)
end

function M.open()
  local state = chat().queue_state()
  if state.count == 0 then
    vim.notify("0x0: queue is empty", vim.log.levels.INFO)
    return
  end
  vim.ui.select(state.items, {
    prompt = ("0x0 queue (%d)"):format(state.count),
    format_item = format_item,
  }, function(item)
    if not item then
      return
    end
    M.actions(item.index)
  end)
end

function M.actions(index)
  local actions = {
    {
      label = "Edit queued message",
      run = function()
        local state = chat().queue_state()
        local item = state.items[index]
        if not item then
          vim.notify("0x0: queued message not found", vim.log.levels.ERROR)
          return
        end
        vim.ui.input({ prompt = "queued message: ", default = item.text }, function(value)
          if not value then
            return
          end
          local ok, err = chat().queue_update(index, vim.trim(value))
          if not ok then
            vim.notify("0x0: " .. (err or "queue update failed"), vim.log.levels.ERROR)
          end
        end)
      end,
    },
    {
      label = "Send next now",
      run = function()
        local ok, err = chat().queue_send_next()
        if not ok then
          vim.notify("0x0: " .. (err or "queue send failed"), vim.log.levels.ERROR)
        end
      end,
    },
    {
      label = "Remove queued message",
      run = function()
        local ok, err = chat().queue_remove(index)
        if not ok then
          vim.notify("0x0: " .. (err or "queue remove failed"), vim.log.levels.ERROR)
        end
      end,
    },
    {
      label = "Clear queue",
      run = function()
        chat().queue_clear()
      end,
    },
  }
  vim.ui.select(actions, {
    prompt = "0x0 queue action",
    format_item = function(action)
      return action.label
    end,
  }, function(action)
    if action then
      action.run()
    end
  end)
end

function M.edit(index)
  local state = chat().queue_state()
  if state.count == 0 then
    vim.notify("0x0: queue is empty", vim.log.levels.INFO)
    return
  end
  local item = state.items[index or 1]
  if not item then
    vim.notify("0x0: queued message not found", vim.log.levels.ERROR)
    return
  end
  vim.ui.input({ prompt = "queued message: ", default = item.text }, function(value)
    if not value then
      return
    end
    local ok, err = chat().queue_update(index or 1, vim.trim(value))
    if not ok then
      vim.notify("0x0: " .. (err or "queue update failed"), vim.log.levels.ERROR)
    end
  end)
end

function M.edit_first()
  M.edit(1)
end

function M.remove_first()
  local ok, err = chat().queue_remove(1)
  if not ok then
    vim.notify("0x0: " .. (err or "queue remove failed"), vim.log.levels.ERROR)
  end
end

function M.clear()
  chat().queue_clear()
end

function M.send_next()
  local ok, err = chat().queue_send_next()
  if not ok then
    vim.notify("0x0: " .. (err or "queue send failed"), vim.log.levels.ERROR)
  end
end

return M
