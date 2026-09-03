-- ue/dap.lua — host-side DAP glue (post-codelldb migration).
--
-- This module wires nvim-dap + nvim-dap-ui to lldb-dap and provides the
-- DAP*-prefixed user commands. Per-platform attach/launch logic lives in
-- ue/dap/{android,win64,linux,mac,ios}.lua.
--
-- What's gone (vs the pre-migration 2424-line version):
--   * codelldb adapter wiring (now: dap.adapters.lldb via _common.ensure_adapter)
--   * Hand-written breakpoint specs (`_dap_make_breakpoint_spec` /
--     `_dap_try_set_breakpoint` / `_dap_clear_breakpoint`) — the original
--     codelldb era helpers are gone, but UE Android still rewrites native
--     `setBreakpoints` source paths before they reach lldb-dap.
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

local function norm_path(path)
  path = tostring(path or "")
  if path == "" then return "" end
  if core and type(core.norm) == "function" then
    return core.norm(path)
  end
  return vim.fs.normalize(path)
end

local function is_file(path)
  path = norm_path(path)
  if path == "" then return false end
  if core and type(core.is_file) == "function" then
    return core.is_file(path)
  end
  local stat = (vim.uv or vim.loop).fs_stat(path)
  return stat and stat.type == "file" or false
end

-- ─────────────────────────────────────────────────────────────────────
-- Module state.
-- ─────────────────────────────────────────────────────────────────────
-- Kept on D so logcat / source path rewriter / ue.lua status cache can
-- read pid / serial / engine_root / project_root.
D._dap_session_state         = {}
D._dap_attach_in_progress    = false
D._dap_run_state             = "idle"   -- idle | attaching | stopped | running | resuming
D._continue_pending          = false
D._step_pending              = false  -- true while a step request awaits adapter `stopped` event
D._step_debounce_until_ms    = 0      -- monotonic-ms watchdog; lets the keymap recover if the adapter never replies
D._step_feedback_until_ms    = 0      -- throttle for visible step-rejection notifications (one per 2 s)
D._continue_debounce_until_ms = 0
D._pause_pending             = false
D._dap_source_file_cache     = {}
D._dap_expected_focus_thread_id = nil

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

local function is_ue_android_lldb_session(session)
  local cfg = session and session.config or nil
  if not cfg then return false end
  return cfg.type == "lldb"
    and cfg.request == "attach"
    and tostring(cfg.name or ""):match("UE Android Attach") ~= nil
end

local function is_ue_ios_lldb_session(session)
  local cfg = session and session.config or nil
  return cfg and cfg.type == "lldb"
    and cfg._ue_ios_session_owner == "legacy-mobiledevice"
end


-- ─── UPSTREAM ROOT CAUSE: nvim-dap synthetic-frame handling ──────────────
-- ANCHOR(ue-synthetic-frame-guard). Three sites in this file defend against the
-- SAME upstream nvim-dap defect; this predicate is their shared classifier.
--
-- Defect: lldb-dap (Android platform-mode attach) reports attach/exception
-- stops as PC-only "synthetic" frames — `line = 0` and/or a `sourceReference`
-- with no real on-disk path. nvim-dap's `Session:jump_to_frame()`
-- (lua/dap/session.lua) does NOT honour `preserveFocusHint`/`threadCausedFocus`
-- for these, and feeds `line = 0` to `nvim_win_set_cursor` (1-based), which
-- raises `E474: Invalid argument`, opens junk `dap-src://` buffers, and emits
-- "Debug adapter stopped at unavailable location" per stopped thread.
--
-- THE CHOKEPOINT is the `before.stackTrace` listener "ue_source_path_rewrite"
-- (search ANCHOR-USE:stackTrace). It runs before nvim-dap's built-in
-- `event_stopped` consumes the stackTrace response, so neutering synthetic
-- frames there (line=-1 placeholder) stops the bad UI hop at the source for
-- every downstream consumer. The two other sites are thin defence-in-depth:
--   • `_frame_set` monkey-patch (ANCHOR-USE:_frame_set) — guards the rare path
--     where a synthetic frame reaches frame-set directly (manual frame nav)
--     without having gone through our stackTrace rewrite.
--   • basename→local-path remap (ANCHOR-USE:bp-response) — orthogonal: it
--     rewrites setBreakpoints RESPONSE source paths (not stop frames) so the
--     breakpoint markers land on the user's local buffer rather than the
--     DWARF basename; it shares no frame logic but is listed here because it
--     is the third place we translate between DWARF/synthetic and local paths.
-- Removing any of these requires the upstream fix to jump_to_frame; until then
-- the chokepoint carries the load and the other two stay as cheap guards.
local function frame_is_synthetic_or_invalid(frame)
  if type(frame) ~= "table" then return true end
  local line = tonumber(frame.line) or 0
  local source = frame.source or {}
  if line < 1 then return true end
  if tonumber(source.sourceReference or 0) ~= 0 then return true end
  local path = norm_path(source.path or "")
  if path == "" or path:match("^[a-z]+://") then return true end
  return false
end

local function frame_is_local_file(frame)
  if frame_is_synthetic_or_invalid(frame) then return false end
  return is_file(norm_path(frame.source.path or ""))
end

local function is_ue_android_source_path(path)
  path = norm_path(path or "")
  if path == "" then return false end
  return path:find("/Engine/Source/", 1, true) ~= nil
    or path:find("/Source/", 1, true) ~= nil
end

local function ue_android_breakpoint_source(original_source)
  local path = norm_path(original_source and original_source.path or "")
  if path == "" or not is_ue_android_source_path(path) then
    return original_source
  end
  -- UE Android DWARF commonly records file names / relative paths, while the
  -- user's nvim buffer path is a Windows absolute path under D:/workspace/... .
  -- Passing that absolute path through DAP setBreakpoints makes lldb-dap return
  -- verified=false, rendered as `DapBreakpointRejected` (`R`).  Use basename
  -- for the DAP request; keep the user's local path only in nvim-dap storage.
  local name = vim.fs.basename(path)
  if not name or name == "" then return original_source end
  return { name = name, path = name }
end

local function local_path_for_breakpoint_source(source)
  local path = source and source.path or nil
  if type(path) ~= "string" or path == "" then return nil end
  if is_file(norm_path(path)) then return norm_path(path) end
  if source and source.name then
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fs.basename(name) == source.name then
        return norm_path(name)
      end
    end
  end
  return nil
end

local function remap_breakpoint_response_to_local_paths(response)
  -- ANCHOR-USE:bp-response — see ANCHOR(ue-synthetic-frame-guard) above.
  -- Thin/orthogonal site: rewrites setBreakpoints RESPONSE source paths
  -- (DWARF basename → user's local buffer path) so breakpoint markers render
  -- on the local file, not a synthetic basename source.
  if not response or not response.breakpoints then return end
  for _, bp in ipairs(response.breakpoints) do
    if bp.source then
      local local_path = local_path_for_breakpoint_source(bp.source)
      if local_path then
        bp.source.path = local_path
        bp.source.name = vim.fs.basename(local_path)
      end
    end
  end
end

local function append_android_bp_diag(lines)
  if type(lines) == "string" then lines = { lines } end
  if type(lines) ~= "table" then return end
  pcall(function()
    local path = vim.fn.stdpath("cache") .. ("/ue-dap-bp-diag.%d.log"):format(vim.fn.getpid())
    local fh = io.open(path, "a")
    if not fh then return end
    for _, line in ipairs(lines) do
      fh:write(tostring(line), "\n")    end
    fh:close()
  end)
end

-- ─── Live (session-time) breakpoint planting ─────────────────────────────
-- PROVEN PATH, not a workaround (design android-dap-live-breakpoints D2;
-- 2026-06-15 gate evidence tools/evidence/android-f9/livebp-gate.*.json).
-- After configurationDone, nvim-dap's native setBreakpoints for an Android
-- attach session resolves AND hits on this device/route (K30 platform mode +
-- 3.5 matching symbols). The earlier "you must :UEDAPReattach" warning was for
-- a route where the memory write was silently dropped (361b9e7); that does not
-- reproduce here, so session-time F9 is handled live.
--

-- Pure helper (unit-tested via D._live_plant_command_for_test): build the
-- lldb-dap evaluate backtick command for one file:line breakpoint. The basename
-- form MUST match what attach-time preseed uses (ue_android_breakpoint_source),
-- because that is the shape proven to resolve against the device DWARF.
-- Returns nil when source/line cannot produce a valid command.
local function ue_android_live_plant_command(source, line)
  line = tonumber(line)
  if not line or line <= 0 then return nil end
  local rewritten = ue_android_breakpoint_source(source or {})
  local file = rewritten and (rewritten.name or rewritten.path) or nil
  if type(file) ~= "string" or file == "" then
    file = source and source.name or nil
  end
  if type(file) ~= "string" or file == "" then return nil end
  return string.format('`breakpoint set -f "%s" -l %d', file, line), file
end

-- Pure helper (unit-tested via D._scan_breakpoint_resolved_for_test): parse the
-- `resolved = N` count from an `lldb breakpoint list` dump. Returns the LAST
-- resolved value seen (the dump lists one breakpoint per block), or nil if no
-- resolved line is present. This is the honest-verified signal: resolved>0 means
-- LLDB actually planted the breakpoint; resolved=0 / nil means it did not.
local function scan_breakpoint_resolved(text)
  local resolved = nil
  for l in (tostring(text or "") .. "\n"):gmatch("([^\n]*)\n") do
    local n = l:match("locations = %d+, resolved = (%d+)")
    if n then resolved = tonumber(n) end
  end
  return resolved
end
-- Channel priority (D2): B = evaluate backtick `breakpoint set -f/-l` (reuses
-- the attach-time preseed file:line form that is proven to resolve, and the
-- evaluate result text carries `resolved=N` for honest verified state) → A =
-- DAP setBreakpoints native (already in flight; used as the fallback path).
-- C = address is NOT needed (gate showed B/A both hit).
--
-- This helper sends the file:line command over evaluate and reads back
-- `breakpoint list` to confirm resolved>0. It NEVER detach+reattach and NEVER
-- fakes success: a failure to resolve is surfaced via vim.notify + diag log.
local function ue_android_live_plant_via_evaluate(session, source, lines)
  if type(lines) ~= "table" or #lines == 0 then return end

  for _, bp in ipairs(lines) do
    local cmd, file = ue_android_live_plant_command(source, type(bp) == "table" and bp.line or bp)
    if cmd then
      local line = tonumber(type(bp) == "table" and bp.line or bp)
      append_android_bp_diag({
        "== live breakpoint plant (evaluate) ==",
        "cmd=" .. cmd,
      })
      pcall(function()
        session:request("evaluate", { expression = cmd, context = "repl" },
          function(set_err, set_res)
            append_android_bp_diag({
              "live plant evaluate response:",
              "error=" .. tostring(set_err and (set_err.message or set_err) or "nil"),
              "result=" .. tostring(set_res and set_res.result or ""),
            })
            -- Read back resolved state and surface honest feedback.
            session:request("evaluate", { expression = "`breakpoint list", context = "repl" },
              function(list_err, list_res)
                local text = list_res and list_res.result or ""
                append_android_bp_diag({ "live plant breakpoint list:", text })
                local resolved = scan_breakpoint_resolved(text)
                if set_err or (resolved ~= nil and resolved == 0) then
                  -- MUST NOT fake success; tell the user exactly what failed.
                  local now = mono_ms()
                  if now >= (D._ue_android_bp_notice_until_ms or 0) then
                    D._ue_android_bp_notice_until_ms = now + 5000
                    vim.notify(
                      string.format(
                        "[ue.dap] live breakpoint %s:%d did not resolve (%s). "
                        .. "See :UEDAPDiag / ue-dap-bp-diag.log.",
                        file, line,
                        set_err and "command error" or "resolved=0"),
                      vim.log.levels.WARN)
                  end
                end
              end)
          end)
      end)
    end
  end
end

local function frame_has_local_source(frame)
  local source = frame and frame.source or nil
  if not source then return false end
  if tonumber(source.sourceReference or 0) ~= 0 then return false end
  local path = norm_path(source.path or "")
  if path == "" or path:match("^[a-z]+://") then return false end
  local cache = D._dap_source_file_cache or {}
  local cached = cache[path]
  if cached == nil then
    cached = is_file(path)
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

local function jump_to_local_source_frame(session, frame)
  if not frame_has_local_source(frame) then return end
  if type(session._frame_set) == "function" then
    local ok = pcall(function() session:_frame_set(frame) end)
    if ok then return end
  end

  -- lldb-dap can produce source-backed frames with line=0/column=0 for
  -- attach stops or synthetic frames. nvim_win_set_cursor requires a
  -- 1-based line inside the current buffer; passing 0 raises
  -- `Vim:E474: Invalid argument` after a successful attach. Clamp and pcall
  -- the UI hop so debugger attachment never reports a false failure.
  local path = norm_path(frame.source and frame.source.path or "")
  if path == "" then return end
  local ok_edit = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(path))
  if not ok_edit then return end

  local line = tonumber(frame.line) or 1
  local col = tonumber(frame.column) or 1
  if line < 1 then line = 1 end
  if col < 1 then col = 1 end
  local max_line = vim.api.nvim_buf_line_count(0)
  if max_line < 1 then max_line = 1 end
  if line > max_line then line = max_line end
  pcall(vim.api.nvim_win_set_cursor, 0, { line, math.max(col - 1, 0) })
