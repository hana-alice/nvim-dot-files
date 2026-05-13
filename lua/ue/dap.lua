-- ue/dap.lua — host-side DAP glue (post-codelldb migration).
--
-- This module wires nvim-dap + nvim-dap-ui to lldb-dap and provides the
-- DAP*-prefixed user commands. Per-platform attach/launch logic lives in
-- ue/dap/{android,win64,linux,mac,ios}.lua.
--
-- What's gone (vs the pre-migration 2424-line version):
--   * codelldb adapter wiring (now: dap.adapters.lldb via _common.ensure_adapter)
--   * Hand-written breakpoint specs (`_dap_make_breakpoint_spec` /
--     `_dap_try_set_breakpoint` / `_dap_clear_breakpoint`) — lldb-dap natively
--     speaks DAP `setBreakpoints`, so nvim-dap's own toggle/persistence works.
--   * ASLR fix-up listeners (`_setup_aslr_listeners` / `_apply_aslr_fix` /
--     `_reapply_breakpoints`) — codelldb attached via raw gdb-remote and
--     missed module-load events; lldb-dap drives lldb's own attach machinery
--     and gets correct module bases for free.
--   * `long_path()` / 8.3 short-path expansion — only existed to dodge a
--     codelldb URL parser bug.
--   * `aslr_trace.log` debug instrumentation.
--   * `kill_managed_codelldb_processes` — lldb-dap exits cleanly on disconnect.
--   * `UEDapBreakpoint` sign — nvim-dap's default `DapBreakpoint` is fine now.
--   * Android `_android_dap_config` / `_android_preflight_ps1` /
--     `_android_launch_preflight_ps1` / `android_dap_attach` /
--     `android_dap_launch` — all moved to ue.dap.android with a clean API.

local D = {}

-- Upstream utilities — set by D.setup_core() from ue.lua.
local core = {}

-- ─────────────────────────────────────────────────────────────────────
-- Module state.
-- ─────────────────────────────────────────────────────────────────────
-- Kept on D so logcat / source path rewriter / ue.lua status cache can
-- read pid / serial / engine_root / project_root.
D._dap_session_state         = {}
D._dap_attach_in_progress    = false
D._dap_run_state             = "idle"   -- idle | attaching | stopped | running | resuming
D._continue_pending          = false
D._continue_debounce_until_ms = 0
D._pause_pending             = false
D._dap_source_file_cache     = {}

-- ─────────────────────────────────────────────────────────────────────
-- Helpers.
-- ─────────────────────────────────────────────────────────────────────

local function mono_ms()
  local uv = vim.uv or vim.loop
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1e6)
  end
  return math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
end

local function is_sigstop_stop(body)
  if type(body) ~= "table" then return false end
  local text = table.concat({
    tostring(body.reason or ""),
    tostring(body.description or ""),
    tostring(body.text or ""),
  }, " "):lower()
  return text:find("sigstop", 1, true) ~= nil
end

local function frame_has_local_source(frame)
  local source = frame and frame.source or nil
  if not source then return false end
  if tonumber(source.sourceReference or 0) ~= 0 then return false end
  local path = core.norm(source.path or "")
  if path == "" or path:match("^[a-z]+://") then return false end
  local cache = D._dap_source_file_cache or {}
  local cached = cache[path]
  if cached == nil then
    cached = core.is_file(path)
    cache[path] = cached
    D._dap_source_file_cache = cache
  end
  return cached
end

local function pick_local_source_frame(frames)
  for _, frame in ipairs(frames or {}) do
    if frame_has_local_source(frame) then return frame end
  end
  return nil
end

local function maybe_jump_to_local_source_frame(session, body)
  if not session or D._dap_attach_in_progress or is_sigstop_stop(body) then return end
  if frame_has_local_source(session.current_frame) then return end
  local thread_id = (body and body.threadId) or session.stopped_thread_id
  if not thread_id then return end
  local thread = session.threads and session.threads[thread_id] or nil
  local cached = thread and thread.frames or nil
  if cached and #cached > 0 then
    local f = pick_local_source_frame(cached)
    if f then
      if type(session._frame_set) == "function" then session:_frame_set(f); return end
      vim.cmd("edit " .. vim.fn.fnameescape(core.norm(f.source.path)))
      vim.api.nvim_win_set_cursor(0, { f.line or 1, math.max((f.column or 1) - 1, 0) })
    end
    return
  end
  session:request("stackTrace", { threadId = thread_id, startFrame = 0, levels = 20 },
    function(err, response)
      if err or not response then return end
      local frames = response.stackFrames or {}
      local f = pick_local_source_frame(frames)
      if not f then return end
      vim.schedule(function()
        if type(session._frame_set) == "function" then session:_frame_set(f); return end
        vim.cmd("edit " .. vim.fn.fnameescape(core.norm(f.source.path)))
        vim.api.nvim_win_set_cursor(0, { f.line or 1, math.max((f.column or 1) - 1, 0) })
      end)
    end)
