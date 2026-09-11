-- Presentation data only: no compiler requests, editor mutation, or lineage writes.
local M = {}
M.OBSERVATIONS = {
  ["cpp-semantic-navigation"] = "semantic-contracts-2026-09-09",
  ["cpp-semantic-performance"] = "semantic-contracts-2026-09-09",
}
local location_mod = require("utils.ue_goto.location")
local transaction = require("utils.ue_goto.semantic_transaction")

function M.terminal_notice(sym, result)
  if not result or result.stage == "stale" then return end
  local status = result.state or "unavailable"
  local reason = result.reason or "unknown"
  local label = ({
    ["already-at-definition"] = "already at definition",
    ["definition-not-found"] = "semantic definition unavailable",
    ["definition-absent-in-complete-index"] = "complete index contains no definition",
    ["identity-conflict"] = "semantic identity conflicted",
    ["identity-missing"] = "semantic identity missing",
    ["index-incomplete"] = "partial index has not covered the definition yet",
    ["index-provider-not-ready"] = "semantic index is not ready",
    ["index-stale-for-module"] = "semantic index is stale for this module",
    ["jump-failed"] = "semantic jump failed",
    ["multiple-definitions"] = "semantic definition was not unique",
    ["provider-error"] = "provider request failed",
    ["provider-method-unsupported"] = "provider method unsupported",
    ["provider-timeout"] = "provider timed out",
    ["semantic-cursor-invalid"] = "compiler could not resolve the exact cursor entity",
    ["semantic-sidecar-unavailable"] = "compiler semantic tooling unavailable",
    ["semantic-tu-unavailable"] = "translation-unit semantic context unavailable",
    ["target-is-current-declaration"] = "declaration has no proven out-of-line definition",
    ["stale-request"] = "semantic request became stale",
  })[reason] or reason

  -- Actionable remedy for the readiness family. A bare "unavailable" leaves the
  -- user with no next step, which is how the original report ended up as "this
  -- can obviously be located, why is it asking me to choose". The controlled
  -- index is delivered BY UEPrepare -- users must not be expected to remember
  -- platform-specific index commands, so the hint points at the habitual flow.
  local remedy = ({
    ["index-provider-not-ready"] =
      "semantic index has not been delivered yet -- if :UEPrepare just finished, the index build may still be running (watch its progress); if it failed, see :NvimLog",
    ["index-stale-for-module"] =
      "semantic index is stale for this module -- re-run :UEPrepare after the build",
    ["index-incomplete"] =
      "index coverage has not reached this definition yet -- wait for the running index build to finish",
    ["active-compile-command-missing"] =
      "no compile command for this file in the active database -- re-run :UEPrepare for the current platform/configuration",
  })[reason]

  return string.format("C++ definition %s%s%s%s",
    tostring(status),
    sym and sym ~= "" and (" for `" .. sym .. "`") or "",
    label ~= "" and (": " .. tostring(label)) or "",
    remedy and ("\n" .. remedy) or ""),
    status == "unavailable" and vim.log.levels.WARN or vim.log.levels.INFO,
    { title = "C++ definition", timeout = 5000 }
end

