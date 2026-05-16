--- LRU cache for completion results with prefix-match shifting.
--- When the user types a character that matches the start of a cached completion,
--- the completion is shifted by one character and reused without a server round-trip.

local M = {}

---@class zxz.complete.CacheEntry
---@field key string
---@field completion string
---@field timestamp number

---@type zxz.complete.CacheEntry[]
local _entries = {}
local _max_entries = 100

--- Initialize the cache with a max size.
---@param max_entries integer
function M.init(max_entries)
  _max_entries = max_entries or 100
  _entries = {}
end

--- Append a single JSONL line to the telemetry file (if enabled).
---@param outcome "accept"|"dismiss"
---@param key string
function M.log_outcome(outcome, key)
  local ok, config = pcall(require, "zxz.core.config")
  if
    not ok
    or not config.current.complete
    or not config.current.complete.telemetry
    or not config.current.complete.telemetry.enabled
  then
    return
  end
  local path = config.current.complete.telemetry.path
  if not path or path == "" then
    local paths = require("zxz.core.paths")
    path = paths.complete_dir() .. "/telemetry.jsonl"
  end
  local dir = vim.fn.fnamemodify(path, ":h")
  if vim.fn.isdirectory(dir) == 0 then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local fd = io.open(path, "a")
  if not fd then
    return
  end
  local key_digest = key
  if #key_digest > 80 then
    key_digest = key_digest:sub(1, 80) .. "..."
  end
  fd:write(vim.json.encode({
    at = os.time(),
    outcome = outcome,
    key_digest = key_digest,
  }) .. "\n")
  fd:close()
end

--- Generate a cache key from context.
---@param prefix string
---@param suffix string
---@param language string
---@return string
function M.make_key(prefix, suffix, language)
  -- Use last 200 chars of prefix + first 200 chars of suffix + language
  local p = prefix:sub(-200)
  local s = suffix:sub(1, 200)
  return p .. "\0" .. s .. "\0" .. language
end

--- Get a cached completion.
---@param key string
---@return string?
function M.get(key)
  for _, entry in ipairs(_entries) do
    if entry.key == key then
      entry.timestamp = vim.uv.now()
      return entry.completion
    end
  end
  return nil
end

--- Store a completion in the cache.
---@param key string
---@param completion string
function M.set(key, completion)
  -- Check if key already exists
  for i, entry in ipairs(_entries) do
    if entry.key == key then
      entry.completion = completion
      entry.timestamp = vim.uv.now()
      return
    end
  end

  -- Add new entry
  table.insert(_entries, {
    key = key,
    completion = completion,
    timestamp = vim.uv.now(),
  })

  -- Evict oldest if over max
  if #_entries > _max_entries then
    local oldest_idx = 1
    local oldest_time = _entries[1].timestamp
    for i = 2, #_entries do
      if _entries[i].timestamp < oldest_time then
        oldest_idx = i
        oldest_time = _entries[i].timestamp
      end
    end
    table.remove(_entries, oldest_idx)
  end
end

--- Clear all cached entries.
function M.clear()
  _entries = {}
end

return M
