local M = {}

M.CPP_SOURCE_EXTS = {
  c = true, cc = true, cpp = true, cxx = true, m = true, mm = true,
}

M.CPP_HEADER_EXTS = {
  h = true, hh = true, hpp = true, hxx = true, inl = true, ipp = true,
  ixx = true,
}

local CPP_PROGRESS_NOTICE_MS = 150

local function semantic_location(value)
  if type(value) ~= "table" then return nil end
  if value.uri and (value.range or value.targetSelectionRange or value.targetRange) then
    return value
  end
  local path = value.path or value.file or value.filename
  local line = tonumber(value.line)
  local column = tonumber(value.column or value.col or 1)
  if not path or not line then return nil end
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = math.max(0, line - 1), character = math.max(0, column - 1) },
      ["end"] = { line = math.max(0, line - 1), character = math.max(0, column - 1) },
    },
  }
end

local function semantic_terminal_notice(sym, result)
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

  vim.notify(string.format("C++ definition %s%s%s%s",
    tostring(status),
    sym and sym ~= "" and (" for `" .. sym .. "`") or "",
    label ~= "" and (": " .. tostring(label)) or "",
    remedy and ("\n" .. remedy) or ""),
    status == "unavailable" and vim.log.levels.WARN or vim.log.levels.INFO,
    { title = "C++ definition", timeout = 5000 })
end

