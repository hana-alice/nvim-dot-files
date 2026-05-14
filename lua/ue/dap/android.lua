-- ue.dap.android — Android DAP attach via codelldb + Android lldb-server.
--
-- Adapter: vadimcn/codelldb (resolved by ue.dap._common.find_codelldb).
-- Wire:    nvim-dap → codelldb (host) → gdb-remote tcp://127.0.0.1:<port>
--          → adb forward → run-as <pkg> lldb-server-ndk27 gdbserver --attach
--
-- Why codelldb (not lldb-dap):
--   * Windows host + Android lldb-server + lldb-dap 21.x crashes on the first
--     setBreakpoints (LLVM #102254 / #138096). Pure gdb-remote-port mode in
--     lldb-dap doesn't enumerate modules over Android (#126935), leaving
--     every breakpoint unverified. codelldb's request="custom" exposes
--     ordered targetCreateCommands / processCreateCommands that map 1:1 to
--     a known-good bare-lldb sequence and resolves source breakpoints
--     against the locally-loaded DWARF. See
--     docs/plans/2026-05-13_123500-android-aslike-nvim-ide-route.md.
--
-- Why gdbserver --attach (not platform mode):
--   * platform mode requires the device-side lldb-server to ship every
--     module file back to the host on demand, which is slow and brittle
--     for a 3.85 GB libUE4.so. With gdbserver --attach + a host-loaded
--     symbol_lib, the host has the full DWARF and only needs the device
--     for ptrace + memory + register reads.
--
-- Requirements on the device (auto-bootstrapped where possible):
--   * lldb-server (NDK 27, LLDB 18) pushed to /data/local/tmp and copied
--     into the app sandbox via run-as.
--   * Process matching session.package_name running.
--   * App is debuggable (android:debuggable=true) OR adb root works.
--
-- Requirements on the host (one-time):
--   * codelldb 1.12.2+ unpacked under one of the paths returned by the
--     platform driver's default_codelldb_paths().
--   * A symbol-rich libUE4.so (DWARF) available locally — either the
--     Binaries/Android/Client_Symbols_v* tree or the Intermediate jni
--     output. Pointed to by ue.config dap.android_symbol_lib OR auto-
--     detected from the project root.
--   * Optional: source-map entries (DAP "sourceMap") so DWARF build-machine
--     paths (e.g. D:\project\uetemp\Engine\) resolve to the local checkout.

local C   = require("ue.dap._common")
local fs  = require("ue.core.fs")
local log = require("utils.log")

local M = {}

-- ── shared session state ──────────────────────────────────────────────────
M._session = {
  pid               = nil,
  serial            = nil,
  port              = 5045,
  package_name      = nil,
  adb               = "adb",
  lldb_server_local = nil,  -- host path to NDK lldb-server
  symbol_lib        = nil,  -- host path to libUE4.so (with DWARF)
  source_map        = nil,  -- list of { from, to } pairs
  engine_root       = nil,  -- host engine root, used to wire LLDB UE data formatters
}

local function reset_session()
  for k in pairs(M._session) do M._session[k] = nil end
  M._session.adb  = "adb"
  M._session.port = 5045
end

-- ── config helpers ────────────────────────────────────────────────────────

local function ue_cfg_get(key)
  local ok, cfg = pcall(require, "ue.config")
  if not ok or not cfg or not cfg.get then return nil end
  return cfg.get(key)
end

local function default_lldb_server_globs()
  local ok_plat, plat = pcall(require, "utils.platform")
  if not ok_plat or not plat or not plat.driver then return {} end
  local d = plat.driver()
  if d and d.default_lldb_server_paths then return d.default_lldb_server_paths() or {} end
  return {}
end

local function pick_lldb_server_for_tests(globs)
  local cfg_path = ue_cfg_get("dap.android_lldb_server")
  if type(cfg_path) == "string" and cfg_path ~= "" and fs.is_file(cfg_path) then
    return cfg_path
  end
  cfg_path = ue_cfg_get("dap.lldb_server_path")
  if type(cfg_path) == "string" and cfg_path ~= "" and fs.is_file(cfg_path) then
    return cfg_path
  end
  -- For codelldb + gdb-remote we want NDK 27's lldb-server (LLDB 18). The
  -- bundled liblldb on the host is 22.1.4-codelldb; cross-major gdb-remote
  -- is empirically OK. The platform driver glob list is shared with the
  -- old lldb-dap route which intentionally pinned NDK 21 first to dodge a
  -- qLaunchGDBServer deadlock — that constraint does NOT apply to gdbserver
  -- --attach. Resolve all candidates, then pick the highest NDK version.
  local matches = {}
  for _, pattern in ipairs(globs or {}) do
    local hit = vim.fn.glob(pattern)
    if hit and hit ~= "" then
      for line in (hit .. "\n"):gmatch("([^\n]+)\n") do
        if fs.is_file(line) then matches[#matches + 1] = line end
      end
    end
  end
  if #matches == 0 then return nil end
  local function ndk_version(p)
    local v = p:match("[Nn][Dd][Kk][/\\](%d+)%.")
    return v and tonumber(v) or 0
  end
  table.sort(matches, function(a, b) return ndk_version(a) > ndk_version(b) end)
  return matches[1]
end

local function pick_lldb_server()
  local picked = pick_lldb_server_for_tests(default_lldb_server_globs())
  if picked then return picked end
  local typed = vim.fn.input("Path to arm64 lldb-server (NDK 27 preferred): ")
  if typed == "" then return nil end
  if not fs.is_file(typed) then
    vim.notify("Not a readable file: " .. typed, vim.log.levels.WARN)
    return nil
  end
  return typed
end

local function pick_package(ctx)
  local engine_root = ctx and ctx.engine_root
  if engine_root then
    local ok_ue, ue = pcall(require, "ue")
    if ok_ue and ue and ue.read_state then
      local ok_s, s = pcall(ue.read_state, engine_root)
      if ok_s and type(s) == "table" and type(s.android_package) == "string"
        and s.android_package ~= "" then
        return s.android_package
      end
    end
  end
  local cfg_pkg = ue_cfg_get("dap.android_package")
  if type(cfg_pkg) == "string" and cfg_pkg ~= "" then return cfg_pkg end
  local typed = vim.fn.input("Android package name: ", "")
  if typed == "" then return nil end
  return typed
end

local function pick_symbol_lib(ctx)
  local cfg_sym = ue_cfg_get("dap.android_symbol_lib")
  if type(cfg_sym) == "string" and cfg_sym ~= "" and fs.is_file(cfg_sym) then
    return cfg_sym
  end
  -- Auto-search common UE Android symbol locations under project_root.
  local proot = ctx and (ctx.project_root or ctx.engine_root)
  if proot then
    local candidates = {
      proot .. "/Source/Client/Binaries/Android/*Symbols*/Client-arm64/libUE4.so",
      proot .. "/Source/Client/Binaries/Android/*Symbols*/Client-arm64/libUnreal.so",
      proot .. "/Source/Client/Intermediate/Android/arm64/jni/arm64-v8a/libUE4.so",
      proot .. "/Source/Client/Intermediate/Android/arm64/jni/arm64-v8a/libUnreal.so",
    }
    for _, pat in ipairs(candidates) do
      local hit = vim.fn.glob(pat)
      if hit and hit ~= "" then
        for line in (hit .. "\n"):gmatch("([^\n]+)\n") do
          if fs.is_file(line) then return line end
        end
      end
    end
  end
  local typed = vim.fn.input("Path to host libUE4.so (with DWARF): ", "", "file")
  if typed == "" then return nil end
  if not fs.is_file(typed) then
    vim.notify("Not a readable file: " .. typed, vim.log.levels.WARN)
    return nil
  end
  return typed
end

local function pick_port()
  local cfg_port = ue_cfg_get("dap.android_port")
  if type(cfg_port) == "number" and cfg_port > 0 then return cfg_port end
  -- Allocate a free TCP port on the host. We can't reserve it (lldb-server
  -- on the device binds the same number after `adb forward`), but the
  -- host-side `adb forward tcp:N tcp:N` will still claim it cleanly so
  -- two concurrent sessions never collide on the historical default 5045.
  local ok, server = pcall(vim.uv.new_tcp)
  if ok and server then
    local bind_ok = pcall(server.bind, server, "127.0.0.1", 0)
    if bind_ok then
      local sn = server:getsockname()
      local port = sn and sn.port
      pcall(server.close, server)
      if type(port) == "number" and port > 0 then return port end
    else
      pcall(server.close, server)
    end
  end
  return 5045
end

local function pick_source_map(ctx)
  -- ue.config.dap.android_source_map = { { from, to }, ... }
  local cfg_sm = ue_cfg_get("dap.android_source_map")
  if type(cfg_sm) == "table" and #cfg_sm > 0 then return cfg_sm end
  -- DWARF on UE Android builds bakes the build-machine root into
  -- DW_AT_comp_dir (observed: "D:\project\uetemp\Engine\Source"). Map both
  -- backslash and forward-slash variants of the build root onto the local
  -- project root so codelldb can resolve at least Game-side sources.
  -- Engine sources are only resolvable if the user has a local Engine tree
  -- under project_root/Engine. When absent, the Engine map still points
  -- somewhere existing so codelldb won't bail with "Cursor position outside
  -- buffer" — frames just won't show source for Engine code (expected).
  local proot = ctx and (ctx.project_root or ctx.engine_root)
  if not proot then return nil end
  local sm = {
    { from = "D:\\project\\uetemp", to = proot },
    { from = "D:/project/uetemp",   to = proot },
  }
  if fs.is_dir(proot .. "/Engine") then
    -- Prefer explicit Engine→Engine mapping if the user has source locally.
    table.insert(sm, 1, { from = "D:\\project\\uetemp\\Engine", to = proot .. "/Engine" })
    table.insert(sm, 1, { from = "D:/project/uetemp/Engine",   to = proot .. "/Engine" })
  end
  return sm
end

-- ── adb helpers ───────────────────────────────────────────────────────────

local function adb_run(adb, args)
  local cmd = { adb }
  vim.list_extend(cmd, args)
  local out = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then return "" end
  return (out or ""):gsub("[\r\n]+$", "")
end

local function pick_serial(adb)
  local out = adb_run(adb, { "devices" })
  for line in out:gmatch("[^\n]+") do
    local serial, status = line:match("^(%S+)%s+(%S+)$")
    if serial and status == "device" and serial ~= "List" then
      return serial
    end
  end
  return nil
end

local function pidof(adb, serial, pkg)
  local out = adb_run(adb, { "-s", serial, "shell", "pidof", "-s", pkg })
  local digits = (out or ""):match("(%d+)")
  return digits and tonumber(digits) or nil
end

-- Push lldb-server → /data/local/tmp/lldb-server-ndk27, then copy into the
-- app sandbox via run-as. Idempotent: skip push if remote size matches.
local function ensure_lldb_server_in_app(adb, serial, pkg, src)
  local local_size = vim.fn.getfsize(src)
  if local_size <= 0 then
    return false, "lldb-server source not readable: " .. tostring(src)
  end

  -- Stage in /data/local/tmp.
  local remote_tmp = "/data/local/tmp/lldb-server-ndk27"
  local remote_size = adb_run(adb, {
    "-s", serial, "shell", "stat", "-c", "%s", remote_tmp,
  })
  if tostring(remote_size) ~= tostring(local_size) then
    if adb_run(adb, { "-s", serial, "push", src, remote_tmp }) == "" then
      if vim.v.shell_error ~= 0 then return false, "adb push failed" end
    end
  end

  -- Copy into app sandbox via run-as. cp+chmod under run-as is allowed
  -- because the dest is the app's own home dir. Use absolute path because
  -- `adb shell run-as <pkg> cp ...` may not chdir into the sandbox on
  -- newer Android (see SPAWN comment below for details).
  local sandbox = "/data/data/" .. pkg
  local server_abs = sandbox .. "/lldb-server-ndk27"
  adb_run(adb, { "-s", serial, "shell", "run-as", pkg,
    "cp", remote_tmp, server_abs })
  adb_run(adb, { "-s", serial, "shell", "run-as", pkg,
    "chmod", "755", server_abs })

  -- Verify presence.
  local check = adb_run(adb, { "-s", serial, "shell", "run-as", pkg,
    "ls", server_abs })
  if not check:match("lldb%-server%-ndk27") then
    return false, "lldb-server not present in app sandbox after copy"
  end
  return true, "ready"
end

-- Spawn lldb-server gdbserver --attach <pid> as the app UID. Detached
-- background so it survives the adb shell exit. Returns (ok, err).
local function start_lldb_server_gdbserver(adb, serial, pkg, pid, port)
  -- Kill any prior lldb-server-ndk27 owned by this UID.
  pcall(adb_run, adb, { "-s", serial, "shell", "run-as", pkg,
    "pkill", "-f", "lldb-server-ndk27" })
  vim.wait(150)

  -- Make sure the target process is not stuck in T (SIGSTOP) state from a
  -- previous detach gone wrong.
  local st = adb_run(adb, { "-s", serial, "shell",
    "cat", "/proc/" .. tostring(pid) .. "/status" })
  if st:match("State:%s*[Tt]") then
    pcall(adb_run, adb, { "-s", serial, "shell", "kill", "-CONT", tostring(pid) })
    vim.wait(80)
  end

  -- Launch lldb-server gdbserver --attach as detached background. We use
  -- `adb shell` with `nohup ... < /dev/null >log 2>&1 &` so it survives
  -- the shell exit. The trailing `&` is critical; without it adb shell
  -- waits for the server to exit.
  --
  -- NDK 27 lldb-server (LLDB 18) takes the listen address as a positional
  -- `[host]:port` argument and rejects `*:port` wildcard form. Older NDKs
  -- accepted `*:port`. We use 127.0.0.1 because `adb forward` only forwards
  -- to the device's local interface anyway.
  --
  -- IMPORTANT: do NOT use vim.fn.jobstart({...}, { detach = true }) here.
  -- In headless/embedded nvim runs (CI, tests, eager Neovide startup) the
  -- child can be reaped before adb has time to fork the device-side shell.
  -- vim.fn.system blocks until adb shell returns — and adb shell DOES
  -- return immediately because the device-side `&` backgrounds the
  -- lldb-server. Net effect: synchronous on the host, async on the device.
  --
  -- ALSO IMPORTANT: on some Android 14+ builds (observed on NX809J / Android
  -- 15) `adb shell run-as <pkg> sh -c "..."` does NOT chdir into the app
  -- sandbox — the sh process inherits cwd=/ from adbd and run-as only
  -- changes uid. `./lldb-server-ndk27` then fails with "No such file" and
  -- the redirect target `./lldb-server.log` fails with "Read-only file
  -- system". We must explicitly `cd /data/data/<pkg>` first.
  --
  -- WINDOWS QUOTING / sh-in-sh trap: passing the full command as a single
  -- adb shell argument (with embedded `sh -c '...'`) makes the device-side
  -- /system/bin/sh strip the inner quotes and the command runs in a way
  -- that hangs `adb shell` for 60s. The cleanest fix is to write a tiny
  -- shell script into /data/local/tmp (world-readable) and just exec it via
  -- `run-as <pkg> sh /data/local/tmp/...sh`. No nested quoting at all.
  local sandbox = "/data/data/" .. pkg
  local script_remote = "/data/local/tmp/ue-dap-lldbsrv.sh"
  local script_body = string.format(
    "#!/system/bin/sh\ncd %s\nnohup ./lldb-server-ndk27 gdbserver --attach %d 127.0.0.1:%d </dev/null >./lldb-server.log 2>&1 &\n",
    sandbox, pid, port
  )
  local tmp_local = vim.fn.tempname() .. ".sh"
  local f = io.open(tmp_local, "wb")
  if not f then return false, "could not create local tempfile" end
  f:write(script_body)
  f:close()
  adb_run(adb, { "-s", serial, "push", tmp_local, script_remote })
  adb_run(adb, { "-s", serial, "shell", "chmod", "755", script_remote })
  pcall(os.remove, tmp_local)
  vim.fn.system({ adb, "-s", serial, "shell", "run-as", pkg, "sh", script_remote })
  vim.wait(400)

  -- adb forward host:port → device:port. Idempotent.
  adb_run(adb, { "-s", serial, "forward", "--remove", "tcp:" .. port })
  if adb_run(adb, { "-s", serial, "forward", "tcp:" .. port, "tcp:" .. port }) == "" then
    if vim.v.shell_error ~= 0 then return false, "adb forward failed" end
  end

  -- Verify TracerPid was set (i.e. ptrace took hold).
  for _ = 1, 10 do
    local s = adb_run(adb, { "-s", serial, "shell",
      "cat", "/proc/" .. tostring(pid) .. "/status" })
    local tracer = s:match("TracerPid:%s*(%d+)")
    if tracer and tonumber(tracer) > 0 then return true, nil end
    vim.wait(100)
  end
  return false, "TracerPid never set; lldb-server failed to attach"
end

-- ── codelldb config builders ──────────────────────────────────────────────

-- Read /proc/<pid>/maps via run-as and extract the runtime load base of
-- libUE4.so. Required because LLDB's gdb-remote (gdbserver --attach mode)
-- doesn't auto-sync module slides on Android — without this all stack
-- frames stay as raw addresses.
-- Returns the base as a hex STRING (without "0x"); LuaJIT's number formatting
-- truncates 64-bit pointers to 32 bits when using %x, so we keep it textual.
local function pick_libue4_base(adb, serial, pkg, pid)
  local out = adb_run(adb, { "-s", serial, "shell", "run-as", pkg,
    "cat", "/proc/" .. tostring(pid) .. "/maps" })
  if not out or out == "" then return nil end
  for line in out:gmatch("[^\r\n]+") do
    local lo, _, _, off = line:match("^(%x+)%-(%x+)%s+(%S+)%s+(%x+)")
    if lo and off == "00000000" and line:find("libUE4%.so") then
      return lo  -- raw hex string, e.g. "7594c2a000"
    end
  end
  return nil
end

local function find_engine_root_from_cwd()
  local d = vim.fn.getcwd()
  for _ = 1, 12 do
    if vim.uv.fs_stat(d .. "/Engine/Build/BatchFiles") then return d end
    local parent = vim.fs.dirname(d)
    if not parent or parent == d then break end
    d = parent
  end
  return nil
end

local function init_commands(session)
  local cmds = {
    "settings set plugin.process.gdb-remote.packet-timeout 60",
    "settings set target.inline-breakpoint-strategy always",
    "settings set target.move-to-nearest-code true",
  }
  -- UE LLDB pretty-printers for FString / FName / TArray / TMap / FVector …
  -- Shipped by Epic at  <engine>/Engine/Extras/LLDBDataFormatters/.
  -- _2ByteChars variant matches UE's default 2-byte TCHAR build (Android,
  -- Win64, Linux). If user is on a 4-byte TCHAR build they can swap the
  -- filename via ue.config.dap.lldb_formatter_path.
  local er = session and session.engine_root
  if not er or er == "" then er = find_engine_root_from_cwd() end
  local cfg_path
  local ok_cfg, ue_cfg = pcall(require, "ue.config")
  if ok_cfg and ue_cfg and ue_cfg.get then
    cfg_path = ue_cfg.get("dap.lldb_formatter_path")
  end
  local formatter = cfg_path
  if (not formatter or formatter == "") and er and er ~= "" then
    formatter = er .. "/Engine/Extras/LLDBDataFormatters/UE4DataFormatters_2ByteChars.py"
  end
  if formatter and formatter ~= "" then
    local f = io.open(formatter, "r")
    if f then
      f:close()
      table.insert(cmds, string.format('command script import "%s"', formatter))
    else
      -- Silent skip: missing formatter is annoying but not fatal.
      -- Surface it once via :messages so users notice if they expect it.
      vim.schedule(function()
        vim.notify(
          "[ue.dap] LLDB formatter not found: " .. formatter ..
          "\n(set ue.config.dap.lldb_formatter_path to override)",
          vim.log.levels.WARN)
      end)
    end
  end
  return cmds
