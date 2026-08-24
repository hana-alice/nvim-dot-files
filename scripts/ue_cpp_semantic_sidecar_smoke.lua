-- Read-only real-workspace smoke for canonical-USR module definition lookup.
-- All workspace-specific paths arrive through UE_CPP_SEMANTIC_SMOKE_INPUT;
-- output contains labels, hashes, basenames, lines, and bounded metrics only.

vim.opt.runtimepath:prepend(vim.fn.stdpath("config"))

local semantic_context = require("utils.ue_goto.semantic_context")
local semantic_sidecar = require("utils.ue_goto.semantic_sidecar")

local function fail(reason)
  io.stderr:write(vim.json.encode({ summary = "FAIL", reason = reason }) .. "\n")
  vim.cmd("cquit 1")
end

local function normalize(path)
  return vim.fs.normalize(tostring(path or "")):gsub("\\", "/"):lower()
end

local function basename(path)
  return vim.fn.fnamemodify(path, ":t")
end

local function read_json(path)
  local lines = vim.fn.readfile(path, "b")
  if not lines or #lines == 0 then return nil end
  local ok, decoded = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok and decoded or nil
end

local function marker_column(case)
  local lines = vim.fn.readfile(case.query_path, "b")
  local line = lines[tonumber(case.line)]
  if not line then return nil end
  local start = 1
  local occurrence = math.max(1, tonumber(case.occurrence or 1) or 1)
  local found
  for _ = 1, occurrence do
    found = line:find(case.symbol, start, true)
    if not found then return nil end
    start = found + #case.symbol
  end
  return found
end

local function short_hash(value)
  return vim.fn.sha256(tostring(value or "")):sub(1, 16)
end

local raw = vim.env.UE_CPP_SEMANTIC_SMOKE_INPUT
if not raw or raw == "" then fail("input-missing") end
local ok_spec, spec = pcall(vim.json.decode, raw)
if not ok_spec or type(spec) ~= "table" then fail("input-invalid-json") end
if type(spec.cases) ~= "table" or #spec.cases == 0 then fail("cases-missing") end
if type(spec.controlled_cdb_paths) ~= "table" or #spec.controlled_cdb_paths == 0 then
  fail("controlled-cdb-paths-missing")
end

local entries = read_json(spec.active_cdb_path)
local database = entries and semantic_context.load_compilation_database(entries) or nil
if not database then fail("active-cdb-unreadable") end

local sidecar_opts = {
  max_tus = 1,
  idle_evict_ms = 600000,
}
if type(spec.clangd_path) == "string" and spec.clangd_path ~= "" then
  sidecar_opts.toolchain = { clangd_candidates = { spec.clangd_path } }
end
local sidecar = semantic_sidecar.new(sidecar_opts)
if not sidecar.toolchain.ok then fail("toolchain-unavailable") end

local results = {}
local identities = {}
local groups = {}

local ok_run, run_err = xpcall(function()
  -- Resolve every exact-position identity first. Cases are ordered by origin
  -- TU so the default one-TU LRU remains bounded while adjacent queries reuse.
  for _, case in ipairs(spec.cases) do
    local compile = database.by_file[semantic_context.match_key(case.origin_tu)]
    if not compile then error(case.name .. ":compile-command-missing") end
    local column = marker_column(case)
    if not column then error(case.name .. ":query-marker-missing") end
    local query = sidecar:handle_request({
      v = 1,
      id = "query-" .. case.name,
      op = "query",
      query = {
        path = case.query_path,
        line = tonumber(case.line),
        column = column,
        document_version = 1,
      },
      contexts = {
        {
          id = "origin-" .. short_hash(case.origin_tu),
          origin_tu = case.origin_tu,
          cdb_dir = vim.fs.dirname(spec.active_cdb_path),
          compile = compile,
        },
      },
      overlays = {},
    })
    if query.state ~= "resolved" or type(query.usr) ~= "string" or query.usr == "" then
      error(case.name .. ":query:" .. tostring(query.reason or query.state))
    end
    identities[case.name] = query.usr
    local group = tostring(case.usr_group or case.name)
    if groups[group] and groups[group] ~= query.usr then
      error(case.name .. ":usr-group-conflict")
    end
    groups[group] = query.usr
    results[case.name] = {
      name = case.name,
      usr_hash = short_hash(query.usr),
      entity_kind = query.entity_kind,
      query_ms = query.metrics and query.metrics.cursor_query_ms or nil,
    }
  end

  local group_names = vim.tbl_keys(groups)
  table.sort(group_names)
  for left = 1, #group_names do
    for right = left + 1, #group_names do
      if groups[group_names[left]] == groups[group_names[right]] then
        error("usr-groups-not-distinct")
      end
    end
  end

  -- Destination lookup traverses the controlled module contexts. Repeated
  -- canonical USRs reuse the unique resolved destination across call sites.
  for _, case in ipairs(spec.cases) do
    local request = {
      v = 1,
      id = "lookup-" .. case.name,
      op = "lookup-definition",
      usr = identities[case.name],
      subject = case.query_path,
      cdb_paths = spec.controlled_cdb_paths,
      overlays = {},
      document_version = 1,
    }
    local first = sidecar:handle_request(request)
    if first.state ~= "resolved" or not first.definition then
      error(case.name .. ":lookup:" .. tostring(first.reason or first.state))
    end
    if normalize(first.definition.path) ~= normalize(case.expected_definition_path)
        or tonumber(first.definition.line) ~= tonumber(case.expected_definition_line) then
      error(case.name .. ":destination-mismatch")
    end

    request.id = "lookup-warm-" .. case.name
    local warm = sidecar:handle_request(request)
    if warm.state ~= "resolved" or not (warm.metrics and warm.metrics.cache_hit) then
      error(case.name .. ":warm-cache-miss")
    end
    if normalize(warm.definition.path) ~= normalize(first.definition.path)
        or tonumber(warm.definition.line) ~= tonumber(first.definition.line) then
      error(case.name .. ":warm-destination-mismatch")
    end

    local result = results[case.name]
    result.state = "resolved"
    result.target = basename(first.definition.path) .. ":" .. tostring(first.definition.line)
    result.lookup_ms = first.metrics and first.metrics.total_ms or nil
    result.cold_parse_ms = first.metrics and first.metrics.cold_parse_ms or nil
    result.shim_abi = first.metrics and first.metrics.shim_abi_version or nil
    result.tu_count = first.metrics and first.metrics.tu_count or nil
    result.rss_mib = first.metrics and first.metrics.process_rss_bytes
      and math.floor(first.metrics.process_rss_bytes / 1048576 + 0.5) or nil
    result.warm_cache_hit = true
  end
end, function(err)
  return tostring(err):match("([^\r\n]+)") or "smoke-failed"
end)

sidecar:shutdown()
if not ok_run then fail(run_err:gsub("^.-:%d+: ", "")) end

for _, case in ipairs(spec.cases) do
  io.stdout:write(vim.json.encode(results[case.name]) .. "\n")
end
io.stdout:write(vim.json.encode({ summary = "PASS", cases = #spec.cases }) .. "\n")