local function record_semantic_probe(result, tx)
  if not result then return end
  local ok, probe = pcall(require, "utils.probe")
  if not ok or type(probe.record) ~= "function" then return end
  local index = tx and tx.index or {}
  local generation_class = index.readiness ~= "ready" and tostring(index.readiness or "missing")
    or (index.complete and "complete" or "partial")
  if result.state ~= "resolved" then
    pcall(probe.record, "cpp-semantic-navigation",
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
  pcall(probe.record, "cpp-semantic-performance",
    string.format("%s|%s", query_kind, generation_class), {
      elapsed_ms = tonumber(result.elapsed_ms) or 0,
      index_wait_ms = tonumber(result.index_wait_ms) or 0,
      tu_count = tonumber(metrics.tu_count),
      process_rss_bytes = tonumber(metrics.process_rss_bytes),
      generation_class = generation_class,
    })
end

--- Readiness outranks the sidecar's own verdict when classifying a failure.
---
--- Pure and exposed so the invariant is provable headless instead of only
--- reachable through a live sidecar. See the call site in `semantic_failure`
--- for the full rationale; the short version: `semantic_sidecar` reports
--- "ambiguous-context" whenever several contexts merely failed differently, and
--- `ambiguous-context` is the one terminal state that legitimately shows the
--- user a chooser -- so an index-readiness failure was being rendered as a
--- pick-list of unity TUs for symbols that have exactly one definition (P12).
--- @param state string terminal state proposed by the sidecar
--- @param stage string
--- @param reason string
--- @param index table|nil transaction index snapshot ({ readiness, freshness, ... })
--- @return string state, string stage, string reason
function M._apply_readiness_override(state, stage, reason, index)
  index = index or {}
  if state ~= "ambiguous-context" then
    return state, stage, reason
  end
  if index.readiness == "ready" then
    return state, stage, reason
  end
  local stale = index.readiness == "stale"
    or index.freshness == "stale"
    or index.freshness == "stale-for-module"
  return "unavailable", "context",
    stale and "index-stale-for-module" or "index-provider-not-ready"
end

function M.install(owner, deps)
  local location_mod = require("utils.ue_goto.location")
  local provider = require("utils.ue_goto.provider")
  local semantic = require("utils.ue_goto.semantic_client")
  local transaction = require("utils.ue_goto.semantic_transaction")
  local dtrace = assert(deps.dtrace, "dtrace is required")
  local jump_to_location = assert(deps.jump_to_location, "jump_to_location is required")
  local format_jump_msg = assert(deps.format_jump_msg, "format_jump_msg is required")

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

  function owner.explain_lines()
    local tx = owner._last_cpp_transaction
    if not tx then return { "(no C++ semantic transaction yet)" } end
    local result = transaction.last_result(tx) or {}
    local index = tx.index or {}
    local provider_result = result.provider_result or {}
    return {
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
  end

  owner._test_explain_lines = owner.explain_lines

  function owner.explain()
    local lines = owner.explain_lines()
    vim.cmd("vnew")
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.bo.buftype = "nofile"
    vim.bo.bufhidden = "wipe"
    vim.bo.swapfile = false
    vim.api.nvim_buf_set_name(0, "UEDefExplain")
  end

  local function setup_semantic_trace()
    semantic.set_trace(function(fields)
      dtrace(
        "semantic event=%s request=%s context=%s provider=%s usr=%s state=%s elapsed=%s stale=%s",
        tostring(fields.event or "?"), tostring(fields.request_id or "?"),
        tostring(fields.context_id or "?"), tostring(fields.provider or "?"),
        tostring(fields.usr or "?"), tostring(fields.terminal_state or "?"),
        tostring(fields.elapsed_ms or "?"), tostring(fields.stale_reason or "?"))
    end)
  end

  function M.cpp_definition(sym, bufnr, ref_file, _ext)
    setup_semantic_trace()
    local snapshot = semantic.begin_action(bufnr)
    local environment, env_err = semantic.discover_toolchain(bufnr)
    if not environment then
      dtrace("semantic state=unavailable reason=toolchain-or-context")
      local failed_tx = transaction.create({ bufnr = bufnr, snapshot = snapshot, symbol = sym })
      local failed = transaction.terminal("unavailable", "environment",
        "semantic-sidecar-unavailable", { detail = env_err })
      failed.elapsed_ms = 0
      transaction.finish_once(failed_tx, failed)
      owner._last_cpp_transaction = failed_tx
      record_semantic_probe(failed, failed_tx)
      semantic_terminal_notice(sym, failed)
      return
    end

    local tx = transaction.create({
      bufnr = bufnr,
      snapshot = snapshot,
      build = {
        build_fingerprint = environment.build_fingerprint,
        project_root = environment.project_root,
        engine_root = environment.engine_root,
      },
      context = { active_build_key = environment.active_build_key },
      index = environment.index,
      symbol = sym,
    })
    owner._last_cpp_transaction = tx
    local started_at = vim.uv.hrtime()

    local function request_is_current(response)
      local current, reason = semantic.snapshot_is_current(snapshot, response)
      if not current then return false, reason end
      if type(semantic.index_snapshot_is_current) == "function" then
        local index_current, index_reason = semantic.index_snapshot_is_current(tx.index, bufnr)
        if not index_current then return false, index_reason end
      end
      return true
    end

    local function definition_miss_reason()
      local index = tx.index or {}
      if index.freshness == "stale-for-module" or index.freshness == "stale"
          or index.readiness == "stale" then
        return "index-stale-for-module"
      end
      if index.readiness ~= "ready" then
        return "index-provider-not-ready"
      end
      if index.complete or index.coverage_level == "full" then
        return "definition-absent-in-complete-index"
      end
      return "index-incomplete"
    end

    local function semantic_failure(response, default_stage)
      local raw = tostring(response and response.reason or "")
      local reason = "semantic-tu-unavailable"
      local stage = default_stage or "tu"
      if raw == "active-compile-command-missing" then
        reason, stage = raw, "context"
      elseif raw:find("query%-file%-not%-in%-tu") then
        reason, stage = "query-file-not-in-tu", "context"
      elseif raw == "no-contexts" or raw == "no-proven-context"
          or raw:find("compilation%-database%-unreadable") then
        reason, stage = "context-not-member", "context"
      elseif raw == "multiple-context-failures" then
        reason, stage = "context-resolution-failed", "context"
      elseif raw == "libclang-not-found" or raw:find("toolchain") then
        reason, stage = "semantic-sidecar-unavailable", "environment"
      elseif raw:find("invalid%-cursor") or raw:find("invalid%-null")
          or raw:find("invalid%-empty%-usr") or raw:find("invalid%-declaration") then
        reason, stage = "semantic-cursor-invalid", "entity"
      end
      local state = response and response.state or "unavailable"
      if not transaction.TERMINAL_STATES[state] then state = "unavailable" end

      -- READINESS OUTRANKS THE SIDECAR'S OWN VERDICT.
      --
      -- semantic_sidecar aggregates per-context outcomes and reports
      -- "ambiguous-context" whenever several contexts merely failed differently
      -- (semantic_sidecar.lua: has_ambiguous and not has_unavailable). Trusting
      -- that verbatim mislabels an index-readiness problem as genuine ambiguity,
      -- and "ambiguous" is the one state that legitimately shows the user a
      -- chooser -- so a symbol with exactly ONE definition ends up presented as
      -- a pick-list of unity TUs (observed on WrapAroundAllocateMemory, whose
      -- module contains a single out-of-line definition).
      --
      -- ambiguous-context means "multiple PROVEN contexts resolve to different
      -- entities". When the controlled index never got delivered there are no
      -- proven contexts at all, so the honest state is `unavailable` with a
      -- readiness reason (P12: Clang semantic failure must fail honestly; text
      -- hits cannot distinguish overloads, same-name symbols or namespaces).
      state, stage, reason = M._apply_readiness_override(state, stage, reason, tx.index)

      -- Contexts are evidence for an ambiguity the user can actually act on: each
      -- one must have RESOLVED to a real target. Failure records are not choices.
      -- The sidecar only reaches `ambiguous-context` from its `#resolved > 1`
      -- branch now, but this stays defensive: a chooser fed with unresolved
      -- contexts is exactly the "pick one of these unity cpp files" symptom, and
      -- P12 forbids presenting text/TU guesses as definition targets.
      local ambiguous_contexts = nil
      if state == "ambiguous-context" and response and type(response.contexts) == "table" then
        local resolved_only = {}
        for _, c in ipairs(response.contexts) do
          if type(c) == "table" and c.state == "resolved" then
            resolved_only[#resolved_only + 1] = c
          end
        end
        if #resolved_only > 1 then
          ambiguous_contexts = resolved_only
        else
          -- Not a real ambiguity after filtering: fail honestly instead of
          -- offering a list the user cannot reason about.
          state = "unavailable"
        end
      end

      return transaction.terminal(state, stage, reason, {
        detail = raw ~= "" and raw or nil,
        diagnostics = response and response.diagnostics,
        contexts = ambiguous_contexts,
        metrics = response and response.metrics,
      })
    end

    local function provider_failure(result)
      local reason = result and result.reason
      if reason == "provider-method-unsupported" or reason == "provider-timeout"
          or reason == "provider-error" then
        return transaction.terminal("unavailable", "provider", reason, {
          provider = "clangd",
          provider_result = result,
        })
      end
      return nil
    end

    local progress_notice = nil
    local progress_timer = vim.defer_fn(function()
      local current = semantic.snapshot_is_current(snapshot)
      if current then
        local ok, progress_ui = pcall(require, "utils.ue_goto.ui")
        if ok then progress_notice = progress_ui.progress_notice("⏳ resolving C++ definition ...") end
      end
    end, CPP_PROGRESS_NOTICE_MS)

    local function clear_progress()
      if progress_timer then
        pcall(function() progress_timer:stop() end)
        pcall(function() progress_timer:close() end)
        progress_timer = nil
      end
      if progress_notice then
        pcall(progress_notice.clear)
        progress_notice = nil
      end
    end

    local function finish(result)
      transaction.finish_once(tx, result, function(final)
        clear_progress()
        final.elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1000000)
        owner._last_cpp_transaction = tx
        record_semantic_probe(final, tx)
        if final.state ~= "resolved" then
          semantic_terminal_notice(sym, final)
        end
      end)
    end

    local function finish_stale(reason)
      dtrace("semantic provider=clangd state=stale reason=%s", reason)
      transaction.finish_once(tx, transaction.terminal("unavailable", "stale", "stale-request", {
        stale_reason = reason,
      }), function(final)
        clear_progress()
        final.elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1000000)
        owner._last_cpp_transaction = tx
      end)
    end

    local function jump_resolved(location, tag, extra)
      if transaction.same_subject_location(tx, location) then
        finish(transaction.terminal("unavailable", "destination", "already-at-definition", extra))
        return
      end
      if jump_to_location(location) then
        local payload = vim.deepcopy(extra or {})
        local terminal_reason = payload.terminal_reason or "definition-resolved"
        payload.terminal_reason = nil
        finish(transaction.terminal("resolved", "jump", terminal_reason,
          vim.tbl_extend("force", {
            location = location,
            destination_role = payload.destination_role or "definition",
          }, payload)))
        vim.notify(format_jump_msg(sym, location, tag), vim.log.levels.INFO,
          { title = "C++ definition", timeout = 3000 })
        return
      end
      finish(transaction.terminal("unavailable", "jump", "jump-failed", extra))
    end

    local function declaration_fallback(role, declaration, extra)
      if not declaration then
        finish(transaction.terminal("unavailable", "destination", "definition-not-found", extra))
        return
      end
      local miss_reason = extra and extra.fallback_reason or definition_miss_reason()
      if role == "declaration" or (miss_reason ~= "index-incomplete"
          and miss_reason ~= "index-provider-not-ready" and miss_reason ~= "identity-missing") then
        local stage = miss_reason == "identity-missing" and "entity" or "index"
        finish(transaction.terminal("unavailable", stage, miss_reason,
          vim.tbl_extend("force", { subject_role = role, index = tx.index }, extra or {})))
        return
      end
      local target_path = location_mod.location_path(declaration):lower()
      if M.CPP_HEADER_EXTS[target_path:match("%.([^./\\]+)$") or ""] then
        if extra and extra.origin_context then
          local lineage = vim.deepcopy(extra.origin_context)
          lineage.subject_membership = { [target_path] = true }
          semantic.note_origin(snapshot.winid, lineage, environment.build_fingerprint)
        end
      end
      jump_resolved(declaration, "semantic·declaration", vim.tbl_extend("force", {
        destination_role = "declaration",
        terminal_reason = miss_reason,
        index = tx.index,
      }, extra or {}))
    end

    local function lookup_module_definition(authoritative_usr, role, on_miss)
      if type(authoritative_usr) ~= "string" or authoritative_usr == ""
          or type(semantic.lookup_definition) ~= "function" then
        on_miss()
        return
      end
      dtrace("semantic provider=libclang request=lookup-definition usr=%s", authoritative_usr)
      semantic.lookup_definition({
        usr = authoritative_usr,
        path = ref_file,
        environment = environment,
        snapshot = snapshot,
      }, function(response)
        local current, stale_reason = request_is_current(response)
        if not current then
          finish_stale(stale_reason)
          return
        end
        local definition = semantic_location(response and response.definition)
        if response and response.state == "resolved" and definition then
          jump_resolved(definition, "libclang·module-USR", {
            provider = "libclang-module",
            destination_role = "definition",
            subject_role = role,
            identity = authoritative_usr,
            metrics = response.metrics,
          })
          return
        end
        if response and response.reason == "multiple-definitions" then
          finish(transaction.terminal("unavailable", "destination", "multiple-definitions", {
            provider = "libclang-module",
            subject_role = role,
            identity = authoritative_usr,
            contexts = response.contexts,
            metrics = response.metrics,
          }))
          return
        end
        on_miss(response)
      end)
    end

    if M.CPP_HEADER_EXTS[_ext] then
      semantic.resolve_header({
        snapshot = snapshot,
        environment = environment,
        header = ref_file,
        line = snapshot.cursor[1],
        column = snapshot.cursor[2] + 1,
      }, function(response, stale_reason)
        if not response then
          if stale_reason then finish_stale(stale_reason) end
          return
        end
        if response.state ~= "resolved" then
          finish(semantic_failure(response, "context"))
          return
        end
        local definition = semantic_location(response.definition)
        local declaration = semantic_location(response.declaration)
        local role = transaction.subject_role(tx, declaration, definition)
        if definition then
          jump_resolved(definition, "libclang·USR", {
            provider = "libclang",
            destination_role = "definition",
            subject_role = role,
          })
          return
        end
        if not declaration then
          finish(transaction.terminal("invalid-semantic-context", "destination", "definition-not-found", {
            provider = "libclang",
            subject_role = role,
          }))
          return
        end

        local authoritative_usr = response.usr
        if type(authoritative_usr) ~= "string" or authoritative_usr == "" then
          declaration_fallback(role, declaration, {
            provider = "libclang",
            subject_role = role,
            stage = "entity",
            reason = "identity-missing",
          })
          return
        end

        local function clangd_cross_tu()
          dtrace("semantic provider=clangd request=symbolInfo context=header-cross-tu usr=%s",
            authoritative_usr)
          provider.async_clangd_symbol_info(bufnr, function(symbol_info)
            local identity_current, identity_stale = request_is_current()
            if not identity_current then
              finish_stale(identity_stale)
              return
            end
            local clangd_usr = symbol_info.usr
            local clangd_client_ids = symbol_info.client_ids
            local provider_terminal = provider_failure(symbol_info)
            if provider_terminal then finish(provider_terminal); return end
            if clangd_usr ~= authoritative_usr then
              dtrace("semantic provider=clangd state=invalid-semantic-context usr-mismatch=%s/%s",
                tostring(authoritative_usr), tostring(clangd_usr))
              if not clangd_usr then
                declaration_fallback(role, declaration, {
                  provider = "clangd",
                  subject_role = role,
                  fallback_reason = "identity-missing",
                  provider_result = symbol_info,
                })
              else
                finish(transaction.terminal("invalid-semantic-context", "entity",
                  "identity-conflict", {
                    provider = "clangd",
                    subject_role = role,
                    provider_result = symbol_info,
                  }))
              end
              return
            end

            provider.async_lsp_request(bufnr, "textDocument/definition", function(definition_result)
              local still_current, reason = request_is_current()
              if not still_current then
                finish_stale(reason)
                return
              end
              local definition_failure = provider_failure(definition_result)
              if definition_failure then finish(definition_failure); return end
              local locations = transaction.filter_definition_locations(
                tx, definition_result.locations or {}, declaration)
              if #locations ~= 1 then
                dtrace("semantic provider=clangd state=invalid-semantic-context n=%d usr=%s",
                  #locations, authoritative_usr)
                if #locations == 0 then
                  declaration_fallback(role, declaration, {
                    provider = "clangd",
                    subject_role = role,
                    stage = "destination",
                    reason = "definition-not-found",
                    provider_result = definition_result,
                  })
                  return
                end
                finish(transaction.terminal("unavailable", "destination", "multiple-definitions", {
                  provider = "clangd",
                  subject_role = role,
                  provider_result = definition_result,
                }))
                return
              end
              jump_resolved(locations[1], "clangd·USR-verified", {
                provider = "clangd",
                destination_role = "definition",
                subject_role = role,
                identity = authoritative_usr,
              })
            end, {
              client_ids = clangd_client_ids,
              snapshot = tx,
              structured = true,
              compile_command_source = response.contexts and response.contexts[1]
                and response.contexts[1].origin_tu or nil,
            })
          end, {
            snapshot = tx,
            structured = true,
            compile_command_source = response.contexts and response.contexts[1]
              and response.contexts[1].origin_tu or nil,
          })
        end

        lookup_module_definition(authoritative_usr, role, clangd_cross_tu)
      end)
      return
    end

    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" })
    if not clients or vim.tbl_isempty(clients) then
      finish(transaction.terminal("unavailable", "provider", "provider-method-unsupported"))
      return
    end

    -- Source TUs already have an exact command transported to clangd from the
    -- controlled active CDB. Query clangd at the immutable cursor snapshot;
    -- do not make every gd parse the 200MB+ CDB again in the libclang sidecar.
    dtrace("semantic provider=clangd request=symbolInfo+definition context=source-exact-command")
    provider.async_clangd_symbol_info(bufnr, function(symbol_info)
      local identity_current, identity_stale = request_is_current(symbol_info)
      if not identity_current then
        finish_stale(identity_stale)
        return
      end
      local usr = symbol_info.usr
      local clangd_client_ids = symbol_info.client_ids
      local provider_terminal = provider_failure(symbol_info)
      if provider_terminal then finish(provider_terminal); return end
      if not usr then
        finish(transaction.terminal("invalid-semantic-context", "entity",
          symbol_info.reason == "identity-conflict" and "identity-conflict" or "identity-missing", {
            provider = "clangd",
            provider_result = symbol_info,
          }))
        return
      end

      provider.async_lsp_request(bufnr, "textDocument/definition", function(definition_result)
        local still_current, reason = request_is_current(definition_result)
        if not still_current then
          finish_stale(reason)
          return
        end
        local definition_failure = provider_failure(definition_result)
        if definition_failure then finish(definition_failure); return end
        local locs = transaction.filter_definition_locations(
          tx, definition_result.locations or {}, nil)
        if #locs == 0 then
          finish(transaction.terminal("unavailable", "index", definition_miss_reason(), {
            provider = "clangd",
            identity = usr,
            provider_result = definition_result,
          }))
          return
        end
        if #locs > 1 then
          finish(transaction.terminal("unavailable", "destination", "multiple-definitions", {
            provider = "clangd",
            identity = usr,
            provider_result = definition_result,
          }))
          return
        end

        local target_path = location_mod.location_path(locs[1]):lower()
        if M.CPP_HEADER_EXTS[target_path:match("%.([^./\\]+)$") or ""]
            and type(symbol_info.exact_command) == "table" then
          local exact = symbol_info.exact_command
          local compile = {
            directory = exact.workingDirectory,
            file = ref_file,
            argv = vim.deepcopy(exact.compilationCommand or {}),
          }
          local compile_fingerprint = vim.fn.sha256(vim.json.encode(compile))
          local lineage = {
            context_id = compile_fingerprint,
            origin_tu = ref_file,
            cdb_dir = environment.cdb_dir,
            compile = compile,
            compile_command_fingerprint = compile_fingerprint,
            subject_membership = { [target_path] = true },
          }
          semantic.note_origin(snapshot.winid, lineage, environment.build_fingerprint)
        end
        dtrace("semantic provider=clangd context=source-exact-command usr=%s state=resolved",
          tostring(usr))
        jump_resolved(locs[1], "clangd·semantic", {
          provider = "clangd",
          destination_role = "definition",
          subject_role = "reference",
          identity = usr,
        })
      end, {
        client_ids = clangd_client_ids,
        snapshot = tx,
        structured = true,
        compile_command_source = ref_file,
      })
    end, {
      snapshot = tx,
      structured = true,
      compile_command_source = ref_file,
    })
  end

  return M
end

return M
