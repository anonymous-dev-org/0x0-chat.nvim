-- Repo map: treesitter-backed digest of top-level symbols in the
-- repository. Cached per repo root; rebuilt on demand and on a stale
-- timer. Budget-aware per LD3 (default 50 KB).

local Checkpoint = require("zeroxzero.checkpoint")
local Recent = require("zeroxzero.context.recent")

local M = {}

local DEFAULT_BUDGET_BYTES = 50 * 1024
local STALE_AFTER_SECONDS = 10 * 60

---@type table<string, { built_at: integer, map: table, serialized: string }>
local cache = {}

---@type table<string, table<string, string>>
local TOP_LEVEL_NODES = {
  lua = {
    function_declaration = "function",
    local_function = "function",
    method_definition = "method",
    assignment_statement = "assignment",
  },
  typescript = {
    function_declaration = "function",
    class_declaration = "class",
    method_definition = "method",
    export_statement = "export",
    interface_declaration = "interface",
    type_alias_declaration = "type",
  },
  typescriptreact = {
    function_declaration = "function",
    class_declaration = "class",
    method_definition = "method",
    export_statement = "export",
  },
  javascript = {
    function_declaration = "function",
    class_declaration = "class",
    method_definition = "method",
    export_statement = "export",
  },
  python = {
    function_definition = "function",
    class_definition = "class",
  },
  rust = {
    function_item = "function",
    impl_item = "impl",
    struct_item = "struct",
    enum_item = "enum",
    trait_item = "trait",
  },
  go = {
    function_declaration = "function",
    method_declaration = "method",
    type_declaration = "type",
  },
}

local FILETYPE_FROM_EXT = {
  lua = "lua",
  ts = "typescript",
  tsx = "typescriptreact",
  js = "javascript",
  jsx = "javascript",
  py = "python",
  rs = "rust",
  go = "go",
}

---@param path string
---@return string|nil
local function filetype_for(path)
  local ext = path:match("%.([^.]+)$")
  if not ext then
    return nil
  end
  return FILETYPE_FROM_EXT[ext:lower()]
end

---@param node TSNode
---@param source string
---@return string|nil
local function identifier_name(node, source)
  for child in node:iter_children() do
    local t = child:type()
    if t == "identifier" or t == "name" or t == "property_identifier" or t == "type_identifier" then
      return vim.treesitter.get_node_text(child, source)
    end
  end
  return nil
end