end

local function maybe_jump_to_local_source_frame(session, body)
  if not session or D._dap_attach_in_progress or is_sigstop_stop(body) then return end
  if body and body.preserveFocusHint and not body.threadCausedFocus then return end
  if frame_has_local_source(session.current_frame) then return end
  local thread_id = (body and body.threadId) or session.stopped_thread_id
  if not thread_id then return end
  local thread = session.threads and session.threads[thread_id] or nil
  local cached = thread and thread.frames or nil
  if cached and #cached > 0 then
    local f = pick_local_source_frame(cached)
    if f then jump_to_local_source_frame(session, f) end
    return
  end
  session:request("stackTrace", { threadId = thread_id, startFrame = 0, levels = 20 },
    function(err, response)
      if err or not response then return end
      local frames = response.stackFrames or {}
      local f = pick_local_source_frame(frames)
      if not f then return end
      vim.schedule(function()
        jump_to_local_source_frame(session, f)
      end)
    end)
end

local function request_dap_continue(dap)
  local session = dap and dap.session and dap.session() or nil
  if not session then return false end
  session._ue_expected_focus_thread_id = nil
  D._dap_expected_focus_thread_id = nil
  D._continue_pending = true
  D._dap_run_state = "resuming"
  D._continue_debounce_until_ms = mono_ms() + 750
  local ok, err
  if type(session._step) == "function" then
    ok, err = pcall(function()
      session:_step("continue", { singleThread = false })
    end)
  else
    ok, err = pcall(dap.continue)
  end
  if ok then return true end
  D._continue_pending = false
  D._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  D._continue_debounce_until_ms = 0
  vim.notify("Continue failed: " .. tostring(err), vim.log.levels.WARN)
  return false
end

local function remember_focus_thread(session, thread_id)
  if not session or not thread_id then return end
  session._ue_expected_focus_thread_id = thread_id
  D._dap_expected_focus_thread_id = thread_id
end

local function current_stopped_thread(session)
  if not session then return nil end
  if session.stopped_thread_id then return session.stopped_thread_id end
  local only
  for id, thread in pairs(session.threads or {}) do
    if thread and thread.stopped then
      if only then return nil end
      only = thread.id or id
    end
  end
  return only
end

-- Throttled feedback for step-request rejections. High-frequency drops
-- (held F10) stay silent so the user is not spammed; low-frequency cases
-- (session running, state machine confused) surface a one-shot hint per
-- 2 s window so the user knows why their keypress did nothing.
local function step_feedback(msg, level)
  local now = mono_ms()
  if now < (D._step_feedback_until_ms or 0) then return end
  D._step_feedback_until_ms = now + 2000
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function request_step(dap, command)
  local session = dap and dap.session and dap.session() or nil
  if not session then return end

  -- Re-entrancy guard. Holding F10 / pressing F10 faster than the adapter
  -- can answer with a stopped event produces back-to-back step requests.
  -- lldb-dap 22.1.6 in platform-android mode crashes the inferior when it
  -- receives a second `next` / `stepIn` before the previous one resolved
  -- (see MEMORY: lldb-dap-22-platform-mode-breakpoint-crash). Drop
  -- duplicate step requests until the adapter sends back `stopped` or the
  -- short debounce window expires.
  --
  -- Silent drops (high-frequency, expected): held F10, _continue_pending,
  -- resuming. Spamming notify here would punish the exact case the guard
  -- exists to absorb.
  local now = mono_ms()
  if D._step_pending then
    if now < (D._step_debounce_until_ms or 0) then return end
    -- Debounce window lapsed without a stopped event — assume the previous
    -- step is genuinely lost so we don't deadlock the keymap forever.
    D._step_pending = false
  end
  if D._continue_pending or D._dap_run_state == "resuming" then return end

  -- Visible feedback (low-frequency, surprising): session is actively
  -- running, or the state machine is in a state from which we cannot
  -- step. These mean the user pressed F10 expecting motion and got
  -- nothing — they deserve to know why.
  if D._dap_run_state == "running" then
    step_feedback("[ue.dap] session is running — press F6 (UEDAPPause) before stepping",
      vim.log.levels.WARN)
    return
  end
  -- Only step when the adapter is parked. Allow the case where our tracker
  -- thinks we are idle but the session reports a stopped thread.
  if D._dap_run_state ~= "stopped" and not session.stopped_thread_id then
    step_feedback(("[ue.dap] cannot step in state '%s' (no stopped thread); use :UEDAPDiag")
      :format(tostring(D._dap_run_state or "?")), vim.log.levels.WARN)
    return
  end

  local thread_id = current_stopped_thread(session)
  if thread_id then remember_focus_thread(session, thread_id) end
  local opts = { singleThread = true }
  if type(session._step) ~= "function" then
    vim.notify("[ue.dap] active session does not support stepping", vim.log.levels.WARN)
    return
  end

  D._step_pending = true
  D._step_debounce_until_ms = now + 750
  D._dap_run_state = "resuming"
  local ok, err = pcall(function()
    session:_step(command, opts)
  end)
  if not ok then
    D._step_pending = false
    D._step_debounce_until_ms = 0
    D._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
    vim.notify("[ue.dap] step (" .. tostring(command) .. ") failed: " .. tostring(err),
      vim.log.levels.WARN)
  end
end

local function reset_session_state()
  D._dap_attach_in_progress    = false
  D._dap_run_state             = "idle"
  D._continue_pending          = false
  D._continue_debounce_until_ms = 0
  D._pause_pending             = false
  D._step_pending              = false
  D._step_debounce_until_ms    = 0
  D._step_feedback_until_ms    = 0
  D._dap_source_file_cache     = {}
  for k in pairs(D._dap_session_state or {}) do
    D._dap_session_state[k] = nil
  end
  D._dap_expected_focus_thread_id = nil
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

-- ─── Live-breakpoint pure-logic test seams ───────────────────────────────
-- These expose the two pure helpers that carry the load-bearing invariants of
-- the session-time live breakpoint path (change android-dap-live-breakpoints).
-- Tested in tests/cases/dap_spec.lua so the behavior — not just the source
-- text — is locked against regression.

--- Build the live-plant evaluate command for one file:line. Returns (cmd, file)
--- or nil. MUST use the same basename form as attach-time preseed.
function D._live_plant_command_for_test(source, line)
  return ue_android_live_plant_command(source, line)
end

--- Parse `resolved = N` from an lldb `breakpoint list` dump. Returns the last
--- resolved count or nil. This is the honest-verified signal (resolved>0 = real
--- plant; 0/nil = failure → warn, never fake success).
function D._scan_breakpoint_resolved_for_test(text)
  return scan_breakpoint_resolved(text)
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

--- Toggle a breakpoint at the cursor.  Wraps nvim-dap's native toggle and
--- persists the bp set to disk so it survives nvim restarts.  Storage is
--- per UE project (see ue.dap._persist_bp).
function D.dap_toggle_breakpoint()
  local ok = D.ensure_dap_loaded()
  if not ok then return end
  local pbp = require("ue.dap._persist_bp")
  pbp.toggle()
end

--- Set a conditional breakpoint and persist it.
function D.dap_set_conditional_breakpoint()
  if not D.ensure_dap_loaded() then return end
  require("ue.dap._persist_bp").toggle_conditional()
end

--- Set a logpoint and persist it.
function D.dap_set_logpoint()
  if not D.ensure_dap_loaded() then return end
  require("ue.dap._persist_bp").toggle_logpoint()
end

--- Clear all breakpoints (current bufs + persisted store).
function D.dap_clear_breakpoints()
  if not D.ensure_dap_loaded() then return end
  require("ue.dap._persist_bp").clear_all()
end

--- Print persisted bp list (debug aid).
function D.dap_list_breakpoints()
  if not D.ensure_dap_loaded() then return end
  require("ue.dap._persist_bp").list()
end

-- ── Inspect / evaluate / navigate ──────────────────────────────────────────
--
-- These wrap `dap.ui.widgets` and `dap.session():request` to give us the
-- VSCode/CLion-equivalent debug interactions: hover-eval, expression prompt,
-- add-watch from cword, run-to-cursor, frame up/down, restart frame.
--
-- All of them no-op (with a notify) when there's no active session — this
-- keeps F-key bindings safe to press before attach has happened.