end

local function request_dap_continue(dap)
  local session = dap and dap.session and dap.session() or nil
  if not session then return false end
  D._continue_pending = true
  D._dap_run_state = "resuming"
  D._continue_debounce_until_ms = mono_ms() + 750
  local ok, err = pcall(dap.continue)
  if ok then return true end
  D._continue_pending = false
  D._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  D._continue_debounce_until_ms = 0
  vim.notify("Continue failed: " .. tostring(err), vim.log.levels.WARN)
  return false
end

local function reset_session_state()
  D._dap_attach_in_progress    = false
  D._dap_run_state             = "idle"
  D._continue_pending          = false
  D._continue_debounce_until_ms = 0
  D._pause_pending             = false
  D._dap_source_file_cache     = {}
  D._dap_session_state         = {}
end

-- ─────────────────────────────────────────────────────────────────────
-- Public probes / config helpers.
-- ─────────────────────────────────────────────────────────────────────

local function ue_cfg_get(key)
  local ok, cfg = pcall(require, "ue.config")
  if ok and cfg and cfg.get then return cfg.get(key) end
  return nil
end

--- Resolve an Android package name without prompting unless necessary.
function D._pick_android_package_for_test(state_value)
  local saved = state_value or ""
  if saved ~= "" then return saved end
  local cfg_pkg = ue_cfg_get("dap.android_package")
  if type(cfg_pkg) == "string" and cfg_pkg ~= "" then return cfg_pkg end
  return vim.fn.input("Android package name: ", "")
end

--- Resolve the path to an arm64 lldb-server. Headless smoke uses this.
function D._pick_lldb_server_for_test(globs)
  local cfg_path = ue_cfg_get("dap.android_lldb_server")
  if type(cfg_path) == "string" and cfg_path ~= "" and vim.fn.filereadable(cfg_path) == 1 then
    return cfg_path
  end
  for _, pattern in ipairs(globs or {}) do
    local hit = vim.fn.glob(pattern)
    if hit and hit ~= "" then return hit end
  end
  return vim.fn.input("Path to arm64 lldb-server: ")
end

--- Resolve an lldb-dap adapter path. Returns absolute path or nil.
function D.lldb_dap_path()
  return require("ue.dap._common").find_lldb_dap()
end

--- Strip Globals / Static scopes (massive variable trees that hang dap-ui).
function D._dap_filter_scopes(scope_resp)
  if type(scope_resp) ~= "table" or type(scope_resp.scopes) ~= "table" then
    return scope_resp
  end
  for i = #scope_resp.scopes, 1, -1 do
    local scope = scope_resp.scopes[i]
    local name = core.trim(scope and scope.name or "")
    if name == "Globals" or name == "Static" then
      table.remove(scope_resp.scopes, i)
    end
  end
  return scope_resp
end

-- ─────────────────────────────────────────────────────────────────────
-- nvim-dap loaders.
-- ─────────────────────────────────────────────────────────────────────

function D.ensure_dap_loaded()
  local ok, dap = pcall(require, "dap")
  if ok then return true, dap end
  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok and lazy and type(lazy.load) == "function" then
    lazy.load({ plugins = { "nvim-dap", "nvim-dap-ui", "nvim-nio" } })
  end
  ok, dap = pcall(require, "dap")
  if not ok then
    require("utils.log").notify_error("dap", "nvim-dap not available")
    return false, nil
  end
  return true, dap
end

function D.ensure_dapui_loaded()
  local ok, dapui = pcall(require, "dapui")
  if ok then return true, dapui end
  if not D.ensure_dap_loaded() then return false, nil end
  ok, dapui = pcall(require, "dapui")
  if not ok then
    require("utils.log").notify_error("dap", "nvim-dap-ui not available")
    return false, nil
  end
  return true, dapui
