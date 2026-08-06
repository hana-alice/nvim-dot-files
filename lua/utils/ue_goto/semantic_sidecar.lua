local protocol = require("utils.ue_goto.semantic_protocol")
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local semantic_context = require("utils.ue_goto.semantic_context")
local logger = require("utils.log").scoped("ue.semantic_sidecar")

local M = {}
local Sidecar = {}
Sidecar.__index = Sidecar

require("utils.ue_goto.semantic_sidecar_tu").install(Sidecar)
require("utils.ue_goto.semantic_sidecar_catalog").install(Sidecar)

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
      ops = { "handshake", "catalog", "prove", "query", "stats", "evict", "shutdown" },
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
    local db = entries and semantic_context.load_compilation_database(entries) or nil
    return db and db.by_file[semantic_context.match_key(request.source)] or nil
  end
  local merged = compile_entry(cdb_path)
  local active = compile_entry(active_cdb_path)
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

  self:_prune_idle(libclang.now_ms())

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
    local result, meta = self:_resolve_context(ctx, request.query, request.overlays or {})
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
      local identity = result.usr
        .. "\0"
        .. result.declaration.path
        .. "\0"
        .. tostring(result.declaration.line)
        .. "\0"
        .. tostring(result.declaration.column)
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
  if #resolved == 1 or #identities == 1 then
    local winner = resolved[1]
    frame = {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = "resolved",
      context_id = winner.context_id,
      usr = winner.usr,
      declaration = winner.declaration,
      definition = winner.definition,
      document_version = winner.document_version,
      epoch = winner.epoch,
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
      metrics = metrics,
    }
  elseif #unresolved > 0 then
    local state = unresolved[1].state
    frame = {
      v = protocol.VERSION,
      id = request.id,
      op = "query",
      ok = true,
      state = state,
      contexts = unresolved,
      reason = unresolved[1].reason,
      probes = state == "unavailable" and self.toolchain.probes or nil,
      diagnostics = unresolved[1].diagnostics,
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
  for key, entry in pairs(self.tus) do
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
  local evicted = 0
  if request.all then
    for key, entry in pairs(self.tus) do
      self:_dispose_tu(entry)
      self.tus[key] = nil
      evicted = evicted + 1
    end
  elseif request.context_ids and #request.context_ids > 0 then
    local wanted = {}
    for _, id in ipairs(request.context_ids) do
      wanted[id] = true
    end
    for key, entry in pairs(self.tus) do
      if wanted[entry.context_id] then
        self:_dispose_tu(entry)
        self.tus[key] = nil
        evicted = evicted + 1
      end
    end
  else
    self:_prune_idle(libclang.now_ms())
  end

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
  local idle_evict_ms = tonumber(
    opts.idle_evict_ms or vim.env.UE_SEMANTICD_IDLE_EVICT_MS or 30000
  ) or 30000
  local instance = setmetatable({
    toolchain = toolchain,
    protocol = protocol,
    tus = {},
    cdbs = {},
    max_tus = math.max(1, math.floor(max_tus)),
    idle_evict_ms = math.max(1000, math.floor(idle_evict_ms)),
  }, Sidecar)

  if toolchain.ok then
    instance.index = toolchain.lib.clang_createIndex(0, 0)
  else
    instance.index = nil
  end
  return instance
end

function M._discover_toolchain_for_test(opts)
  return libclang.discover_toolchain(opts)
end

return M