local function _require_session()
  local ok, dap = D.ensure_dap_loaded()
  if not ok then return nil, nil end
  local s = dap.session()
  if not s then
    vim.notify("[ue.dap] no active session", vim.log.levels.WARN)
    return nil, dap
  end
  return s, dap
end

--- Show a floating hover popup with the variable / expression under cursor.
--- In visual mode evaluates the selection. K-style.
function D.dap_hover()
  local _, dap = D.ensure_dap_loaded()
  if not dap then return end
  if not dap.session() then
    vim.notify("[ue.dap] no active session — start attach first", vim.log.levels.WARN)
    return
  end
  local ok, widgets = pcall(require, "dap.ui.widgets")
  if not ok then
    vim.notify("[ue.dap] dap.ui.widgets not available", vim.log.levels.WARN)
    return
  end
  -- Visual selection? Pull the selected text as the expression.
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    -- yank to register z without clobbering "
    vim.cmd('noautocmd silent normal! "zy')
    local expr = vim.fn.getreg("z")
    if expr and expr ~= "" then
      widgets.hover(function() return expr end)
      return
    end
  end
  widgets.hover()
end

--- Prompt for an arbitrary expression and print the result to :messages.
--- Useful when you want the answer to stick around instead of disappearing
--- with a hover popup.
function D.dap_eval_prompt()
  local sess = _require_session()
  if not sess then return end
  vim.ui.input({ prompt = "DAP eval: " }, function(expr)
    if not expr or expr == "" then return end
    local frame_id
    if sess.current_frame then frame_id = sess.current_frame.id end
    sess:request("evaluate", {
      expression = expr,
      context = "repl",
      frameId = frame_id,
    }, function(err, body)
      if err then
        vim.notify("[ue.dap eval] " .. (err.message or vim.inspect(err)),
          vim.log.levels.ERROR)
        return
      end
      local out = body and body.result or "<no result>"
      vim.notify("[ue.dap eval] " .. expr .. "  =>  " .. tostring(out),
        vim.log.levels.INFO)
    end)
  end)
end

--- Add the word under cursor (or visual selection) to dapui's Watches panel.
--- Falls back to `dap.repl` `-exec` if dapui isn't loaded.
--- Internal: push a raw expression string into the dapui Watches panel.
--- Returns true on success. Notifies on failure so callers can fail-fast.
function D._dap_watch_push(expr)
  if not expr or expr == "" then
    vim.notify("[ue.dap] watch: empty expression", vim.log.levels.WARN)
    return false
  end
  expr = expr:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local dapui_ok, dapui = D.ensure_dapui_loaded()
  if not (dapui_ok and dapui.elements and dapui.elements.watches
                   and dapui.elements.watches.add) then
    vim.notify("[ue.dap] dapui watches unavailable — use REPL", vim.log.levels.WARN)
    return false
  end
  dapui.elements.watches.add(expr)
  vim.notify("[ue.dap] watch added: " .. expr, vim.log.levels.INFO)
  return true
end

function D.dap_add_watch_cword()
  local sess = _require_session()
  if not sess then return end
  local expr
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd('noautocmd silent normal! "zy')
    expr = vim.fn.getreg("z")
  else
    expr = vim.fn.expand("<cword>")
  end
  if not expr or expr == "" then
    vim.notify("[ue.dap] nothing under cursor to watch", vim.log.levels.WARN)
    return
  end
  D._dap_watch_push(expr)
end

-- ── UE-aware watch templates ───────────────────────────────────────────────
--
-- These commands cover the "I always want to see THIS for THAT type" patterns
-- so the user doesn't have to type out the full lldb expression every time.
-- All of them are just convenience wrappers around _dap_watch_push — the
-- inferior decides whether the expression actually evaluates. If symbols are
-- missing or the function got inlined out, the watch will show
-- "error: <expression failure>" and that's fine — at least the user knows
-- it tried.
--
-- The receiving form (`expr`) is either an argument string or, if omitted,
-- the cword/visual selection — same UX as :UEDAPWatchAdd.
local function _resolve_watch_target(opts_args)
  if opts_args and opts_args ~= "" then return opts_args end
  local mode = vim.api.nvim_get_mode().mode
  if mode == "v" or mode == "V" or mode == "\22" then
    vim.cmd('noautocmd silent normal! "zy')
    local s = vim.fn.getreg("z")
    if s and s ~= "" then return s end
  end
  return vim.fn.expand("<cword>")
end

--- Watch an FName as its resolved string. Goes through FName::ToString()
--- which needs FName symbols — works in Development+, may fail in Shipping.
--- @param expr string  C++ expression that resolves to an FName
function D.dap_watch_fname(expr)
  if not _require_session() then return end
  if not expr or expr == "" then return end
  -- Two siblings: the raw struct (Index visible) + the resolved string.
  D._dap_watch_push(expr)                                 -- raw view: shows {Index=N}
  D._dap_watch_push(("(%s).ToString()"):format(expr))     -- resolved: needs symbols
end

--- Watch a UObject* pointer: show class name + object name.
--- Calls GetClass()->GetName() and GetName() — requires UObject symbols
--- (almost always present in Development).
--- @param expr string  C++ expression that resolves to a UObject*
function D.dap_watch_uobject(expr)
  if not _require_session() then return end
  if not expr or expr == "" then return end
  D._dap_watch_push(expr)                                            -- raw ptr
  D._dap_watch_push(("(%s) ? (%s)->GetName() : FString()"):format(expr, expr))
  D._dap_watch_push(("(%s) ? (%s)->GetClass()->GetName() : FString()"):format(expr, expr))
end

--- Watch an AActor*: class + name + world location (X/Y/Z).
--- @param expr string  C++ expression resolving to AActor*
function D.dap_watch_actor(expr)
  if not _require_session() then return end
  if not expr or expr == "" then return end
  D._dap_watch_push(expr)
  D._dap_watch_push(("(%s) ? (%s)->GetClass()->GetName() : FString()"):format(expr, expr))
  D._dap_watch_push(("(%s) ? (%s)->GetName() : FString()"):format(expr, expr))
  D._dap_watch_push(("(%s) ? (%s)->GetActorLocation() : FVector::ZeroVector"):format(expr, expr))
end

--- Watch a TArray<T>: show the raw struct (size+cap come from the native
--- type summary) plus the first 4 elements via Data[i] indexing. Useful
--- when the dapui Variables panel's lazy-expansion is annoying.
--- @param expr string  C++ expression resolving to a TArray<T>&
function D.dap_watch_tarray(expr)
  if not _require_session() then return end
  if not expr or expr == "" then return end
  D._dap_watch_push(expr)                                  -- {size cap}
  for i = 0, 3 do
    D._dap_watch_push(("(%s).GetData()[%d]"):format(expr, i))
  end
end

--- Generic dispatcher for `:UEDAPWatch <type> [expr]` so we don't have to
--- register one user command per template. Falls back to a plain watch
--- (same as :UEDAPWatchAdd) if `type` is unknown — that way typos don't
--- silently swallow the expression.
function D.dap_watch_template(template, expr)
  expr = _resolve_watch_target(expr)
  if not expr or expr == "" then
    vim.notify("[ue.dap] watch template: missing expression", vim.log.levels.WARN)
    return
  end
  local t = (template or ""):lower()
  if t == "fname" then     D.dap_watch_fname(expr)
  elseif t == "uobject" then D.dap_watch_uobject(expr)
  elseif t == "actor" then   D.dap_watch_actor(expr)
  elseif t == "tarray" then  D.dap_watch_tarray(expr)
  elseif t == "" or t == "raw" then
    D._dap_watch_push(expr)
  else
    vim.notify(
      ("[ue.dap] unknown template '%s' (known: fname uobject actor tarray raw) — adding as raw watch")
        :format(template),
      vim.log.levels.WARN)
    D._dap_watch_push(expr)
  end
end

--- Run-to-cursor: ephemeral breakpoint at current line + continue, removed
--- when the session next stops. Implemented via dap.run_to_cursor() (nvim-dap
--- built-in).
function D.dap_run_to_cursor()
  local _, dap = D.ensure_dap_loaded()
  if not dap then return end
  if not dap.session() then
    vim.notify("[ue.dap] no active session — start attach first", vim.log.levels.WARN)
    return
  end
  dap.run_to_cursor()
end

--- Move up one stack frame (callee -> caller direction).
function D.dap_frame_up()
  local _, dap = D.ensure_dap_loaded()
  if not dap or not dap.session() then
    vim.notify("[ue.dap] no active session", vim.log.levels.WARN); return
  end
  dap.up()
end

--- Move down one stack frame (caller -> callee direction).
function D.dap_frame_down()
  local _, dap = D.ensure_dap_loaded()
  if not dap or not dap.session() then
    vim.notify("[ue.dap] no active session", vim.log.levels.WARN); return
  end
  dap.down()
end

--- Restart the current stack frame (rewinds to function entry, re-executes).
--- Requires adapter support; lldb-dap supports it on attach sessions.
function D.dap_restart_frame()
  local _, dap = D.ensure_dap_loaded()
  if not dap or not dap.session() then
    vim.notify("[ue.dap] no active session", vim.log.levels.WARN); return
  end
  dap.restart_frame()
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
  if ok and dap.session() then request_step(dap, "next") end
end

function D.dap_step_into()
  local ok, dap = D.ensure_dap_loaded()
  if ok and dap.session() then request_step(dap, "stepIn") end
end

function D.dap_step_out()
  local ok, dap = D.ensure_dap_loaded()
  if ok and dap.session() then request_step(dap, "stepOut") end
end

function D.dap_bottom_tab(name, opts)
  if type(D._dap_bottom_tab_impl) == "function" then
    return D._dap_bottom_tab_impl(name, opts)
  end
  vim.notify("[ue.dap] DAP UI tabs are not initialized yet", vim.log.levels.WARN)
end

function D.dap_next_bottom_tab(delta)
  if type(D._dap_next_bottom_tab_impl) == "function" then
    return D._dap_next_bottom_tab_impl(delta)
  end
  vim.notify("[ue.dap] DAP UI tabs are not initialized yet", vim.log.levels.WARN)
end

-- ─────────────────────────────────────────────────────────────────────
-- UI / layout commands.
-- ─────────────────────────────────────────────────────────────────────

function D.dap_toggle_ui()
  local ok, dapui = D.ensure_dapui_loaded()
  if not ok then return end
  if type(D._dap_toggle_debug_layout) == "function" then
    D._dap_toggle_debug_layout()
    return
  end
  dapui.toggle()
end