---@param path string
---@param node_kinds table<string, string>
---@return { kinds: table<string, integer>, names: string[] }|nil
local function symbols_in_file(path, node_kinds)
  local fd = io.open(path, "rb")
  if not fd then
    return nil
  end
  local source = fd:read("*a")
  fd:close()
  if not source or source == "" then
    return { kinds = {}, names = {} }
  end
  local lang_for_ft
  for ft, _ in pairs(node_kinds) do
    lang_for_ft = ft
    break
  end
  -- node_kinds is keyed by treesitter type, not language; we passed the
  -- right table from caller. Lang derives from filetype upstream.
  local lang = nil
  for k, v in pairs(TOP_LEVEL_NODES) do
    if v == node_kinds then
      lang = k
      break
    end
  end
  if not lang then
    return nil
  end
  local ok_parser, parser = pcall(vim.treesitter.get_string_parser, source, lang)
  if not ok_parser or not parser then
    return nil
  end
  local trees = parser:parse()
  if not trees or not trees[1] then
    return nil
  end
  local root = trees[1]:root()
  local kinds = {}
  local names = {}
  for child in root:iter_children() do
    local t = child:type()
    local kind = node_kinds[t]
    if kind then
      kinds[kind] = (kinds[kind] or 0) + 1
      if #names < 5 then
        local n = identifier_name(child, source)
        if n then
          names[#names + 1] = n
        end
      end
    end
  end
  return { kinds = kinds, names = names }
end

---@param root string
---@return string[]
local function list_repo_files(root)
  local out = {}
  local result
  if vim.fn.executable("rg") == 1 then
    result = vim.fn.systemlist({
      "rg",
      "--files",
      "--hidden",
      "-g",
      "!**/.git/**",
      root,
    })
  elseif vim.fn.executable("git") == 1 then
    result = vim.fn.systemlist({ "git", "-C", root, "ls-files" })
  else
    result = vim.fn.systemlist({ "find", root, "-type", "f", "-not", "-path", "*/.git/*" })
  end
  if vim.v.shell_error ~= 0 or not result then
    return out
  end
  for _, line in ipairs(result) do
    if line ~= "" then
      -- Normalize to repo-relative.
      if line:sub(1, #root + 1) == root .. "/" then
        line = line:sub(#root + 2)
      end
      out[#out + 1] = line
    end
  end
  return out
end

---@param path string
---@param recent_set table<string, boolean>
---@return integer
local function score(path, recent_set)
  local s = 0
  if recent_set[path] then
    s = s + 30
  end
  if path:match("^src/") or path:match("^lib/") or path:match("^app/") or path:match("^apps/") then
    s = s + 10
  end
  if path:match("test") or path:match("spec") then
    s = s + 5
  end
  return s
end

---@param map table
---@return string
local function serialize(map)
  local lines = { ("# Repo map (root: %s, %d files)"):format(map.root, #map.entries) }
  for _, e in ipairs(map.entries) do
    local parts = { e.path }
    if next(e.kinds) ~= nil then
      local kparts = {}
      for k, n in pairs(e.kinds) do
        kparts[#kparts + 1] = ("%s:%d"):format(k, n)
      end
      table.sort(kparts)
      parts[#parts + 1] = "[" .. table.concat(kparts, ",") .. "]"
    end
    if e.names and #e.names > 0 then
      parts[#parts + 1] = table.concat(e.names, ",")
    end
    lines[#lines + 1] = table.concat(parts, "  ")
  end
  if map.truncated then
    lines[#lines + 1] = ("(repo map truncated — %d of %d files included)"):format(#map.entries, map.total_candidates)
  end
  return table.concat(lines, "\n")
end

---@param root string
---@param budget integer
---@return table map { root, entries[], truncated, total_candidates }
local function build(root, budget)
  local files = list_repo_files(root)
  local recent_set = {}
  for _, p in ipairs(Recent.list(10)) do
    recent_set[p] = true
  end
  -- Score, then sort.
  local scored = {}
  for _, path in ipairs(files) do
    if not Checkpoint.is_ignored(root, path) then
      scored[#scored + 1] = { path = path, score = score(path, recent_set) }
    end
  end
  table.sort(scored, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return a.path < b.path
  end)

  local entries = {}
  local total = #scored
  local soft_budget = math.floor(budget * 0.9)
  local running = 0
  local truncated = false
  for _, item in ipairs(scored) do
    local path = item.path
    local ft = filetype_for(path)
    local sym = nil
    if ft and TOP_LEVEL_NODES[ft] then
      sym = symbols_in_file(root .. "/" .. path, TOP_LEVEL_NODES[ft])
    end
    local entry = {
      path = path,
      kinds = (sym and sym.kinds) or {},
      names = (sym and sym.names) or {},
    }
    -- Cheap size estimate: serialize this one entry, count bytes.
    local entry_size = #path + 1
    for k, n in pairs(entry.kinds) do
      entry_size = entry_size + #k + 4
    end
    for _, n in ipairs(entry.names) do
      entry_size = entry_size + #n + 1
    end
    if running + entry_size > soft_budget then
      truncated = true
      break
    end
    running = running + entry_size
    entries[#entries + 1] = entry
  end

  return { root = root, entries = entries, truncated = truncated, total_candidates = total }
end

---@type table<string, boolean>
local building = {}

local function schedule_rebuild(root)
  if building[root] then
    return
  end
  building[root] = true
  vim.defer_fn(function()
    local ok, err = pcall(function()
      local config = require("zeroxzero.config").current
      local budget = (config.repo_map and config.repo_map.budget_bytes) or DEFAULT_BUDGET_BYTES
      local map = build(root, budget)
      cache[root] = { built_at = os.time(), map = map, serialized = serialize(map) }
    end)
    if not ok then
      require("zeroxzero.log").warn("repo_map: deferred rebuild failed: " .. tostring(err))
    end
    building[root] = nil
  end, 50)
end

---Non-blocking serialization. On cache miss or stale, returns the
---previous serialization (or a placeholder) and schedules a deferred
---rebuild so the next caller picks up fresh content. (T2.2)
---@param root string
---@return string
function M.get_serialized(root)
  local entry = cache[root]
  local now = os.time()
  if entry and (now - entry.built_at) < STALE_AFTER_SECONDS then
    return entry.serialized
  end
  schedule_rebuild(root)
  if entry then
    return entry.serialized .. "\n(repo map: rebuilding in background — this is the previous snapshot)"
  end
  return "(repo map: building — try again shortly)"
end

---@param root string|nil
function M.invalidate(root)
  if root then
    cache[root] = nil
  else
    cache = {}
  end
end

---@param cwd string|nil
---@return { type: "text", text: string }
function M.format_block(cwd)
  local root = Checkpoint.git_root(cwd or vim.fn.getcwd()) or (cwd or vim.fn.getcwd())
  local digest = M.get_serialized(root)
  return { type = "text", text = digest }
end

return M
