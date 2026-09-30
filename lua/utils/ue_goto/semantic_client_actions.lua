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
  local emit_trace = deps.emit_trace
  local unavailable = deps.unavailable

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
    if type(client.cancel_queued_actions) == "function" then client.cancel_queued_actions() end
    local cleanups = state.action_cleanups or {}
    state.action_cleanups = {}
    for _, cleanup in pairs(cleanups) do pcall(cleanup) end
  end

  function client.add_action_cleanup(snapshot, cleanup)
    if snapshot and snapshot.token == state.active_action_token then
      state.action_cleanups = state.action_cleanups or {}
      local registration = {}
      state.action_cleanups[registration] = cleanup
      return function() state.action_cleanups[registration] = nil end
    end
    return nil
  end

  function client.set_action_cleanup(snapshot, cleanup)
    return client.add_action_cleanup(snapshot, cleanup) ~= nil
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
    if snapshot.overlay_environment and not vim.deep_equal(snapshot.overlay_versions,
        client.overlay_versions(snapshot.overlay_environment)) then
      return false, "overlays-changed"
    end
    for _, version in ipairs(snapshot.dependency_versions or {}) do
      if not vim.api.nvim_buf_is_valid(version.bufnr)
          or vim.api.nvim_buf_get_changedtick(version.bufnr) ~= version.version
          or vim.fs.normalize(vim.api.nvim_buf_get_name(version.bufnr)) ~= version.path then
        return false, "overlays-changed"
      end
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

  function client.overlay_versions(environment, include_unmodified)
    local versions = {}
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
          and (include_unmodified or vim.bo[bufnr].modified) and is_cpp_buffer(bufnr) then
        local path = vim.api.nvim_buf_get_name(bufnr)
        if path ~= "" and (under(path, environment.engine_root)
            or under(path, environment.project_root)) then
          versions[#versions + 1] = {
            bufnr = bufnr,
            path = vim.fs.normalize(path),
            version = vim.api.nvim_buf_get_changedtick(bufnr),
          }
        end
      end
    end
    table.sort(versions, function(a, b) return a.path:lower() < b.path:lower() end)
    return versions
  end

  function client.collect_unsaved_overlays(environment)
    local overlays = {}
    for _, version in ipairs(client.overlay_versions(environment)) do
      overlays[#overlays + 1] = {
        path = version.path,
        version = version.version,
        contents = table.concat(vim.api.nvim_buf_get_lines(version.bufnr, 0, -1, false), "\n") .. "\n",
      }
    end
    return overlays
  end

  function client.capture_overlays(snapshot, environment)
    if not snapshot then return client.collect_unsaved_overlays(environment) end
    if not snapshot.overlays then
      snapshot.overlay_environment = {
        engine_root = environment.engine_root,
        project_root = environment.project_root,
      }
      snapshot.overlay_versions = client.overlay_versions(snapshot.overlay_environment)
      snapshot.dependency_versions = client.overlay_versions(snapshot.overlay_environment, true)
      snapshot.overlays = client.collect_unsaved_overlays(snapshot.overlay_environment)
    end
    return snapshot.overlays
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
    return origin and vim.deepcopy(origin) or nil
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
      overlays = client.capture_overlays(snapshot, environment),
    }, callback, environment, snapshot)
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
      overlays = client.capture_overlays(spec.snapshot, environment),
      document_version = spec.snapshot and spec.snapshot.document_version or nil,
    }, callback, environment, spec.snapshot)
  end

  function client.resolve_header(spec, callback)
    spec = vim.tbl_extend("force", spec, { path = spec.path or spec.header })
    local snapshot, environment = spec.snapshot, spec.environment
    client.capture_overlays(snapshot, environment)
    local function snapshot_current(response)
      local current, reason = client.snapshot_is_current(snapshot, response)
      if not current then return false, reason end
      if environment.index then return client.index_snapshot_is_current(environment.index, snapshot.bufnr) end
      return true
    end

    local function finish(response, context)
      local current, reason = snapshot_current(response)
      if not current then
        emit_trace("stale", { request_id = response and response.id, provider = "libclang", stale_reason = reason })
        callback(nil, reason)
        return
      end
      if response and response.state == "resolved" and context then
        local lineage = vim.deepcopy(context)
        lineage.build_fingerprint = environment.build_fingerprint
        lineage.source_action_token = snapshot.token
        lineage.subject_membership = semantic_context.context_subject_membership(context)
        if #lineage.subject_membership == 0 then lineage.subject_membership = { spec.path } end
        response = vim.tbl_extend("force", response, { origin_context = lineage })
      end
      callback(response)
    end

    local dispatch, catalog_contexts
    catalog_contexts = function()
      client.request("catalog", {
        header = spec.path, cdb_dir = environment.cdb_dir,
        active_cdb_path = environment.active_cdb_path, active_manifest_path = environment.active_manifest_path,
        project_root = environment.project_root, engine_root = environment.engine_root,
        active_build_key = environment.active_build_key, active_build = environment.active_build,
        evidence_roots = environment.evidence_roots,
      }, function(catalog)
        if not snapshot_current() then finish(catalog); return end
        local contexts = catalog and catalog.contexts or {}
        if not catalog or catalog.state == "unavailable" or #contexts == 0 then finish(catalog); return end
        if #contexts == 1 then dispatch(contexts[1], false); return end
        local function original_context(result)
          for _, context in ipairs(contexts) do
            if (context.id or context.context_id) == result.context_id
                or context.origin_tu == result.origin_tu then return context end
          end
        end
        query_contexts(spec, contexts, function(response)
          if not snapshot_current(response) then finish(response); return end
          if response and response.state == "resolved" then
            finish(response, original_context(response))
          elseif response and response.state == "ambiguous-context"
              and type(response.contexts) == "table" and #response.contexts > 1
              and type(spec.choose_context) == "function" then
            spec.choose_context(response.contexts, function(choice)
              if not snapshot_current() or not choice then finish(response); return end
              dispatch(original_context(choice) or choice, false)
            end)
          else
            finish(response or catalog)
          end
        end)
      end, environment, snapshot)
    end

    dispatch = function(context, allow_recatalog)
      query(spec, context, function(response)
        if not snapshot_current(response) then finish(response); return end
        if response and response.reason == "invalid-query-file-not-in-tu" and allow_recatalog then
          state.window_contexts[snapshot.winid] = nil
          catalog_contexts()
          return
        end
        finish(response, context)
      end)
    end

    local inherited = client.window_origin(snapshot.winid, environment.build_fingerprint, spec.path)
    if inherited and inherited.origin_tu then dispatch(inherited, true); return end
    if #environment.evidence_roots == 0 then
      finish(unavailable("no active build dependency roots", "catalog"))
      return
    end
    catalog_contexts()
  end

  function client.prove_source(spec, callback)
    local env = spec.environment
    client.capture_overlays(spec.snapshot, env)
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
    end, env, spec.snapshot)
  end

  local function reset()
    for _, id in ipairs(state.action_autocmds) do pcall(vim.api.nvim_del_autocmd, id) end
    state.window_contexts = {}
    state.action_cleanups = {}
    state.next_action_token = 0
    state.active_action_token = 0
    state.action_autocmds = {}
  end

  return {
    reset = reset,
    TERMINAL = TERMINAL,
  }
end

return M