end

-- ─────────────────────────────────────────────────────────────────────
-- Breakpoint / step / continue / pause user commands.
-- ─────────────────────────────────────────────────────────────────────

--- Toggle a breakpoint at the cursor. Forwards to nvim-dap's native toggle —
--- lldb-dap handles `setBreakpoints` natively, so this Just Works™.
function D.dap_toggle_breakpoint()
  local ok, dap = D.ensure_dap_loaded()
  if not ok then return end
  dap.toggle_breakpoint()
end

function D.dap_continue()
  local ok, dap = D.ensure_dap_loaded()
  if not ok then return end
  if not dap.session() then
    -- No session yet: hand off to nvim-dap's continue() which will pop the
    -- configuration picker (debug existing config / new launch). This keeps
    -- F5 useful before any attach has happened.
    dap.continue()
    return
  end
  if D._dap_attach_in_progress then
    vim.notify("Attach bootstrap still running; wait for READY", vim.log.levels.DEBUG)
    return
  end
  local now = mono_ms()
  if D._dap_run_state ~= "stopped" and now < (D._continue_debounce_until_ms or 0) then
    return
  end
  if D._continue_pending or D._dap_run_state == "resuming" then return end
  local session = dap.session()
  local is_stopped = D._dap_run_state == "stopped"
    or (session.stopped_thread_id and D._dap_run_state ~= "running" and D._dap_run_state ~= "attaching")
  if is_stopped then
    request_dap_continue(dap)
  else
    D._continue_debounce_until_ms = now + 250
    vim.notify("Process already running", vim.log.levels.DEBUG)
  end
end

function D.dap_pause()
  local ok, dap = D.ensure_dap_loaded()
  if not ok or not dap.session() then return end
  if D._pause_pending then return end
  D._pause_pending = true
  vim.defer_fn(function() D._pause_pending = false end, 500)
  local session = dap.session()
  session:request("pause", { threadId = 0 }, function(err)
    if err then
      session:request("threads", {}, function(terr, tresp)
        if not terr and tresp and tresp.threads and tresp.threads[1] then
          session:request("pause", { threadId = tresp.threads[1].id })
        else
          vim.schedule(function()
            require("utils.log").notify_error("dap.pause", "Pause failed: " .. tostring(err))
          end)
        end
      end)
    end
  end)
end

function D.dap_step_over()
  local ok, dap = D.ensure_dap_loaded()
  if ok and dap.session() then dap.step_over() end
end

function D.dap_step_into()
  local ok, dap = D.ensure_dap_loaded()
  if ok and dap.session() then dap.step_into() end
end

function D.dap_step_out()
  local ok, dap = D.ensure_dap_loaded()
  if ok and dap.session() then dap.step_out() end
end

-- ─────────────────────────────────────────────────────────────────────
-- UI / layout commands.
-- ─────────────────────────────────────────────────────────────────────

function D.dap_toggle_ui()
  local ok, dapui = D.ensure_dapui_loaded()
  if not ok then return end
  dapui.toggle()
end

function D.dap_reset_layout()
  local dap_ok, dap = D.ensure_dap_loaded()
  local dapui_ok, dapui = D.ensure_dapui_loaded()
  if dap_ok and dap.session() and dapui_ok then
    dapui.close()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local bt = vim.bo[buf].buftype
        if bt == "nofile" or bt == "prompt" then
          local ft = vim.bo[buf].filetype
          if ft:find("^dap") then pcall(vim.api.nvim_win_close, win, true) end
        end
      end
    end
    vim.cmd("wincmd =")
    dapui.open({ reset = true })
  else
    vim.cmd("only")
    vim.cmd("wincmd =")
  end
end

function D.dap_toggle_repl()
  local ok, dap = D.ensure_dap_loaded()
  if ok then dap.repl.toggle() end
end

-- ─────────────────────────────────────────────────────────────────────
-- Diagnostic command.
-- ─────────────────────────────────────────────────────────────────────