end

-- Commands that run AFTER process is created/attached. Here we:
--   1) Pass-through SIGSEGV (ART uses it for implicit null checks + GC barriers;
--      stopping on every one freezes the game and shows phantom crashes).
--   2) Rebase libUE4.so to the device-side runtime load address. lldb's
--      gdb-remote gdbserver mode does not auto-sync module slides on Android,
--      so without this all libUE4 frames stay as raw addresses with no symbols.
local function post_run_commands(session)
  local cmds = {
    "process handle SIGSEGV --notify true --pass true --stop false",
    "process handle SIGBUS  --notify true --pass true --stop false",
    "process handle SIGPIPE --notify false --pass true --stop false",
  }
  if session.libue4_base then
    table.insert(cmds, string.format(
      "target modules load --file libUE4.so --slide 0x%s", session.libue4_base))
  end
  return cmds
end

-- Build the codelldb DAP config for the current session.
local function codelldb_attach_config(session, source_map)
  local cfg = {
    name        = "UE Android Attach (codelldb)",
    type        = "codelldb",
    request     = "launch",  -- DAP command; targetCreateCommands routes codelldb to custom mode
    stopOnEntry = true,
    cwd         = vim.fn.getcwd(),

    initCommands           = init_commands(session),
    targetCreateCommands   = {
      string.format('target create "%s"', session.symbol_lib),
    },
    processCreateCommands  = {
      string.format("gdb-remote 127.0.0.1:%d", session.port),
    },
    postRunCommands        = post_run_commands(session),
  }
  if type(source_map) == "table" and #source_map > 0 then
    -- codelldb accepts sourceMap as a dict { from = to } — flatten our list.
    local sm = {}
    for _, pair in ipairs(source_map) do
      if pair.from and pair.to then sm[pair.from] = pair.to end
    end
    cfg.sourceMap = sm
  end
  return cfg
