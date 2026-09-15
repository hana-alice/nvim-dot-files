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
    _position_encoding = "utf-8",
    range = {
      start = { line = math.max(0, line - 1), character = math.max(0, column - 1) },
      ["end"] = { line = math.max(0, line - 1), character = math.max(0, column - 1) },
    },
  }
end

local report = require("utils.ue_goto.semantic_report")

local function semantic_terminal_notice(sym, result)
  local message, level, opts = report.terminal_notice(sym, result)
  if message then vim.notify(message, level, opts) end
end

local function record_semantic_probe(result, tx)
  local ok, probe = pcall(require, "utils.probe")
  if not ok then return end
  for _, event in ipairs(report.probes(result, tx)) do
    if event.revision and type(probe.observe) == "function" then pcall(probe.observe, event.topic, event.revision) end
    pcall(probe.record, event.topic, event.key, event.data)
  end
end

--- Readiness outranks the sidecar's own verdict when classifying a failure.
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
  local navigation = { CPP_SOURCE_EXTS = M.CPP_SOURCE_EXTS, CPP_HEADER_EXTS = M.CPP_HEADER_EXTS }
  local location_mod = require("utils.ue_goto.location")
  local provider = require("utils.ue_goto.provider")
  local semantic = require("utils.ue_goto.semantic_client")
  local transaction = require("utils.ue_goto.semantic_transaction")
  local dtrace = assert(deps.dtrace, "dtrace is required")
  local jump_to_location = assert(deps.jump_to_location, "jump_to_location is required")
  local format_jump_msg = assert(deps.format_jump_msg, "format_jump_msg is required")

  function owner.explain_lines()
    return report.explain_lines(owner._last_cpp_transaction)
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

  function navigation.cpp_definition(sym, bufnr, ref_file, _ext)
    setup_semantic_trace()
    local snapshot = semantic.begin_action(bufnr)
    local environment, env_err = semantic.discover_toolchain(bufnr, {
      route = M.CPP_HEADER_EXTS[_ext] and "header" or "source",
    })
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

    if type(semantic.capture_overlays) == "function" then
      semantic.capture_overlays(snapshot, environment)
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
    local origin_context

    local function request_is_current(response)
      local current, reason = semantic.snapshot_is_current(snapshot, response)
      if not current then return false, reason end
      if type(semantic.index_snapshot_is_current) == "function" then
        local index_current, index_reason = semantic.index_snapshot_is_current(tx.index, bufnr)
        if not index_current then return false, index_reason end
      end
      return true
    end

    local function provider_options(fields)
      fields.snapshot, fields.structured, fields.is_current = tx, true, request_is_current
      if type(semantic.add_action_cleanup) == "function" then
        fields.register_cancel = function(cancel) return semantic.add_action_cleanup(snapshot, cancel) end
      end
      return fields
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

      -- Missing index readiness is not proof of conflicting identities.
      state, stage, reason = M._apply_readiness_override(state, stage, reason, tx.index)

      -- Only resolved contexts are valid choices; failure records are evidence.
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
          state = "unavailable"
        end
      end

      return transaction.terminal(state, stage, reason, {
        detail = raw ~= "" and raw or nil,
        diagnostics = response and response.diagnostics,
        contexts = ambiguous_contexts,
        context_evidence = response and response.contexts,
        metrics = response and response.metrics,
      })
    end

    local function provider_failure(result)
      local reason = result and result.reason
      if reason == "provider-unavailable" then
        local readiness_reason = definition_miss_reason()
        local index_unavailable = readiness_reason == "index-provider-not-ready"
          or readiness_reason == "index-stale-for-module"
        return transaction.terminal("unavailable", index_unavailable and "index" or "provider",
          index_unavailable and readiness_reason or reason, {
            provider = "clangd",
            provider_result = result,
          })
      end
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

    if type(semantic.set_action_cleanup) == "function" then
      semantic.set_action_cleanup(snapshot, clear_progress)
    end

    local function finish(result)
      transaction.finish_once(tx, result, function(final)
        clear_progress()
        final.elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1000000)
        if owner._last_cpp_transaction ~= tx then return end
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
      end)
    end

    local header_evidence
    local function jump_resolved(location, tag, extra)
      local current, reason = request_is_current()
      if not current then finish_stale(reason); return end
      if transaction.same_subject_location(tx, location) then
        finish(transaction.terminal("unavailable", "destination", "already-at-definition", extra))
        return
      end
      local payload = vim.tbl_extend("force", vim.deepcopy(header_evidence or {}), vim.deepcopy(extra or {}))
      if type(payload.identity) ~= "string" or payload.identity == "" then
        finish(transaction.terminal("invalid-semantic-context", "entity", "identity-missing", payload))
        return
      end
      payload.location = location
      payload.destination_role = payload.destination_role or "definition"
      payload.metrics = vim.deepcopy(payload.metrics or {})
      payload.metrics.source = payload.metrics.source or payload.provider
      local terminal_reason = payload.terminal_reason or "definition-resolved"
      payload.terminal_reason = nil
      local resolved = transaction.terminal("resolved", "jump", terminal_reason, payload)
      if jump_to_location(location) then
        local origin = extra and extra.origin_context or origin_context
        if origin then
          local lineage = vim.deepcopy(origin)
          local path = location_mod.location_path(location):lower()
          if M.CPP_HEADER_EXTS[path:match("%.([^./\\]+)$") or ""] then
            lineage.subject_membership = vim.tbl_extend("force", lineage.subject_membership or {}, { [path] = true })
          end
          semantic.note_origin(snapshot.winid, lineage, environment.build_fingerprint)
        end
        finish(resolved)
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
      jump_resolved(declaration, "semantic·declaration", vim.tbl_extend("force", {
        destination_role = "declaration",
        terminal_reason = miss_reason,
        index = tx.index,
      }, extra or {}))
    end

    local function lookup_module_definition(authoritative_usr, role, on_miss)
      if type(authoritative_usr) ~= "string" or authoritative_usr == ""
          or type(semantic.lookup_definition) ~= "function" then
        finish(semantic_failure({ state = "unavailable", reason = "module-lookup-unavailable" }, "destination"))
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
            compiler_session = response.compiler_session,
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
        -- A failed/incomplete AST lookup cannot prove a unique destination.
        -- clangd assistance is only allowed when no module contexts exist.
        if response and (response.reason == "no-proven-module-contexts"
            or response.reason == "lookup-no-subject-module-contexts") then
          on_miss(response)
        else
          finish(semantic_failure(response, "destination"))
        end
      end)
    end

    if M.CPP_HEADER_EXTS[_ext] then
      semantic.resolve_header({
        snapshot = snapshot,
        environment = environment,
        header = ref_file,
        line = snapshot.cursor[1],
        column = snapshot.cursor[2] + 1,
        choose_context = function(contexts, callback)
          clear_progress()
          if not request_is_current() then callback(nil); return end
          require("utils.ue_goto.ui").choose_context(contexts, callback)
        end,
      }, function(response, stale_reason)
        if not response then
          if stale_reason then finish_stale(stale_reason) end
          return
        end
        local current, reason = request_is_current(response)
        if not current then finish_stale(reason); return end
        if response.state ~= "resolved" then
          finish(semantic_failure(response, "context"))
          return
        end
        origin_context = response.origin_context
        header_evidence = {
          identity = response.usr,
          compiler_session = response.compiler_session,
          metrics = vim.tbl_extend("force", response.metrics or {}, { source = "libclang" }),
        }
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
              if not clangd_usr and symbol_info.reason ~= "identity-conflict" then
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
                identity_result = symbol_info,
                provider_result = definition_result,
                metrics = { source = "clangd", identity_ms = symbol_info.elapsed_ms,
                  destination_ms = definition_result.elapsed_ms },
              })
            end, provider_options({
              client_ids = clangd_client_ids,
              compile_command_source = response.contexts and response.contexts[1]
                and response.contexts[1].origin_tu or nil,
            }))
          end, provider_options({
            compile_command_source = response.contexts and response.contexts[1]
              and response.contexts[1].origin_tu or nil,
          }))
        end

        lookup_module_definition(authoritative_usr, role, clangd_cross_tu)
      end)
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

      -- clangd toggles from a function definition to its declaration. Detect
      -- the proven source role before that response can be mistaken for a miss.
      for _, definition in ipairs(symbol_info.definitions or {}) do
        if transaction.same_subject_location(tx, definition) then
          finish(transaction.terminal("unavailable", "destination", "already-at-definition", {
            provider = "clangd", identity = usr, destination_role = "definition",
            identity_result = symbol_info,
          }))
          return
        end
      end

      local function receive_definition(definition_result)
        local still_current, reason = request_is_current(definition_result)
        if not still_current then
          finish_stale(reason)
          return
        end
        local definition_failure = provider_failure(definition_result)
        if definition_failure then finish(definition_failure); return end
        local locs = definition_result.locations or {}
        if #locs == 0 then
          finish(transaction.terminal("unavailable", symbol_info.entity_kind == "macro" and "destination" or "index",
            symbol_info.entity_kind == "macro" and "macro-no-source-definition" or definition_miss_reason(), {
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

        local target_key = location_mod.location_key(locs[1]):lower()
        local function contains_target(locations)
          for _, candidate in ipairs(locations or {}) do
            if location_mod.location_key(candidate):lower() == target_key then return true end
          end
          return false
        end
        local function reject_destination(reason, target_evidence)
          finish(transaction.terminal("unavailable", "destination", "definition-not-found", {
            provider = "clangd", identity = usr,
            destination_role = contains_target(symbol_info.declarations) and "declaration" or "unknown",
            provider_result = definition_result,
            identity_result = symbol_info,
            detail = reason, target_identity_result = target_evidence,
          }))
        end
        local function accept_destination(target_evidence, destination_role)
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
            origin_context = lineage
          end
          dtrace("semantic provider=clangd context=source-exact-command usr=%s state=resolved",
            tostring(usr))
          jump_resolved(locs[1], "clangd·semantic", {
            provider = "clangd",
            destination_role = destination_role or "definition",
            terminal_reason = destination_role == "declaration" and "declaration-resolved" or nil,
            subject_role = "reference",
            identity = usr,
            identity_result = symbol_info,
            target_identity_result = target_evidence,
            provider_result = definition_result,
            metrics = { source = "clangd", identity_ms = symbol_info.elapsed_ms,
              destination_ms = definition_result.elapsed_ms },
          })
        end
        if symbol_info.entity_kind == "macro" or contains_target(symbol_info.definitions) then
          accept_destination()
        elseif contains_target(symbol_info.declarations) then
          if symbol_info.entity_kind == "type-alias" or symbol_info.entity_kind == "namespace" then
            accept_destination(nil, "declaration")
          else
            reject_destination("target-is-declaration")
          end
        else
          -- symbolInfo does not consult the index. A definition in another TU
          -- must be checked at that destination using the same client and USR.
          require("utils.ue_goto.clangd_destination").verify(locs[1], usr, clangd_client_ids,
            function(target_evidence)
              if not request_is_current() or target_evidence.reason == "provider-cancelled" then
                finish_stale("destination-changed")
              elseif target_evidence.reason == "ok" then
                accept_destination(target_evidence)
              else
                reject_destination(target_evidence.reason, target_evidence)
              end
            end, provider_options({}))
        end
      end
      if symbol_info.referent_definition then
        receive_definition(symbol_info.referent_definition)
      else
        provider.async_lsp_request(bufnr, "textDocument/definition", receive_definition, provider_options({
          client_ids = clangd_client_ids,
          compile_command_source = ref_file,
        }))
      end
    end, provider_options({
      compile_command_source = ref_file,
      resolve_referent = true,
    }))
  end

  return navigation
end

return M
