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
  -- Strip whitespace + newlines so multi-line visual selections become one expr.
  expr = expr:gsub("[\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local dapui_ok, dapui = D.ensure_dapui_loaded()
  if dapui_ok and dapui.elements and dapui.elements.watches
                and dapui.elements.watches.add then
    dapui.elements.watches.add(expr)
    vim.notify("[ue.dap] watch added: " .. expr, vim.log.levels.INFO)
  else
    vim.notify("[ue.dap] dapui watches unavailable — use REPL", vim.log.levels.WARN)
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
    dapui.open({ reset = true })
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
  if ok then dap.repl.toggle() end
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
          for _, sub in ipairs({ "lib/site-packages/lldb", "Lib/site-packages/lldb",
                                  "lib/python3/dist-packages/lldb" }) do
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
      local function adb(args)
        local cmd = { "adb", "-s", serial }
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
    local logs = {
      { name = "dap.log (nvim-dap)",
        path = vim.fn.stdpath("cache") .. "/dap.log" },
      { name = "ue_dap_e2e.log (lldb-dap trace)",
        path = (vim.uv or vim.loop).os_tmpdir() .. "/ue_dap_e2e.log" },
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
    local function collect(label, ok, data)
      lldb_results[#lldb_results + 1] = ("── %s ──\n%s"):format(label,
        ok and (data or "") or "(failed: " .. tostring(data) .. ")")
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
    eval("image list",                           "image list")
    local state = D._dap_session_state or {}
    local so_name = state.symbol_lib and vim.fn.fnamemodify(state.symbol_lib, ":t") or "libUE4.so"
    eval(('image dump symfile "%s"'):format(so_name), "symfile " .. so_name)
    eval("settings show target.source-map",      "source-map")
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

-- ─────────────────────────────────────────────────────────────────────
-- setup_dap — wire dap-ui listeners, logcat, source-path rewrite,
-- scope filter, VimLeavePre cleanup. Called by lua/plugins/dap.lua.
-- ─────────────────────────────────────────────────────────────────────

function D.setup_dap(dap, dapui)
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

  -- Register a generic cpp configuration so a plain `:DapContinue` / `<F5>`
  -- from any C/C++ buffer drops the user into the UE Android attach picker.
  -- The attach driver builds the real lldb-dap config inside
  -- ue.dap.android.attach (which mutates dap.adapters.lldb if needed); this
  -- entry is just the launcher.
  do
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
    -- Guarantee the editor area holds a real file buffer (NOT a leftover
    -- dap-src:// stub from a previous session). dapui.open() docks its
    -- panels around whatever the current window holds; if that window
    -- has a 1-line nofile buffer the code area collapses to 1 row.
    if saved_buf and vim.api.nvim_buf_is_valid(saved_buf)
       and vim.bo[saved_buf].buftype == "" then
      pcall(vim.api.nvim_set_current_buf, saved_buf)
    end
    dapui.open()
    start_logcat()
    vim.defer_fn(open_logcat_window, 200)
    -- Mark progress popup as done.
    pcall(function() require("ue.dap._progress").done("debugger attached") end)
  end
  dap.listeners.before.event_terminated["dapui_config"] = function() on_session_end() end
  dap.listeners.before.event_exited["dapui_config"]     = function() on_session_end() end
  dap.listeners.after.disconnect["dapui_config"]        = function() on_session_end() end

  -- ─── Rewire `dap.terminate` for UE Android Attach sessions ────────
  -- The dapui controls bar's ■ button (and any plain `:lua require("dap")
  -- .terminate()` invocation) issues a DAP `terminate` request.  codelldb
  -- maps `terminate` to SIGKILL the inferior — fine for `launch` but
  -- catastrophic for `attach` (it kills the game we just attached to).
  --
  -- For our "UE Android Attach" sessions (cfg.request == "launch" but
  -- semantically attach via gdb-remote) we transparently redirect
  -- terminate -> disconnect{terminateDebuggee=false}, i.e. a clean
  -- detach that leaves the device-side process running.  Other sessions
  -- (Win64 Launch / Linux Launch) keep the original terminate semantics.
  if not D._dap_terminate_rewired then
    local orig_terminate = dap.terminate
    dap.terminate = function(opts, terminate_opts, cb)
      local sess = dap.session()
      local cfg = sess and sess.config or nil
      local is_ue_attach =
        cfg and tostring(cfg.name or ""):match("UE Android Attach") ~= nil
      if is_ue_attach then
        return dap.disconnect({ terminateDebuggee = false }, cb)
      end
      return orig_terminate(opts, terminate_opts, cb)
    end
    D._dap_terminate_rewired = true
  end

  -- Wire persistent breakpoints (per-project json under
  -- <engine_root>/.cache/nvim-ue/breakpoints/<project>.json).  setup()
  -- installs autocmds for BufReadPost restore + VimLeavePre flush.
  pcall(function()
    require("ue.dap._persist_bp").setup()
  end)

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
    -- Auto-continue on benign stops that the user did not request:
    --   * `entry` — stopOnEntry=true on Android attach lands us in 174
    --     SIGSTOP events (one per thread) the instant `process attach`
    --     returns. Without auto-continue, the inferior sits frozen, the
    --     watchdog (Android system_server) eventually flags it as ANR
    --     and may relaunch the app — observed as "PID jumps after attach".
    --   * `exception` — Android delivers stray SIGSEGV/SIGSTOP/SIGBUS on
    --     unrelated threads (Chrome_IOThread, Signal Catcher, …). Stopping
    --     on them freezes the app and confuses the user.
    -- A real breakpoint hit reports `hitBreakpointIds`; a user-requested
    -- pause reports `reason = "pause"`. Both bypass auto-continue.
    body = body or {}
    local reason = tostring(body.reason or ""):lower()
    local has_bp = body.hitBreakpointIds and #body.hitBreakpointIds > 0
    local is_benign = (reason == "entry" or reason == "exception") and not has_bp
    if is_benign then
      vim.defer_fn(function()
        if dap.session() == session and D._dap_run_state == "stopped" then
          request_dap_continue(dap)
        end
      end, 50)
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