end

-- ── public: stop / cleanup ────────────────────────────────────────────────

function M.stop_android_debugger(opts)
  opts = opts or {}
  local result = { disconnected = false, adapter_killed = false, orphan_killed = 0 }

  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap and dap.session and dap.session() then
    pcall(function()
      dap.session():request("disconnect", { terminateDebuggee = false })
    end)
    -- NOTE: do NOT call dap.terminate() here. For an attach session,
    -- nvim-dap maps terminate() to a DAP `terminate` request which
    -- codelldb interprets as "kill the debuggee process". We only want
    -- to detach (disconnect terminateDebuggee=false above). The
    -- on_session_end listener will handle UI/logcat/state cleanup
    -- once the disconnect response comes back.
    result.disconnected = true
  end

  -- Tear down device-side resources (lldb-server / port forward / SIGCONT).
  M._cleanup_device_side()
  result.adapter_killed = true

  reset_session()
  return result
end

--- Internal: tear down device-side resources only. Does NOT touch the
--- DAP session — caller is responsible for that.
---
--- This must NEVER send a `disconnect` request: when invoked from the
--- on_session_end listener, codelldb has already begun shutting the
--- adapter down. Sending a second disconnect there causes nvim-dap's
--- callback table to receive a duplicate response with no matching
--- entry, logged as `"No callback found. Did the debug adapter send
--- duplicate responses?"` — and codelldb exits, which makes dapui
--- panels disappear ("the debug UI just closed by itself").
function M._cleanup_device_side()
  local sess = M._session
  if sess.serial and sess.adb then
    if sess.package_name then
      pcall(adb_run, sess.adb, { "-s", sess.serial, "shell", "run-as",
        sess.package_name, "pkill", "-f", "lldb-server-ndk27" })
    end
    pcall(adb_run, sess.adb, { "-s", sess.serial, "forward",
      "--remove", "tcp:" .. (sess.port or 5045) })
    -- If the target was left in T state, SIGCONT it so the next attach
    -- doesn't have to deal with a frozen process.
    if sess.pid then
      pcall(adb_run, sess.adb, { "-s", sess.serial, "shell",
        "kill", "-CONT", tostring(sess.pid) })
    end
  end