--- Dump LLDB state into a scratch buffer (image list / source-map / target list).
--- Uses nvim-dap's native eval — no custom REPL plumbing needed.
function D.dap_diagnose()
  local dap_ok, dap = D.ensure_dap_loaded()
  if not dap_ok or not dap.session() then
    vim.notify("No DAP session", vim.log.levels.WARN)
    return
  end
  local session = dap.session()
  local results = {}
  local pending = 3
  local function collect(label, ok, data)
    results[#results + 1] = ok and (("=== %s ===\n%s"):format(label, data or ""))
                              or  (("=== %s ===\n(failed)"):format(label))
    pending = pending - 1
    if pending <= 0 then
      vim.schedule(function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(table.concat(results, "\n\n"), "\n"))
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].filetype = "log"
        vim.cmd("botright split")
        vim.api.nvim_win_set_buf(0, buf)
      end)
    end
  end
  -- lldb-dap responds to DAP `evaluate` with context="repl" and runs the
  -- string as an lldb command.
  local function eval(cmd, label)
    session:request("evaluate", { expression = "`" .. cmd, context = "repl" },
      function(err, resp)
        collect(label, not err and resp and resp.result ~= nil,
                resp and resp.result or tostring(err))
      end)
  end
  eval("image list",                           "image list")
  local state = D._dap_session_state or {}
  local so_name = state.symbol_lib and vim.fn.fnamemodify(state.symbol_lib, ":t") or "libUE4.so"
  eval(('image dump symfile "%s"'):format(so_name), "symfile " .. so_name)
  eval("settings show target.source-map",      "source-map")
end

-- ─────────────────────────────────────────────────────────────────────
-- Android-debugger lifecycle (forwarded to ue.dap.android).
-- ─────────────────────────────────────────────────────────────────────

--- Stop the active Android DAP session — disconnect, kill remote
--- lldb-server, remove adb forward, clear state. Called from ue.lua's
--- build-android post-step (see ue.lua:6446).
---@return { disconnected: boolean, adapter_killed: boolean, orphan_killed: integer }
function D.stop_android_debugger(opts)
  local ok, android = pcall(require, "ue.dap.android")
  local result
  if ok and type(android.stop_android_debugger) == "function" then
    result = android.stop_android_debugger(opts)
  else
    result = { disconnected = false, adapter_killed = false, orphan_killed = 0 }
  end
  reset_session_state()
  return result
end

-- Convenience pass-throughs so ue.lua's existing UEDAPAttach/UEDAPLaunch
-- command bodies can keep calling M.android_dap_attach() / M.android_dap_launch().
function D.android_dap_attach(_opts)
  local ok, android = pcall(require, "ue.dap.android")
  if not ok then
    require("utils.log").notify_error("dap", "ue.dap.android not loadable")
    return
  end
  local ctx
  if type(core.resolve_context) == "function" then
    local ok_ctx, c = pcall(core.resolve_context)
    if ok_ctx then ctx = c end
  end
  android.attach({ context = ctx })
end

function D.android_dap_launch(_opts)
  local ok, android = pcall(require, "ue.dap.android")
  if not ok then
    require("utils.log").notify_error("dap", "ue.dap.android not loadable")
    return
  end
  local ctx
  if type(core.resolve_context) == "function" then
    local ok_ctx, c = pcall(core.resolve_context)
    if ok_ctx then ctx = c end
  end
  android.launch({ context = ctx })
end

-- ─────────────────────────────────────────────────────────────────────
-- setup_dap — wire dap-ui listeners, logcat, source-path rewrite,
-- scope filter, VimLeavePre cleanup. Called by lua/plugins/dap.lua.
-- ─────────────────────────────────────────────────────────────────────

