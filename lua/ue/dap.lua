-- ue/dap.lua â Android DAP debugging via CodeLLDB
-- Extracted from the monolithic ue.lua. Upstream utility functions are
-- accessed via the `core` table injected by D.setup().

local D = {}

-- Upstream utilities â set by D.setup()
local core = {}

-- Phase J: shared probes for android_package + lldb-server. Both honour
-- ue.config first, then fall back to the existing prompts. Keeping them
-- as D._<name>_for_test makes them reachable from headless smoke without
-- spinning up a real adb session.

local function ue_cfg_get(key)
  local ok, cfg = pcall(require, "ue.config")
  if ok and cfg and cfg.get then return cfg.get(key) end
  return nil
end

local function fs_is_file(path)
  if not path or path == "" then return false end
  return vim.fn.filereadable(path) == 1
end

--- Resolve an android package name without prompting unless necessary.
--- Order: persisted state → ue.config.dap.android_package → prompt.
function D._pick_android_package_for_test(state_value)
  local saved = state_value or ""
  if saved ~= "" then return saved end
  local cfg_pkg = ue_cfg_get("dap.android_package")
  if type(cfg_pkg) == "string" and cfg_pkg ~= "" then return cfg_pkg end
  return vim.fn.input("Android package name: ", "")
end

--- Resolve the path to an arm64 lldb-server.
--- Order: ue.config.dap.lldb_server_path → glob list → prompt.
function D._pick_lldb_server_for_test(globs)
  local cfg_path = ue_cfg_get("dap.lldb_server_path")
  if type(cfg_path) == "string" and cfg_path ~= "" and fs_is_file(cfg_path) then
    return cfg_path
  end
  for _, pattern in ipairs(globs or {}) do
    local hit = vim.fn.glob(pattern)
    if hit and hit ~= "" then return hit end
  end
  return vim.fn.input("Path to arm64 lldb-server: ")
end

-- Module state (was M._xxx in ue.lua)
D._dap_session_state = {}
D._breakpoint_specs = {}
D._dap_attach_in_progress = false
D._dap_run_state = "idle"
D._continue_debounce_until_ms = 0
D._dap_source_file_cache = {}

local function mono_ms()
  local uv = vim.uv or vim.loop
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1e6)
  end
  return math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
end

local function reset_android_dap_state()
  D._dap_attach_in_progress = false
  D._dap_run_state = "idle"
  D._continue_pending = false
  D._continue_debounce_until_ms = 0
  D._pause_pending = false
  D._dap_source_file_cache = {}
  D._dap_session_state = {}
  for _, spec in pairs(D._breakpoint_specs or {}) do
    spec.runtime_breakpoint_id = nil
  end
end

local function stop_process_tree(pid)
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    return false
  end
  if core.is_native_windows() then
    vim.fn.system({ "taskkill", "/F", "/T", "/PID", tostring(pid) })
  else
    vim.fn.system({ "kill", "-9", tostring(pid) })
  end
  return vim.v.shell_error == 0
end

local function cleanup_remote_android_lldb(state)
  state = state or {}
  if not state.package_name then
    return
  end
  local adb = state.adb or "adb"
  local serial = core.trim(state.serial or "")
  local serial_args = {}
  if serial ~= "" then
    serial_args = { "-s", serial }
  end
  -- Kill lldb-server on device
  local kill_cmd = { adb }
  vim.list_extend(kill_cmd, serial_args)
  vim.list_extend(kill_cmd, { "shell", "run-as " .. state.package_name .. " sh -c 'pkill -9 lldb-server 2>/dev/null'" })
  vim.fn.jobstart(kill_cmd, { detach = true })
  -- Remove adb port forward
  local port = state.port or 5039
  local fwd_cmd = { adb }
  vim.list_extend(fwd_cmd, serial_args)
  vim.list_extend(fwd_cmd, { "forward", "--remove", "tcp:" .. port })
  vim.fn.jobstart(fwd_cmd, { detach = true })
end

local function kill_managed_codelldb_processes()
  if not core.is_native_windows() then
    return 0
  end
  local adapter, _, _ = D.codelldb_paths()
  if not adapter then
    return 0
  end
  local shell = core.first_executable({ "pwsh", "powershell", "powershell.exe" })
  if not shell then
    return 0
  end
  local escaped = core.norm(adapter):gsub("/", "\\"):gsub("'", "''")
  local cmd = ([[Get-Process codelldb -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq '%s' } | ForEach-Object { $id = $_.Id; Stop-Process -Id $id -Force -ErrorAction SilentlyContinue; $id }]]):format(escaped)
  local code, lines = core.run_lines({ shell, "-NoProfile", "-NonInteractive", "-Command", cmd })
  if code ~= 0 then
    return 0
  end
  local killed = 0
  for _, line in ipairs(lines or {}) do
    if core.trim(line):match("^%d+$") then
      killed = killed + 1
    end
  end
  return killed
end

function D.stop_android_debugger(opts)
  opts = opts or {}
  local dap_ok, dap = pcall(require, "dap")
  local session = dap_ok and dap.session and dap.session() or nil
  local state = D._dap_session_state or {}
  local adapter_pid = session and session.adapter and session.adapter.pid or nil

  if session then
    pcall(function()
      session:request("disconnect", { terminateDebuggee = false })
    end)
  end
  if adapter_pid then
    stop_process_tree(adapter_pid)
  end

  cleanup_remote_android_lldb(state)
  reset_android_dap_state()

  local killed = 0
  if opts.kill_orphans then
    killed = kill_managed_codelldb_processes()
  end
  return {
    disconnected = session ~= nil,
    adapter_killed = adapter_pid ~= nil,
    orphan_killed = killed,
  }
end

local function clear_android_breakpoint_state()
  D._breakpoint_specs = {}
  pcall(vim.fn.sign_unplace, "ue_dap_bp")
end

local function save_breakpoints()
  local ctx = core.resolve_context()
  if not ctx then return end
  local specs = D._breakpoint_specs or {}
  -- Convert to a serialisable list
  local list = {}
  for key, spec in pairs(specs) do
    list[#list + 1] = {
      key = key,
      set_command = spec.set_command,
      clear_command = spec.clear_command,
      set_commands = spec.set_commands,
      clear_commands = spec.clear_commands,
      file = spec.file,
      line = spec.line,
    }
  end
  core.update_state_field(ctx.engine_root, "breakpoints", list)
end

local function load_breakpoints()
  local ctx = core.resolve_context()
  if not ctx then return end
  local state = core.read_state(ctx.engine_root)
  local list = state and state.breakpoints or {}
  if type(list) ~= "table" or #list == 0 then return end

  vim.fn.sign_define("UEDapBreakpoint", { text = "●", texthl = "DiagnosticError" })

  for _, entry in ipairs(list) do
    local key = core.trim(entry.key)
    local line = tonumber(entry.line)
    local path = key:match("^(.+):%d+$")
    if key ~= "" and line and line > 0 and path and path ~= "" then
      D._breakpoint_specs[key] = D._dap_make_breakpoint_spec(path, line)
      -- Restore sign if the buffer is loaded
      local bufnr = vim.fn.bufnr(path)
      if bufnr ~= -1 then
        vim.fn.sign_place(line, "ue_dap_bp", "UEDapBreakpoint", bufnr, { lnum = line })
      end
    end
  end
  -- For files not yet loaded, place signs when they open
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("ue_dap_bp_restore", { clear = true }),
    callback = function(ev)
      local buf_path = core.norm(vim.api.nvim_buf_get_name(ev.buf))
      if buf_path == "" then return end
      for key, spec in pairs(D._breakpoint_specs) do
        local kpath = key:match("^(.+):%d+$")
        if kpath and core.norm(kpath) == buf_path then
          vim.fn.sign_define("UEDapBreakpoint", { text = "●", texthl = "DiagnosticError" })
          vim.fn.sign_place(spec.line, "ue_dap_bp", "UEDapBreakpoint", ev.buf, { lnum = spec.line })
        end
      end
    end,
  })
end

local function basename(path)
  return path:match("([^/\\]+)$") or path
end

local function is_sigstop_stop(body)
  if type(body) ~= "table" then
    return false
  end
  local text = table.concat({
    tostring(body.reason or ""),
    tostring(body.description or ""),
    tostring(body.text or ""),
  }, " "):lower()
  return text:find("sigstop", 1, true) ~= nil