function M.probes(result, tx)
  local events = {}
  if not result then return events end
  local function record(topic, key, data)
    events[#events + 1] = { topic = topic, key = key, data = data, revision = M.OBSERVATIONS[topic] }
  end
  local index = tx and tx.index or {}
  local generation_class = index.readiness ~= "ready" and tostring(index.readiness or "missing")
    or (index.complete and "complete" or "partial")
  if result.state ~= "resolved" then
    record("cpp-semantic-navigation",
      string.format("%s|%s|%s|%s",
        tostring(result.state or "?"),
        tostring(result.stage or "?"),
        tostring(result.reason or "?"), generation_class), {
      state = result.state,
      stage = result.stage,
      reason = result.reason,
      provider = result.provider,
      generation_class = generation_class,
    })
  end
  local metrics = result.metrics or {}
  local query_kind = metrics.query_kinds and metrics.query_kinds[1]
    and metrics.query_kinds[1].kind or "provider"
  record("cpp-semantic-performance",
    string.format("%s|%s", query_kind, generation_class), {
      elapsed_ms = tonumber(result.elapsed_ms) or 0,
      state = result.state,
      stage = result.stage,
      provider = result.provider,
      index_wait_ms = tonumber(result.index_wait_ms) or 0,
      tu_count = tonumber(metrics.tu_count),
      process_rss_bytes = tonumber(metrics.process_rss_bytes),
      generation_class = generation_class,
    })
  return events
end

local function short_hash(value)
  value = tostring(value or "")
  return value ~= "" and vim.fn.sha256(value):sub(1, 12) or "-"
end

local function display_path(tx, path)
  path = location_mod.normalize_path(path or "")
  for _, item in ipairs({
    { label = "project", root = (tx.build or {}).project_root },
    { label = "engine", root = (tx.build or {}).engine_root },
  }) do
    local root = location_mod.normalize_path(item.root or ""):gsub("/$", "")
    if root ~= "" and (path:lower() == root:lower()
        or path:lower():sub(1, #root + 1) == root:lower() .. "/") then
      local relative = path:sub(#root + 1):gsub("^/", "")
      return item.label .. "/" .. relative
    end
  end
  return vim.fn.fnamemodify(path, ":t")
end

function M.explain_lines(tx)
  if not tx then return { "(no C++ semantic transaction yet)" } end
  local result = transaction.last_result(tx) or {}
  local index = tx.index or {}
  local provider_result = result.provider_result or {}
  local function safe_text(value)
    local text = tostring(value or "-"):sub(1, 4096):gsub("\\", "/")
    -- Preserve the severity/message suffix of standard Clang diagnostics.
    text = text:gsub("file://.-(:%d+:%d+:)", "<path>%1")
      :gsub("[%a]:/.-(:%d+:%d+:)", "<path>%1")
      :gsub("^/.-(:%d+:%d+:)", "<path>%1")
      :gsub("([%s%(=:\"'])(/.-)(:%d+:%d+:)", "%1<path>%3")
    -- Free-form compiler messages may contain quoted paths with spaces.
    -- Prefer losing a path-bearing suffix over leaking private directories.
    text = text:gsub("file://[^%c\"']+", "<path>")
      :gsub("[%a]:/[^%c\"']+", "<path>")
      :gsub("^/[^%c\"']+", "<path>")
      :gsub("([%s%(=:\"'])(/[^%c\"']+)", "%1<path>")
      :gsub("%c", " ")
    return vim.fn.strcharpart(text, 0, 240)
  end
  local lines = {
    "=== UEDefExplain ===",
    string.format("symbol: %s", tostring(tx.symbol or "?")),
    string.format("subject: %s:%d:%d", display_path(tx, tx.subject.path),
      tonumber(tx.subject.line or 0), tonumber(tx.subject.column0 or 0)),
    string.format("document_version: %s", tostring(tx.subject.document_version or "?")),
    string.format("build: %s", short_hash((tx.build or {}).build_fingerprint)),
    string.format("generation: %s", tostring(index.generation_short or "-")),
    string.format("index: coverage=%s readiness=%s freshness=%s base=%s modules=%s",
      tostring(index.coverage_level or "-"), tostring(index.readiness or "-"),
      tostring(index.freshness or "-"), tostring(index.phase or "-"),
      tostring(index.module_count or 0)),
    string.format("state: %s", tostring(result.state or "?")),
    string.format("stage: %s", tostring(result.stage or "?")),
    string.format("reason: %s", tostring(result.reason or "?")),
    string.format("destination_role: %s", tostring(result.destination_role or "?")),
    string.format("provider: %s", tostring(result.provider or "?")),
    string.format("identity_hash: %s", short_hash(result.identity)),
    string.format("provider_clients: %d", #(provider_result.client_results or {})),
    string.format("provider_locations: %d", #(provider_result.locations or {})),
    string.format("elapsed_ms: %s", tostring(result.elapsed_ms or "?")),
  }
  if result.detail then lines[#lines + 1] = "detail: " .. safe_text(result.detail) end
  local diagnostics = result.diagnostics or {}
  for i = 1, math.min(#diagnostics, 8) do
    local diag = diagnostics[i]
    lines[#lines + 1] = "diagnostic: " .. safe_text(type(diag) == "table"
      and (diag.message or diag.spelling or diag.reason) or diag)
  end
  if #diagnostics > 8 then lines[#lines + 1] = "diagnostics omitted: " .. (#diagnostics - 8) end
  local contexts = result.context_evidence or result.contexts or {}
  for i = 1, math.min(#contexts, 8) do
    local ctx = contexts[i]
    lines[#lines + 1] = string.format("context: %s tu=%s state=%s reason=%s definitions=%s",
      short_hash(ctx.context_id or ctx.id), display_path(tx, ctx.origin_tu),
      safe_text(ctx.state), safe_text(ctx.reason), tostring(tonumber(ctx.definition_count) or "-"))
    if ctx.diagnostics and ctx.diagnostics[1] then
      lines[#lines + 1] = "context diagnostic: " .. safe_text(ctx.diagnostics[1])
    end
  end
  if #contexts > 8 then lines[#lines + 1] = "contexts omitted: " .. (#contexts - 8) end
  local metrics = result.metrics or {}
  local values = {}
  for _, key in ipairs({ "cold_parse_ms", "reparse_ms", "tu_count", "process_rss_bytes", "max_tus",
    "lookup_cache_entries", "shim_abi_version" }) do
    if tonumber(metrics[key]) then values[#values + 1] = key .. "=" .. tonumber(metrics[key]) end
  end
  if #values > 0 then lines[#lines + 1] = "metrics: " .. table.concat(values, " ") end
  for i = 1, math.min(#(metrics.query_kinds or {}), 4) do
    local query = metrics.query_kinds[i]
    lines[#lines + 1] = "query: " .. short_hash(query.context_id) .. " kind=" .. safe_text(query.kind)
  end
  local identity_result = result.identity_result or {}
  if identity_result.elapsed_ms or provider_result.elapsed_ms then
    lines[#lines + 1] = string.format("provider timing: identity_ms=%s destination_ms=%s",
      tostring(tonumber(identity_result.elapsed_ms) or "-"), tostring(tonumber(provider_result.elapsed_ms) or "-"))
  end
  if identity_result.declarations or identity_result.definitions then
    lines[#lines + 1] = string.format("compiler roles: declarations=%d definitions=%d",
      #(identity_result.declarations or {}), #(identity_result.definitions or {}))
  end
  return lines
end


return M
