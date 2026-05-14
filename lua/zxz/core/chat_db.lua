local log = require("zxz.core.log")
local paths = require("zxz.core.paths")
local events = require("zxz.core.events")

local M = {}

local initialized_path = nil

local function now()
  return os.time()
end

local function ensure_parent_dir()
  local dir = paths.state_dir()
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

local function sqlite_available()
  return vim.fn.executable("sqlite3") == 1
end

local function db_path()
  ensure_parent_dir()
  return paths.chat_db_path()
end

local function exec(sql, opts)
  opts = opts or {}
  if not sqlite_available() then
    local msg = "sqlite3 executable not found; 0x0 chat storage requires sqlite3"
    log.error("chat_db: " .. msg)
    return nil, msg
  end
  local cmd = { "sqlite3" }
  if opts.json then
    cmd[#cmd + 1] = "-json"
  end
  cmd[#cmd + 1] = db_path()
  local out = vim.fn.system(cmd, sql)
  if vim.v.shell_error ~= 0 then
    local msg = tostring(out)
    log.error("chat_db: sqlite failed: " .. msg)
    return nil, msg
  end
  return out
end

local function sql_quote(value)
  if value == nil then
    return "NULL"
  end
  return "'" .. tostring(value):gsub("'", "''") .. "'"
end

local function json_encode(value)
  if value == nil then
    return nil
  end
  local ok, encoded = pcall(vim.json.encode, value)
  if not ok then
    log.error("chat_db: json encode failed: " .. tostring(encoded))
    return nil
  end
  return encoded
end

local function json_decode(value, fallback)
  if value == nil or value == "" then
    return fallback
  end
  local ok, decoded = pcall(vim.json.decode, value)
  if not ok then
    log.error("chat_db: json decode failed: " .. tostring(decoded))
    return fallback
  end
  return decoded
end

local function select_json(sql)
  local out, err = exec(sql, { json = true })
  if not out then
    return nil, err
  end
  if out == "" then
    return {}
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    log.error("chat_db: sqlite json decode failed: " .. tostring(decoded))
    return nil, tostring(decoded)
  end
  return decoded or {}
end

local function init()
  local path = db_path()
  if initialized_path == path then
    return true
  end
  local sql = [[
PRAGMA journal_mode = WAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS chats (
  id TEXT PRIMARY KEY,
  title TEXT,
  status TEXT NOT NULL DEFAULT 'needs_input',
  root TEXT,
  provider TEXT,
  model TEXT,
  mode TEXT,
  settings_json TEXT,
  run_ids_json TEXT,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS messages (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  seq INTEGER NOT NULL,
  type TEXT NOT NULL,
  status TEXT,
  text TEXT,
  data_json TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL,
  FOREIGN KEY(chat_id) REFERENCES chats(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_messages_chat_seq ON messages(chat_id, seq);
CREATE INDEX IF NOT EXISTS idx_chats_status_updated ON chats(status, updated_at);

CREATE TABLE IF NOT EXISTS runs (
  id TEXT PRIMARY KEY,
  chat_id TEXT,
  status TEXT NOT NULL,
  prompt_summary TEXT,
  root TEXT,
  started_at INTEGER NOT NULL,
  ended_at INTEGER,
  data_json TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_runs_chat_started ON runs(chat_id, started_at);
CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at);

CREATE TABLE IF NOT EXISTS queue_items (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  message_id TEXT,
  seq INTEGER NOT NULL,
  text TEXT NOT NULL,
  context_json TEXT,
  trim_json TEXT,
  status TEXT NOT NULL,
  created_at INTEGER NOT NULL,
  updated_at INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_queue_items_chat_status_seq ON queue_items(chat_id, status, seq);

CREATE TABLE IF NOT EXISTS permissions (
  id TEXT PRIMARY KEY,
  chat_id TEXT NOT NULL,
  run_id TEXT,
  tool_call_id TEXT,
  status TEXT NOT NULL,
  request_json TEXT,
  options_json TEXT,
  decision TEXT,
  created_at INTEGER NOT NULL,
  decided_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_permissions_chat_status ON permissions(chat_id, status, created_at);

CREATE TABLE IF NOT EXISTS tool_calls (
  id TEXT PRIMARY KEY,
  run_id TEXT,
  chat_id TEXT NOT NULL,
  status TEXT,
  kind TEXT,
  title TEXT,
  raw_json TEXT,
  content_json TEXT,
  locations_json TEXT,
  started_at INTEGER,
  ended_at INTEGER
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_run ON tool_calls(run_id, started_at);
CREATE INDEX IF NOT EXISTS idx_tool_calls_chat ON tool_calls(chat_id, started_at);
]]
  local ok, err = exec(sql)
  if ok then
    initialized_path = path
  end
  return ok ~= nil, err
end

local function emit_chat(chat_id)
  events.emit("zxz_chat_updated", chat_id)
end

local function chat_status(entry)
  return entry.status or "needs_input"
end

local function chat_title(entry)
  return entry.title or "untitled"
end

local function insert_message_sql(chat_id, seq, msg)
  local msg_id = ("%s:%s"):format(chat_id, msg.id or seq)
  local encoded = json_encode(msg) or "{}"
  local t = now()
  return table.concat({
    "INSERT INTO messages(id, chat_id, seq, type, status, text, data_json, created_at, updated_at) VALUES(",
    sql_quote(msg_id),
    ",",
    sql_quote(chat_id),
    ",",
    tostring(seq),
    ",",
    sql_quote(msg.type or "message"),
    ",",
    sql_quote(msg.status),
    ",",
    sql_quote(msg.text),
    ",",
    sql_quote(encoded),
    ",",
    tostring(t),
    ",",
    tostring(t),
    ");",
  })
end

---@param entry table
function M.save_chat(entry)
  if not entry or not entry.id or not entry.messages then
    return
  end
  if not init() then
    return
  end
  if #entry.messages == 0 then
    return
  end
  local t = now()
  local created_at = tonumber(entry.created_at) or t
  local settings = entry.settings or {}
  local sql = {
    "BEGIN IMMEDIATE;",
    table.concat({
      "INSERT INTO chats(id, title, status, root, provider, model, mode, settings_json, run_ids_json, created_at, updated_at) VALUES(",
      sql_quote(entry.id),
      ",",
      sql_quote(chat_title(entry)),
      ",",
      sql_quote(chat_status(entry)),
      ",",
      sql_quote(entry.root),
      ",",
      sql_quote(settings.provider),
      ",",
      sql_quote(settings.model),
      ",",
      sql_quote(settings.mode),
      ",",
      sql_quote(json_encode(settings)),
      ",",
      sql_quote(json_encode(entry.run_ids or {})),
      ",",
      tostring(created_at),
      ",",
      tostring(t),
      ") ON CONFLICT(id) DO UPDATE SET ",
      "title=excluded.title, status=excluded.status, root=excluded.root, provider=excluded.provider, ",
      "model=excluded.model, mode=excluded.mode, settings_json=excluded.settings_json, ",
      "run_ids_json=excluded.run_ids_json, updated_at=excluded.updated_at;",
    }),
    "DELETE FROM messages WHERE chat_id = " .. sql_quote(entry.id) .. ";",
  }
  for seq, msg in ipairs(entry.messages or {}) do
    sql[#sql + 1] = insert_message_sql(entry.id, seq, msg)
  end
  sql[#sql + 1] = "COMMIT;"
  local ok = exec(table.concat(sql, "\n"))
  if ok then
    emit_chat(entry.id)
  end
end

---@param id string
---@return table|nil
function M.load_chat(id)
  if not init() then
    return nil
  end
  local chats = select_json("SELECT * FROM chats WHERE id = " .. sql_quote(id) .. " LIMIT 1;")
  if not chats or not chats[1] then
    return nil
  end
  local rows = select_json("SELECT data_json FROM messages WHERE chat_id = " .. sql_quote(id) .. " ORDER BY seq ASC;")
    or {}
  local messages = {}
  for _, row in ipairs(rows) do
    messages[#messages + 1] = json_decode(row.data_json, {})
  end
  local chat = chats[1]
  return {
    id = chat.id,
    title = chat.title or "untitled",
    status = chat.status,
    created_at = tonumber(chat.created_at) or 0,
    updated_at = tonumber(chat.updated_at) or 0,
    messages = messages,
    run_ids = json_decode(chat.run_ids_json, {}),
    settings = json_decode(chat.settings_json, {}),
  }
end

---@return table[]
function M.list_chats()
  if not init() then
    return {}
  end
  local rows = select_json([[
SELECT
  chats.id,
  chats.title,
  chats.status,
  chats.provider,
  chats.model,
  chats.mode,
  chats.updated_at,
  chats.created_at,
  count(messages.id) AS message_count
FROM chats
LEFT JOIN messages ON messages.chat_id = chats.id
GROUP BY chats.id
ORDER BY chats.updated_at DESC;
]]) or {}
  for _, row in ipairs(rows) do
    row.message_count = tonumber(row.message_count) or 0
    row.created_at = tonumber(row.created_at) or 0
    row.updated_at = tonumber(row.updated_at) or 0
  end
  return rows
end

---@param id string
function M.delete_chat(id)
  if not init() then
    return
  end
  if exec("DELETE FROM chats WHERE id = " .. sql_quote(id) .. ";") then
    emit_chat(id)
  end
end

---@param run table
function M.save_run(run)
  if not run or not run.run_id then
    return
  end
  if not init() then
    return
  end
  local encoded = json_encode(run)
  if not encoded then
    return
  end
  local sql = table.concat({
    "INSERT INTO runs(id, chat_id, status, prompt_summary, root, started_at, ended_at, data_json) VALUES(",
    sql_quote(run.run_id),
    ",",
    sql_quote(run.thread_id),
    ",",
    sql_quote(run.status or "running"),
    ",",
    sql_quote(run.prompt_summary),
    ",",
    sql_quote(run.root),
    ",",
    tostring(tonumber(run.started_at) or now()),
    ",",
    run.ended_at and tostring(tonumber(run.ended_at) or now()) or "NULL",
    ",",
    sql_quote(encoded),
    ") ON CONFLICT(id) DO UPDATE SET ",
    "chat_id=excluded.chat_id, status=excluded.status, prompt_summary=excluded.prompt_summary, ",
    "root=excluded.root, started_at=excluded.started_at, ended_at=excluded.ended_at, data_json=excluded.data_json;",
  })
  if exec(sql) and run.thread_id then
    emit_chat(run.thread_id)
  end
end

---@param run_id string
---@return table|nil
function M.load_run(run_id)
  if not init() then
    return nil
  end
  local rows = select_json("SELECT data_json FROM runs WHERE id = " .. sql_quote(run_id) .. " LIMIT 1;")
  if not rows or not rows[1] then
    return nil
  end
  return json_decode(rows[1].data_json, nil)
end

---@return table[]
function M.list_runs()
  if not init() then
    return {}
  end
  local rows = select_json("SELECT data_json FROM runs ORDER BY started_at DESC;") or {}
  local out = {}
  for _, row in ipairs(rows) do
    local run = json_decode(row.data_json, nil)
    if run then
      out[#out + 1] = run
    end
  end
  return out
end

---@param chat_id string
---@return table[]
function M.list_runs_for_chat(chat_id)
  if not init() then
    return {}
  end
  local rows = select_json(
    "SELECT data_json FROM runs WHERE chat_id = " .. sql_quote(chat_id) .. " ORDER BY started_at DESC;"
  ) or {}
  local out = {}
  for _, row in ipairs(rows) do
    local run = json_decode(row.data_json, nil)
    if run then
      out[#out + 1] = run
    end
  end
  return out
end

---@param run_id string
function M.delete_run(run_id)
  if not init() then
    return
  end
  exec("DELETE FROM runs WHERE id = " .. sql_quote(run_id) .. ";")
end

---@param item table
function M.save_queue_item(item)
  if not item or not item.id or not item.chat_id then
    return
  end
  if not init() then
    return
  end
  local t = now()
  local sql = table.concat({
    "INSERT INTO queue_items(id, chat_id, message_id, seq, text, context_json, trim_json, status, created_at, updated_at) VALUES(",
    sql_quote(item.id),
    ",",
    sql_quote(item.chat_id),
    ",",
    sql_quote(item.message_id),
    ",",
    tostring(tonumber(item.seq) or 0),
    ",",
    sql_quote(item.text or ""),
    ",",
    sql_quote(json_encode(item.context_records or item.context_json or {})),
    ",",
    sql_quote(json_encode(item.trim or item.trim_json or {})),
    ",",
    sql_quote(item.status or "queued"),
    ",",
    tostring(tonumber(item.created_at) or t),
    ",",
    tostring(t),
    ") ON CONFLICT(id) DO UPDATE SET ",
    "message_id=excluded.message_id, seq=excluded.seq, text=excluded.text, ",
    "context_json=excluded.context_json, trim_json=excluded.trim_json, ",
    "status=excluded.status, updated_at=excluded.updated_at;",
  })
  if exec(sql) then
    emit_chat(item.chat_id)
  end
end

---@param chat_id string
---@param status? string
---@return table[]
function M.list_queue_items(chat_id, status)
  if not init() then
    return {}
  end
  local where = "chat_id = " .. sql_quote(chat_id)
  if status then
    where = where .. " AND status = " .. sql_quote(status)
  end
  local rows = select_json("SELECT * FROM queue_items WHERE " .. where .. " ORDER BY seq ASC, created_at ASC;") or {}
  for _, row in ipairs(rows) do
    row.seq = tonumber(row.seq) or 0
    row.created_at = tonumber(row.created_at) or 0
    row.updated_at = tonumber(row.updated_at) or 0
    row.context_records = json_decode(row.context_json, {})
    row.trim = json_decode(row.trim_json, {})
  end
  return rows
end

---@param id string
function M.delete_queue_item(id)
  if not init() then
    return
  end
  local existing = select_json("SELECT chat_id FROM queue_items WHERE id = " .. sql_quote(id) .. " LIMIT 1;")
  local chat_id = existing and existing[1] and existing[1].chat_id
  if exec("DELETE FROM queue_items WHERE id = " .. sql_quote(id) .. ";") and chat_id then
    emit_chat(chat_id)
  end
end

---@param item table
function M.save_permission(item)
  if not item or not item.id or not item.chat_id then
    return
  end
  if not init() then
    return
  end
  local t = now()
  local sql = table.concat({
    "INSERT INTO permissions(id, chat_id, run_id, tool_call_id, status, request_json, options_json, decision, created_at, decided_at) VALUES(",
    sql_quote(item.id),
    ",",
    sql_quote(item.chat_id),
    ",",
    sql_quote(item.run_id),
    ",",
    sql_quote(item.tool_call_id),
    ",",
    sql_quote(item.status or "pending"),
    ",",
    sql_quote(json_encode(item.request or {})),
    ",",
    sql_quote(json_encode(item.options or {})),
    ",",
    sql_quote(item.decision),
    ",",
    tostring(tonumber(item.created_at) or t),
    ",",
    item.decided_at and tostring(tonumber(item.decided_at) or t) or "NULL",
    ") ON CONFLICT(id) DO UPDATE SET ",
    "status=excluded.status, request_json=excluded.request_json, options_json=excluded.options_json, ",
    "decision=excluded.decision, decided_at=excluded.decided_at;",
  })
  if exec(sql) then
    emit_chat(item.chat_id)
  end
end

---@param id string
---@param decision string
function M.resolve_permission(id, decision)
  if not init() then
    return
  end
  local existing = select_json("SELECT chat_id FROM permissions WHERE id = " .. sql_quote(id) .. " LIMIT 1;")
  local chat_id = existing and existing[1] and existing[1].chat_id
  local sql = table.concat({
    "UPDATE permissions SET status = 'decided', decision = ",
    sql_quote(decision),
    ", decided_at = ",
    tostring(now()),
    " WHERE id = ",
    sql_quote(id),
    ";",
  })
  if exec(sql) and chat_id then
    emit_chat(chat_id)
  end
end

---@param chat_id string
---@param status? string
---@return table[]
function M.list_permissions(chat_id, status)
  if not init() then
    return {}
  end
  local where = "chat_id = " .. sql_quote(chat_id)
  if status then
    where = where .. " AND status = " .. sql_quote(status)
  end
  local rows = select_json("SELECT * FROM permissions WHERE " .. where .. " ORDER BY created_at ASC;") or {}
  for _, row in ipairs(rows) do
    row.created_at = tonumber(row.created_at) or 0
    row.decided_at = tonumber(row.decided_at)
    row.request = json_decode(row.request_json, {})
    row.options = json_decode(row.options_json, {})
  end
  return rows
end

---@param item table
function M.save_tool_call(item)
  if not item or not item.id or not item.chat_id then
    return
  end
  if not init() then
    return
  end
  local sql = table.concat({
    "INSERT INTO tool_calls(id, run_id, chat_id, status, kind, title, raw_json, content_json, locations_json, started_at, ended_at) VALUES(",
    sql_quote(item.id),
    ",",
    sql_quote(item.run_id),
    ",",
    sql_quote(item.chat_id),
    ",",
    sql_quote(item.status),
    ",",
    sql_quote(item.kind),
    ",",
    sql_quote(item.title),
    ",",
    sql_quote(json_encode(item.raw_input or item.raw or {})),
    ",",
    sql_quote(json_encode(item.content or {})),
    ",",
    sql_quote(json_encode(item.locations or {})),
    ",",
    item.started_at and tostring(tonumber(item.started_at) or now()) or "NULL",
    ",",
    item.ended_at and tostring(tonumber(item.ended_at) or now()) or "NULL",
    ") ON CONFLICT(id) DO UPDATE SET ",
    "run_id=excluded.run_id, status=excluded.status, kind=excluded.kind, title=excluded.title, ",
    "raw_json=excluded.raw_json, content_json=excluded.content_json, ",
    "locations_json=excluded.locations_json, started_at=excluded.started_at, ended_at=excluded.ended_at;",
  })
  if exec(sql) then
    emit_chat(item.chat_id)
  end
end

---@param run_id string
---@return table[]
function M.list_tool_calls_for_run(run_id)
  if not init() then
    return {}
  end
  local rows = select_json(
    "SELECT * FROM tool_calls WHERE run_id = " .. sql_quote(run_id) .. " ORDER BY started_at ASC;"
  ) or {}
  for _, row in ipairs(rows) do
    row.started_at = tonumber(row.started_at)
    row.ended_at = tonumber(row.ended_at)
    row.raw_input = json_decode(row.raw_json, {})
    row.content = json_decode(row.content_json, {})
    row.locations = json_decode(row.locations_json, {})
  end
  return rows
end

function M.new_id(prefix)
  prefix = prefix or "chat"
  return ("%s-%d-%d"):format(prefix, now(), math.random(1, 1e9))
end

function M._reset_for_tests(path)
  initialized_path = nil
  if path and path ~= "" then
    pcall(vim.fn.delete, path)
  end
end

return M
