local protocol = require("utils.ue_goto.semantic_protocol")
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local semantic_context = require("utils.ue_goto.semantic_context")
local logger = require("utils.log").scoped("ue.semantic_sidecar")

local M = {}
local Sidecar = {}
Sidecar.__index = Sidecar

local function location_key(loc)
  if type(loc) ~= "table" then return nil end
  return table.concat({
    tostring(loc.path or ""),
    tostring(loc.line or ""),
    tostring(loc.column or ""),
    tostring(loc.offset or ""),
  }, "\0")
end

local function aggregate_diagnostics(contexts)
  local out, seen = {}, {}
  for _, context in ipairs(contexts or {}) do
    for _, diagnostic in ipairs(context.diagnostics or {}) do
      if type(diagnostic) == "string" and diagnostic ~= "" and not seen[diagnostic] then
        seen[diagnostic] = true
        out[#out + 1] = diagnostic
      end
    end
  end
  return out
end

local function summarize_unresolved(unresolved)
  local state_counts, reason_counts = {}, {}
  for _, context in ipairs(unresolved or {}) do
    local state = tostring(context.state or "unavailable")
    local reason = tostring(context.reason or "unknown")
    state_counts[state] = (state_counts[state] or 0) + 1
    reason_counts[reason] = (reason_counts[reason] or 0) + 1
  end

  local state = "unavailable"
  local has_unavailable = state_counts.unavailable ~= nil
  local has_invalid = state_counts["invalid-semantic-context"] ~= nil
  if has_invalid and not has_unavailable then
    state = "invalid-semantic-context"
  end
  -- NOTE: `ambiguous-context` is deliberately NOT reachable from here.
  --
  -- Every entry in `unresolved` FAILED to resolve. A per-context result can carry
  -- state="ambiguous-context" simply because several candidate TUs might include
  -- the header (semantic_context.catalog_contexts returns that whenever more than
  -- one context survives dedup) -- that means "we could not narrow it down", NOT
  -- "multiple proven contexts legitimately resolve to different entities".
  --
  -- Promoting that to a top-level `ambiguous-context` was the bug: ambiguous is
  -- the one terminal state that legitimately shows the user a chooser, so a
  -- symbol with exactly ONE definition was presented as a pick-list of unity TUs.
  -- Genuine ambiguity is produced by the `#resolved > 1` branch below, where each
  -- entry really did resolve. Failures must fail honestly (P12).

  local reasons = vim.tbl_keys(reason_counts)
  table.sort(reasons)
  return state, (#reasons == 1 and reasons[1] or "multiple-context-failures")
end

local function select_identity_winner(results)
  table.sort(results, function(a, b)
    local a_has_def = a.definition ~= nil
    local b_has_def = b.definition ~= nil
    if a_has_def ~= b_has_def then
      return a_has_def
    end
    return tostring(a.context_id or "") < tostring(b.context_id or "")
  end)
  return results[1]
end

local tu_store = require("utils.ue_goto.semantic_sidecar_tu")
local catalog = require("utils.ue_goto.semantic_sidecar_catalog")
local definition_resolver = require("utils.ue_goto.semantic_sidecar_definition")

function Sidecar:_metrics(extra)
  local metrics = self.tu_store:_metrics(extra)
  metrics.lookup_cache_entries = vim.tbl_count(self.definitions.lookup_cache)
  metrics.max_lookup_entries = self.definitions.max_lookup_entries
  metrics.controlled_cdb_entries = vim.tbl_count(self.definitions.controlled_cdb_cache)
  return metrics
end

function Sidecar:handle_catalog(request)
  return self.catalog:handle_catalog(request)
end

function Sidecar:handle_lookup_definition(request)
  return self.definitions:handle_lookup_definition(request)
end

function Sidecar:shutdown()
  self.definitions:evict()
  self.tu_store:shutdown()
end

function Sidecar:_log_metrics(kind, metrics)
  logger.info_ctx(kind, "metrics", metrics)
end

function Sidecar:handle_handshake(request)
  local frame = {
    v = protocol.VERSION,
    id = request.id,
    op = "handshake",
    ok = self.toolchain.ok,
    metrics = self:_metrics(),
  }
  if self.toolchain.ok then
    frame.toolchain = {
      clangd_path = self.toolchain.clangd_path,
      libclang_path = self.toolchain.libclang_path,
      clang_version = self.toolchain.clang_version,
      toolchain_identity = self.toolchain.toolchain_identity,
    }
    frame.capabilities = {
      query_states = {
        "resolved",
        "ambiguous-context",
        "invalid-semantic-context",
        "unavailable",
      },
      ops = {
        "handshake", "catalog", "prove", "query", "lookup-definition",
        "stats", "evict", "shutdown",
      },
    }
  else
    frame.state = "unavailable"
    frame.reason = self.toolchain.reason
    frame.probes = self.toolchain.probes
  end
  return frame
end

function Sidecar:handle_prove(request)
  local started = libclang.uv.hrtime()
  local cdb_path = request.cdb_path or libclang.join(request.cdb_dir, "compile_commands.json")
  local active_cdb_path = request.active_cdb_path or cdb_path
  local fresh, freshness_reason = libclang.active_cdb_is_fresh(
    cdb_path, active_cdb_path, request.active_manifest_path)
  if not fresh then
    return {
      v = protocol.VERSION,
      id = request.id,
      op = "prove",
      ok = true,
      state = "unavailable",
      reason = freshness_reason,
      context_id = request.context_id,
      metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
    }
  end
  local function compile_entry(path)
    local entries = libclang.read_json(path)
    local db, detail = semantic_context.load_compilation_database(entries)
    if not db or not db.complete then
      return nil, { complete = false, rejected = db and db.rejected or { { reason = detail or "cdb-unreadable" } } }
    end
    return db and db.by_file[semantic_context.match_key(request.source)] or nil
  end
  local merged, merged_coverage = compile_entry(cdb_path)
  local active, active_coverage = compile_entry(active_cdb_path)
  if merged_coverage or active_coverage then
    return {
      v = protocol.VERSION, id = request.id, op = "prove", ok = true, state = "unavailable",
      reason = merged_coverage and "merged-cdb-incomplete" or "active-cdb-incomplete",
      coverage = merged_coverage or active_coverage,
      metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
    }
  end
  if not active then
    return {
      v = protocol.VERSION,
      id = request.id,
      op = "prove",
      ok = true,
      state = "unavailable",
      reason = "active-compile-command-missing",
      context_id = request.context_id,
      metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
    }
  end
  if not merged then
    return {
      v = protocol.VERSION,
      id = request.id,
      op = "prove",
      ok = true,
      state = "unavailable",
      reason = "merged-compile-command-missing",
      context_id = request.context_id,
      metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
    }
  end
  local fingerprint = libclang.sha256(vim.json.encode({
    cwd = merged.directory,
    origin_tu = merged.file,
    argv = merged.argv,
  }))
  return {
    v = protocol.VERSION,
    id = request.id,
    op = "prove",
    ok = true,
    state = "resolved",
    context_id = request.context_id,
    origin_tu = libclang.normalize(request.source),
    compile = merged,
    compile_command_fingerprint = fingerprint,
    metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
  }
end

function Sidecar:handle_query(request)
  local started = libclang.uv.hrtime()
  if not self.toolchain.ok then
    return {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = "unavailable",
      reason = self.toolchain.reason,
      probes = self.toolchain.probes,
      metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
    }
  end

  self.tu_store:_prune_idle(libclang.now_ms())

  local contexts = {}
  local aggregate = {
    cold_parse_ms = 0,
    reparse_ms = 0,
    query_ms = 0,
    warm_query_ms = 0,
    compile_command_fingerprints = {},
    query_kinds = {},
  }

  for _, ctx in ipairs(request.contexts or {}) do
    local result, meta = self.tu_store:_resolve_context(ctx, request.query, request.overlays or {})
    contexts[#contexts + 1] = result
    if meta then
      aggregate.cold_parse_ms = aggregate.cold_parse_ms + (meta.cold_parse_ms or 0)
      aggregate.reparse_ms = aggregate.reparse_ms + (meta.reparse_ms or 0)
      aggregate.query_ms = aggregate.query_ms + (meta.query_ms or 0)
      if meta.query_kind == "warm" then
        aggregate.warm_query_ms = aggregate.warm_query_ms + (meta.query_ms or 0)
      end
      aggregate.compile_command_fingerprints[#aggregate.compile_command_fingerprints + 1] =
        meta.compile_command_fingerprint
      aggregate.query_kinds[#aggregate.query_kinds + 1] = {
        context_id = ctx.id,
        kind = meta.query_kind,
      }
    end
  end

  local resolved = {}
  local unresolved = {}
  local by_identity = {}
  for _, result in ipairs(contexts) do
    if result.state == "resolved" then
      resolved[#resolved + 1] = result
      local identity = result.canonical_identity and result.canonical_identity.key or result.usr
      by_identity[identity] = by_identity[identity] or {}
      table.insert(by_identity[identity], result)
    else
      unresolved[#unresolved + 1] = result
    end
  end

  local metrics = self:_metrics({
    total_ms = libclang.duration_ms(started),
    cold_parse_ms = aggregate.cold_parse_ms,
    reparse_ms = aggregate.reparse_ms,
    cursor_query_ms = aggregate.query_ms,
    warm_query_ms = aggregate.warm_query_ms,
    compile_command_fingerprints = aggregate.compile_command_fingerprints,
    query_kinds = aggregate.query_kinds,
  })

  local identities = vim.tbl_keys(by_identity)
  local frame
  if #unresolved > 0 then
    local state, reason = summarize_unresolved(unresolved)
    frame = {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = state,
      contexts = contexts,
      reason = reason,
      probes = state == "unavailable" and self.toolchain.probes or nil,
      diagnostics = aggregate_diagnostics(contexts),
      metrics = metrics,
    }
  elseif #resolved == 1 or #identities == 1 then
    local bucket = #identities == 1 and by_identity[identities[1]] or resolved
    local winner = select_identity_winner(bucket)
    local definition_keys = {}
    for _, result in ipairs(bucket) do
      local key = location_key(result.definition)
      if key then definition_keys[key] = true end
    end
    local unique_definition_keys = vim.tbl_keys(definition_keys)
    if #unique_definition_keys > 1 then
      frame = {
        v = protocol.VERSION,
        id = request.id,
        op = "query",
        ok = true,
        state = "ambiguous-context",
        contexts = bucket,
        diagnostics = aggregate_diagnostics(bucket),
        metrics = metrics,
      }
      self:_log_metrics("query", metrics)
      return frame
    end
    frame = {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = "resolved",
      context_id = winner.context_id,
      usr = winner.usr,
      cursor_role = winner.cursor_role,
      cursor_kind = winner.cursor_kind,
      entity_kind = winner.entity_kind,
      canonical_identity = winner.canonical_identity,
      declaration = winner.declaration,
      definition = winner.definition,
      document_version = winner.document_version,
      epoch = winner.epoch,
      contexts = bucket,
      metrics = metrics,
    }
  elseif #resolved > 1 then
    frame = {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = "ambiguous-context",
      contexts = resolved,
      diagnostics = aggregate_diagnostics(resolved),
      metrics = metrics,
    }
  else
    frame = {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = "unavailable",
      reason = "no-contexts",
      metrics = metrics,
    }
  end

  self:_log_metrics("query", metrics)
  return frame
end

function Sidecar:handle_stats(request)
  local entries = {}
  for key, entry in pairs(self.tu_store.tus) do
    entries[#entries + 1] = {
      key = key,
      context_id = entry.context_id,
      epoch = entry.epoch,
      last_used_ms = entry.last_used_ms,
      parse_ms = entry.parse_ms,
      reparse_ms = entry.reparse_ms,
      compile_command_fingerprint = entry.compile.fingerprint,
    }
  end
  table.sort(entries, function(a, b) return a.last_used_ms > b.last_used_ms end)
  return {
    v = protocol.VERSION,
    id = request.id,
    op = "stats",
    ok = true,
    metrics = self:_metrics(),
    tus = entries,
  }
end

function Sidecar:handle_evict(request)
  self.definitions:evict()
  local evicted = self.tu_store:evict(request)

  return {
    v = protocol.VERSION,
    id = request.id,
    op = "evict",
    ok = true,
    evicted = evicted,
    metrics = self:_metrics(),
  }
end

function Sidecar:handle_shutdown(request)
  local metrics = self:_metrics()
  self:shutdown()
  return {
    v = protocol.VERSION,
    id = request.id,
    op = "shutdown",
    ok = true,
    metrics = metrics,
    shutdown = true,
  }
end

function Sidecar:handle_request(request)
  if request.op == "handshake" then
    return self:handle_handshake(request)
  end
  if request.op == "catalog" then
    return self:handle_catalog(request)
  end
  if request.op == "prove" then
    return self:handle_prove(request)
  end
  if request.op == "query" then
    return self:handle_query(request)
  end
  if request.op == "lookup-definition" then
    return self:handle_lookup_definition(request)
  end
  if request.op == "stats" then
    return self:handle_stats(request)
  end
  if request.op == "evict" then
    return self:handle_evict(request)
  end
  if request.op == "shutdown" then
    return self:handle_shutdown(request)
  end
  return protocol.request_error(request, "unknown-op", "unsupported operation", {
    op = request.op,
  })
end

function M.new(opts)
  opts = opts or {}
  local toolchain = libclang.discover_toolchain(opts.toolchain)
  local max_tus = tonumber(opts.max_tus or vim.env.UE_SEMANTICD_MAX_TUS or 1) or 1
  local max_lookup_entries = tonumber(
    opts.max_lookup_entries or vim.env.UE_SEMANTICD_MAX_LOOKUP_ENTRIES or 128
  ) or 128
  local idle_evict_ms = tonumber(
    opts.idle_evict_ms or vim.env.UE_SEMANTICD_IDLE_EVICT_MS or 30000
  ) or 30000
  local instance = setmetatable({ toolchain = toolchain, protocol = protocol }, Sidecar)
  instance.tu_store = tu_store.new(toolchain, {
    max_tus = math.max(1, math.floor(max_tus)),
    idle_evict_ms = math.max(1000, math.floor(idle_evict_ms)),
  })
  instance.definitions = definition_resolver.new({
    toolchain = toolchain, protocol = protocol, location_key = location_key,
    max_lookup_entries = math.max(1, math.floor(max_lookup_entries)),
    metrics = function(extra) return instance:_metrics(extra) end,
    acquire_tu = function(ctx, overlays) return instance.tu_store:_ensure_tu(ctx, overlays) end,
    diagnostics = function(entry) return instance.tu_store:_diagnostics(entry) end,
    prune_tus = function(now) return instance.tu_store:_prune_idle(now) end,
  })
  instance.catalog = catalog.new({
    toolchain = toolchain, protocol = protocol,
    metrics = function(extra) return instance:_metrics(extra) end,
  })
  return instance
end

function M._discover_toolchain_for_test(opts)
  return libclang.discover_toolchain(opts)
end

return M
