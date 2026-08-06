-- Read-only real-workspace smoke for the contextual C++ semantic sidecar.
--
-- Input is intentionally external so this repository never stores a project
-- name or workspace path:
--   UE_CPP_SEMANTIC_SMOKE_SPEC={"cdb_dir":"...","cases":[...]}
-- Each case contains label, origin_tu, path, line, column, expected_path,
-- expected_line and optional usr_group. The script never writes target files.

local cfg = vim.fn.stdpath("config")
vim.opt.rtp:prepend(cfg)
package.path = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;" .. package.path

local protocol = require("utils.ue_goto.semantic_protocol")
local sidecar_mod = require("utils.ue_goto.semantic_sidecar")

local raw = vim.env.UE_CPP_SEMANTIC_SMOKE_SPEC or ""
assert(raw ~= "", "UE_CPP_SEMANTIC_SMOKE_SPEC is required")
local spec = vim.json.decode(raw)
assert(type(spec) == "table" and type(spec.cdb_dir) == "string", "cdb_dir is required")
assert(type(spec.cases) == "table" and #spec.cases > 0, "at least one case is required")
if type(spec.clangd_path) == "string" and spec.clangd_path ~= "" then
  vim.env.UE_CLANGD = spec.clangd_path
end

local sidecar = sidecar_mod.new({ max_tus = tonumber(spec.max_tus) or 3 })
local handshake = sidecar:handle_request({ v = protocol.VERSION, id = "hello", op = "handshake" })
assert(handshake.ok, "semantic toolchain unavailable: " .. tostring(handshake.reason))

local function normalize(path)
  return vim.fs.normalize(path):gsub("\\", "/"):lower()
end

local function target_of(response)
  return response.definition or response.declaration
end

local function short_hash(text)
  return vim.fn.sha256(tostring(text or "")):sub(1, 16)
end

local function context_for_case(case)
  if type(spec.evidence_roots) == "table" and #spec.evidence_roots > 0 then
    local catalog = sidecar:handle_request({
      v = protocol.VERSION,
      id = case.label .. "-catalog",
      op = "catalog",
      header = vim.fs.normalize(case.catalog_subject or case.path),
      cdb_dir = vim.fs.normalize(spec.cdb_dir),
      project_root = spec.project_root,
      engine_root = spec.engine_root,
      active_build_key = spec.active_build_key,
      active_build = spec.active_build,
      evidence_roots = spec.evidence_roots,
    })
    local matches = {}
    for _, context in ipairs(catalog.contexts or {}) do
      if not case.origin_contains
          or tostring(context.origin_tu):find(case.origin_contains, 1, true) then
        matches[#matches + 1] = context
      end
    end
    if #matches ~= 1 then
      local available = {}
      for _, context in ipairs(catalog.contexts or {}) do
        available[#available + 1] = vim.fn.fnamemodify(context.origin_tu or "", ":t")
          .. ":" .. tostring(context.evidence_kind or "?")
      end
      error(tostring(case.label) .. " expected one proven context, got " .. tostring(#matches)
        .. "; catalog=" .. tostring(catalog.state)
        .. "; cpp_json=" .. tostring(catalog.metrics and catalog.metrics.cpp_json_scanned)
        .. "; depfiles=" .. tostring(catalog.metrics and catalog.metrics.depfiles_scanned)
        .. "; available=" .. table.concat(available, ","))
    end
    case._catalog_metrics = catalog.metrics or {}
    return matches[1]
  end
  return {
    id = short_hash(vim.json.encode({ case.origin_tu, spec.cdb_dir })),
    origin_tu = vim.fs.normalize(case.origin_tu),
    cdb_dir = vim.fs.normalize(spec.cdb_dir),
  }
end

local function query_case(case, version, overlays)
  case._context = case._context or context_for_case(case)
  local response = sidecar:handle_request({
    v = protocol.VERSION,
    id = case.label .. "-v" .. tostring(version),
    op = "query",
    query = {
      path = vim.fs.normalize(case.path),
      line = assert(tonumber(case.line), "case.line is required"),
      column = assert(tonumber(case.column), "case.column is required"),
      document_version = version,
    },
    contexts = { case._context },
    overlays = overlays,
  })
  if response.state ~= "resolved" then
    local detail = response.contexts and response.contexts[1] or response
    io.stderr:write(vim.json.encode({
      label = case.label,
      state = response.state,
      reason = response.reason,
      context_reason = detail and detail.reason,
      cursor_kind = detail and detail.cursor_kind,
      diagnostics = detail and detail.diagnostics,
    }) .. "\n")
  end
  assert(response.state == "resolved",
    tostring(case.label) .. " state=" .. tostring(response.state)
      .. " reason=" .. tostring(response.reason))
  local target = assert(target_of(response), tostring(case.label) .. " has no semantic target")
  assert(normalize(target.path) == normalize(case.expected_path),
    tostring(case.label) .. " target path mismatch")
  assert(target.line == tonumber(case.expected_line),
    tostring(case.label) .. " target line=" .. tostring(target.line)
      .. " expected=" .. tostring(case.expected_line))
  io.write(vim.json.encode({
    label = case.label,
    state = response.state,
    usr_hash = short_hash(response.usr),
    target = vim.fn.fnamemodify(target.path, ":t") .. ":" .. tostring(target.line),
    query_kind = response.metrics.query_kinds[1].kind,
    cold_parse_ms = response.metrics.cold_parse_ms,
    reparse_ms = response.metrics.reparse_ms,
    warm_query_ms = response.metrics.warm_query_ms,
    tu_count = response.metrics.tu_count,
    process_rss_bytes = response.metrics.process_rss_bytes,
    diagnostics = #(response.diagnostics or {}),
    catalog_ms = tonumber(case._catalog_metrics and case._catalog_metrics.total_ms),
    evidence_discovery = case._catalog_metrics and case._catalog_metrics.evidence_discovery,
    evidence_files_scanned = (tonumber(case._catalog_metrics and case._catalog_metrics.cpp_json_scanned) or 0)
      + (tonumber(case._catalog_metrics and case._catalog_metrics.depfiles_scanned) or 0),
  }) .. "\n")
  return response
end

local responses, groups = {}, {}
for _, case in ipairs(spec.cases) do
  local response = query_case(case, 1)
  responses[case.label] = response
  if case.usr_group then
    local prior = groups[case.usr_group]
    if prior then
      assert(prior == response.usr,
        "USR group mismatch for " .. tostring(case.usr_group))
    else
      groups[case.usr_group] = response.usr
    end
  end
end

local first = spec.cases[1]
local warm = query_case(first, 1)
assert(warm.metrics.query_kinds[1].kind == "warm", "repeat query did not reuse warm TU")
assert(warm.usr == responses[first.label].usr, "warm query changed semantic identity")

if spec.reparse_label then
  local chosen
  for _, case in ipairs(spec.cases) do
    if case.label == spec.reparse_label then chosen = case; break end
  end
  assert(chosen, "reparse_label does not name a case")
  local file = assert(io.open(chosen.path, "rb"))
  local contents = file:read("*a")
  file:close()
  local reparsed = query_case(chosen, 2, {
    { path = vim.fs.normalize(chosen.path), contents = contents .. "\n", version = 2 },
  })
  assert(reparsed.metrics.query_kinds[1].kind == "reparse", "overlay did not trigger reparse")
  assert(reparsed.usr == responses[chosen.label].usr, "identical overlay changed semantic identity")
end

local stats = sidecar:handle_request({ v = protocol.VERSION, id = "stats", op = "stats" })
io.write(vim.json.encode({
  summary = "PASS",
  cases = #spec.cases,
  tu_count = stats.metrics.tu_count,
  process_rss_bytes = stats.metrics.process_rss_bytes,
}) .. "\n")
sidecar:shutdown()