function D.dap_reset_layout()
  local dap_ok, dap = D.ensure_dap_loaded()
  local dapui_ok, dapui = D.ensure_dapui_loaded()
  if not dap_ok or not dapui_ok then
    vim.cmd("only")
    vim.cmd("wincmd =")
    return
  end

  -- Step 1: close any leftover dap-* panels and dap-src:// virtual buffers.
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      local bt = vim.bo[buf].buftype
      local ft = vim.bo[buf].filetype
      local name = vim.api.nvim_buf_get_name(buf)
      if (bt == "nofile" or bt == "prompt") and ft:find("^dap") then
        pcall(vim.api.nvim_win_close, win, true)
      elseif name:match("^dap%-src://") then
        -- close (and wipe) the 1-line memory-reference stub buffer so
        -- it never re-anchors as the editor area on next attach
        pcall(vim.api.nvim_win_close, win, true)
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
  pcall(function() dapui.close() end)

  -- Step 2: re-anchor a real file buffer in the current window if it
  -- ended up empty / on a stub.
  local cur = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_is_valid(cur) then
    local b = vim.api.nvim_win_get_buf(cur)
    local bt = vim.bo[b].buftype
    local name = vim.api.nvim_buf_get_name(b)
    if bt ~= "" or name:match("^dap%-src://") then
      -- find any normal file buffer to pin
      for _, bf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bf) and vim.bo[bf].buftype == ""
           and vim.api.nvim_buf_get_name(bf) ~= "" then
          local n = vim.api.nvim_buf_get_name(bf)
          if not n:match("^dap%-src://") then
            pcall(vim.api.nvim_set_current_buf, bf)
            break
          end
        end
      end
    end
  end

  vim.cmd("wincmd =")

  -- Step 3: if a session is active, re-open dapui (and re-pin saved_buf
  -- handling via the listener — we can just call dapui.open here).
  if dap.session() then
    if type(D._dap_open_debug_layout) == "function" then
      D._dap_open_debug_layout({ reset = true })
    else
      dapui.open({ reset = true })
    end
    -- restart logcat panel if Android session
    local android_ok, _ = pcall(require, "ue.dap.android")
    if android_ok and D._dap_session_state and D._dap_session_state.pid then
      -- defer slightly so dapui finishes its splits first
      vim.defer_fn(function()
        -- start_logcat / open_logcat_window are local closures inside
        -- setup_dap; we just notify and rely on the user re-attaching
        -- if logcat is needed. (logcat survives reset_layout typically.)
      end, 100)
    end
  end
end

function D.dap_toggle_repl()
  local ok, dap = D.ensure_dap_loaded()
  if not ok then return end
  if dap.session() and type(D._dap_bottom_tab_impl) == "function" then
    D.dap_bottom_tab("repl")
    return
  end
  dap.repl.toggle()
end

-- ─────────────────────────────────────────────────────────────────────
-- Diagnostic command.
-- ─────────────────────────────────────────────────────────────────────