end

-- Cleanup hook called by ue.dap on session end events (terminated/exited/
-- disconnect). MUST NOT issue another `disconnect` — see _cleanup_device_side
-- comment. Only releases device-side resources and clears local state.
function M.cleanup(_session_state)
  M._cleanup_device_side()
  reset_session()
  return { device_cleaned = true }
end

-- ── public: attach / launch ───────────────────────────────────────────────

local function bootstrap_session(opts)
  opts = opts or {}
  local ctx = opts.context
  local P = require("ue.dap._progress")

  local sess = M._session
  sess.adb  = "adb"
  sess.port = pick_port()
  sess.engine_root = ctx and ctx.engine_root or nil

  P.step("1/6  picking package …")
  local pkg = pick_package(ctx)
  if not pkg then P.hide(); return nil end
  sess.package_name = pkg

  P.step("2/6  picking device …")
  local serial = (ctx and ctx.android_serial) or pick_serial(sess.adb)
  if not serial then
    P.error("no device in `adb devices`")
    return nil
  end
  sess.serial = serial

  P.step("3/6  locating lldb-server …")
  local server_src = pick_lldb_server()
  if not server_src then P.hide(); return nil end
  sess.lldb_server_local = server_src

  P.step("4/6  picking symbol lib …")
  local sym = pick_symbol_lib(ctx)
  if not sym then P.hide(); return nil end
  sess.symbol_lib = sym

  sess.source_map = pick_source_map(ctx)

  P.step("5/6  pushing lldb-server to device …")
  local ok_push, push_msg = ensure_lldb_server_in_app(sess.adb, serial, pkg, server_src)
  if not ok_push then
    P.error("lldb-server bootstrap failed: " .. tostring(push_msg))
    log.notify_error("dap.android", "lldb-server bootstrap failed: " .. push_msg)
    return nil
  end

  return true
