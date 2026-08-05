local M = {}

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
    local context
    if type(origin_tu) == "table" then
      context = vim.deepcopy(origin_tu)
      context.build_fingerprint = build_fingerprint or context.build_fingerprint
    else
      context = {
        origin_tu = origin_tu,
        id = context_id,
        context_id = context_id,
        build_fingerprint = build_fingerprint,
      }
    end
    state.window_contexts[winid] = context
  end

  function client.window_origin(winid, build_fingerprint)
    winid = winid or vim.api.nvim_get_current_win()
    local origin = state.window_contexts[winid]
    if origin and origin.build_fingerprint ~= build_fingerprint then
      state.window_contexts[winid] = nil
      return nil
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
    }
  end

  local function query(spec, context, callback)
    local snapshot, environment = spec.snapshot, spec.environment
    local request_context = wire_context(context, environment)
    client.request("query", {
      query = {
        path = spec.path,
        line = spec.line,
        column = spec.column,
        document_version = snapshot.document_version,
      },
      contexts = { request_context },
      overlays = client.collect_unsaved_overlays(environment),
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

    local function dispatch(context)
      query(spec, context, function(response)
        if response and response.state == "resolved" then
          context.build_fingerprint = environment.build_fingerprint
          client.note_origin(snapshot.winid, context, environment.build_fingerprint)
        end
        finish(response)
      end)
    end

    local inherited = client.window_origin(snapshot.winid, environment.build_fingerprint)
    if inherited and inherited.origin_tu then
      dispatch(inherited)
      return
    end

    if #environment.evidence_roots == 0 then
      finish(unavailable("no active build dependency roots", "catalog"))
      return
    end
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
      elseif #contexts == 1 then
        dispatch(contexts[1])
      else
        finish_progress(timer)
        vim.ui.select(contexts, {
          prompt = "Select proven translation-unit context",
          format_item = function(item)
            return tostring(item.label or vim.fn.fnamemodify(item.origin_tu or "", ":t"))
          end,
        }, function(choice)
          if not choice then
            notify_terminal(catalog)
            callback(catalog)
            return
          end
          dispatch(choice)
        end)
      end
    end, environment)
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
      if proof and proof.state == "resolved" then
        proof.origin_context = {
          id = proof.context_id,
          context_id = proof.context_id,
          origin_tu = proof.origin_tu,
          cdb_dir = env.cdb_dir,
          compile = proof.compile,
        }
      end
      callback(proof)
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