--- Dump LLDB state into a scratch buffer (image list / source-map / target list).
--- Uses nvim-dap's native eval — no custom REPL plumbing needed.
function D.dap_diagnose()
  local dap_ok, dap = D.ensure_dap_loaded()
  local session = (dap_ok and dap.session) and dap.session() or nil
  local sections = {}

  local function push(title, body)
    table.insert(sections, ("=== %s ===\n%s"):format(title, body or "(empty)"))
  end

  -- ── A. nvim-dap session metadata ─────────────────────────────────────
  do
    local lines = {}
    if not session then
      lines[#lines + 1] = "(no active session)"
    else
      local thread_count = vim.tbl_count(session.threads or {})
      local cur_frame = session.current_frame
      lines[#lines + 1] = ("initialized       : %s"):format(tostring(session.initialized))
      lines[#lines + 1] = ("stopped_thread_id : %s"):format(tostring(session.stopped_thread_id))
      lines[#lines + 1] = ("thread count      : %d"):format(thread_count)
      lines[#lines + 1] = ("run_state         : %s"):format(tostring(D._dap_run_state or "?"))
      lines[#lines + 1] = ("current frame     : %s"):format(
        cur_frame and (("#%s %s (%s:%s)"):format(
          cur_frame.id or "?", cur_frame.name or "?",
          (cur_frame.source and cur_frame.source.path) or "?",
          cur_frame.line or "?")) or "-")
      if session.config then
        lines[#lines + 1] = ("config.name       : %s"):format(session.config.name or "-")
        lines[#lines + 1] = ("config.request    : %s"):format(session.config.request or "-")
        lines[#lines + 1] = ("config.type       : %s"):format(session.config.type or "-")
      end
    end
    push("DAP session", table.concat(lines, "\n"))
  end

  -- ── B. ue.dap.android session state + adapter resolution ─────────────
  do
    local lines = {}
    local s = D._dap_session_state or {}
    lines[#lines + 1] = ("package    : %s"):format(s.package_name or "-")
    lines[#lines + 1] = ("serial     : %s"):format(s.serial or "-")
    lines[#lines + 1] = ("pid        : %s"):format(s.pid or "-")
    lines[#lines + 1] = ("port       : %s"):format(s.port or "-")
    lines[#lines + 1] = ("symbol_lib : %s"):format(s.symbol_lib or "-")
    -- adapter path + version probe
    local ok_common, common = pcall(require, "ue.dap._common")
    if ok_common and common.find_lldb_dap then
      local dap_exe = common.find_lldb_dap()
      lines[#lines + 1] = ("lldb-dap   : %s"):format(dap_exe or "(not resolved)")
      if dap_exe and vim.fn.executable(dap_exe) == 1 then
        local ver = vim.fn.system({ dap_exe, "--version" })
        -- lldb-dap --version prints multiple lines; the actual version is in
        -- "  LLVM version X.Y.Z" or "lldb version X.Y.Z". Grep the first
        -- line that has a "version" token with digits after it.
        local pretty
        for _, line in ipairs(vim.split(ver or "", "[\r\n]+", { plain = false })) do
          local v = line:match("version%s+([%d%.]+)")
          if v then pretty = line:gsub("^%s+", ""); break end
        end
        lines[#lines + 1] = ("  version  : %s"):format(pretty or "(no parsable version)")
        -- python availability (same probe as attach_commands)
        local root = vim.fs.dirname(vim.fs.dirname(dap_exe))
        local has_py = false
        if root then
          for _, sub in ipairs(require("utils.platform").driver().lldb_python_relative_paths()) do
            local st = (vim.uv or vim.loop).fs_stat(root .. "/" .. sub)
            if st and st.type == "directory" then has_py = true; break end
          end
        end
        lines[#lines + 1] = ("  python   : %s"):format(has_py and "yes" or "NO (FString native fallback only)")
      end
    end
    -- liveness state
    local ok_and, android = pcall(require, "ue.dap.android")
    if ok_and then
      lines[#lines + 1] = ("liveness   : %s (misses=%s)"):format(
        android._liveness_timer and "polling" or "off",
        tostring(android._liveness_misses or 0))
      if android._last_session then
        lines[#lines + 1] = ("reattach target: %s @ %s"):format(
          android._last_session.package_name or "-",
          android._last_session.serial or "-")
      end
    end
    push("ue.dap.android state", table.concat(lines, "\n"))
  end

  -- ── C. device-side: lldb-server processes + adb forward list ─────────
  do
    local lines = {}
    local s = D._dap_session_state or {}
    local serial = s.serial
    if not serial or serial == "" then
      lines[#lines + 1] = "(no serial — device probes skipped)"
    else
      local adb_tool = s.adb or require("utils.android_device").adb_executable()
      local function adb(args)
        local cmd = { adb_tool, "-s", serial }
        for _, a in ipairs(args) do cmd[#cmd + 1] = a end
        local out = vim.fn.systemlist(cmd)
        return out, vim.v.shell_error
      end
      local ps_out, _ = adb({ "shell", "ps -A | grep lldb-server" })
      lines[#lines + 1] = "lldb-server processes:"
      if #ps_out == 0 then
        lines[#lines + 1] = "  (none)"
      else
        for _, l in ipairs(ps_out) do lines[#lines + 1] = "  " .. l end
      end
      local fwd_out, _ = adb({ "forward", "--list" })
      lines[#lines + 1] = ""
      lines[#lines + 1] = "adb forward --list:"
      if #fwd_out == 0 then
        lines[#lines + 1] = "  (none)"
      else
        for _, l in ipairs(fwd_out) do lines[#lines + 1] = "  " .. l end
      end
      if s.package_name then
        local pid_out, _ = adb({ "shell", "pidof " .. s.package_name })
        local pid = (pid_out[1] or ""):gsub("%s+$", "")
        lines[#lines + 1] = ""
        lines[#lines + 1] = ("inferior pid (pidof): %s"):format(pid ~= "" and pid or "(dead)")
        if pid ~= "" then
          local status_out, _ = adb({ "shell",
            ("cat /proc/%s/status 2>/dev/null | grep -E '^State|^TracerPid'"):format(pid) })
          for _, l in ipairs(status_out) do lines[#lines + 1] = "  " .. l end
        end
      end
    end
    push("device-side (adb)", table.concat(lines, "\n"))
  end

  -- ── D. log files: paths + last 20 lines of each ──────────────────────
  do
    local lines = {}
    local pid = vim.fn.getpid()
    local logs = {
      { name = "dap.log (nvim-dap)",
        path = vim.fn.stdpath("cache") .. ("/dap.%d.log"):format(pid) },
      { name = "lldb-dap protocol",
        path = vim.fn.stdpath("cache") .. ("/lldb-dap-protocol.%d.log"):format(pid) },
      { name = "UE DAP breakpoint diagnostics",
        path = vim.fn.stdpath("cache") .. ("/ue-dap-bp-diag.%d.log"):format(pid) },
    }
    for _, l in ipairs(logs) do
      lines[#lines + 1] = ("── %s ──"):format(l.name)
      lines[#lines + 1] = ("path: %s"):format(l.path)
      local fst = (vim.uv or vim.loop).fs_stat(l.path)
      if not fst then
        lines[#lines + 1] = "  (file does not exist)"
      elseif fst.size == 0 then
        lines[#lines + 1] = "  (empty)"
      else
        lines[#lines + 1] = ("  size: %d bytes, mtime: %s"):format(
          fst.size, os.date("%H:%M:%S", fst.mtime.sec))
        -- last 20 lines
        local ok_read, all = pcall(vim.fn.readfile, l.path)
        if ok_read and #all > 0 then
          local start = math.max(1, #all - 20)
          lines[#lines + 1] = ("  ── tail (last %d lines) ──"):format(#all - start + 1)
          for i = start, #all do lines[#lines + 1] = "    " .. all[i] end
        end
      end
      lines[#lines + 1] = ""
    end
    push("log files", table.concat(lines, "\n"))
  end

  -- ── E. (if session active) lldb introspection commands ────────────────
  -- These need an active stopped session; if not we just skip the section.
  if session then
    local pending = 3
    local lldb_results = {}
    -- Universal cap: any single lldb response that comes back bigger than
    -- this is truncated before we touch it. We've seen `image list` and
    -- especially `image dump symfile libUE4.so` produce >1M lines on UE
    -- Android (~700 modules / millions of symbols), which OOMs nvim with
    -- a wedged buffer. The cap is intentionally tiny — diag is supposed
    -- to be a one-screen summary, not a full dump. Use :UEDAPRepl <cmd>
    -- if you need the raw output.
    local MAX_BYTES_PER_RESPONSE = 32 * 1024  -- 32 KB
    local MAX_LINES_PER_RESPONSE = 200
    local function clamp(s)
      s = s or ""
      if #s > MAX_BYTES_PER_RESPONSE then
        s = s:sub(1, MAX_BYTES_PER_RESPONSE)
          .. ("\n... (truncated; raw response was %d bytes, cap is %d. Run :UEDAPRepl <cmd> for full output)")
            :format(#s, MAX_BYTES_PER_RESPONSE)
      end
      -- Also clamp line count in case it's lots of short lines.
      local lines = vim.split(s, "\n", { plain = true })
      if #lines > MAX_LINES_PER_RESPONSE then
        local kept = {}
        for i = 1, MAX_LINES_PER_RESPONSE do kept[i] = lines[i] end
        kept[#kept + 1] = ("... (truncated; %d more lines elided)"):format(#lines - MAX_LINES_PER_RESPONSE)
        s = table.concat(kept, "\n")
      end
      return s
    end
    local function collect(label, ok, data)
      lldb_results[#lldb_results + 1] = ("── %s ──\n%s"):format(label,
        ok and clamp(data or "") or "(failed: " .. tostring(data) .. ")")
      pending = pending - 1
      if pending <= 0 then
        push("lldb introspection (via DAP evaluate)", table.concat(lldb_results, "\n\n"))
        D._render_diag_buffer(sections)
      end
    end
    local function eval(cmd, label)
      session:request("evaluate", { expression = "`" .. cmd, context = "repl" },
        function(err, resp)
          collect(label, not err and resp and resp.result ~= nil,
                  resp and resp.result or tostring(err))
        end)
    end
    -- All three of these can produce huge output on UE Android (image list
    -- itself is fine but image dump symfile on libUE4.so is multi-MB).
    -- We rely on clamp() above as the universal safety net rather than
    -- per-command argument tricks.
    eval("image list -b",                          "image list -b (basename)")
    local state = D._dap_session_state or {}
    local so_name = state.symbol_lib and vim.fn.fnamemodify(state.symbol_lib, ":t") or "libUE4.so"
    eval(('image dump symfile "%s"'):format(so_name), "symfile " .. so_name)
    eval("settings show target.source-map",        "source-map")
  else
    D._render_diag_buffer(sections)
  end
end

--- Render the assembled diagnostic sections into a scratch buffer in a
--- bottom split. Factored out so dap_diagnose can call it both synchronously
--- (no session) and from the lldb evaluate completion callback.
function D._render_diag_buffer(sections)
  vim.schedule(function()
    local buf = vim.api.nvim_create_buf(false, true)
    local body = table.concat(sections, "\n\n")
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(body, "\n", { plain = true }))
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].filetype = "log"
    vim.api.nvim_buf_set_name(buf, "UEDAPDiag@" .. os.date("%H%M%S"))
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
    vim.api.nvim_win_set_height(0, math.min(30, math.max(15, vim.api.nvim_buf_line_count(buf))))
    -- press q to wipe
    vim.keymap.set("n", "q", "<cmd>bwipeout<cr>", { buffer = buf, silent = true, desc = "Close diag" })
  end)
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

--- Reattach to the last-known Android session (same pkg/serial/symbol_lib,
--- fresh pid). Used after the app crashes / is killed / hot-reloads and
--- the liveness poller has auto-detached. No prompts on success path.
function D.android_dap_reattach()
  local ok, android = pcall(require, "ue.dap.android")
  if not ok then
    require("utils.log").notify_error("dap", "ue.dap.android not loadable")
    return
  end
  if type(android.reattach) ~= "function" then
    vim.notify("[dap] reattach not available in this build", vim.log.levels.WARN)
    return
  end
  android.reattach()
end

--- Print a one-line summary of the current Android DAP session: package,
--- serial, pid, port, libUE4 base, liveness poller state. Cheap probe so
--- the user can sanity-check the wire without diving into :messages.
function D.android_dap_status()
  local ok, android = pcall(require, "ue.dap.android")
  if not ok then
    require("utils.log").notify_error("dap", "ue.dap.android not loadable")
    return
  end
  if type(android.status) == "function" then
    android.status()
  else
    vim.notify("[dap] status not available in this build", vim.log.levels.WARN)
  end
end

--- Generic owner-preserving stop for host targets that do not need a custom
--- transport teardown. The registry only calls this after resolving the
--- frozen session owner; it never consults the live target selection.
function D.dap_stop_session(opts)
  opts = type(opts) == "table" and opts or {}
  -- Keep nvim-dap's native terminate semantics for desktop owners. Android
  -- and iOS register target-owned stop handlers, so only this generic handler
  -- receives the fallback from the toolbar's terminate path.
  if opts.source == "terminate" and type(opts.fallback) == "function" then
    return opts.fallback()
  end
  local ok_dap, dap = pcall(require, "dap")
  local owner = opts.owner
  local session = owner and owner.session
    or (ok_dap and dap.session and dap.session())
  if not ok_dap or not session then
    return nil, "no active DAP session for the frozen owner"
  end
  if type(dap.disconnect) == "function" then
    dap.disconnect({ terminateDebuggee = false })
    return { disconnected = true, owner = owner and owner.owner }
  end
  return nil, "DAP disconnect is unavailable"
end

function D.dap_status_session(opts)
  opts = type(opts) == "table" and opts or {}
  local owner = opts.owner or {}
  local state = owner.session and "ACTIVE" or "idle"
  local message = ("[ue.dap] %s session owner=%s operation=%s adapter=%s"):format(
    state,
    tostring(owner.owner or "unknown"),
    tostring(owner.operation or "unknown"),
    tostring(owner.adapter or "unknown")
  )
  vim.notify(message, vim.log.levels.INFO)
  return message
end

-- ─────────────────────────────────────────────────────────────────────
-- setup_dap — wire dap-ui listeners, logcat, source-path rewrite,
-- scope filter, VimLeavePre cleanup. Called by lua/plugins/dap.lua.
-- ─────────────────────────────────────────────────────────────────────

function D.setup_dap(dap, dapui)
  local session_mod = package.loaded["dap.session"] or require("dap.session")
  -- Wire the lldb-dap adapter for ALL routes (host-side win64/linux/mac/ios
  -- AND Android). dap.adapters.lldb is the single adapter used everywhere
  -- after the 2026-05-21 codelldb→lldb-dap migration. Listener installation
  -- below must not gate on adapter presence — even on hosts without lldb-dap
  -- the user can still install dapui panels and breakpoint UI; missing
  -- adapter is reported when they try to start a session.
  local lldb_dap = D.lldb_dap_path()
  if lldb_dap then
    require("ue.dap._common").ensure_adapter(dap, lldb_dap)
  end

  -- Register the Android convenience entry only on a host that explicitly
  -- supports Android DAP. A macOS host must not inherit the Windows Android
  -- transport merely because the target module is importable.
  -- The attach driver builds the real lldb-dap config inside
  -- ue.dap.android.attach (which mutates dap.adapters.lldb if needed); this
  -- entry is just the launcher.
  if require("ue.targets").supports(
    "Android", "dap_attach", require("utils.platform").driver()
  ) then
    -- Idempotent registration: only inject our entry if not already
    -- present. Users can append their own configurations.cpp items;
    -- we never overwrite the table.
    dap.configurations = dap.configurations or {}
    local cpp = dap.configurations.cpp or {}
    local have_ue_attach = false
    for _, c in ipairs(cpp) do
      if c and (c.name == "UE Android Attach (lldb-dap)"
                or c.name == "UE Android Attach (codelldb)") then
        have_ue_attach = true
        break
      end
    end
    if not have_ue_attach then
      table.insert(cpp, 1, {
        name    = "UE Android Attach (lldb-dap)",
        type    = "lldb",
        request = "attach",
        program = function()
          -- Hand off to the real attach pipeline; nvim-dap will see
          -- this returns nil/false and abort its own session start.
          vim.schedule(function()
            require("ue.dap.android").attach({})
          end)
          return nil
        end,
      })
    end
    dap.configurations.cpp  = cpp
    dap.configurations.c    = dap.configurations.c   or cpp
    dap.configurations.rust = dap.configurations.rust or cpp
  end

  -- ─── window / layout save & restore ───────────────────────────────
  -- "main_win" is the one normal-file window the user works in during a
  -- DAP session. dapui's three side panels surround it. We pin it on
  -- session start so the layout is deterministic — no leftover build
  -- output / floats / extra splits — and we keep it alive even if the
  -- user accidentally <C-w>q's it (we re-create it from saved_buf).
  local saved_win, saved_buf

  --- Pick the "best" window to keep as the main code window:
  -- prefer the current window if it holds a real file; otherwise scan
  -- for any normal-file window; otherwise fall back to current.
  local function pick_main_window()
    local cur = vim.api.nvim_get_current_win()
    local function is_code_win(w)
      if not vim.api.nvim_win_is_valid(w) then return false end
      if vim.api.nvim_win_get_config(w).relative ~= "" then return false end
      local b = vim.api.nvim_win_get_buf(w)
      local bt = vim.bo[b].buftype
      local ft = vim.bo[b].filetype
      if bt ~= "" then return false end
      if ft:find("^dap") or ft == "snacks_picker_list" or ft == "snacks_picker_input"
         or ft == "snacks_dashboard" or ft == "snacks_explorer" then return false end
      -- Reject dap-src:// virtual source stubs (memory-reference views
      -- left over from a prior session). They have buftype="" but are
      -- 1-line placeholders that collapse the editor area.
      local name = vim.api.nvim_buf_get_name(b)
      if name:match("^dap%-src://") then return false end
      return true
    end
    if is_code_win(cur) then return cur end
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if is_code_win(w) then return w end
    end
    return cur
  end

  local function save_layout()
    if saved_win then return end
    -- 1) pick the main code window before we touch anything
    local main = pick_main_window()
    local main_buf
    if vim.api.nvim_win_is_valid(main) then
      main_buf = vim.api.nvim_win_get_buf(main)
    end
    -- if pick_main_window fell through (only dap-src:// or dapui buffers
    -- left from a prior session) main_buf is bogus — make a fresh empty
    -- buffer so the editor area has a proper anchor.
    local main_name = main_buf and vim.api.nvim_buf_get_name(main_buf) or ""
    local main_bt = main_buf and vim.bo[main_buf].buftype or "?"
    local main_ft = main_buf and vim.bo[main_buf].filetype or "?"
    if main_bt ~= "" or main_ft:find("^dap") or main_name:match("^dap%-src://") then
      vim.cmd("enew")
      saved_win = vim.api.nvim_get_current_win()
      saved_buf = vim.api.nvim_get_current_buf()
    else
      pcall(vim.api.nvim_set_current_win, main)
      saved_win = main
      saved_buf = main_buf
    end
    -- 2) close everything else (build output, floats, extra splits) so
    --    dapui.open() lands into a deterministic single-window layout.
    pcall(vim.cmd, "only")
  end

  --- Public helper: ensure the user's current window is a real code
  --- window (used by pickers / file commands so they don't crash on
  --- nofile/prompt buftypes left by dapui panels).
  function D.dap_focus_main_window()
    local cur = vim.api.nvim_get_current_win()
    if vim.api.nvim_win_is_valid(cur) then
      local b = vim.api.nvim_win_get_buf(cur)
      if vim.bo[b].buftype == "" and not vim.bo[b].filetype:find("^dap") then
        return cur
      end
    end
    -- current window is dapui / nofile / prompt — try saved main
    if saved_win and vim.api.nvim_win_is_valid(saved_win) then
      pcall(vim.api.nvim_set_current_win, saved_win)
      return saved_win
    end
    -- saved main was closed — re-create it from saved_buf
    if saved_buf and vim.api.nvim_buf_is_valid(saved_buf) then
      vim.cmd("topleft vsplit")
      vim.cmd("wincmd l")
      pcall(vim.api.nvim_set_current_buf, saved_buf)
      saved_win = vim.api.nvim_get_current_win()
      return saved_win
    end
    -- last resort: any normal-file window in the tab
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w)
         and vim.api.nvim_win_get_config(w).relative == "" then
        local b = vim.api.nvim_win_get_buf(w)
        if vim.bo[b].buftype == "" then
          pcall(vim.api.nvim_set_current_win, w)
          saved_win = w; saved_buf = b
          return w
        end
      end
    end
    -- no normal-file window left at all — make one
    vim.cmd("enew")
    saved_win = vim.api.nvim_get_current_win()
    saved_buf = vim.api.nvim_get_current_buf()
    return saved_win
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
  local start_logcat
  local bottom_tabs = { "repl", "console", "breakpoints", "logcat" }
  local bottom_tab_labels = {
    repl = "REPL",
    console = "Console",
    breakpoints = "Breakpoints",
    logcat = "Logcat",
  }
  local active_bottom_tab = "repl"

  local function current_android_state()
    local state = D._dap_session_state or {}
    local ok_android, android = pcall(require, "ue.dap.android")
    local sess = ok_android and android and android._session or nil
    if type(sess) == "table" then
      for k, v in pairs(sess) do
        if state[k] == nil and v ~= nil then
          state[k] = v
        end
      end
    end
    return state
  end

  local function bottom_tab_statusline(active)
    local parts = {}
    for i, name in ipairs(bottom_tabs) do
      local label = bottom_tab_labels[name] or name
      if name == active then
        parts[#parts + 1] = "%#TabLineSel#%" .. i
          .. "@v:lua.UEDapBottomTabClick@ " .. label .. " %T"
      else
        parts[#parts + 1] = "%#TabLine#%" .. i
          .. "@v:lua.UEDapBottomTabClick@ " .. label .. " %T"
      end
    end
    parts[#parts + 1] = "%#TabLineFill#"
    return table.concat(parts, "")
  end

  local function is_bottom_tab_win(win)
    if not vim.api.nvim_win_is_valid(win) then return false end
    local buf = vim.api.nvim_win_get_buf(win)
    local ft = vim.bo[buf].filetype
    local name = vim.api.nvim_buf_get_name(buf)
    return ft == "dap-repl"
      or ft == "dapui_console"
      or ft == "dapui_breakpoints"
      or name:match("logcat:%d+$") ~= nil
  end

  local function find_bottom_tab_window()
    if D._dap_bottom_tab_win and vim.api.nvim_win_is_valid(D._dap_bottom_tab_win) then
      return D._dap_bottom_tab_win
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if is_bottom_tab_win(win) then
        D._dap_bottom_tab_win = win
        return win
      end
    end
    return nil
  end

  local function render_dapui_element(name)
    if not (dapui and dapui.elements and dapui.elements[name]) then return nil end
    local elem = dapui.elements[name]
    pcall(function()
      if elem.render then elem.render() end
    end)
    if elem.buffer then
      local ok_buf, buf = pcall(elem.buffer)
      if ok_buf and buf and vim.api.nvim_buf_is_valid(buf) then return buf end
    end
    return nil
  end

  local function bottom_tab_buffer(name)
    if name == "logcat" then
      if (not logcat_buf or not vim.api.nvim_buf_is_valid(logcat_buf))
         and type(start_logcat) == "function" then
        local state = current_android_state()
        if state.pid and state.pid ~= "" then
          start_logcat()
        end
      end
      if logcat_buf and vim.api.nvim_buf_is_valid(logcat_buf) then return logcat_buf end
      return nil
    end
    return render_dapui_element(name)
  end

  local function apply_bottom_tab_window(win, active)
    if not win or not vim.api.nvim_win_is_valid(win) then return end
    pcall(vim.api.nvim_win_set_option, win, "winbar", "")
    pcall(vim.api.nvim_win_set_option, win, "statusline", bottom_tab_statusline(active))
    pcall(vim.api.nvim_win_set_option, win, "number", false)
    pcall(vim.api.nvim_win_set_option, win, "relativenumber", false)
    pcall(vim.api.nvim_win_set_option, win, "signcolumn", "no")
    pcall(vim.api.nvim_win_set_option, win, "wrap", false)
  end

  _G.UEDapBottomTabClick = function(minwid)
    local name = bottom_tabs[tonumber(minwid) or 1] or "repl"
    vim.schedule(function()
      if type(D.dap_bottom_tab) == "function" then
        D.dap_bottom_tab(name)
      end
    end)
  end

  local function open_bottom_tab_window()
    local existing = find_bottom_tab_window()
    if existing then
      return existing
    end

    local code_win = saved_win
    if not (code_win and vim.api.nvim_win_is_valid(code_win)) then
      code_win = D.dap_focus_main_window()
    end
    if not (code_win and vim.api.nvim_win_is_valid(code_win)) then return nil end

    local cur = vim.api.nvim_get_current_win()
    pcall(vim.api.nvim_set_current_win, code_win)
    vim.cmd("belowright split")
    local win = vim.api.nvim_get_current_win()
    D._dap_bottom_tab_win = win
    pcall(vim.api.nvim_win_set_height, win, 12)
    apply_bottom_tab_window(win, active_bottom_tab)
    pcall(vim.api.nvim_set_current_win, code_win)
    if cur ~= code_win and vim.api.nvim_win_is_valid(cur) then
      pcall(vim.api.nvim_set_current_win, cur)
    end
    return win
  end

  local function open_debug_layout(opts)
    opts = opts or {}
    -- dap-ui owns only the left debug rail. The bottom tab host is our own
    -- split under the saved code window, so it aligns with code instead of
    -- spanning under the left rail.
    dapui.open({ layout = 1, reset = opts.reset })
    D._dap_bottom_tab_win = open_bottom_tab_window()
    D.dap_bottom_tab(active_bottom_tab or "repl", { quiet = true })
  end

  local function close_debug_layout()
    if D._dap_bottom_tab_win and vim.api.nvim_win_is_valid(D._dap_bottom_tab_win) then
      pcall(vim.api.nvim_win_close, D._dap_bottom_tab_win, true)
    end
    dapui.close({ layout = 1 })
    D._dap_bottom_tab_win = nil
  end

  function D._dap_open_debug_layout(opts)
    open_debug_layout(opts)
  end

  function D._dap_toggle_debug_layout()
    if find_bottom_tab_window() then
      close_debug_layout()
    else
      open_debug_layout({ reset = false })
    end
  end

  D._dap_bottom_tab_impl = function(name, opts)
    opts = opts or {}
    name = tostring(name or active_bottom_tab or "repl"):lower()
    if not vim.tbl_contains(bottom_tabs, name) then
      vim.notify("[ue.dap] unknown tab: " .. name, vim.log.levels.WARN)
      return
    end
    active_bottom_tab = name
    local buf = bottom_tab_buffer(name)
    if not buf then
      if not opts.quiet then
        vim.notify("[ue.dap] tab unavailable: " .. name, vim.log.levels.WARN)
      end
      return
    end
    local win = find_bottom_tab_window()
    if not win then
      win = open_bottom_tab_window()
    end
    if not win then return end
    vim.api.nvim_win_set_buf(win, buf)
    D._dap_bottom_tab_win = win
    apply_bottom_tab_window(win, name)
  end

  D._dap_next_bottom_tab_impl = function(delta)
    delta = delta or 1
    local cur = active_bottom_tab or "repl"
    local idx = 1
    for i, name in ipairs(bottom_tabs) do
      if name == cur then idx = i; break end
    end
    idx = ((idx - 1 + delta) % #bottom_tabs) + 1
    D.dap_bottom_tab(bottom_tabs[idx])
  end

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

  start_logcat = function()
    stop_logcat()
    local state = current_android_state()
    local pid = state.pid
    local adb = state.adb or require("utils.android_device").adb_executable()
    local serial = state.serial or ""
    if not pid or pid == "" or serial == "" then return end
    logcat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[logcat_buf].buftype = "nofile"
    vim.bo[logcat_buf].bufhidden = "wipe"
    vim.bo[logcat_buf].filetype = "log"
    vim.api.nvim_buf_set_name(logcat_buf, "logcat:" .. pid)
    local cmd = require("utils.android_device").adb_args(
      adb, serial, { "logcat", "--pid=" .. pid })
    if not cmd then return end
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
    if logcat_job <= 0 then
      vim.notify("[ue.dap] logcat failed to start: " .. table.concat(cmd, " "),
        vim.log.levels.WARN)
    else
      -- Register the logcat adb job for :Tasks list/cancel. Pure side-path:
      -- register only, after job creation; on_exit above is untouched. This is
      -- the adb logcat reader we spawn (NOT the DAP session), so it's safe to
      -- list/cancel. The DAP adapter + on-device process are never registered
      -- (K5 boundary).
      pcall(function()
        require("utils.task_registry").register({
          name = "logcat:" .. tostring(pid),
          group = "dap",
          kind = "job",
          handle = logcat_job,
          started_at = os.time(),
        })
      end)
    end
  end

  local function open_logcat_window()
    if not logcat_buf or not vim.api.nvim_buf_is_valid(logcat_buf) then return end
    D.dap_bottom_tab("logcat", { quiet = true })
  end

  -- ─── source-path rewrite (relative LLDB paths → absolute) ─────────
  local source_path_cache = {}
  local function resolve_source_path(rel_path)
    if not rel_path or rel_path == "" then return nil end
    -- lldb-dap 22 occasionally emits source.path frames as msgpack bin →
    -- Vim Blob in lua. Trap: type(blob) reports "string" so a naive type
    -- guard doesn't filter it. Force-coerce via tostring so downstream
    -- pattern matches / vim.fn.filereadable / cache keys all see a real
    -- Lua string.
    rel_path = tostring(rel_path)
    if rel_path == "" then return nil end
    local cached = source_path_cache[rel_path]
    if cached ~= nil then return cached or nil end
    if rel_path:match("^[A-Za-z]:") or rel_path:match("^/") then
      local p = norm_path(rel_path)
      if is_file(p) then source_path_cache[rel_path] = p; return p end
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
      local cand = norm_path(prefix .. "/" .. rel_path)
      if is_file(cand) then source_path_cache[rel_path] = cand; return cand end
    end
    source_path_cache[rel_path] = false
    return nil
  end

  -- ─── nvim-dap listeners ───────────────────────────────────────────
  local function on_session_end(session)
    stop_logcat()
    restore_layout()
    source_path_cache = {}
    D._ue_android_pending_bps = {}  -- clear pending breakpoints on session end
    local platforms = require("ue.dap.platforms")
    platforms.dispatch_lifecycle("cleanup", {
      session = session,
      session_state = D._dap_session_state,
    })
    platforms.end_session(session)
    reset_session_state()
  end

  -- nvim-dap-ui assumes every `threads` response has `body.threads`.
  -- lldb-dap 22 may still emit an `entry` stopped event after an attach
  -- command failure (`process attach --pid` can print `Cannot get process
  -- architecture` / `lost connection`, then the deferred DAP attach response
  -- is success=false). nvim-dap reacts to that stopped event by requesting
  -- `threads`; the adapter correctly answers success=false with no response
  -- body. Older dapui then indexes `args.response.threads` and raises a
  -- vim.schedule callback error, masking the real attach failure.
  --
  -- Important nvim-dap contract: `before.threads` listeners cannot suppress
  -- `after.threads` listeners; returning true only unregisters that before
  -- listener. So wrap the already-registered after-listeners installed by
  -- dapui.setup() and no-op only this failed-threads shape. This is an
  -- editor/UI guard only: it does not change attachCommands, stopOnEntry,
  -- signal disposition, or the lldb protocol flow.
  D._dap_threads_listener_wrapped = D._dap_threads_listener_wrapped or {}
  local after_threads = dap.listeners.after and dap.listeners.after.threads or nil
  if type(after_threads) == "table" then
    for key, listener in pairs(after_threads) do
      if type(listener) == "function" then
        local rec = D._dap_threads_listener_wrapped[key]
        if not (rec and rec.wrapper == listener) then
          local orig = listener
          local wrapper = function(session, err, response, request, request_seq)
            if is_ue_android_lldb_session(session) and err and not (response and response.threads) then
              return
            end
            return orig(session, err, response, request, request_seq)
          end
          after_threads[key] = wrapper
          D._dap_threads_listener_wrapped[key] = { orig = orig, wrapper = wrapper }
        end
      end
    end
  end

  dap.listeners.after.event_initialized["dapui_config"] = function(session)
    local owner, owner_err = require("ue.dap.platforms").bind_session(session)
    -- Non-UE dap configurations remain unmanaged and retain native nvim-dap
    -- behavior. Only malformed explicit UE owner metadata is actionable.
    if not owner and owner_err and owner_err.owner then
      require("utils.log").notify_error(
        "dap.owner",
        tostring(owner_err and owner_err.reason or "session owner metadata is missing")
      )
    end
    close_explorer()
    save_layout()
    -- Guarantee the editor area holds a real file buffer (NOT a leftover
    -- dap-src:// stub from a previous session). dapui.open() docks its
    -- panels around whatever the current window holds; if that window
    -- has a 1-line nofile buffer the code area collapses to 1 row.
    if saved_buf and vim.api.nvim_buf_is_valid(saved_buf)
       and vim.bo[saved_buf].buftype == "" then
      pcall(vim.api.nvim_set_current_buf, saved_buf)
    end
    open_debug_layout({ reset = true })
    start_logcat()
    local config = session and session.config or nil
    if config and config._ue_ios_session_owner == "legacy-mobiledevice" then
      pcall(function()
        require("ue.dap._progress").step("iOS transport attached; arming source breakpoints …")
      end)
    else
      pcall(function() require("ue.dap._progress").done("debugger attached") end)
    end
  end
  dap.listeners.before.event_terminated["dapui_config"] = function(session) on_session_end(session) end
  -- NOTE: the `exited` body carries the only structured exit status we ever
  -- get (`{"body":{"exitCode":9},"event":"exited"}`). The dapui hook below
  -- historically dropped it; record it FIRST so the platform owner's cleanup
  -- can tell "externally SIGKILLed" from "the app crashed on its own".
  dap.listeners.before.event_exited["ue_exit_reason"] = function(session, body)
    if not is_ue_android_lldb_session(session) then return end
    local code = body and tonumber(body.exitCode)
    if code then
      pcall(function()
        require("ue.dap.exit_reason").note({ status = code, source = "exited" })
      end)
    end
  end
  dap.listeners.before.event_exited["dapui_config"]     = function(session) on_session_end(session) end
  dap.listeners.after.disconnect["dapui_config"]        = function(session) on_session_end(session) end

  -- ─── Rewire `dap.terminate` through the frozen session owner ─────
  -- The dapui controls bar's ■ button (and any plain `:lua require("dap")
  -- .terminate()` invocation) issues a DAP `terminate` request.  lldb-dap
  -- maps `terminate` to SIGKILL the inferior — fine for `launch` but
  -- catastrophic for `attach` (it kills the game we just attached to).
  --
  -- Android/iOS owners perform their target-specific detach and transport
  -- cleanup. Generic desktop owners delegate back to nvim-dap's original
  -- terminate implementation, preserving launch/attach behavior without
  -- consulting the current UI platform selection.
  if not D._dap_terminate_rewired then
    local orig_terminate = dap.terminate
    dap.terminate = function(opts, terminate_opts, cb)
      local sess = dap.session()
      local handled, result = require("ue.dap.platforms").dispatch_lifecycle("stop", {
        session = sess,
        callback = cb,
        source = "terminate",
        fallback = function()
          return orig_terminate(opts, terminate_opts, cb)
        end,
      })
      if handled then
        return result
      end
      return orig_terminate(opts, terminate_opts, cb)
    end
    D._dap_terminate_rewired = true
  end

  -- ANCHOR-USE:_frame_set — see ANCHOR(ue-synthetic-frame-guard) at the top of
  -- this file. Defence-in-depth (thin): the stackTrace chokepoint already
  -- neuters synthetic frames before nvim-dap consumes them, but a synthetic
  -- frame can still reach `_frame_set` directly via manual frame navigation
  -- that bypasses our rewrite. Drop it here too so the cursor never hops to a
  -- line=0 / dap-src:// frame. Removing this depends on the upstream
  -- jump_to_frame fix; until then it stays as a cheap guard.
  if session_mod then
    if not session_mod._ue_android_orig_frame_set then
      session_mod._ue_android_orig_frame_set = session_mod._frame_set
    end
    local orig_frame_set = session_mod._ue_android_orig_frame_set
    session_mod._ue_android_invalid_frame_guard = true
    session_mod._frame_set = function(session, frame)
      if (is_ue_android_lldb_session(session) or is_ue_ios_lldb_session(session))
        and frame_is_synthetic_or_invalid(frame) then
        return
      end
      return orig_frame_set(session, frame)
    end

    -- Android attachCommands are owned by ue.dap.android. This module only
    -- rewrites DAP source paths and reports adapter responses.
  end

  -- ─── nvim-dap-ui threads-list crash guard ─────────────────────────────
  -- <engine_root>/.cache/nvim-ue/breakpoints/<project>.json).  setup()
  -- installs autocmds for BufReadPost restore + VimLeavePre flush.
  pcall(function()
    require("ue.dap._persist_bp").setup()
  end)

  dap.listeners.after.event_initialized["ue-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    D._dap_run_state = D._dap_attach_in_progress and "attaching" or "stopped"
    -- Tell the user the entry stop is expected. On Android attach with
    -- lldb-dap 22 + stopOnEntry=true the inferior stops with ~174 SIGSTOP
    -- threads; nvim-dap consumes them all (auto_continue_if_many_stopped=
    -- false in _common.lua) and waits. The user must press F5 (or
    -- :DapContinue / :UEDAPContinue) to resume.
    vim.notify(
      "[ue.dap] Attached. Stopped at entry — press F5 (or :DapContinue) to run.",
      vim.log.levels.INFO)
  end

  -- ─── lldb-dap 22 platform-mode attach: per-thread stopped events ─────
  -- Per llvmorg-22.1.6 lldb/tools/lldb-dap/EventHelper.cpp L177-249
  -- (SendThreadStoppedEvent): on stopOnEntry attach, lldb-dap emits one
  -- DAP `stopped` event PER THREAD that has a stop reason. For a UE4 app
  -- that is ~174 events in a burst. This is upstream-blessed behavior
  -- (LLVM commit 7a417614) and nvim-dap already accommodates it via
  -- `dap.defaults.lldb.auto_continue_if_many_stopped = false` (set in
  -- `lua/ue/dap/_common.lua`). With that flag false, nvim-dap's
  -- session.lua L733-748 sees N>1 stopped events, sets should_jump=false
  -- for later non-focused stops, does NOT send a continue, and lets the
  -- inferior stay frozen at entry until the user resumes manually.
  --
  -- A previous version of this file monkey-patched Session.event_stopped
  -- to drop "entry burst" tail events, AND scheduled a 50ms client-side
  -- auto-continue. Both were unnecessary workarounds we wrote ourselves:
  -- the monkey-patch broke nvim-dap's thread-state bookkeeping, and the
  -- 50ms auto-continue raced the burst (resuming the inferior before
  -- nvim-dap finished consuming the 173 tail events), producing ~322
  -- `invalid thread` error popups. Both have been removed; the protocol
  -- now flows naturally per the DAP spec.

  dap.listeners.before.event_stopped["ue-dap-preserve-lldb-focus"] = function(session, body)
    if dap.session() ~= session or not body or not body.threadId then return end
    local cfg = session.config or {}
    if cfg.type ~= "lldb" then return end

    if body.threadCausedFocus then
      session._ue_last_focus_thread_id = body.threadId
      session._ue_expected_focus_thread_id = nil
      D._dap_expected_focus_thread_id = nil
      return
    end

    -- lldb-dap 22 can report a stop as multiple per-thread `stopped`
    -- events. The event for the thread that should own editor focus is
    -- marked `threadCausedFocus`; other events carry `preserveFocusHint`.
    -- nvim-dap currently ignores both fields. If a non-focus event arrives
    -- first after F10/F11, it would become `stopped_thread_id`, so the next
    -- step would run the wrong thread. Seed the expected focus thread before
    -- nvim-dap's handler sees non-focus events.
    if body.preserveFocusHint then
      local focus = session._ue_expected_focus_thread_id
        or D._dap_expected_focus_thread_id
        or session.stopped_thread_id
      if focus and focus ~= body.threadId then
        session.stopped_thread_id = focus
      end
    end
  end

  dap.listeners.after.event_stopped["ue-dap-run-state"] = function(session, _body)
    if dap.session() ~= session then return end
    D._dap_run_state = "stopped"
    D._continue_pending = false
    D._continue_debounce_until_ms = 0
    D._pause_pending = false
    D._step_pending = false
    D._step_debounce_until_ms = 0
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
  dap.listeners.after.configurationDone["ue_android_bp_config_done"] = function(session)
    if not is_ue_android_lldb_session(session) then return end
    session._ue_android_configuration_done = true
    append_android_bp_diag("== DAP configurationDone ==")
  end
  dap.listeners.after.event_stopped["ue-dap-source-nav"] = function(session, body)
    if dap.session() ~= session then return end
    local cfg = session.config or {}
    local is_ios_entry_stop = cfg._ue_ios_session_owner == "legacy-mobiledevice"
      and body and (body.reason == "entry"
        or tostring(body.description or ""):find("SIGSTOP", 1, true) ~= nil)
    if is_ios_entry_stop then return end
    if is_ue_android_lldb_session(session) then
      local frame = session.current_frame
      append_android_bp_diag({
        "== DAP stopped event ==",
        "reason=" .. tostring(body and body.reason or ""),
        "threadId=" .. tostring(body and body.threadId or ""),
        "hitBreakpointIds=" .. vim.inspect(body and body.hitBreakpointIds or {}),
        "currentFrame=" .. vim.inspect(frame),
      })
      local is_entry_stop = body and (body.reason == "entry"
        or tostring(body.description or ""):find("SIGSTOP", 1, true) ~= nil)
      if is_entry_stop then
        return
      end
    end
    maybe_jump_to_local_source_frame(session, body)
  end

  -- NOTE: nvim-dap's `listeners.before.setBreakpoints` does NOT run before the
  -- request is sent — it runs in the RESPONSE pipeline with the signature
  -- (session, err, response, request, request_seq), same as the after-listener
  -- (see dap/session.lua handle_body L1104-1109; changelog 2026-06-02 pitfall).
  -- So we cannot mutate outgoing `args.source` here. Source-path basename
  -- rewriting for the wire is owned by ue.dap.android (attachCommands + DWARF
  -- match); this listener records the OUTGOING request shape (the original
  -- setBreakpoints arguments live in `request`, which session.lua stores from
  -- `message_requests[seq]`) so the live-plant path below can replay the real
  -- file:line set. `request` here is the request payload table; its breakpoint
  -- lines are under `request.breakpoints` / `request.lines` (NOT nested under
  -- `.arguments` — nvim-dap stashes the arguments table directly).
  dap.listeners.before.setBreakpoints["ue_android_bp_record_request"] = function(session, _err, _response, request)
    if not is_ue_android_lldb_session(session) then return end
    -- `request` may be the raw arguments table or wrap it under `.arguments`
    -- depending on nvim-dap version; handle both.
    local args = request and (request.arguments or request) or nil
    if type(args) ~= "table" then return end
    local lines = args.breakpoints or args.lines or {}
    session._ue_android_last_setbp = {
      source = vim.deepcopy(args.source),
      lines = vim.deepcopy(lines),
    }
  end

  dap.listeners.after.setBreakpoints["ue_android_bp_local_response"] = function(session, _err, response, request)
    if not is_ue_android_lldb_session(session) then return end
    remap_breakpoint_response_to_local_paths(response)
    append_android_bp_diag({
      "== DAP setBreakpoints response ==",
      "configurationDone=" .. tostring(session._ue_android_configuration_done == true),
      vim.inspect(response),
    })
    -- configurationDone gate distinguishes initial sync vs live change:
    --   • before gate  → initial breakpoints already preseeded into
    --     attachCommands by ue.dap.android; nothing more to do here.
    --   • after gate   → a session-time F9 change. The 2026-06-15 gate proved
    --     live planting resolves AND hits on this route, so we plant it live
    --     via the evaluate channel (design D2-B) instead of warning the user
    --     to :UEDAPReattach. The native setBreakpoints response above is kept
    --     in the diag log; the live evaluate path is the one that arms LLDB.
    if session._ue_android_configuration_done ~= true then
      append_android_bp_diag("initial setBreakpoints sync; preseed owns initial breakpoints")
      return
    end
    -- Recover the requested file:line set. Prefer the `request` payload handed
    -- to this same after-listener (authoritative for THIS response); fall back
    -- to the snapshot recorded by the before-listener.
    local snap = session._ue_android_last_setbp
    local req_args = request and (request.arguments or request) or nil
    local source = (req_args and req_args.source) or (snap and snap.source) or nil
    local lines = (req_args and (req_args.breakpoints or req_args.lines))
      or (snap and snap.lines) or {}
    append_android_bp_diag({
      "active-session setBreakpoints: line_count=" .. tostring(type(lines) == "table" and #lines or -1),
    })
    if type(lines) == "table" and #lines > 0 then
      append_android_bp_diag("active-session setBreakpoints → live evaluate plant")
      ue_android_live_plant_via_evaluate(session, source, lines)
    else
      append_android_bp_diag("active-session setBreakpoints with no lines (clear); native response stands")
    end
  end

  -- K33 diagnosis: capture lldb-dap console/output events to a host log file so
  -- the postRunCommands probe (image list / image lookup / breakpoint list)
  -- output is inspectable without a live REPL.
  dap.listeners.after.event_output["ue_android_bp_diag"] = function(session, body)
    if not is_ue_android_lldb_session(session) then return end
    local out = body and body.output
    if type(out) ~= "string" or out == "" then return end
    append_android_bp_diag(out)
    -- Truthful exit reporting: lldb announces the inferior's death only as
    -- `Process <pid> exited with status = N (0x…)` on the console. Capture N
    -- here so the owner can explain it instead of emitting a generic
    -- "App … exited. Detaching." (see lua/ue/dap/exit_reason.lua).
    pcall(function()
      local er = require("ue.dap.exit_reason")
      local status = er.parse_console_exit(out)
      if status then er.note({ status = status, source = "console" }) end
    end)
  end

  dap.listeners.before.scopes["ue_block_globals"] = function(_, _, body)
    D._dap_filter_scopes(body)
  end

  dap.listeners.before.stackTrace["ue_source_path_rewrite"] = function(session, err, response)
    -- ANCHOR-USE:stackTrace — THE CHOKEPOINT for the synthetic-frame defect.
    -- See ANCHOR(ue-synthetic-frame-guard) at the top of this file. This runs
    -- before nvim-dap's built-in event_stopped consumes the stackTrace
    -- response, so neutering synthetic frames here (line=-1 placeholder) is the
    -- single load-bearing fix; the _frame_set patch and bp-response remap are
    -- only thin defence-in-depth around it.
    if err or not response or not response.stackFrames then return end
    local sanitize_synthetic = is_ue_android_lldb_session(session)
      or is_ue_ios_lldb_session(session)
    local filtered = nil
    local sanitized = nil
    for _, frame in ipairs(response.stackFrames) do
      local source = frame.source
      if source and source.path then
        local resolved = resolve_source_path(source.path)
        if resolved then source.path = resolved end
      end

      -- nvim-dap's built-in Session:event_stopped() consumes stackTrace
      -- responses before after.event_stopped listeners run. lldb-dap can
      -- return PC-only frames with line=0/sourceReference>0 for Android
      -- stops; if those reach nvim-dap with a `source` table, jump_to_frame()
      -- opens dap-src:// and tries to cursor to {0, 0}, producing E474.
      --
      -- Do NOT replace an all-synthetic stack with an empty list: upstream
      -- nvim-dap reports "Debug adapter stopped at unavailable location" for
      -- every stopped thread. Keep a non-jumpable placeholder source instead:
      -- jump_to_frame() returns before source_to_bufnr() when line < 0, so it
      -- preserves frameId/scopes without opening dap-src:// or notifying
      -- "Source missing". Real local-file frames and breakpoint hits are kept
      -- untouched.
      if sanitize_synthetic then
        if frame_is_synthetic_or_invalid(frame) then
          local copy = vim.deepcopy(frame)
          copy.line = -1
          copy.column = 1
          copy.source = {
            name = source and source.name or frame.name or "<synthetic>",
          }
          sanitized = sanitized or {}
          sanitized[#sanitized + 1] = copy
        else
          filtered = filtered or {}
          filtered[#filtered + 1] = frame
        end
      end
    end
    if sanitize_synthetic then
      if filtered and #filtered > 0 then
        response.stackFrames = filtered
      else
        response.stackFrames = sanitized or {}
      end
      response.totalFrames = #response.stackFrames
    end
  end

  -- ─── auto re-spawn main code window if user accidentally closes it ─
  -- During a DAP session, dapui panels are buftype=nofile/prompt. If
  -- the user does <C-w>q on the only normal-file window, the next
  -- picker (<space><space>, <space>e, …) lands in a nofile window and
  -- crashes. We watch WinClosed; if after the close there's no
  -- normal-file window left in the tab, we re-spawn one from saved_buf
  -- so the layout stays usable.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = vim.api.nvim_create_augroup("ue_dap_main_window_guard", { clear = true }),
    callback = function()
      if not dap.session() then return end
      vim.schedule(function()
        if not dap.session() then return end
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(w)
             and vim.api.nvim_win_get_config(w).relative == "" then
            local b = vim.api.nvim_win_get_buf(w)
            local ft = vim.bo[b].filetype
            if vim.bo[b].buftype == "" and not ft:find("^dap") then
              return  -- still have a code window, nothing to do
            end
          end
        end
        -- no normal-file window left — re-spawn from saved_buf
        D.dap_focus_main_window()
      end)
    end,
  })

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
      local platforms = require("ue.dap.platforms")
      platforms.dispatch_lifecycle("cleanup", {
        session = session,
        session_state = D._dap_session_state,
      })
      platforms.end_session(session)
      reset_session_state()
    end,
  })
end

--- Inject upstream core utilities. Called once from ue.lua.
function D.setup_core(core_table)
  core = core_table
end

return D