end

-- Common tail of attach/launch: spin up lldb-server gdbserver, snapshot
-- libUE4.so base, hand off to codelldb. Mutates sess.
local function _finalize_session(sess, pid, cfg_name, run_label)
  local P = require("ue.dap._progress")
  sess.pid = pid

  P.step(("starting lldb-server (pid=%s port=%d) …"):format(pid, sess.port))
  local ok_srv, srv_err = start_lldb_server_gdbserver(
    sess.adb, sess.serial, sess.package_name, pid, sess.port)
  if not ok_srv then
    P.error("lldb-server gdbserver failed: " .. tostring(srv_err))
    log.notify_error("dap.android", "lldb-server gdbserver failed: " .. srv_err)
    M.stop_android_debugger()
    return
  end

  -- Snapshot device-side libUE4.so load base for module rebasing.
  P.step("reading /proc/" .. pid .. "/maps for libUE4.so base …")
  sess.libue4_base = pick_libue4_base(sess.adb, sess.serial, sess.package_name, pid)
  if sess.libue4_base then
    P.step("libUE4.so base = 0x" .. sess.libue4_base .. "  — attaching …")
  else
    P.step("libUE4.so base not found; frames will show raw addresses — attaching …")
  end

  local cfg = codelldb_attach_config(sess, sess.source_map)
  cfg.name = cfg_name
  C.run_codelldb(cfg, run_label)
  -- Progress popup finalized by ue.dap.lua's event_initialized listener
  -- (P.done) or by stop_android_debugger / on_session_end (P.hide).
