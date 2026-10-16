-- Headless integration seam: copied input enters the real prepare delivery path.
-- Scanning, GTAGS, csearch, RSP generation, partition and UBT are deliberately
-- outside this fixture. No production caller enables it implicitly.
local M = {}
local fs = require("ue.core.fs")
local uv = vim.uv or vim.loop

local required = { "index_dir", "index_state", "index_queue", "index_cdb_dir",
  "index_current_cdb", "index_hot_cdb", "index_full_cdb", "active_cdb",
  "current_index", "hot_index", "full_index", "semantic_cdb",
  "semantic_current_cdb", "semantic_hot_cdb", "semantic_full_cdb", "runtime_dir" }

-- Resolve existing parents too, so a junction cannot redirect a future output.
local function canonical(path)
  if type(path) ~= "string" or not fs.is_absolute_path(path) or path:find("[%z\r\n]") then return nil end
  local normalized = fs.norm(path)
  local cursor, suffix = normalized, {}
  while not uv.fs_stat(cursor) do
    local parent = vim.fs.dirname(cursor)
    if parent == cursor then return nil end
    table.insert(suffix, 1, vim.fs.basename(cursor)); cursor = parent
  end
  local real = uv.fs_realpath(cursor)
  if not real then return nil end
  for _, part in ipairs(suffix) do real = fs.join(real, part) end
  return require("utils.platform").driver().path_key(fs.norm(real))
end

local function inside(path, root)
  return path and root and path:sub(1, #root + 1) == root .. "/"
end

function M.validate(ctx, private_root, opts)
  if vim.g.ue_prepare_headless ~= 1 or #vim.api.nvim_list_uis() ~= 0 then
    return nil, "prepare fixture requires explicit headless mode"
  end
  if type(ctx) ~= "table" or type(ctx.paths) ~= "table" then return nil, "fixture context is missing" end
  local root = canonical(private_root)
  if not root or not uv.fs_stat(private_root) or uv.fs_stat(private_root).type ~= "directory" then
    return nil, "private fixture root must be an existing absolute directory"
  end
  for _, source in ipairs({ ctx.engine_root or "", ctx.project_root or "" }) do
    local source_root = canonical(source)
    if source_root and (root == source_root or inside(root, source_root)) then
      return nil, "private fixture root overlaps source checkout"
    end
  end
  for _, name in ipairs(required) do
    if not inside(canonical(ctx.paths[name]), root) then return nil, "fixture path escapes private root: " .. name end
  end
  for name, path in pairs(ctx.paths) do
    if name ~= "platform_key" and name ~= "project_key" then
      if not inside(canonical(path), root) then return nil, "fixture path escapes private root: " .. tostring(name) end
    end
  end
  opts = opts or {}
  local limit = opts.input_limit or 30
  if type(limit) ~= "number" or limit < 1 or limit > 256 or limit % 1 ~= 0 then
    return nil, "fixture input limit must be an integer between 1 and 256"
  end
  local file = io.open(ctx.paths.active_cdb, "rb")
  if not file then return nil, "copied fixture CDB is missing" end
  local bytes = file:read("*a"); file:close()
  local ok, entries = pcall(vim.json.decode, bytes)
  if not ok or type(entries) ~= "table" or not vim.islist(entries) or #entries < 1 or #entries > limit then
    return nil, "copied fixture CDB must contain 1.." .. limit .. " entries"
  end
  for _, entry in ipairs(entries) do
    if type(entry) ~= "table" or type(entry.file) ~= "string" or entry.file == "" then
      return nil, "copied fixture CDB contains an invalid entry"
    end
  end
  return { private_root = root, input_count = #entries, input_limit = limit }
end

function M.start(ctx, private_root, opts, deps)
  local fixture, err = M.validate(ctx, private_root, opts)
  if not fixture then return false, err end
  if deps.running() or deps.build_running() then return false, "prepare or UE build is already running" end
  local lease, lease_err = deps.lock.acquire(fs.join(ctx.paths.runtime_dir, "prepare.lock"))
  if not lease then return false, lease_err end
  ctx._headless_index_fixture = fixture
  deps.set_lease(lease)
  deps.set_running(true)
  local ok, failure = xpcall(function() deps.schedule(ctx) end, debug.traceback)
  deps.set_running(false) -- The ordinary setter releases this same prepare lease.
  if not ok then return false, failure end
  return true, fixture
end

return M
