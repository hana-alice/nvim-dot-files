local M = {}
local semantic_context = require("utils.ue_goto.semantic_context")

local TERMINAL = {
  resolved = true,
  ["ambiguous-context"] = true,
  ["invalid-semantic-context"] = true,
  unavailable = true,
}

function M.install(client, deps)
  local state = deps.state
  local hash_text = deps.hash_text
  local close_timer = deps.close_timer
  local emit_trace = deps.emit_trace
  local unavailable = deps.unavailable
  local PROGRESS_DELAY_MS = deps.PROGRESS_DELAY_MS

  function client.clear_contexts(build_fingerprint)
    for winid, context in pairs(state.window_contexts) do
      if not build_fingerprint or context.build_fingerprint ~= build_fingerprint then
        state.window_contexts[winid] = nil
      end
    end
  end

  function client.begin_action(bufnr)
    if not bufnr or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    client.cancel_action()
    state.next_action_token = state.next_action_token + 1
    state.active_action_token = state.next_action_token
    local snapshot = {
      token = state.next_action_token,
      winid = vim.api.nvim_get_current_win(),
      bufnr = bufnr,
      cursor = vim.api.nvim_win_get_cursor(0),
      changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
      document_version = vim.api.nvim_buf_get_changedtick(bufnr),
    }
    local function invalidate()
      if state.active_action_token == snapshot.token then client.cancel_action() end
    end
    local ok_buffer, buffer_id = pcall(vim.api.nvim_create_autocmd, {
      "CursorMoved", "CursorMovedI", "BufLeave", "TextChanged", "TextChangedI",
    }, {
      buffer = bufnr,
      once = true,
      callback = invalidate,
      desc = "Invalidate stale C++ semantic definition action",
    })
    if ok_buffer then state.action_autocmds[#state.action_autocmds + 1] = buffer_id end
    local ok_window, window_id = pcall(vim.api.nvim_create_autocmd, "WinLeave", {
      once = true,
      callback = function()
        if vim.api.nvim_get_current_win() == snapshot.winid then invalidate() end
      end,
      desc = "Invalidate C++ semantic action when its window is left",
    })
    if ok_window then state.action_autocmds[#state.action_autocmds + 1] = window_id end
    return snapshot
  end

  function client.cancel_action()
    for _, id in ipairs(state.action_autocmds) do pcall(vim.api.nvim_del_autocmd, id) end
    state.action_autocmds = {}
    state.next_action_token = state.next_action_token + 1
    state.active_action_token = state.next_action_token
    if state.active_notice then
      pcall(state.active_notice.clear)
      state.active_notice = nil
    end
  end

  function client.snapshot_is_current(snapshot, response)
    if not snapshot or snapshot.token ~= state.active_action_token then return false, "superseded" end
    if not vim.api.nvim_win_is_valid(snapshot.winid) then return false, "window-invalid" end
    if vim.api.nvim_get_current_win() ~= snapshot.winid then return false, "window-changed" end
    if vim.api.nvim_win_get_buf(snapshot.winid) ~= snapshot.bufnr then return false, "buffer-changed" end
    if vim.api.nvim_buf_get_changedtick(snapshot.bufnr) ~= snapshot.changedtick then
      return false, "document-changed"
    end
    local cursor = vim.api.nvim_win_get_cursor(snapshot.winid)
    if cursor[1] ~= snapshot.cursor[1] or cursor[2] ~= snapshot.cursor[2] then
      return false, "cursor-changed"
    end
    if response and response.document_version ~= nil
        and response.document_version ~= snapshot.document_version then
      return false, "response-version-mismatch"
    end
    return true
  end

  local function is_cpp_buffer(bufnr)
    local ft = vim.bo[bufnr].filetype
    if ft == "c" or ft == "cpp" or ft == "objc" or ft == "objcpp" then return true end
    local path = vim.api.nvim_buf_get_name(bufnr):lower()
    return path:match("%.c$") or path:match("%.cc$") or path:match("%.cpp$")
      or path:match("%.cxx$") or path:match("%.h$") or path:match("%.hh$")
      or path:match("%.hpp$") or path:match("%.hxx$") or path:match("%.inl$")
      or path:match("%.ipp$") or false
  end

  local function under(path, root)
    if not root or root == "" then return false end
    path = vim.fs.normalize(path):gsub("\\", "/"):lower()
    root = vim.fs.normalize(root):gsub("\\", "/"):lower():gsub("/$", "")
    return path == root or path:sub(1, #root + 1) == root .. "/"
  end

  function client.collect_unsaved_overlays(environment)
    local overlays = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
          and vim.bo[bufnr].modified and is_cpp_buffer(bufnr) then
        local path = vim.api.nvim_buf_get_name(bufnr)
        if path ~= "" and (under(path, environment.engine_root)
            or under(path, environment.project_root)) then
          overlays[#overlays + 1] = {
            path = vim.fs.normalize(path),
            contents = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n") .. "\n",
            version = vim.api.nvim_buf_get_changedtick(bufnr),
          }
        end
      end
    end
    table.sort(overlays, function(a, b) return a.path:lower() < b.path:lower() end)
    return overlays
  end

  function client.note_origin(winid, origin_tu, build_fingerprint, context_id)
    winid = winid or vim.api.nvim_get_current_win()
    local lineage
    if type(origin_tu) == "table" then
      lineage = semantic_context.make_lineage_record({
        context = origin_tu,
        build_fingerprint = build_fingerprint or origin_tu.build_fingerprint,
        source_action_token = origin_tu.source_action_token,
      })
      if not lineage then
        lineage = vim.deepcopy(origin_tu)
        lineage.build_fingerprint = build_fingerprint or lineage.build_fingerprint
      end
    else
      lineage = {
        origin_tu = origin_tu,
        id = context_id,
        context_id = context_id,
        build_fingerprint = build_fingerprint,
        subject_membership = {},
      }
    end
    state.window_contexts[winid] = lineage
  end

  function client.window_origin(winid, build_fingerprint, subject_path)
    winid = winid or vim.api.nvim_get_current_win()
    local origin = state.window_contexts[winid]
    if origin and origin.build_fingerprint ~= build_fingerprint then
      state.window_contexts[winid] = nil
      return nil
    end
    if origin and subject_path then
      local ok = semantic_context.context_supports_subject(origin, subject_path)
      if not ok then
        state.window_contexts[winid] = nil
        return nil
      end
    end
    return origin
  end

  local function finish_progress(timer)
    close_timer(timer)
    if state.active_notice then
      pcall(state.active_notice.clear)
      state.active_notice = nil
    end
  end

  local function diagnostic_summary(response)
    local diagnostics = response and response.diagnostics
    if type(diagnostics) ~= "table" and response and type(response.contexts) == "table"
        and response.contexts[1] then
      diagnostics = response.contexts[1].diagnostics
    end
    if type(diagnostics) ~= "table" or #diagnostics == 0 then return "" end
    local first = tostring(diagnostics[1]):gsub("[\r\n]+", " ")
    if #first > 240 then first = first:sub(1, 237) .. "..." end
    return string.format("; %d diagnostic(s): %s", #diagnostics, first)
  end

  local function terminal_message(response)
    local state_name = response and response.state or "unavailable"
    if state_name == "ambiguous-context" then
      return "C++ definition needs an explicit translation-unit context"
    elseif state_name == "invalid-semantic-context" then
      return "C++ semantic context is invalid" .. diagnostic_summary(response)
    end
    return "C++ semantic definition unavailable: "
      .. tostring(response and response.reason or "unknown reason")
  end

  local function notify_terminal(response)
    if response and response.state == "resolved" then return end
    vim.notify(terminal_message(response),
      response and response.state == "unavailable" and vim.log.levels.WARN or vim.log.levels.INFO,
      { title = "C++ definition", timeout = 6000 })
  end

  local function wire_context(context, environment)
    local origin_tu = context.origin_tu
    local id = context.id or context.context_id or hash_text(vim.json.encode({
      environment.build_fingerprint, tostring(origin_tu or "")
    }))
    return {
      id = id,
      context_id = id,
      origin_tu = origin_tu,
      cdb_dir = context.cdb_dir or environment.cdb_dir,
      compile = context.compile,
      evidence_fingerprint = context.evidence_fingerprint,
      subject_membership = semantic_context.context_subject_membership(context),
    }
  end

  -- Query one OR MANY contexts in a single round trip.
  --
  -- The sidecar's `handle_query` already accepts `contexts` (plural), evaluates
  -- each one, groups the results by canonical identity (`by_identity`) and checks
  -- whether they agree on a single definition (`unique_definition_keys`). That is
  -- exactly the convergence a header needs -- and the client had never used it,
  -- always sending `{ single_context }`.
  --
  -- Consequence of that omission: whenever a header had more than one candidate
  -- origin TU, the client skipped straight to a chooser listing TU FILE NAMES.
  -- But a non-self-contained header being included by many TUs is normal, not
  -- ambiguity -- and the user cannot tell which `VulkanRHI_3.cpp` holds the
  -- definition of the symbol under the cursor. Reported symptom: "gd waits a long
  -- time, then pops a Module chooser", for a symbol with exactly ONE definition.
  --
  -- Passing every candidate lets the compiler decide, which is what C5 requires:
  -- identity comes from canonical USR agreement, never from picking a file.
  local function query_contexts(spec, contexts, callback)
    local snapshot, environment = spec.snapshot, spec.environment
    local wire = {}
    for _, context in ipairs(contexts) do
      wire[#wire + 1] = wire_context(context, environment)
    end
    client.request("query", {
      query = {
        path = spec.path,
        line = spec.line,
        column = spec.column,
        document_version = snapshot and snapshot.document_version or nil,
      },
      contexts = wire,
      overlays = client.collect_unsaved_overlays(environment),
    }, callback, environment)
  end

  local function query(spec, context, callback)
    return query_contexts(spec, { context }, callback)
  end

  function client.lookup_definition(spec, callback)
    local environment = spec.environment
    local cdb_paths = environment.semantic_cdb_paths or {}
    if #cdb_paths == 0 then
      for _, candidate in ipairs(environment.controlled_candidates or {}) do
        if candidate.background_cdb_path then
          cdb_paths[#cdb_paths + 1] = candidate.background_cdb_path
        end
      end
    end
    if #cdb_paths == 0 then
      vim.schedule(function()
        callback(unavailable("no-proven-module-contexts", "lookup-definition"))
      end)
      return
    end
    client.request("lookup-definition", {
      usr = spec.usr,
      subject = spec.path,
      cdb_paths = cdb_paths,
      overlays = client.collect_unsaved_overlays(environment),
      document_version = spec.snapshot and spec.snapshot.document_version or nil,
    }, callback, environment)
  end

  function client.resolve_header(spec, callback)
    spec.path = spec.path or spec.header
    local snapshot, environment = spec.snapshot, spec.environment
    local timer = vim.defer_fn(function()
      if not client.snapshot_is_current(snapshot) then return end
      local ok, ui = pcall(require, "utils.ue_goto.ui")
      if ok then
        state.active_notice = ui.progress_notice("⏳ resolving C++ header in translation-unit context ...")
      end
    end, PROGRESS_DELAY_MS)

    local function finish(response)
      finish_progress(timer)
      local current, stale_reason = client.snapshot_is_current(snapshot, response)
      if not current then
        emit_trace("stale", {
          request_id = response and response.id,
          context_id = response and response.context_id,
          provider = "libclang",
          terminal_state = response and response.state,
          stale_reason = stale_reason,
        })
        callback(nil, stale_reason)
        return
      end
      notify_terminal(response)
      callback(response)
    end

    local dispatch

    local function catalog_contexts(allow_select)
      client.request("catalog", {
        header = spec.path,
        cdb_dir = environment.cdb_dir,
        active_cdb_path = environment.active_cdb_path,
        active_manifest_path = environment.active_manifest_path,
        project_root = environment.project_root,
        engine_root = environment.engine_root,
        active_build_key = environment.active_build_key,
        active_build = environment.active_build,
        evidence_roots = environment.evidence_roots,
      }, function(catalog)
        local current, stale_reason = client.snapshot_is_current(snapshot)
        if not current then
          finish_progress(timer)
          emit_trace("stale", {
            request_id = catalog.id,
            provider = "sidecar",
            terminal_state = catalog.state,
            stale_reason = stale_reason,
          })
          callback(nil, stale_reason)
          return
        end
        local contexts = catalog.contexts or {}
        if catalog.state == "unavailable" or #contexts == 0 then
          finish(catalog)
        elseif #contexts == 1 or allow_select == false then
          dispatch(contexts[1], false)
        else
          -- CONVERGE FIRST, ASK ONLY IF THE COMPILER GENUINELY DISAGREES.
          --
          -- Several candidate origin TUs is the NORMAL state for a header that is
          -- included widely; it means "we have not decided which TU to evaluate
          -- in", not "this position denotes different entities". Prompting here
          -- outsourced our job to the user, and gave them TU file names as the
          -- only basis for a choice they cannot make.
          --
          -- So evaluate all candidates in one round trip and let the sidecar's
          -- existing identity grouping decide: if every context agrees on one
          -- canonical entity and one definition, it answers `resolved` and we jump
          -- straight there. It only returns `ambiguous-context` when the results
          -- really differ, which is the sole case worth asking about.
          query_contexts(spec, contexts, function(response)
            local still_current, why = client.snapshot_is_current(snapshot)
            if not still_current then
              finish_progress(timer)
              callback(nil, why)
              return
            end

            if response and response.state == "resolved" then
              -- Remember the proven TU so later navigations in this window skip
              -- the catalog entirely.
              local chosen = response.contexts and response.contexts[1] or nil
              if chosen then
                local lineage = vim.deepcopy(chosen)
                lineage.build_fingerprint = environment.build_fingerprint
                lineage.source_action_token = snapshot.token
                lineage.subject_membership = semantic_context.context_subject_membership(chosen)
                if #lineage.subject_membership == 0 then
                  lineage.subject_membership = { spec.path }
                end
                client.note_origin(snapshot.winid, lineage, environment.build_fingerprint)
              end
              finish(response)
              return
            end

            -- Genuine disagreement between proven contexts: this is the only
            -- situation where the user has something real to decide.
            if response and response.state == "ambiguous-context"
                and type(response.contexts) == "table" and #response.contexts > 1 then
              finish_progress(timer)
              vim.ui.select(response.contexts, {
                prompt = "Multiple proven contexts resolve differently",
                format_item = function(item)
                  -- Show WHAT differs (the target), not just which TU: the TU name
                  -- alone is not actionable information for the user.
                  local tu = tostring(item.label or vim.fn.fnamemodify(item.origin_tu or "", ":t"))
                  local def = item.definition
                  if type(def) == "table" and def.path then
                    return ("%s  →  %s:%s"):format(
                      tu,
                      vim.fn.fnamemodify(tostring(def.path), ":t"),
                      tostring(def.line or "?"))
                  end
                  return tu
                end,
              }, function(choice)
                if not choice then
                  notify_terminal(response)
                  callback(response)
                  return
                end
                dispatch(choice, false)
              end)
              return
            end

            -- Could not converge and disagreement was not proven: fail honestly
            -- rather than handing back a list of TUs as if it were an answer (P12).
            finish(response or catalog)
          end)
        end
      end, environment)
    end

    dispatch = function(context, allow_recatalog)
      query(spec, context, function(response)
        if response and response.reason == "invalid-query-file-not-in-tu" and allow_recatalog then
          state.window_contexts[snapshot.winid] = nil
          catalog_contexts(true)
          return
        end
        if response and response.state == "resolved" then
          local lineage = vim.deepcopy(context)
          lineage.build_fingerprint = environment.build_fingerprint
          lineage.source_action_token = snapshot.token
          lineage.subject_membership = semantic_context.context_subject_membership(context)
          if #lineage.subject_membership == 0 then
            lineage.subject_membership = { spec.path }
          end
          client.note_origin(snapshot.winid, lineage, environment.build_fingerprint)
        end
        finish(response)
      end)
    end

    local inherited = client.window_origin(snapshot.winid, environment.build_fingerprint, spec.path)
    if inherited and inherited.origin_tu then
      dispatch(inherited, true)
      return
    end

    if #environment.evidence_roots == 0 then
      finish(unavailable("no active build dependency roots", "catalog"))
      return
    end
    catalog_contexts(true)
  end

  function client.prove_source(spec, callback)
    local env = spec.environment
    local context_id = hash_text(vim.json.encode({ env.build_fingerprint, spec.source }))
    client.request("prove", {
      source = spec.source,
      cdb_dir = env.cdb_dir,
      cdb_path = env.cdb_path,
      active_cdb_path = env.active_cdb_path,
      active_manifest_path = env.active_manifest_path,
      context_id = context_id,
    }, function(proof)
      if not proof or proof.state ~= "resolved" then
        callback(proof)
        return
      end
      local origin_context = {
        id = proof.context_id,
        context_id = proof.context_id,
        origin_tu = proof.origin_tu,
        cdb_dir = env.cdb_dir,
        compile = proof.compile,
      }
      query({
        snapshot = spec.snapshot,
        environment = env,
        path = spec.source,
        line = spec.line,
        column = spec.column,
      }, origin_context, function(entity)
        if not entity or entity.state ~= "resolved" then
          callback(entity or proof)
          return
        end
        entity.origin_tu = proof.origin_tu
        entity.compile = proof.compile
        entity.compile_command_fingerprint = proof.compile_command_fingerprint
        entity.origin_context = origin_context
        callback(entity)
      end)
    end, env)
  end

  local function reset()
    for _, id in ipairs(state.action_autocmds) do pcall(vim.api.nvim_del_autocmd, id) end
    state.window_contexts = {}
    state.active_notice = nil
    state.action_autocmds = {}
  end

  return {
    reset = reset,
    TERMINAL = TERMINAL,
  }
end

return M