end

function M.attach(opts)
  if not bootstrap_session(opts) then return end
  local sess = M._session
  local P = require("ue.dap._progress")

  P.step("6/6  finding pid for " .. (sess.package_name or "?") .. " …")
  local pid = pidof(sess.adb, sess.serial, sess.package_name)
  if not pid then
    P.error(("process %s not running on %s"):format(sess.package_name, sess.serial))
    M.stop_android_debugger()
    return
  end
  _finalize_session(sess, pid, "UE Android Attach (codelldb)", "UEDAP android attach")
end

function M.launch(opts)
  if not bootstrap_session(opts) then return end
  local sess = M._session
  local P = require("ue.dap._progress")

  P.step("6/6  starting activity " .. (sess.package_name or "?") .. " …")
  pcall(adb_run, sess.adb, {
    "-s", sess.serial, "shell", "monkey", "-p", sess.package_name,
    "-c", "android.intent.category.LAUNCHER", "1",
  })

  P.step("waiting for process to appear …")
  local pid
  for _ = 1, 25 do
    pid = pidof(sess.adb, sess.serial, sess.package_name)
    if pid then break end
    vim.wait(200)
  end
  if not pid then
    P.error(("%s did not start within 5s"):format(sess.package_name))
    M.stop_android_debugger()
    return
  end
  _finalize_session(sess, pid, "UE Android Launch (codelldb)", "UEDAP android launch")
end

-- ── test hooks ────────────────────────────────────────────────────────────

function M._pick_lldb_server_for_test(globs)
  return pick_lldb_server_for_tests(globs)
end

function M._codelldb_attach_config_for_test(session, source_map)
  return codelldb_attach_config(session, source_map)
end

return M