end

local function frame_has_local_source(frame)
  local source = frame and frame.source or nil
  if not source then
    return false
  end
  if tonumber(source.sourceReference or 0) ~= 0 then
    return false
  end
  local path = core.norm(source.path or "")
  if path == "" or path:match("^[a-z]+://") then
    return false
  end
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
    if frame_has_local_source(frame) then
      return frame
    end
  end
  return nil
end

local function request_stack_frames(session, thread_id, cb)
  if not session or not thread_id then
    if cb then cb(nil) end
    return
  end
  session:request("stackTrace", {
    threadId = thread_id,
    startFrame = 0,
    levels = 20,
  }, function(err, response)
    if err then
      if cb then cb(nil, err) end
      return
    end
    local frames = response and response.stackFrames or nil
    local thread = session.threads and session.threads[thread_id] or nil
    if thread and frames then
      thread.frames = frames
    end
    if cb then cb(frames) end
  end)
end

local function maybe_jump_to_local_source_frame(session, body)
  if not session or D._dap_attach_in_progress or is_sigstop_stop(body) then
    return
  end
  if frame_has_local_source(session.current_frame) then
    return
  end

  local thread_id = (body and body.threadId) or session.stopped_thread_id
  if not thread_id then
    return
  end

  local function jump_from_frames(frames)
    if frame_has_local_source(session.current_frame) then
      return
    end
    local frame = pick_local_source_frame(frames)
    if not frame then
      return
    end
    if type(session._frame_set) == "function" then
      session:_frame_set(frame)
      return
    end
    local source = frame.source or {}
    local path = core.norm(source.path or "")
    if path == "" then
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { frame.line or 1, math.max((frame.column or 1) - 1, 0) })
  end

  local thread = session.threads and session.threads[thread_id] or nil
  if thread and thread.frames and #thread.frames > 0 then
    jump_from_frames(thread.frames)
    return
  end

  request_stack_frames(session, thread_id, function(frames)
    vim.schedule(function()
      jump_from_frames(frames)
    end)
  end)
end

local function request_dap_continue(dap)
  local session = dap and dap.session and dap.session() or nil
  if not session then
    return false
  end
  D._continue_pending = true
  D._dap_run_state = "resuming"
  D._continue_debounce_until_ms = mono_ms() + 750
  local ok, err = pcall(dap.continue)
  if ok then
    return true
  end
  D._continue_pending = false
  D._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  D._continue_debounce_until_ms = 0
  vim.notify("Continue failed: " .. tostring(err), vim.log.levels.WARN)
  return false
end

-- Simple slash-to-backslash for paths that are already Windows-native (no WSL
-- conversion needed).  Used by DAP config builders below.
local function slash_to_backslash(p)
  if not p or p == "" then return nil end
  return (tostring(p):gsub("/", "\\"))
end

function D.codelldb_paths()
  local candidates = {
    vim.fn.stdpath("data") .. "/codelldb/extension/extension",
    vim.fn.stdpath("config") .. "/data/codelldb/extension/extension",
  }
  for _, root in ipairs(candidates) do
    local adapter = root .. "/adapter/codelldb"
    local liblldb = root .. "/lldb/bin/liblldb"
    if vim.fn.has("win32") == 1 then
      adapter = adapter .. ".exe"
      liblldb = liblldb .. ".dll"
    elseif vim.fn.has("mac") == 1 then
      liblldb = liblldb .. ".dylib"
    else
      liblldb = liblldb .. ".so"
    end
    if vim.fn.filereadable(adapter) == 1 then
      return adapter, liblldb, root
    end
  end
  return nil, nil, nil
end

