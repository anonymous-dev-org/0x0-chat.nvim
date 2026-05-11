local log = require("zxz.core.log")
local paths = require("zxz.core.paths")

local M = {}

local function dir()
  local d = paths.history_dir()
  if vim.fn.isdirectory(d) == 0 then
    vim.fn.mkdir(d, "p")
  end
  return d
end

local function path_for(id)
  return dir() .. "/" .. id .. ".json"
end

---@return string id
local function new_id()
  return ("%d-%d"):format(os.time(), math.random(1, 1e9))
end

---@param entry { id: string, title?: string, created_at: integer, messages: table[], settings?: table }
function M.save(entry)
  if not entry or not entry.id or not entry.messages then
    return
  end
  if #entry.messages == 0 then
    return
  end
  entry.updated_at = os.time()
  entry.created_at = entry.created_at or entry.updated_at
  entry.title = entry.title or "untitled"
  local ok, encoded = pcall(vim.json.encode, entry)
  if not ok then
    log.error("history_store: encode failed for " .. entry.id .. ": " .. tostring(encoded))
    return
  end
  local p = path_for(entry.id)
  local file, ferr = io.open(p, "w")
  if not file then
    log.error("history_store: open(w) failed for " .. p .. ": " .. tostring(ferr))
    return
  end
  file:write(encoded)
  file:close()
end

---@param id string
---@return table|nil
function M.load(id)
  local p = path_for(id)
  local file = io.open(p, "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    log.error("history_store: decode failed for " .. p .. ": " .. tostring(decoded))
    return nil
  end
  return decoded
end

---@return table[] entries (sorted by updated_at desc, summary fields only)
function M.list()
  local entries = {}
  local files = vim.fn.glob(dir() .. "/*.json", false, true)
  for _, f in ipairs(files) do
    local file = io.open(f, "r")
    if file then
      local content = file:read("*a")
      file:close()
      local ok, decoded = pcall(vim.json.decode, content)
      if ok and decoded and decoded.id then
        entries[#entries + 1] = {
          id = decoded.id,
          title = decoded.title or "untitled",
          updated_at = decoded.updated_at or 0,
          created_at = decoded.created_at or 0,
          message_count = decoded.messages and #decoded.messages or 0,
        }
      end
    end
  end
  table.sort(entries, function(a, b)
    return (a.updated_at or 0) > (b.updated_at or 0)
  end)
  return entries
end

---@param id string
function M.delete(id)
  os.remove(path_for(id))
end

M.new_id = new_id

return M