function D.setup_dap(dap, dapui)
  -- Wire the lldb-dap adapter (may be re-wired later when find_lldb_dap
  -- result changes due to PATH updates).
  local adapter = D.lldb_dap_path()
  if not adapter then
    vim.notify("lldb-dap not found. Install LLVM 18+ to enable DAP debugging.",
               vim.log.levels.WARN)
    return
  end
  require("ue.dap._common").ensure_adapter(dap, adapter)

  -- ─── window / layout save & restore ───────────────────────────────
  local saved_win, saved_buf
  local function save_layout()
    if not saved_win then
      saved_win = vim.api.nvim_get_current_win()
      saved_buf = vim.api.nvim_get_current_buf()
    end
  end
  local function restore_layout()
    dapui.close()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local bt = vim.bo[buf].buftype
        local ft = vim.bo[buf].filetype
        if bt == "nofile" or ft:find("^dap") then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    if saved_win and vim.api.nvim_win_is_valid(saved_win) then
      pcall(vim.api.nvim_set_current_win, saved_win)
    elseif saved_buf and vim.api.nvim_buf_is_valid(saved_buf) then
      pcall(vim.cmd, "buffer " .. saved_buf)
    end
    saved_win, saved_buf = nil, nil
    vim.cmd("wincmd =")
  end

  local function close_explorer()
    local ok_snacks, snacks = pcall(require, "snacks")
    if ok_snacks and snacks.picker and snacks.picker.get then
      for _, picker in ipairs(snacks.picker.get({ source = "explorer" }) or {}) do
        pcall(function() picker:close() end)
      end
    end
  end

  -- ─── logcat side-panel (Android sessions only) ────────────────────
  local logcat_buf, logcat_job

  local function stop_logcat()
    if logcat_job then pcall(vim.fn.jobstop, logcat_job); logcat_job = nil end
    if logcat_buf and vim.api.nvim_buf_is_valid(logcat_buf) then
      for _, win in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == logcat_buf then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
      pcall(vim.api.nvim_buf_delete, logcat_buf, { force = true })
      logcat_buf = nil
    end
  end

  local function start_logcat()
    stop_logcat()
    local state = D._dap_session_state or {}
    local pid, adb, serial = state.pid, state.adb or "adb", state.serial or ""
    if not pid or pid == "" then return end
    logcat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[logcat_buf].buftype = "nofile"
    vim.bo[logcat_buf].bufhidden = "wipe"
    vim.bo[logcat_buf].filetype = "log"
    vim.api.nvim_buf_set_name(logcat_buf, "logcat:" .. pid)
    local cmd = { adb }
    if serial ~= "" then vim.list_extend(cmd, { "-s", serial }) end
    vim.list_extend(cmd, { "logcat", "--pid=" .. pid })
    local buf = logcat_buf
    logcat_job = vim.fn.jobstart(cmd, {
      on_stdout = function(_, data)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local lines = {}
        for _, line in ipairs(data) do
          if line ~= "" then lines[#lines + 1] = line end
        end
        if #lines > 0 then
          vim.schedule(function()
            if not vim.api.nvim_buf_is_valid(buf) then return end
            vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)
            for _, win in ipairs(vim.api.nvim_list_wins()) do
              if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
                local lc = vim.api.nvim_buf_line_count(buf)
                pcall(vim.api.nvim_win_set_cursor, win, { lc, 0 })
              end
            end
          end)
        end
      end,
      on_stderr = function() end,
      on_exit = function() logcat_job = nil end,
    })
  end

  local function open_logcat_window()
    if not logcat_buf or not vim.api.nvim_buf_is_valid(logcat_buf) then return end
    local target_win
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local ft = vim.bo[vim.api.nvim_win_get_buf(win)].filetype
        if ft == "dap-repl" or ft == "dapui_console" then
          target_win = win
          break
        end
      end
    end
    if target_win then
      vim.api.nvim_set_current_win(target_win)
      vim.cmd("vertical rightbelow split")
      vim.api.nvim_win_set_buf(0, logcat_buf)
      vim.wo.number = false
      vim.wo.relativenumber = false
      vim.wo.signcolumn = "no"
      vim.wo.wrap = false
    end
  end

  -- ─── source-path rewrite (relative LLDB paths → absolute) ─────────
  local source_path_cache = {}
  local function resolve_source_path(rel_path)
    if not rel_path or rel_path == "" then return nil end
    local cached = source_path_cache[rel_path]
    if cached ~= nil then return cached or nil end
    if rel_path:match("^[A-Za-z]:") or rel_path:match("^/") then
      local p = core.norm(rel_path)
      if core.is_file(p) then source_path_cache[rel_path] = p; return p end
      source_path_cache[rel_path] = false; return nil
    end
    local state = D._dap_session_state or {}
    local prefixes = {}
    local er = state.engine_root or ""
    if er ~= "" then
      prefixes[#prefixes + 1] = er .. "/Engine/Source"
      prefixes[#prefixes + 1] = er .. "/Engine"
      prefixes[#prefixes + 1] = er
    end
    local pr = state.project_root or ""
    if pr ~= "" then
      prefixes[#prefixes + 1] = pr .. "/Source"
      prefixes[#prefixes + 1] = pr
    end
    prefixes[#prefixes + 1] = vim.fn.getcwd()
    for _, prefix in ipairs(prefixes) do
      local cand = core.norm(prefix .. "/" .. rel_path)
      if core.is_file(cand) then source_path_cache[rel_path] = cand; return cand end
    end
    source_path_cache[rel_path] = false
    return nil
  end

  -- ─── nvim-dap listeners ───────────────────────────────────────────
  local function on_session_end()
    stop_logcat()
    restore_layout()
    source_path_cache = {}
    -- Hand cleanup of remote lldb-server / adb forward to ue.dap.android.
    local ok, android = pcall(require, "ue.dap.android")
    if ok and android.cleanup then
      pcall(android.cleanup, D._dap_session_state)
    end
    reset_session_state()
  end

  dap.listeners.after.event_initialized["dapui_config"] = function()
    close_explorer()
    save_layout()
    dapui.open()
    start_logcat()
    vim.defer_fn(open_logcat_window, 200)
  end
  dap.listeners.before.event_terminated["dapui_config"] = function() on_session_end() end
  dap.listeners.before.event_exited["dapui_config"]     = function() on_session_end() end
  dap.listeners.after.disconnect["dapui_config"]        = function() on_session_end() end

  dap.listeners.after.event_initialized["ue-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    D._dap_run_state = D._dap_attach_in_progress and "attaching" or "stopped"
  end
  dap.listeners.after.event_stopped["ue-dap-run-state"] = function(session, body)
    if dap.session() ~= session then return end
    D._dap_run_state = "stopped"
    D._continue_pending = false
    D._continue_debounce_until_ms = 0
    D._pause_pending = false
    -- Auto-continue on signal stops that aren't breakpoints (Android sends
    -- stray SIGSTOP/SIGSEGV on unrelated threads — Chrome_IOThread, Signal
    -- Catcher, …). Stopping on them freezes the app and confuses the user.
    if not D._dap_attach_in_progress then
      body = body or {}
      local reason = tostring(body.reason or ""):lower()
      local has_bp = body.hitBreakpointIds and #body.hitBreakpointIds > 0
      if reason == "exception" and not has_bp then
        vim.defer_fn(function()
          if dap.session() == session and D._dap_run_state == "stopped" then
            request_dap_continue(dap)
          end
        end, 50)
      end
    end
  end
  dap.listeners.after.event_continued["ue-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    D._dap_run_state = "running"
    D._continue_pending = false
    session.current_frame = nil
    session.stopped_thread_id = nil
  end
  dap.listeners.after["continue"]["ue-dap-run-state"] = function(session, err)
    if dap.session() ~= session or not err then return end
    D._continue_pending = false
    D._continue_debounce_until_ms = 0
    D._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  end
  dap.listeners.after.event_stopped["ue-dap-source-nav"] = function(session, body)
    if dap.session() ~= session then return end
    maybe_jump_to_local_source_frame(session, body)
  end

  dap.listeners.before.scopes["ue_block_globals"] = function(_, _, body)
    D._dap_filter_scopes(body)
  end

  dap.listeners.before.stackTrace["ue_source_path_rewrite"] = function(_, err, response)
    if err or not response or not response.stackFrames then return end
    for _, frame in ipairs(response.stackFrames) do
      local source = frame.source
      if source and source.path then
        local resolved = resolve_source_path(source.path)
        if resolved then source.path = resolved end
      end
    end
  end

  -- ─── signs ────────────────────────────────────────────────────────
  vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
  vim.fn.sign_define("DapStopped",    { text = "▶", texthl = "DiagnosticInfo", linehl = "CursorLine" })

  -- ─── VimLeavePre: detach + cleanup, but NEVER kill the debuggee ───
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ue_dap_cleanup", { clear = true }),
    callback = function()
      local session = dap.session()
      if session then
        pcall(function()
          session:request("disconnect", { terminateDebuggee = false })
        end)
      end
      local ok, android = pcall(require, "ue.dap.android")
      if ok and android.cleanup then
        pcall(android.cleanup, D._dap_session_state)
      end
      reset_session_state()
    end,
  })
end

--- Inject upstream core utilities. Called once from ue.lua.
function D.setup_core(core_table)
  core = core_table
end

return D