function D._reapply_breakpoints(cb)
  local specs = D._breakpoint_specs or {}
  local keys = vim.tbl_keys(specs)
  if #keys == 0 then
    if cb then cb() end
    return
  end
  local pending = #keys
  local restored = 0
  local failed = {}
  local function done()
    pending = pending - 1
    if pending <= 0 then
      -- After all BPs set, check resolved status
      D._dap_eval_lldb("breakpoint list", function(_, bp_list)
        vim.schedule(function()
          local total, resolved = 0, 0
          if bp_list then
            for n in bp_list:gmatch("resolved = (%d+)") do
              total = total + 1
              resolved = resolved + tonumber(n)
            end
          end
          local parts = { ("BPs restored: %d/%d"):format(restored, #keys) }
          if total > 0 then
            parts[#parts + 1] = ("resolved: %d/%d"):format(resolved, total)
          end
          if #failed > 0 then
            local sample = {}
            for i = 1, math.min(#failed, 3) do
              sample[#sample + 1] = failed[i]
            end
            parts[#parts + 1] = ("failed: %d"):format(#failed)
            parts[#parts + 1] = table.concat(sample, "\n")
          end
          local level = (#failed == 0 and resolved > 0) and vim.log.levels.INFO or vim.log.levels.WARN
          vim.notify(table.concat(parts, "\n"), level)
        end)
        if cb then cb() end
      end)
    end
  end
  for _, key in ipairs(keys) do
    local spec = specs[key]
    -- After ASLR fix, use the canonical set_command directly.
    -- Do NOT use _dap_try_set_breakpoint here: CodeLLDB REPL evaluate returns ""
    -- for breakpoint commands, so the multi-variant fallback creates 9 duplicate
    -- breakpoints per spec (none get deleted because resolution is never detected).
    local cmd = spec.set_command
    if not cmd or cmd == "" then
      failed[#failed + 1] = ("%s:%d: no set_command"):format(spec.file or "?", spec.line or 0)
      done()
    else
      D._dap_eval_lldb(cmd, function(ok, result)
        if ok then
          restored = restored + 1
          -- Try to extract breakpoint id from console output (may be empty for CodeLLDB)
          local bp_id = tostring(result or ""):match("Breakpoint%s+(%d+):")
          if bp_id then
            spec.runtime_breakpoint_id = bp_id
          end
        else
          failed[#failed + 1] = ("%s:%d: %s"):format(spec.file or "?", spec.line or 0, tostring(result))
        end
        done()
      end)
    end
  end
end

local function android_symbol_copy_root(ctx)
  local project_root = ctx and ctx.project_root or ""
  local project_name = core.trim(vim.fs.basename(project_root))
  if project_name == "" then
    project_name = "default"
  end
  return core.join(vim.fn.stdpath("cache"), "ue", "android-symbols", project_name)
end

local function copy_file_if_needed(source, dest)
  source = core.norm(source)
  dest = core.norm(dest)
  if source == "" or dest == "" or not core.is_file(source) then
    return nil, "source file not found"
  end

  local src_stat = core.file_stat(source)
  local dest_stat = core.file_stat(dest)
  local needs_copy = not dest_stat
    or (src_stat and dest_stat and src_stat.size ~= dest_stat.size)
    or core.file_mtime(source) > core.file_mtime(dest)

  if not needs_copy then
    return dest
  end

  core.ensure_dir(core.dirname(dest))
  if vim.uv and vim.uv.fs_copyfile then
    local ok, err = vim.uv.fs_copyfile(source, dest)
    if ok then
      return dest
    end
    return nil, err or "fs_copyfile failed"
  end

  local ok, err = pcall(vim.fn.writefile, vim.fn.readblob(source), dest, "b")
  if ok then
    return dest
  end
  return nil, err or "writefile failed"
end

local function android_symbol_candidates(project_root)
  if project_root == "" then
    return {}
  end

  local patterns = {
    core.join(project_root, "Binaries", "Android", "*.so"),
    core.join(project_root, "Source", "*", "Binaries", "Android", "*.so"),
    core.join(project_root, "Intermediate", "Android", "arm64", "jni", "arm64-v8a", "libUE4.so"),
    core.join(project_root, "Intermediate", "Android", "arm64", "jni", "arm64-v8a", "libUnreal.so"),
  }
  local candidates = {}
  local seen = {}
  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(core.glob_paths(pattern)) do
      if core.is_file(path) and not seen[path] then
        seen[path] = true
        table.insert(candidates, path)
      end
    end
  end
  table.sort(candidates, function(a, b)
    local a_intermediate = core.path_has_prefix(a, core.join(project_root, "Intermediate"))
    local b_intermediate = core.path_has_prefix(b, core.join(project_root, "Intermediate"))
    if a_intermediate ~= b_intermediate then
      return not a_intermediate
    end
    return core.file_mtime(a) > core.file_mtime(b)
  end)
  return candidates
end

local function resolve_android_symbol_lib(ctx)
  local project_root = ctx and ctx.project_root or ""
  for _, path in ipairs(android_symbol_candidates(project_root)) do
    return path
  end
  return ""
end

local function snapshot_android_symbol_lib(ctx, symbol_lib)
  symbol_lib = core.norm(symbol_lib)
  if symbol_lib == "" or not core.is_file(symbol_lib) then
    return symbol_lib, nil
  end

  local basename = core.trim(vim.fs.basename(symbol_lib))
  if basename == "" then
    return symbol_lib, nil
  end

  local snapshot_dir = android_symbol_copy_root(ctx)
  local snapshot = core.join(snapshot_dir, basename)
  local copied, err = copy_file_if_needed(symbol_lib, snapshot)
  if copied then
    return copied, nil
  end
  return symbol_lib, err
end

function D._setup_aslr_listeners(dap, attach_state, progress_update)
  local handled = false
  local function do_aslr_and_continue()
    if handled then return end
    handled = true
    dap.listeners.after.event_stopped["ue_aslr_fix"] = nil
    dap.listeners.after.event_initialized["ue_aslr_fix"] = nil
    progress_update("applying ASLR fix...")
    D._apply_aslr_fix(attach_state, function(ok)
      local function do_continue()
        -- MUST use dap.continue() to keep nvim-dap state in sync.
        -- Using _dap_eval_lldb("process continue") bypasses the DAP protocol
        -- and leaves nvim-dap unaware the process is running, which causes:
        -- 1) no auto-jump to source on breakpoint hit
        -- 2) F5 sends duplicate continue → CodeLLDB disconnects
        vim.schedule(function()
          progress_update("READY")
          request_dap_continue(dap)
          D._dap_attach_in_progress = false
        end)
      end
      if ok then
        progress_update("ASLR fix applied, syncing breakpoints...")
        D._reapply_breakpoints(function() do_continue() end)
      else
        progress_update("ASLR fix FAILED — continuing without fix", vim.log.levels.WARN)
        do_continue()
      end
    end)
  end
  -- Primary: on first stopped event (SIGSTOP from attach)
  dap.listeners.after.event_stopped["ue_aslr_fix"] = function(dap_session)
    if dap.session() ~= dap_session then return end
    progress_update("stopped event received")
    do_aslr_and_continue()
  end
  -- Fallback: if event_stopped doesn't fire within 5s
  dap.listeners.after.event_initialized["ue_aslr_fix"] = function()
    dap.listeners.after.event_initialized["ue_aslr_fix"] = nil
    progress_update("DAP initialized, waiting for stopped event...")
    vim.defer_fn(function()
      if not handled then
        progress_update("stopped event timeout, applying ASLR fix anyway...")
        do_aslr_and_continue()
      end
    end, 5000)
  end
end

function D._apply_aslr_fix(session_state, cb)
  local pid = session_state.pid
  -- The symbol file on disk (e.g. Client-arm64.so) is the LOCAL path passed
  -- to LLDB `target create`.  The on-device .so loaded into the running
  -- process has a different name (UE main module is usually libUE4.so or
  -- libUnreal.so).  We search /proc/<pid>/maps for the device-side name and
  -- tell LLDB to slide the locally-loaded module by that base address.
  local device_so_candidates = { "libUE4.so", "libUnreal.so" }
  local pkg = session_state.package_name or ""
  local adb = session_state.adb or "adb"
  -- The LOCAL symbol .so passed to `target create` becomes an LLDB module
  -- whose name is its basename (e.g. Client-arm64.so). `target modules load
  -- --file` must reference that LLDB module name, NOT the device-side .so.
  local lldb_module = vim.fn.fnamemodify(session_state.symbol_lib or "", ":t")
  if lldb_module == "" then lldb_module = "libUE4.so" end
  local cb_fired = false

  local function fire_cb(ok, msg)
    if cb_fired then return end
    cb_fired = true
    if msg then
      vim.notify("ASLR fix: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR)
      if not ok then require("utils.log").error("dap.aslr", msg) end
    end
    if cb then cb(ok) end
  end

  local function parse_base(text, candidates)
    for line in text:gmatch("[^\r\n]+") do
      for _, name in ipairs(candidates) do
        if line:find(name, 1, true) then
          return line:match("(%x+)%-")
        end
      end
    end
    return nil
  end

  local function apply_slide(base_addr)
    local base_hex = "0x" .. base_addr
    vim.notify("ASLR fix: " .. lldb_module .. " base=" .. base_hex)
    D._dap_eval_lldb(
      ("target modules load --file %s --slide %s"):format(lldb_module, base_hex),
      function(ok2, result2)
        vim.schedule(function()
          if ok2 then
            D._dap_eval_lldb("image list " .. lldb_module, function(_, img)
              vim.schedule(function()
                vim.notify("ASLR fix applied (slide=" .. base_hex .. ")\n" .. (img or ""))
                fire_cb(true, nil)
              end)
            end)
          else
            fire_cb(false, "target modules load FAILED: " .. tostring(result2))
          end
        end)
      end
    )
  end

  local function fallback_adb()
    if pkg == "" then
      fire_cb(false, "no package_name for adb fallback")
      return
    end
    vim.notify("ASLR fix: trying adb run-as fallback...")
    vim.fn.jobstart({ adb, "shell", "run-as", pkg, "cat", "/proc/" .. pid .. "/maps" }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        local text = table.concat(data or {}, "\n")
        local base = parse_base(text, device_so_candidates)
        if base then
          vim.schedule(function() apply_slide(base) end)
        else
          -- Diagnostic: dump every .so seen in maps so the user can pick the
          -- real device-side UE module name and add it to device_so_candidates.
          local seen = {}
          for so in text:gmatch("/[^%s]+%.so") do
            seen[vim.fn.fnamemodify(so, ":t")] = true
          end
          local names = {}
          for n, _ in pairs(seen) do table.insert(names, n) end
          table.sort(names)
          local hint = #names > 0
              and ("\nLibs seen on device: " .. table.concat(names, ", "))
              or "\n(maps was empty — adb run-as likely denied; try: adb shell run-as " .. pkg .. " cat /proc/" .. pid .. "/maps)"
          vim.schedule(function()
            fire_cb(false, "no candidate of {" .. table.concat(device_so_candidates, ", ") .. "} found in /proc/" .. pid .. "/maps" .. hint)
          end)
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.schedule(function() fire_cb(false, "adb run-as exit " .. code) end)
        end
      end,
    })
  end

  -- Read /proc/<pid>/maps directly via adb. The previously-tried "primary"
  -- path (LLDB `platform shell grep ...` against remote-android platform)
  -- does NOT work: lldb-server's android platform sandbox replies
  -- "error: unable to run remote process" for arbitrary shell commands,
  -- which codelldb forwards as a console message and never resolves the
  -- evaluate request — causing a 15-second hang for nothing.
  fallback_adb()

  vim.defer_fn(function() fire_cb(false, "timed out (15s)") end, 15000)
end

function D._android_dap_config(session)
  local target_create = {}
  if session.symbol_lib then
    table.insert(target_create, ('target create "%s"'):format(session.symbol_lib))
  end
  for _, sp in ipairs(session.exec_search_paths or {}) do
    table.insert(target_create, ('settings append target.exec-search-paths "%s"'):format(sp))
  end
  local formatter = vim.fn.stdpath("config") .. "/data/UE4DataFormatters_2ByteChars.py"
  local init_commands = {
    "settings set stop-disassembly-display never",
    "settings set target.inline-breakpoint-strategy always",
    "settings set target.move-to-nearest-code true",
    "settings set target.process.stop-on-sharedlibrary-events false",
    "platform select remote-android",
  }
  if vim.uv.fs_stat(formatter) then
    table.insert(init_commands, ('command script import "%s"'):format(formatter:gsub("\\", "/")))
  end
  return {
    name = "UE Android Attach",
    type = "codelldb",
    request = "attach",
    breakpointMode = "file",
    stopOnEntry = false,
    program = session.symbol_lib,
    cwd = session.project_root or vim.fn.getcwd(),
    sourceLanguages = { "cpp" },
    sourceMap = (session.source_map and next(session.source_map)) and session.source_map or vim.empty_dict(),
    initCommands = init_commands,
    targetCreateCommands = target_create,
    processCreateCommands = {
      ('platform connect "%s"'):format(session.connect_uri),
      ("process attach -p %s"):format(session.pid),
      "settings set target.process.thread.step-avoid-regexp ''",
      "process handle SIGSTOP -p true -s false -n false",
      "process handle SIGSEGV -p true -s false -n false",
      "process handle SIGBUS -p true -s false -n false",
      "process handle SIGPIPE -p true -s false -n false",
    },
    preTerminateCommands = { "process detach" },
  }
end

function D._android_preflight_ps1(session)
  local pkg = session.package_name
  local port = session.port or 5039
  return ([[
$ErrorActionPreference = "Stop"
$adb = "]] .. (session.adb or "adb") .. [["
$port = ]] .. port .. [[

$serial = (& $adb devices | Select-String "^\S+\s+device$" | Select-Object -First 1).Line.Split()[0]
if (-not $serial) { throw "No Android device found" }
Write-Host "serial=$serial"
$raw = (& $adb -s $serial shell pidof -s "]] .. pkg .. [[" 2>$null)
$targetPid = (($raw | Out-String) -replace '\D','').Trim()
if (-not $targetPid) { throw "Process ]] .. pkg .. [[ not running" }
Write-Host "pid=$targetPid"
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c 'pkill -9 lldb-server 2>/dev/null; rm -rf /data/data/]] .. pkg .. [[/lldb 2>/dev/null'" 2>$null
& $adb -s $serial shell "run-as ]] .. pkg .. [[ mkdir -p /data/data/]] .. pkg .. [[/lldb/bin"
& $adb -s $serial push "]] .. session.lldb_server_path .. [[" "/data/local/tmp/lldb-server"
& $adb -s $serial shell "cat /data/local/tmp/lldb-server | run-as ]] .. pkg .. [[ sh -c 'cat > /data/data/]] .. pkg .. [[/lldb/bin/lldb-server && chmod 700 /data/data/]] .. pkg .. [[/lldb/bin/lldb-server'"
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c '/data/data/]] .. pkg .. [[/lldb/bin/lldb-server platform --server --listen tcp://0.0.0.0:$port </dev/null >/dev/null 2>&1 & echo started'"
$retries = 0
$lldbPid = ""
while ($retries -lt 5) {
    Start-Sleep -Milliseconds 500
    $lldbPid = ((& $adb -s $serial shell "run-as ]] .. pkg .. [[ pidof lldb-server" 2>$null) | Out-String).Trim()
    if ($lldbPid) { break }
    $retries++
}
if (-not $lldbPid) { throw "lldb-server failed to start" }
Write-Host "lldb-server pid=$lldbPid"
try { & $adb -s $serial forward --remove tcp:$port 2>$null } catch {}
& $adb -s $serial forward tcp:$port tcp:$port
Write-Host "connect_uri=connect://[$serial]:$port"
$targetPid | Out-File -Encoding ascii "]] .. session.pid_file .. [["
$serial | Out-File -Encoding ascii "]] .. session.serial_file .. [["
Write-Host "PREFLIGHT_OK"
]])
end

function D.android_dap_attach()
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok then
    require("utils.log").notify_error("dap", "nvim-dap not installed")
    return
  end
  if D._dap_attach_in_progress then
    vim.notify("DAP attach/launch already in progress", vim.log.levels.WARN)
    return
  end
  if vim.fn.exepath("adb") == "" then
    require("utils.log").notify_error("dap", "adb not found in PATH")
    return
  end
  local ctx = core.resolve_context() or {}
  local project_root = ctx.project_root or ""
  local engine_root = ctx.engine_root or ""
  local state = ctx.state or {}

  -- Prefer non-Intermediate .so and debug against a snapshot copy so builds can replace the original.
  local symbol_lib = resolve_android_symbol_lib(ctx)
  if symbol_lib == "" then
    local default = project_root ~= "" and (project_root .. "/") or ""
    symbol_lib = vim.fn.input("Path to symbol .so (with debug symbols): ", default)
  end
  if symbol_lib == "" then return end
  local original_symbol_lib = symbol_lib
  local snapshot_err
  symbol_lib, snapshot_err = snapshot_android_symbol_lib(ctx, symbol_lib)
  if snapshot_err then
    vim.notify("Android symbols snapshot failed, using original .so: " .. snapshot_err, vim.log.levels.WARN)
    require("utils.log").warn("dap.attach", "snapshot failed: %s", snapshot_err)
  end

  -- Package name: read from persisted state, fallback to prompt
  local saved_pkg = state.android_package or ""
  local package_name = saved_pkg
  if package_name == "" then
    package_name = vim.fn.input("Android package name: ", "")
  end
  if package_name == "" then return end
  -- Persist for next attach
  if engine_root ~= "" and package_name ~= saved_pkg then
    core.update_state_field(engine_root, "android_package", package_name)
    core.invalidate_status_cache()
  end

  -- lldb-server: ue.config first, then Android Studio + NDK globs, then prompt
  local localappdata = vim.fn.expand("$LOCALAPPDATA")
  -- IMPORTANT: lldb-server must come from the SAME NDK version that built the UE
  -- game .so. Mismatched versions (e.g. NDK r25 client vs NDK r21 game) handshake
  -- OK then drop the connection during register/auxv exchange. UE 4.x/5.x ships
  -- with NDK 21.4.7075529 by default — prefer that, then fall back to others.
  local search_patterns = {
    localappdata .. "/Android/Sdk/ndk/21.*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
    localappdata .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server",
    localappdata .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
  }
  local as_lldb = D._pick_lldb_server_for_test(search_patterns)
  if as_lldb == "" then return end

  local tmpdir = vim.fn.tempname():gsub("[/\\][^/\\]*$", "")
  local dap_port = 5039
  local attach_state = {
    package_name = package_name,
    symbol_lib = slash_to_backslash(symbol_lib) or symbol_lib,
    original_symbol_lib = slash_to_backslash(original_symbol_lib) or original_symbol_lib,
    lldb_server_path = slash_to_backslash(as_lldb) or as_lldb,
    project_root = slash_to_backslash(project_root) or project_root,
    engine_root = slash_to_backslash(engine_root) or engine_root,
    adb = slash_to_backslash(vim.fn.exepath("adb")) or "adb",
    port = dap_port,
    pid_file = slash_to_backslash(tmpdir .. "/ue_dap_pid.txt"),
    serial_file = slash_to_backslash(tmpdir .. "/ue_dap_serial.txt"),
    exec_search_paths = { slash_to_backslash(vim.fn.fnamemodify(symbol_lib, ":h")) },
    source_map = {},
  }
  if engine_root ~= "" then
    local er = engine_root:gsub("\\", "/")
    attach_state.source_map[er] = er
  end
  if project_root ~= "" then
    local pr = project_root:gsub("\\", "/")
    attach_state.source_map[pr] = pr
  end

  D._dap_attach_in_progress = true
  D._dap_run_state = "attaching"
  D._dap_source_file_cache = {}
  local progress = { "DAP Attach" }
  local notify_id = "ue_dap_attach"
  local function progress_update(msg, level)
    table.insert(progress, msg)
    vim.notify(table.concat(progress, "\n"), level or vim.log.levels.INFO, { id = notify_id, title = "DAP Attach" })
    if level == vim.log.levels.ERROR then
      require("utils.log").error("dap.attach", msg)
    elseif level == vim.log.levels.WARN then
      require("utils.log").warn("dap.attach", msg)
    end
  end

  progress_update("starting preflight...")
  local ps1 = D._android_preflight_ps1(attach_state)
  local preflight_done = false
  local preflight_job = vim.fn.jobstart({ "powershell", "-NoProfile", "-Command", ps1 }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update(line) end) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update("ERR: " .. line, vim.log.levels.WARN) end) end
      end
    end,
    on_exit = function(_, code)
      preflight_done = true
      vim.schedule(function()
        if code ~= 0 then
          D._dap_attach_in_progress = false
          D._dap_run_state = "idle"
          progress_update("FAILED (exit " .. code .. ")", vim.log.levels.ERROR)
          return
        end
        local pid = core.trim((vim.fn.readfile(attach_state.pid_file) or {})[1] or "")
        local serial = core.trim((vim.fn.readfile(attach_state.serial_file) or {})[1] or "")
        -- LLDB platform=remote-android requires connect://[<serial>]:<port>.
        -- "connect://localhost:<port>" is rejected by remote-android with
        -- "Invalid URL:" even though tcp forwarding is set up correctly.
        local connect_uri = (serial ~= "" and ("connect://[%s]:%d"):format(serial, attach_state.port or 5039))
          or ("connect://localhost:%d"):format(attach_state.port or 5039)
        if pid == "" then
          D._dap_attach_in_progress = false
          D._dap_run_state = "idle"
          progress_update("no PID produced", vim.log.levels.ERROR)
          return
        end
        attach_state.pid = pid
        attach_state.serial = serial
        attach_state.connect_uri = connect_uri
        D._dap_session_state = attach_state
        progress_update(("pid=%s, connecting DAP..."):format(pid))
        D._setup_aslr_listeners(dap, attach_state, progress_update)
        dap.run(D._android_dap_config(attach_state))
      end)
    end,
  })
  -- Timeout: kill preflight if it hangs (device disconnected, adb stuck)
  if preflight_job and preflight_job > 0 then
    vim.defer_fn(function()
      if preflight_done then return end
      pcall(vim.fn.jobstop, preflight_job)
      D._dap_attach_in_progress = false
      D._dap_run_state = "idle"
      progress_update("TIMED OUT (30s) — device may be disconnected", vim.log.levels.ERROR)
    end, 30000)
  end
end

function D._android_launch_preflight_ps1(session)
  local pkg = session.package_name
  local port = session.port or 5039
  -- Native debugging: start app normally (not -D which waits for JDWP/Java debugger).
  -- Auto-detect main launcher activity from package manager.
  return ([[
$ErrorActionPreference = "Stop"
$adb = "]] .. (session.adb or "adb") .. [["
$port = ]] .. port .. [[

$serial = (& $adb devices | Select-String "^\S+\s+device$" | Select-Object -First 1).Line.Split()[0]
if (-not $serial) { throw "No Android device found" }
Write-Host "device=$serial"
# Detect main activity
$dumpLines = (& $adb -s $serial shell "dumpsys package ]] .. pkg .. [[" 2>$null) -split "`n"
$activity = ""
$inMain = $false
foreach ($l in $dumpLines) {
    if ($l -match 'android\.intent\.action\.MAIN') { $inMain = $true; continue }
    if ($inMain -and $l -match ']] .. pkg:gsub("%.", "\\.") .. [[/([^\s]+)') {
        $activity = $Matches[1]
        break
    }
    if ($inMain -and $l.Trim() -eq "") { $inMain = $false }
}
if (-not $activity) { $activity = "com.epicgames.unreal.GameActivity" }
Write-Host "activity=$activity"
# Force-stop
Write-Host "force-stop..."
& $adb -s $serial shell "am force-stop ]] .. pkg .. [["
Start-Sleep -Milliseconds 500
# Launch
Write-Host "launching ]] .. pkg .. [[/$activity ..."
& $adb -s $serial shell "am start -n ]] .. pkg .. [[/$activity"
Write-Host "waiting for process..."
$retries = 0
$targetPid = ""
while ($retries -lt 15) {
    Start-Sleep -Milliseconds 500
    $raw = (& $adb -s $serial shell pidof -s "]] .. pkg .. [[" 2>$null)
    $targetPid = (($raw | Out-String) -replace '\D','').Trim()
    if ($targetPid) { break }
    $retries++
}
if (-not $targetPid) { throw "Process ]] .. pkg .. [[ did not start within 8s" }
Write-Host "pid=$targetPid"
Write-Host "setting up lldb-server..."
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c 'pkill -9 lldb-server 2>/dev/null; rm -rf /data/data/]] .. pkg .. [[/lldb 2>/dev/null'" 2>$null
& $adb -s $serial shell "run-as ]] .. pkg .. [[ mkdir -p /data/data/]] .. pkg .. [[/lldb/bin"
& $adb -s $serial push "]] .. session.lldb_server_path .. [[" "/data/local/tmp/lldb-server"
& $adb -s $serial shell "cat /data/local/tmp/lldb-server | run-as ]] .. pkg .. [[ sh -c 'cat > /data/data/]] .. pkg .. [[/lldb/bin/lldb-server && chmod 700 /data/data/]] .. pkg .. [[/lldb/bin/lldb-server'"
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c '/data/data/]] .. pkg .. [[/lldb/bin/lldb-server platform --server --listen tcp://0.0.0.0:$port </dev/null >/dev/null 2>&1 & echo started'"
$retries = 0
$lldbPid = ""
while ($retries -lt 5) {
    Start-Sleep -Milliseconds 500
    $lldbPid = ((& $adb -s $serial shell "run-as ]] .. pkg .. [[ pidof lldb-server" 2>$null) | Out-String).Trim()
    if ($lldbPid) { break }
    $retries++
}
if (-not $lldbPid) { throw "lldb-server failed to start" }
Write-Host "lldb-server pid=$lldbPid"
try { & $adb -s $serial forward --remove tcp:$port 2>$null } catch {}
& $adb -s $serial forward tcp:$port tcp:$port
Write-Host "connect_uri=connect://[$serial]:$port"
$targetPid | Out-File -Encoding ascii "]] .. session.pid_file .. [["
$serial | Out-File -Encoding ascii "]] .. session.serial_file .. [["
Write-Host "PREFLIGHT_OK"
]])
end

function D.android_dap_launch()
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok then
    require("utils.log").notify_error("dap", "nvim-dap not installed")
    return
  end
  if D._dap_attach_in_progress then
    vim.notify("DAP attach/launch already in progress", vim.log.levels.WARN)
    return
  end
  if vim.fn.exepath("adb") == "" then
    require("utils.log").notify_error("dap", "adb not found in PATH")
    return
  end
  local ctx = core.resolve_context() or {}
  local project_root = ctx.project_root or ""
  local engine_root = ctx.engine_root or ""
  local state = ctx.state or {}

  -- Prefer non-Intermediate .so and debug against a snapshot copy so builds can replace the original.
  local symbol_lib = resolve_android_symbol_lib(ctx)
  if symbol_lib == "" then
    local default = project_root ~= "" and (project_root .. "/") or ""
    symbol_lib = vim.fn.input("Path to symbol .so (with debug symbols): ", default)
  end
  if symbol_lib == "" then return end
  local original_symbol_lib = symbol_lib
  local snapshot_err
  symbol_lib, snapshot_err = snapshot_android_symbol_lib(ctx, symbol_lib)
  if snapshot_err then
    vim.notify("Android symbols snapshot failed, using original .so: " .. snapshot_err, vim.log.levels.WARN)
    require("utils.log").warn("dap.attach", "snapshot failed: %s", snapshot_err)
  end

  -- Package name
  local saved_pkg = state.android_package or ""
  local package_name = saved_pkg
  if package_name == "" then
    package_name = vim.fn.input("Android package name: ", "")
  end
  if package_name == "" then return end
  if engine_root ~= "" and package_name ~= saved_pkg then
    core.update_state_field(engine_root, "android_package", package_name)
    core.invalidate_status_cache()
  end

  -- lldb-server: ue.config first, then Android Studio + NDK globs, then prompt
  local localappdata = vim.fn.expand("$LOCALAPPDATA")
  -- IMPORTANT: lldb-server must come from the SAME NDK version that built the UE
  -- game .so. Mismatched versions (e.g. NDK r25 client vs NDK r21 game) handshake
  -- OK then drop the connection during register/auxv exchange. UE 4.x/5.x ships
  -- with NDK 21.4.7075529 by default — prefer that, then fall back to others.
  local search_patterns = {
    localappdata .. "/Android/Sdk/ndk/21.*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
    localappdata .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server",
    localappdata .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
  }
  local as_lldb = D._pick_lldb_server_for_test(search_patterns)
  if as_lldb == "" then return end

  local tmpdir = vim.fn.tempname():gsub("[/\\][^/\\]*$", "")
  local dap_port = 5039
  local attach_state = {
    package_name = package_name,
    symbol_lib = slash_to_backslash(symbol_lib) or symbol_lib,
    original_symbol_lib = slash_to_backslash(original_symbol_lib) or original_symbol_lib,
    lldb_server_path = slash_to_backslash(as_lldb) or as_lldb,
    project_root = slash_to_backslash(project_root) or project_root,
    engine_root = slash_to_backslash(engine_root) or engine_root,
    adb = slash_to_backslash(vim.fn.exepath("adb")) or "adb",
    port = dap_port,
    pid_file = slash_to_backslash(tmpdir .. "/ue_dap_pid.txt"),
    serial_file = slash_to_backslash(tmpdir .. "/ue_dap_serial.txt"),
    exec_search_paths = { slash_to_backslash(vim.fn.fnamemodify(symbol_lib, ":h")) },
    source_map = {},
  }
  if engine_root ~= "" then
    local er = engine_root:gsub("\\", "/")
    attach_state.source_map[er] = er
  end
  if project_root ~= "" then
    local pr = project_root:gsub("\\", "/")
    attach_state.source_map[pr] = pr
  end

  D._dap_attach_in_progress = true
  D._dap_run_state = "attaching"
  D._dap_source_file_cache = {}
  local progress = { "DAP Launch" }
  local notify_id = "ue_dap_launch"
  local function progress_update(msg, level)
    table.insert(progress, msg)
    vim.notify(table.concat(progress, "\n"), level or vim.log.levels.INFO, { id = notify_id, title = "DAP Launch" })
    if level == vim.log.levels.ERROR then
      require("utils.log").error("dap.launch", msg)
    elseif level == vim.log.levels.WARN then
      require("utils.log").warn("dap.launch", msg)
    end
  end

  progress_update("starting...")
  local ps1 = D._android_launch_preflight_ps1(attach_state)
  local preflight_done = false
  local preflight_job = vim.fn.jobstart({ "powershell", "-NoProfile", "-Command", ps1 }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update(line) end) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update("ERR: " .. line, vim.log.levels.WARN) end) end
      end
    end,
    on_exit = function(_, code)
      preflight_done = true
      vim.schedule(function()
        if code ~= 0 then
          D._dap_attach_in_progress = false
          D._dap_run_state = "idle"
          progress_update("FAILED (exit " .. code .. ")", vim.log.levels.ERROR)
          return
        end
        local pid = core.trim((vim.fn.readfile(attach_state.pid_file) or {})[1] or "")
        local serial = core.trim((vim.fn.readfile(attach_state.serial_file) or {})[1] or "")
        -- LLDB platform=remote-android requires connect://[<serial>]:<port>.
        -- "connect://localhost:<port>" is rejected by remote-android with
        -- "Invalid URL:" even though tcp forwarding is set up correctly.
        local connect_uri = (serial ~= "" and ("connect://[%s]:%d"):format(serial, attach_state.port or 5039))
          or ("connect://localhost:%d"):format(attach_state.port or 5039)
        if pid == "" then
          D._dap_attach_in_progress = false
          D._dap_run_state = "idle"
          progress_update("no PID produced", vim.log.levels.ERROR)
          return
        end
        attach_state.pid = pid
        attach_state.serial = serial
        attach_state.connect_uri = connect_uri
        D._dap_session_state = attach_state
        progress_update(("pid=%s, connecting DAP..."):format(pid))
        D._setup_aslr_listeners(dap, attach_state, progress_update)
        dap.run(D._android_dap_config(attach_state))
      end)
    end,
  })
  -- Timeout: kill preflight if it hangs (device disconnected, adb stuck)
  if preflight_job and preflight_job > 0 then
    vim.defer_fn(function()
      if preflight_done then return end
      pcall(vim.fn.jobstop, preflight_job)
      D._dap_attach_in_progress = false
      D._dap_run_state = "idle"
      progress_update("TIMED OUT (30s) — device may be disconnected", vim.log.levels.ERROR)
    end, 30000)
  end
end

function D._dap_eval_lldb(command, cb)
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok then
    if cb then cb(false, "DAP not available") end
    return
  end
  local session = dap.session()
  if not session then
    if cb then cb(false, "No DAP session") end
    return
  end
  -- CodeLLDB repl evaluate works without frameId even when the process is running
  session:evaluate(command, function(err, resp)
    local result = resp and resp.result or ""
    if err then
      if cb then cb(false, tostring(err)) end
    else
      if cb then cb(true, result) end
    end
  end, { context = "repl" })
end

function D._dap_make_breakpoint_spec(path, line)
  path = core.norm(path)
  line = tonumber(line)
  if path == "" or not line or line <= 0 then
    return nil
  end

  local files = {}
  local seen = {}
  local function add(candidate)
    candidate = core.trim(candidate)
    if candidate == "" or seen[candidate] then
      return
    end
    seen[candidate] = true
    files[#files + 1] = candidate
  end

  add(path)
  if core.is_native_windows() then
    add(path:gsub("/", "\\"))
  end

  local ctx = core.resolve_context() or {}
  local roots = {}
  local function add_root(root)
    root = core.norm(root)
    if root ~= "" then
      roots[#roots + 1] = root
    end
  end

  add_root(ctx.project_root or "")
  if core.trim(ctx.project_root or "") ~= "" then
    add_root(core.join(ctx.project_root, "Source"))
  end
  add_root(ctx.engine_root or "")
  if core.trim(ctx.engine_root or "") ~= "" then
    add_root(core.join(ctx.engine_root, "Engine"))
    add_root(core.join(ctx.engine_root, "Engine", "Source"))
  end

  for _, root in ipairs(roots) do
    if core.path_has_prefix(path, root) then
      local relative = core.relative_to(root, path)
      add(relative)
      if core.is_native_windows() then
        add(relative:gsub("/", "\\"))
      end
    end
  end

  add(basename(path))

  local set_commands = {}
  local clear_commands = {}
  for _, file in ipairs(files) do
    local escaped = file:gsub('"', '\\"')
    set_commands[#set_commands + 1] = ('breakpoint set --file "%s" --line %d'):format(escaped, line)
    clear_commands[#clear_commands + 1] = ('breakpoint clear --file "%s" --line %d'):format(escaped, line)
  end

  return {
    set_command = set_commands[1],
    clear_command = clear_commands[1],
    set_commands = set_commands,
    clear_commands = clear_commands,
    file = path,
    line = line,
    runtime_breakpoint_id = nil,
  }
end

function D._dap_try_set_breakpoint(spec, cb)
  spec = spec or {}
  local set_commands = spec.set_commands or {}
  if #set_commands == 0 and spec.set_command then
    set_commands = { spec.set_command }
  end
  local clear_commands = spec.clear_commands or {}
  if #clear_commands == 0 and spec.clear_command then
    clear_commands = { spec.clear_command }
  end

  if #set_commands == 0 then
    if cb then
      cb(false, "No breakpoint commands", false)
    end
    return
  end

  local index = 1
  local last_result = ""

  local function finish(ok, result, resolved)
    if cb then
      cb(ok, result, resolved)
    end
  end

  local function try_next()
    local set_command = set_commands[index]
    if not set_command then
      finish(false, last_result ~= "" and last_result or "No breakpoint command resolved", false)
      return
    end

    -- CodeLLDB REPL evaluate returns "" for breakpoint commands.
    -- Capture the actual output from event_output console events.
    local dap = require("dap")
    local console_lines = {}
    local listener_key = "bp-try-" .. tostring(vim.uv.hrtime())
    dap.listeners.after.event_output[listener_key] = function(_, body)
      if body and body.category == "console" and body.output then
        console_lines[#console_lines + 1] = body.output
      end
    end

    D._dap_eval_lldb(set_command, function(ok, repl_result)
      -- Remove listener after a short delay to catch trailing output
      vim.defer_fn(function()
        dap.listeners.after.event_output[listener_key] = nil

        if not ok then
          finish(false, repl_result, false)
          return
        end

        -- Merge REPL result with captured console output
        local result = tostring(repl_result or "")
        if result == "" and #console_lines > 0 then
          result = table.concat(console_lines, "")
        end
        last_result = result

        local breakpoint_id = result:match("Breakpoint%s+(%d+)")
        local locations = tonumber(result:match("locations%s*=%s*(%d+)"))
        local lower = result:lower()
        local resolved = (locations or 0) > 0
          or lower:find("resolved", 1, true) ~= nil
          or lower:find("where =", 1, true) ~= nil
        local is_last = index >= #set_commands

        spec.set_command = set_command
        spec.clear_command = clear_commands[index] or spec.clear_command
        spec.runtime_breakpoint_id = breakpoint_id

        if resolved or is_last then
          finish(true, result, resolved)
          return
        end

        if breakpoint_id then
          D._dap_eval_lldb("breakpoint delete " .. breakpoint_id, function()
            spec.runtime_breakpoint_id = nil
            index = index + 1
            try_next()
          end)
        else
          index = index + 1
          try_next()
        end
      end, 100)
    end)
  end

  try_next()
end

function D._dap_clear_breakpoint(spec, cb)
  spec = spec or {}
  local commands = {}
  if spec.runtime_breakpoint_id then
    commands[#commands + 1] = "breakpoint delete " .. spec.runtime_breakpoint_id
  end
  if spec.clear_command then
    commands[#commands + 1] = spec.clear_command
  end
  if #commands == 0 then
    if cb then
      cb(false, "No breakpoint clear command")
    end
    return
  end

  local index = 1
  local function try_next(last_result)
    local command = commands[index]
    if not command then
      if cb then
        cb(false, last_result or "No breakpoint clear command")
      end
      return
    end

    D._dap_eval_lldb(command, function(ok, result)
      if ok then
        spec.runtime_breakpoint_id = nil
        if cb then
          cb(true, result)
        end
        return
      end

      index = index + 1
      try_next(result)
    end)
  end

  try_next()
end

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

function D.ensure_dap_loaded()
  local dap_ok, dap = pcall(require, "dap")
  if dap_ok then
    return true, dap
  end

  local lazy_ok, lazy = pcall(require, "lazy")
  if lazy_ok and lazy and type(lazy.load) == "function" then
    lazy.load({ plugins = { "nvim-dap", "nvim-dap-ui", "nvim-nio" } })
  end

  dap_ok, dap = pcall(require, "dap")
  if not dap_ok then
    require("utils.log").notify_error("dap", "nvim-dap not available")
    return false, nil
  end
  return true, dap
end

function D.ensure_dapui_loaded()
  local dapui_ok, dapui = pcall(require, "dapui")
  if dapui_ok then
    return true, dapui
  end

  local dap_ok = D.ensure_dap_loaded()
  if not dap_ok then
    return false, nil
  end

  dapui_ok, dapui = pcall(require, "dapui")
  if not dapui_ok then
    require("utils.log").notify_error("dap", "nvim-dap-ui not available")
    return false, nil
  end
  return true, dapui
end

function D.dap_toggle_breakpoint()
  local dap_ok, dap = pcall(require, "dap")
  local has_session = dap_ok and dap.session() ~= nil

  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path = core.norm(vim.api.nvim_buf_get_name(bufnr))
  if path == "" then return end
  local file = basename(path)
  local key = path .. ":" .. line
  local is_set = D._breakpoint_specs[key] ~= nil

  if is_set then
    -- Remove breakpoint
    local spec = D._breakpoint_specs[key]
    D._breakpoint_specs[key] = nil
    vim.fn.sign_unplace("ue_dap_bp", { buffer = bufnr, id = line })
    if has_session then
      D._dap_clear_breakpoint(spec, function(ok2, result)
        vim.schedule(function()
          local msg = ok2 and ("BP cleared: %s:%d"):format(file, line) or ("BP clear failed: %s"):format(result)
          vim.notify(msg, ok2 and vim.log.levels.INFO or vim.log.levels.ERROR)
          if not ok2 then require("utils.log").error("dap.bp", msg) end
        end)
      end)
    else
      vim.notify(("BP removed (pending): %s:%d"):format(file, line))
    end
  else
    -- Add breakpoint (prefer exact source path, fallback to shorter LLDB matches)
    local spec = D._dap_make_breakpoint_spec(path, line)
    if not spec then
      require("utils.log").notify_error("dap.bp", "BP set failed: invalid path or line")
      return
    end
    D._breakpoint_specs[key] = spec
    vim.fn.sign_define("UEDapBreakpoint", { text = "●", texthl = "DiagnosticError" })
    vim.fn.sign_place(line, "ue_dap_bp", "UEDapBreakpoint", bufnr, { lnum = line })
    if has_session then
      D._dap_try_set_breakpoint(spec, function(ok2, result, resolved)
        vim.schedule(function()
          if ok2 then
            if resolved then
              vim.notify(("BP set: %s:%d (resolved)"):format(file, line))
            else
              -- Diagnose exact-path miss without being confused by other breakpoints.
              D._dap_eval_lldb(('image lookup --file "%s"'):format(spec.file:gsub('"', '\\"')), function(_, lookup)
                vim.schedule(function()
                  local diag = ("BP unresolved: %s:%d\n"):format(file, line)
                  diag = diag .. "LLDB tried: " .. tostring(spec.set_command)
                  if lookup and lookup ~= "" then
                    local lines = {}
                    for l in lookup:gmatch("[^\n]+") do
                      lines[#lines + 1] = l
                      if #lines >= 8 then break end
                    end
                    diag = diag .. "\nimage lookup found:\n" .. table.concat(lines, "\n")
                  else
                    diag = diag .. "\nimage lookup: file NOT found in module debug info"
                  end
                  vim.notify(diag, vim.log.levels.WARN)
                end)
              end)
            end
          else
            D._breakpoint_specs[key] = nil
            vim.fn.sign_unplace("ue_dap_bp", { buffer = bufnr, id = line })
            require("utils.log").notify_error("dap.bp", ("BP set failed: %s"):format(result))
          end
        end)
      end)
    else
      vim.notify(("BP pending: %s:%d (will apply on attach)"):format(file, line))
    end
  end
  save_breakpoints()
end

function D.dap_continue()
  local ok, dap = D.ensure_dap_loaded()
  if not ok or not dap.session() then return end
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

function D.dap_toggle_ui()
  local ok, dapui = D.ensure_dapui_loaded()
  if not ok then return end
  dapui.toggle()
end

function D.dap_reset_layout()
  local dap_ok, dap = D.ensure_dap_loaded()
  local dapui_ok, dapui = D.ensure_dapui_loaded()
  if dap_ok and dap.session() and dapui_ok then
    -- DAP active: close and re-open DAP UI to reset split sizes
    dapui.close()
    -- Close all non-normal windows (leftover floats, etc.)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local bt = vim.bo[buf].buftype
        if bt == "nofile" or bt == "prompt" then
          local ft = vim.bo[buf].filetype
          if ft:find("^dap") then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      end
    end
    vim.cmd("wincmd =")
    dapui.open({ reset = true })
  else
    -- No DAP: close everything except current window
    vim.cmd("only")
    vim.cmd("wincmd =")
  end
end

function D.dap_toggle_repl()
  local ok, dap = D.ensure_dap_loaded()
  if ok then dap.repl.toggle() end
end

function D.dap_diagnose()
  local dap_ok, dap = D.ensure_dap_loaded()
  if not dap_ok or not dap.session() then
    vim.notify("No DAP session", vim.log.levels.WARN)
    return
  end

  local results = {}
  local pending = 3
  local function collect(label, ok, data)
    if ok and data and data ~= "" then
      results[#results + 1] = ("=== %s ===\n%s"):format(label, data)
    else
      results[#results + 1] = ("=== %s ===\n(empty)"):format(label)
    end
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

  -- 1) What modules does LLDB have loaded?
  D._dap_eval_lldb("image list", function(ok, r) collect("image list", ok, r) end)
  -- 2) Check symbol file status for the main .so
  local state = D._dap_session_state or {}
  local so_name = state.symbol_lib and vim.fn.fnamemodify(state.symbol_lib, ":t") or "libUE4.so"
  D._dap_eval_lldb(
    ('image dump symfile "%s"'):format(so_name),
    function(ok, r) collect("symfile " .. so_name, ok, r) end
  )
  -- 3) Check source map and settings
  D._dap_eval_lldb("settings show target.source-map", function(ok, r) collect("source-map", ok, r) end)
end

function D.setup_dap(dap, dapui)
  local adapter, liblldb = D.codelldb_paths()
  if not adapter then
    vim.notify("CodeLLDB not found. Install it to enable Android debugging.", vim.log.levels.WARN)
    return
  end
  dap.adapters.codelldb = {
    type = "server",
    port = "${port}",
    executable = { command = adapter, args = { "--port", "${port}", "--liblldb", liblldb } },
  }
  -- Remember which window/buffer was active before DAP UI opened
  local saved_win = nil
  local saved_buf = nil
  local function save_layout()
    if not saved_win then
      saved_win = vim.api.nvim_get_current_win()
      saved_buf = vim.api.nvim_get_current_buf()
    end
  end
  local function restore_layout()
    dapui.close()
    -- Close any leftover DAP/special windows, keep only normal file windows
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
    -- Focus the original window or the first remaining window
    if saved_win and vim.api.nvim_win_is_valid(saved_win) then
      pcall(vim.api.nvim_set_current_win, saved_win)
    elseif saved_buf and vim.api.nvim_buf_is_valid(saved_buf) then
      -- Original window gone but buffer alive — switch to it
      pcall(vim.cmd, "buffer " .. saved_buf)
    end
    saved_win = nil
    saved_buf = nil
    -- Equalize whatever windows remain
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

  local logcat_buf = nil
  local logcat_job = nil

  local function stop_logcat()
    if logcat_job then
      pcall(vim.fn.jobstop, logcat_job)
      logcat_job = nil
    end
    if logcat_buf and vim.api.nvim_buf_is_valid(logcat_buf) then
      -- Close any window showing the logcat buffer
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
    local pid = state.pid
    local adb = state.adb or "adb"
    local serial = state.serial or ""
    if not pid or pid == "" then return end

    logcat_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[logcat_buf].buftype = "nofile"
    vim.bo[logcat_buf].bufhidden = "wipe"
    vim.bo[logcat_buf].filetype = "log"
    vim.api.nvim_buf_set_name(logcat_buf, "logcat:" .. pid)

    local cmd = { adb }
    if serial ~= "" then
      vim.list_extend(cmd, { "-s", serial })
    end
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
            -- Auto-scroll windows showing this buffer
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
    -- Find the bottom DAP panel (repl/console) to place logcat next to it
    local target_win = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local ft = vim.bo[buf].filetype
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

  local function on_session_end()
    stop_logcat()
    restore_layout()
    source_path_cache = {}
    -- Clean up any pending ASLR listeners (session died before event_stopped)
    dap.listeners.after.event_stopped["ue_aslr_fix"] = nil
    dap.listeners.after.event_initialized["ue_aslr_fix"] = nil
    -- Keep _breakpoint_specs and signs so they persist across re-attach.
    -- They will be re-applied to the new LLDB session after ASLR fix.
    -- Kill remote lldb-server so re-attach can start a new one
    cleanup_remote_android_lldb(D._dap_session_state)
    reset_android_dap_state()
  end

  dap.listeners.after.event_initialized["dapui_config"] = function()
    close_explorer()
    save_layout()
    dapui.open()
    start_logcat()
    vim.defer_fn(open_logcat_window, 200)
  end
  dap.listeners.before.event_terminated["dapui_config"] = function() on_session_end() end
  dap.listeners.before.event_exited["dapui_config"] = function() on_session_end() end
  dap.listeners.after.disconnect["dapui_config"] = function() on_session_end() end

  dap.listeners.after.event_initialized["ue-android-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    D._dap_run_state = D._dap_attach_in_progress and "attaching" or "stopped"
  end
  dap.listeners.after.event_stopped["ue-android-dap-run-state"] = function(session, body)
    if dap.session() ~= session then return end
    D._dap_run_state = "stopped"
    D._continue_pending = false
    D._continue_debounce_until_ms = 0
    D._pause_pending = false
    -- Auto-continue on signal stops (exception) that are not breakpoints and
    -- not during attach bootstrap.  Android processes receive stray SIGSTOP /
    -- SIGSEGV / etc. on unrelated threads (Chrome_IOThread, Signal Catcher,
    -- …).  Stopping on them freezes the app and confuses the user.
    if not D._dap_attach_in_progress then
      body = body or {}
      local reason = tostring(body.reason or ""):lower()
      local has_bp = body.hitBreakpointIds and #body.hitBreakpointIds > 0
      if reason == "exception" and not has_bp then
        vim.defer_fn(function()
          if dap.session() == session and D._dap_run_state == "stopped" then
            vim.notify("Auto-continuing past signal on thread "
              .. tostring(body.threadId or "?"), vim.log.levels.DEBUG)
            request_dap_continue(dap)
          end
        end, 50)
      end
    end
  end
  dap.listeners.after.event_continued["ue-android-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    D._dap_run_state = "running"
    D._continue_pending = false
    session.current_frame = nil
    session.stopped_thread_id = nil
  end
  dap.listeners.after["continue"]["ue-android-dap-run-state"] = function(session, err)
    if dap.session() ~= session or not err then return end
    D._continue_pending = false
    D._continue_debounce_until_ms = 0
    D._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  end
  dap.listeners.after.event_stopped["ue-android-dap-source-nav"] = function(session, body)
    if dap.session() ~= session then return end
    maybe_jump_to_local_source_frame(session, body)
  end

  -- Strip huge Global/Static scopes before nvim-dap's callback requests variables for them.
  dap.listeners.before.scopes["ue_block_globals"] = function(_, _, body)
    D._dap_filter_scopes(body)
  end

  -- Rewrite relative source paths in stack frames so dap-ui can open local files.
  -- LLDB returns paths relative to DWARF comp_dir (e.g. "Runtime/VulkanRHI/Private/VulkanShaders.cpp").
  -- We join with known prefixes — NO glob (glob freezes Neovim on large UE trees).
  local source_path_cache = {}
  local function resolve_source_path(rel_path)
    if not rel_path or rel_path == "" then return nil end
    local cached = source_path_cache[rel_path]
    if cached ~= nil then return cached or nil end

    -- Already absolute and exists?
    if rel_path:match("^[A-Za-z]:") or rel_path:match("^/") then
      local p = core.norm(rel_path)
      if core.is_file(p) then
        source_path_cache[rel_path] = p
        return p
      end
      source_path_cache[rel_path] = false
      return nil
    end

    -- Build candidate prefixes: DWARF comp_dir is typically engine_root/Engine/Source,
    -- so relative paths like "Runtime/VulkanRHI/Private/X.cpp" resolve from there.
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
      local candidate = core.norm(prefix .. "/" .. rel_path)
      if core.is_file(candidate) then
        source_path_cache[rel_path] = candidate
        return candidate
      end
    end

    source_path_cache[rel_path] = false
    return nil
  end

  dap.listeners.before.stackTrace["ue_source_path_rewrite"] = function(_, err, response)
    if err or not response or not response.stackFrames then return end
    for _, frame in ipairs(response.stackFrames) do
      local source = frame.source
      if source and source.path then
        local resolved = resolve_source_path(source.path)
        if resolved then
          source.path = resolved
        end
      end
    end
  end
  vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
  vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DiagnosticInfo", linehl = "CursorLine" })

  -- Full cleanup on quit: disconnect DAP, kill CodeLLDB adapter, kill remote lldb-server
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ue_dap_cleanup", { clear = true }),
    callback = function()
      local session = dap.session()
      if not session then return end
      -- Detach cleanly so the game keeps running
      pcall(function()
        session:request("disconnect", { terminateDebuggee = false })
      end)
      -- Kill CodeLLDB adapter process
      local adapter_pid = session.adapter and session.adapter.pid
      if adapter_pid then
        if vim.fn.has("win32") == 1 then
          vim.fn.system({ "taskkill", "/F", "/T", "/PID", tostring(adapter_pid) })
        else
          vim.fn.system({ "kill", "-9", tostring(adapter_pid) })
        end
      end
      -- Kill remote lldb-server
      cleanup_remote_android_lldb(D._dap_session_state)
      -- Clear session state but persist breakpoints to disk
      reset_android_dap_state()
      save_breakpoints()
    end,
  })

  -- Restore breakpoints from last session
  load_breakpoints()
end

--- Inject upstream core utilities and initialize DAP state.
--- @param core_table table  Functions from ue/init.lua: trim, norm, join, dirname, is_file, ensure_dir, run_lines, file_stat, glob_paths, is_native_windows, slash_to_backslash, resolve_context, invalidate_status_cache, refresh_statusline
function D.setup_core(core_table)
  core = core_table
end

return D
