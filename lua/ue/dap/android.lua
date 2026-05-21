-- ue.dap.android — Android DAP attach via lldb-dap + Android lldb-server.
--
-- Adapter: LLVM lldb-dap (resolved by ue.dap._common.find_lldb_dap).
-- Wire:    nvim-dap → lldb-dap (host, LLVM 22.1.6) → platform connect
--          → adb forward → lldb-server platform on /data/local/tmp/ (PUBLIC)
--          → process attach --pid → ART implicit-null SIGSEGV suppressed
--          via `process handle SIGSEGV/SIGBUS/SIGPIPE --notify false`.
--
-- Why lldb-dap (migrated from codelldb 2026-05-21):
--   * codelldb is a VS Code extension carrying a vendored liblldb. It works
--     but is one more thing to bundle, version-pin and patch. lldb-dap ships
--     in the LLVM toolchain we already require for clangd/UE — one adapter,
--     one liblldb, one set of expectations.
--   * The 2026-05-21 "lldb-dap crashes on Android setBP" reputation was a
--     self-inflicted symptom from `process handle SIGSEGV --notify true`,
--     not an LLVM bug. With --notify false lldb-dap 22.1.6 + platform mode
--     attaches and plants breakpoints stably (probe_bp_v12 + probe_bp_v13
--     in C:/tools/lldb-22, end-to-end hit confirmed against UE Android
--     FEngineLoop::Tick on 2026-05-21).
--
-- Why platform mode (not gdb-remote gdbserver --attach):
--   * platform mode is what the modern lldb shipping in Android Studio,
--     Xcode and the LLVM source tree expects. It auto-syncs module slides
--     so we no longer have to read /proc/<pid>/maps and inject a manual
--     `target modules load --slide`.
--   * lldb-server runs as PUBLIC user under /data/local/tmp/lldb-server.
--     UE Android apps are built with android:debuggable=true (otherwise
--     gdb can't attach either) so adb can `ptrace` them through the
--     PUBLIC server without run-as sandbox copying.
--   * platform mode pulls libUE4.so into ~/.lldb/module_cache/ on first
--     attach (one-time, 3.85 GB) and caches forever. This is purely a
--     symbol-name source; for source-line resolution we still feed the
--     host-side DWARF via `target.exec-search-paths` and a sourceMap.
--
-- Requirements on the device (auto-bootstrapped):
--   * lldb-server (NDK 27, LLDB 18) pushed to /data/local/tmp/lldb-server.
--     The PUBLIC location means no run-as sandbox copy is needed — anybody
--     can `cd /data/local/tmp && ./lldb-server platform --server --listen *:N`.
--   * Process matching session.package_name running.
--   * App is debuggable (android:debuggable=true) OR adb root works.
--
-- Requirements on the host (one-time):
--   * LLVM 22.1.6+ with lldb-dap.exe on PATH or under
--     C:/tools/lldb-22/install/bin/, or pointed to by
--     ue.config.dap.lldb_dap_path.
--   * A symbol-rich libUE4.so (DWARF) available locally — either the
--     Binaries/Android/Client_Symbols_v* tree or the Intermediate jni
--     output. Pointed to by ue.config dap.android_symbol_lib OR auto-
--     detected from the project root. Strictly optional but strongly
--     recommended: without it lldb-dap will pull stripped libUE4.so from
--     the device into ~/.lldb/module_cache (no source lines).
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

-- ── reattach memory ───────────────────────────────────────────────────────
-- Snapshot of the last successful session, kept across stop() so that
-- :UEDAPReattach can replay pkg/serial/symbol_lib without re-prompting.
M._last_session = nil

local function snapshot_last_session()
  local s = M._session
  if not (s.package_name and s.serial and s.symbol_lib) then return end
  M._last_session = {
    package_name      = s.package_name,
    serial            = s.serial,
    symbol_lib        = s.symbol_lib,
    lldb_server_local = s.lldb_server_local,
    source_map        = s.source_map,
    engine_root       = s.engine_root,
    adb               = s.adb,
  }
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
  -- NDK 27's lldb-server (LLDB 18) is the historical safe pick on Android:
  -- it speaks the platform protocol that LLVM 22 host lldb-dap understands,
  -- and the host/device version skew (host=22 device=18) is empirically
  -- safe for platform mode. Higher NDK lldb-servers (e.g. r29 LLDB 21)
  -- also work but offer no observable upside. Resolve all candidates,
  -- then pick the highest NDK version.
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
  -- project root so lldb-dap can resolve at least Game-side sources.
  -- Engine sources are only resolvable if the user has a local Engine tree
  -- under project_root/Engine. When absent, the Engine map still points
  -- somewhere existing so lldb-dap won't bail with "Cursor position outside
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

-- Parse `adb devices` into { {serial, status, model?}, ... }.
-- status ∈ { "device", "unauthorized", "offline", "no permissions", ... }
local function list_devices(adb)
  local out = adb_run(adb, { "devices", "-l" })
  local rows = {}
  for line in out:gmatch("[^\n]+") do
    if not line:match("^List of devices") and line ~= "" then
      local serial, status, rest = line:match("^(%S+)%s+(%S+)%s*(.*)$")
      if serial and status and serial ~= "List" then
        local model = rest and rest:match("model:(%S+)") or nil
        rows[#rows + 1] = { serial = serial, status = status, model = model }
      end
    end
  end
  return rows
end

-- Resolve the adb serial to use for this session.
-- Behavior (per user policy "多设备你给我选,不要自己决定"):
--   * 0 ready devices  → notify + nil (with hints for unauthorized/offline)
--   * 1 ready device   → return it silently
--   * >1 ready devices → vim.ui.select, ALWAYS prompt, never cache a default
-- `done(serial|nil)` is called with the picked serial or nil on cancel/empty.
-- Returns the serial synchronously when possible (0 or 1 device); for the
-- multi-device case it returns nil and dispatches `done` asynchronously.
local function pick_serial_async(adb, done)
  local rows = list_devices(adb)
  local ready, not_ready = {}, {}
  for _, r in ipairs(rows) do
    if r.status == "device" then ready[#ready + 1] = r
    else not_ready[#not_ready + 1] = r end
  end

  if #ready == 0 then
    if #not_ready > 0 then
      local parts = {}
      for _, r in ipairs(not_ready) do
        local hint = r.status
        if r.status == "unauthorized" then
          hint = "unauthorized (tap 'Allow USB debugging' on device)"
        elseif r.status == "offline" then
          hint = "offline (try `adb kill-server && adb devices`)"
        end
        parts[#parts + 1] = string.format("  %s  %s", r.serial, hint)
      end
      vim.notify("No ready Android device. Detected:\n" .. table.concat(parts, "\n"),
        vim.log.levels.WARN)
    else
      vim.notify("No Android device found in `adb devices`.\n" ..
        "Connect a device with USB debugging enabled.", vim.log.levels.WARN)
    end
    done(nil)
    return nil
  end

  if #ready == 1 then
    done(ready[1].serial)
    return ready[1].serial
  end

  -- Multi-device: ALWAYS prompt. No silent default.
  local items = {}
  for _, r in ipairs(ready) do items[#items + 1] = r end
  vim.ui.select(items, {
    prompt = "Select Android device for DAP attach:",
    format_item = function(r)
      if r.model then return ("%s  [%s]"):format(r.serial, r.model) end
      return r.serial
    end,
  }, function(choice)
    done(choice and choice.serial or nil)
  end)
  return nil
end

-- Sync wrapper retained for tests/legacy callers that don't expect async.
-- For the multi-device case this returns nil; production code MUST use
-- pick_serial_async via bootstrap_session (which is already async-friendly).
local function pick_serial(adb)
  local picked
  pick_serial_async(adb, function(s) picked = s end)
  return picked
end

local function pidof(adb, serial, pkg)
  local out = adb_run(adb, { "-s", serial, "shell", "pidof", "-s", pkg })
  local digits = (out or ""):match("(%d+)")
  return digits and tonumber(digits) or nil
end

-- Push lldb-server → /data/local/tmp/lldb-server (PUBLIC). Idempotent:
-- skip push if the remote file is the same size. lldb-dap platform mode
-- doesn't need the server inside the app sandbox; PUBLIC /data/local/tmp/
-- is sufficient because we ptrace via the device's debug user, not via
-- run-as.
local function ensure_lldb_server_pushed(adb, serial, src)
  local local_size = vim.fn.getfsize(src)
  if local_size <= 0 then
    return false, "lldb-server source not readable: " .. tostring(src)
  end

  local remote = "/data/local/tmp/lldb-server"
  local remote_size = adb_run(adb, {
    "-s", serial, "shell", "stat", "-c", "%s", remote,
  })
  if tostring(remote_size) ~= tostring(local_size) then
    if adb_run(adb, { "-s", serial, "push", src, remote }) == "" then
      if vim.v.shell_error ~= 0 then return false, "adb push failed" end
    end
  end
  adb_run(adb, { "-s", serial, "shell", "chmod", "755", remote })

  -- Verify presence.
  local check = adb_run(adb, { "-s", serial, "shell", "ls", remote })
  if not check:match("lldb%-server") then
    return false, "lldb-server not present after push"
  end
  return true, "ready"
end

-- Spawn `lldb-server platform --server --listen *:<port>` as a PUBLIC
-- background process under /data/local/tmp/. Returns (ok, err).
--
-- platform mode is fundamentally different from gdbserver --attach:
--   * We do NOT pre-attach to the pid. lldb-dap on the host issues a
--     `process attach --pid N` over the platform connection at attach
--     time, and the device-side server does ptrace internally.
--   * We do NOT need to be inside the app sandbox: the platform server
--     speaks to the host on a single TCP port and forks per-target
--     gdbserver children itself, each of which inherits the platform
--     server's UID (which can be the shell user on debuggable apps).
--   * We DO still need `adb forward tcp:N tcp:N` so host lldb-dap can
--     reach the device-side listener.
local function start_lldb_server_platform(adb, serial, port)
  -- Kill any prior lldb-server (platform or gdbserver) lingering on the
  -- device. Wildcard match on the binary name covers both modes and any
  -- previous run that may have crashed without cleanup.
  pcall(adb_run, adb, { "-s", serial, "shell",
    "killall lldb-server 2>/dev/null; true" })
  vim.wait(150)

  -- Spawn `lldb-server platform --server --listen *:N` as a never-exiting
  -- foreground process on the device, and treat the host-side `adb shell`
  -- as a long-lived background job that mirrors that lifetime.
  --
  -- DO NOT use nohup + `&` + `vim.fn.system(...)`. On Android 14+ adbd's
  -- shell does NOT consider its stdout closed even when the child is
  -- `nohup`-ed and redirected — the adb shell client therefore blocks
  -- forever, and so does vim.fn.system (proven on an arm64 emulator
  -- 2026-05-21: device-side server reaches LISTEN state, host-side
  -- vim.fn.system never returns). probe_bp_v13.py escaped this by using
  -- subprocess.Popen with stdout=DEVNULL and NOT calling .wait() — same
  -- shape we replicate here via vim.fn.jobstart (detached + no callbacks).
  --
  -- IMPORTANT: `--listen *:port` works for `lldb-server platform`. The
  -- positional `[host]:port` form that NDK 27 lldb-server's gdbserver mode
  -- required does NOT apply here — platform mode accepts the wildcard.
  local cmd = string.format(
    "cd /data/local/tmp && ./lldb-server platform --server --listen \\*:%d",
    port
  )
  -- jobstart returns immediately; we don't care about output, but we DO
  -- want the job tracked so a later VimLeavePre can kill the adb client
  -- (which kills the device-side ssh-tunnel-equivalent and thus the
  -- platform server too).
  local jobid = vim.fn.jobstart({ adb, "-s", serial, "shell", cmd }, {
    detach = false,
    -- Discard output: lldb-server platform doesn't print anything
    -- meaningful and keeping the pipe open silently is fine since
    -- jobstart doesn't block on a full buffer.
  })
  if not jobid or jobid <= 0 then
    return false, "failed to spawn adb shell lldb-server (jobstart=" .. tostring(jobid) .. ")"
  end
  -- Snapshot the job id on the module so cleanup can kill it on detach.
  M._lldb_server_jobid = jobid

  -- Give the device-side lldb-server time to bind the socket BEFORE we
  -- try `adb forward`. 400ms is conservative; probe_bp_v13.py uses 1.5s.
  vim.wait(800)

  -- adb forward host:port → device:port. Idempotent.
  adb_run(adb, { "-s", serial, "forward", "--remove", "tcp:" .. port })
  if adb_run(adb, { "-s", serial, "forward", "tcp:" .. port, "tcp:" .. port }) == "" then
    if vim.v.shell_error ~= 0 then return false, "adb forward failed" end
  end

  return true, nil
end

-- ── lldb-dap config builder ───────────────────────────────────────────────

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
    -- platform connect needs a high packet timeout on slow USB cables /
    -- emulators with heavy load. 60s leaves room for first-attach module
    -- enumeration on a 3.85 GB libUE4.so.
    "settings set plugin.process.gdb-remote.packet-timeout 60",
    "settings set target.inline-breakpoint-strategy always",
    "settings set target.move-to-nearest-code true",
  }
  -- Point lldb at the host-side symbol-rich libUE4.so so it doesn't fetch
  -- the stripped device copy into ~/.lldb/module_cache. The host DWARF gives
  -- us source-line frames; without this lldb-dap still works but frame
  -- paths point inside the cache and source view is empty.
  if session and session.symbol_lib and session.symbol_lib ~= "" then
    local dir = vim.fs.dirname(session.symbol_lib)
    if dir and dir ~= "" then
      table.insert(cmds, string.format(
        'settings set target.exec-search-paths "%s"', dir))
    end
  end
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

-- Commands batched inside the `attach` request. Order matters:
--   1. platform select remote-android       → switches lldb to talk Android
--   2. platform connect connect://[serial]:port  → opens the wire
--   3. process attach --pid N                → ptraces the target
--   4. process handle SIG*  --notify FALSE   → CRITICAL: without this,
--      lldb-dap broadcasts a DAP `stopped` event per signal per thread,
--      flooding stdout pipe → Win32 EINVAL → adapter dies. See
--      skill lldb-dap-22-platform-mode-breakpoint-crash for the full
--      forensics. probe_bp_v13.py is the contract test.
local function attach_commands(session)
  return {
    "platform select remote-android",
    string.format("platform connect connect://[%s]:%d",
      session.serial, session.port),
    string.format("process attach --pid %d", session.pid),
    "process handle SIGSEGV --notify false --pass false --stop false",
    "process handle SIGBUS  --notify false --pass false --stop false",
    "process handle SIGPIPE --notify false --pass false --stop false",
  }
end

-- Build the lldb-dap DAP config for the current session.
--
-- lldb-dap uses the DAP `attach` request with custom `attachCommands` for
-- non-trivial attach flows (anything beyond `pid + program`). All the
-- platform-mode wiring lives in attachCommands; nvim-dap just hands the
-- whole thing to lldb-dap which executes them in order.
local function lldb_dap_attach_config(session, source_map)
  local cfg = {
    name           = "UE Android Attach (lldb-dap)",
    type           = "lldb",  -- matches dap.adapters.lldb wired by _common.ensure_adapter
    request        = "attach",
    -- stopOnEntry MUST be true even though we don't want to "stop on
    -- entry" semantically. Background: lldb-dap's platform-mode attach
    -- sequence executes attachCommands (platform select / connect / process
    -- attach), at which point the target is paused. lldb-dap then reports
    -- this paused state via a `stopped` event. If stopOnEntry=false,
    -- nvim-dap auto-issues `continue` before our user-level continue gets
    -- a chance, and any subsequent `configurationDone` request fails with
    -- "Expected process to be stopped". With stopOnEntry=true nvim-dap
    -- waits for an explicit continue. We never expose the "entry stop"
    -- to the user — the post-attach continue in finalize hands the
    -- process right back to running before any UI panel paints.
    stopOnEntry    = true,
    -- lldb-dap timeout in seconds for the full attach sequence (platform
    -- connect + process attach + module enumeration). Default is 30s
    -- which is too short for a 3.85 GB libUE4.so over USB. probe_bp_v13
    -- uses 180s and verified it's enough margin. Note this is a
    -- lldb-dap-specific config key under the `attach` request body, not
    -- a DAP-spec field.
    timeout        = 180,
    cwd            = vim.fn.getcwd(),
    initCommands   = init_commands(session),
    attachCommands = attach_commands(session),
  }
  if type(source_map) == "table" and #source_map > 0 then
    -- lldb-dap accepts sourceMap as a dict { from = to } (same shape as
    -- codelldb did) — flatten our list-of-pairs.
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

  -- Stop the liveness poller FIRST so it can't race with reset_session.
  if M._stop_liveness_poller then pcall(M._stop_liveness_poller) end
  -- Remember session for :UEDAPReattach BEFORE reset_session wipes it.
  snapshot_last_session()

  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap and dap.session and dap.session() then
    pcall(function()
      dap.session():request("disconnect", { terminateDebuggee = false })
    end)
    -- NOTE: do NOT call dap.terminate() here. For an attach session,
    -- nvim-dap maps terminate() to a DAP `terminate` request which
    -- lldb-dap interprets as "kill the debuggee process". We only want
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
--- on_session_end listener, lldb-dap has already begun shutting the
--- adapter down. Sending a second disconnect there causes nvim-dap's
--- callback table to receive a duplicate response with no matching
--- entry, logged as `"No callback found. Did the debug adapter send
--- duplicate responses?"` — and lldb-dap exits, which makes dapui
--- panels disappear ("the debug UI just closed by itself").
function M._cleanup_device_side()
  local sess = M._session
  -- Stop the host-side `adb shell lldb-server platform` job we spawned via
  -- jobstart in start_lldb_server_platform. Killing the adb client closes
  -- the shell, which the device propagates to the platform server.
  if M._lldb_server_jobid and M._lldb_server_jobid > 0 then
    pcall(vim.fn.jobstop, M._lldb_server_jobid)
    M._lldb_server_jobid = nil
  end
  if sess.serial and sess.adb then
    -- PUBLIC platform-mode lldb-server: no need for run-as. A plain
    -- killall on the binary covers both the live platform server and any
    -- gdbserver child it forked for this session.
    pcall(adb_run, sess.adb, { "-s", sess.serial, "shell",
      "killall lldb-server 2>/dev/null; true" })
    pcall(adb_run, sess.adb, { "-s", sess.serial, "forward",
      "--remove", "tcp:" .. (sess.port or 5039) })
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
  if M._stop_liveness_poller then pcall(M._stop_liveness_poller) end
  snapshot_last_session()
  M._cleanup_device_side()
  reset_session()
  return { device_cleaned = true }
end

-- ── public: attach / launch ───────────────────────────────────────────────

local function bootstrap_session(opts, on_ready)
  opts = opts or {}
  local ctx = opts.context
  local P = require("ue.dap._progress")

  local sess = M._session
  sess.adb  = "adb"
  sess.port = pick_port()
  sess.engine_root = ctx and ctx.engine_root or nil

  P.step("1/6  picking package …")
  local pkg = pick_package(ctx)
  if not pkg then P.hide(); on_ready(false); return end
  sess.package_name = pkg

  P.step("2/6  picking device …")
  if ctx and ctx.android_serial then
    sess.serial = ctx.android_serial
  end

  local function after_serial(serial)
    if not serial then
      P.error("no device selected")
      on_ready(false); return
    end
    sess.serial = serial

    P.step("3/6  locating lldb-server …")
    local server_src = pick_lldb_server()
    if not server_src then P.hide(); on_ready(false); return end
    sess.lldb_server_local = server_src

    P.step("4/6  picking symbol lib …")
    local sym = pick_symbol_lib(ctx)
    if not sym then P.hide(); on_ready(false); return end
    sess.symbol_lib = sym

    sess.source_map = pick_source_map(ctx)

    P.step("5/6  pushing lldb-server to device …")
    local ok_push, push_msg = ensure_lldb_server_pushed(sess.adb, serial, server_src)
    if not ok_push then
      P.error("lldb-server bootstrap failed: " .. tostring(push_msg))
      log.notify_error("dap.android", "lldb-server bootstrap failed: " .. push_msg)
      on_ready(false); return
    end

    on_ready(true)
  end

  if sess.serial then
    after_serial(sess.serial)
  else
    pick_serial_async(sess.adb, after_serial)
  end
end

-- Common tail of attach/launch: spin up the lldb-server platform server,
-- then hand the lldb-dap config to nvim-dap. Mutates sess (records pid).
local function _finalize_session(sess, pid, cfg_name, run_label)
  local P = require("ue.dap._progress")
  sess.pid = pid

  P.step(("starting lldb-server platform (port=%d) …"):format(sess.port))
  local ok_srv, srv_err = start_lldb_server_platform(
    sess.adb, sess.serial, sess.port)
  if not ok_srv then
    P.error("lldb-server platform failed: " .. tostring(srv_err))
    log.notify_error("dap.android", "lldb-server platform failed: " .. srv_err)
    M.stop_android_debugger()
    return
  end

  -- platform mode auto-syncs module slides; the manual libUE4.so rebase
  -- we used to do here is no longer required.
  P.step("attaching …")

  local cfg = lldb_dap_attach_config(sess, sess.source_map)
  cfg.name = cfg_name
  C.run(cfg, run_label)
  -- Progress popup finalized by ue.dap.lua's event_initialized listener
  -- (P.done) or by stop_android_debugger / on_session_end (P.hide).
end

function M.attach(opts)
  if M._attach_in_progress then
    vim.notify("[ue.dap.android] attach already in progress — wait for it to finish or :UEDAPStop",
      vim.log.levels.WARN)
    return
  end
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap and dap.session and dap.session() then
    vim.notify("[ue.dap.android] DAP session already active — :UEDAPStop first, or :UEDAPReattach",
      vim.log.levels.WARN)
    return
  end
  M._attach_in_progress = true
  bootstrap_session(opts, function(ok)
    if not ok then M._attach_in_progress = false; return end
    local sess = M._session
    local P = require("ue.dap._progress")
    P.step("6/6  finding pid for " .. (sess.package_name or "?") .. " …")
    local pid = pidof(sess.adb, sess.serial, sess.package_name)
    if not pid then
      P.error(("process %s not running on %s"):format(sess.package_name, sess.serial))
      M._attach_in_progress = false
      M.stop_android_debugger()
      return
    end
    _finalize_session(sess, pid, "UE Android Attach (lldb-dap)", "UEDAP android attach")
    M._attach_in_progress = false
    M._start_liveness_poller()
  end)
end

function M.launch(opts)
  if M._attach_in_progress then
    vim.notify("[ue.dap.android] attach already in progress", vim.log.levels.WARN)
    return
  end
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap and dap.session and dap.session() then
    vim.notify("[ue.dap.android] DAP session already active — :UEDAPStop first",
      vim.log.levels.WARN)
    return
  end
  M._attach_in_progress = true
  bootstrap_session(opts, function(ok)
    if not ok then M._attach_in_progress = false; return end
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
      M._attach_in_progress = false
      M.stop_android_debugger()
      return
    end
    _finalize_session(sess, pid, "UE Android Launch (lldb-dap)", "UEDAP android launch")
    M._attach_in_progress = false
    M._start_liveness_poller()
  end)
end

-- ── public: reattach (same pkg/serial/symbol_lib, fresh pid) ──────────────
-- Keeps the last successful session's pkg/serial/symbol_lib/lldb_server_local
-- in M._last_session and lets the user re-attach in one command after the app
-- restarts (Live++/hot-reload/manual relaunch). No re-pick of paths/devices.
-- (snapshot_last_session / M._last_session are defined near the top so
-- stop_android_debugger / cleanup can reference them.)

function M.reattach()
  if M._attach_in_progress then
    vim.notify("[ue.dap.android] attach in progress", vim.log.levels.WARN)
    return
  end
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap and dap.session and dap.session() then
    vim.notify("[ue.dap.android] active session — :UEDAPStop first", vim.log.levels.WARN)
    return
  end
  local last = M._last_session
  if not last then
    vim.notify("[ue.dap.android] no previous session to reattach to — use :UEDAPAttach",
      vim.log.levels.WARN)
    return
  end

  M._attach_in_progress = true
  -- Replay state into the live session table.
  local sess = M._session
  sess.adb               = last.adb or "adb"
  sess.serial            = last.serial
  sess.package_name      = last.package_name
  sess.symbol_lib        = last.symbol_lib
  sess.lldb_server_local = last.lldb_server_local
  sess.source_map        = last.source_map
  sess.engine_root       = last.engine_root
  sess.port              = pick_port()

  local P = require("ue.dap._progress")
  P.step(("reattach: waiting for %s on %s …"):format(last.package_name, last.serial))

  -- Poll up to 10s for the app to be running.
  local pid
  for _ = 1, 50 do
    pid = pidof(sess.adb, sess.serial, sess.package_name)
    if pid then break end
    vim.wait(200)
  end
  if not pid then
    P.error(("%s not running on %s after 10s"):format(last.package_name, last.serial))
    M._attach_in_progress = false
    return
  end

  -- Ensure lldb-server is still in the sandbox (Android may have cleared
  -- /data/data/<pkg> on user-data wipe / reinstall).
  local ok_push, push_msg = ensure_lldb_server_pushed(
    sess.adb, sess.serial, sess.lldb_server_local)
  if not ok_push then
    P.error("lldb-server re-stage failed: " .. tostring(push_msg))
    M._attach_in_progress = false
    return
  end

  _finalize_session(sess, pid,
    "UE Android Attach (lldb-dap)", "UEDAP android reattach")
  M._attach_in_progress = false
  M._start_liveness_poller()
end

-- ── public: liveness poller ───────────────────────────────────────────────
-- IDE-style auto-detach: poll the app pid every 1.5s; after 2 consecutive
-- misses, assume the app exited (user-killed, crash, Low-Memory-Killer) and
-- auto stop the DAP session + notify. User policy: direct stop+notify, NO
-- reattach prompt (dapui floats would steal focus). User can :UEDAPReattach
-- manually when they restart the app.
M._liveness_timer  = nil
M._liveness_misses = 0

function M._stop_liveness_poller()
  if M._liveness_timer then
    pcall(function() M._liveness_timer:stop() end)
    pcall(function() M._liveness_timer:close() end)
    M._liveness_timer = nil
  end
  M._liveness_misses = 0
end

function M._start_liveness_poller()
  M._stop_liveness_poller()
  snapshot_last_session()  -- remember for :UEDAPReattach
  local sess = M._session
  if not (sess.adb and sess.serial and sess.package_name and sess.pid) then return end
  local adb, serial, pkg, pid = sess.adb, sess.serial, sess.package_name, sess.pid
  local timer = vim.uv.new_timer()
  if not timer then return end
  M._liveness_timer = timer
  timer:start(2000, 1500, vim.schedule_wrap(function()
    -- Bail if session is gone (user already stopped, or a different attach).
    local ok_dap, dap = pcall(require, "dap")
    local has_sess = ok_dap and dap and dap.session and dap.session() or nil
    if not has_sess or M._session.pid ~= pid then
      M._stop_liveness_poller()
      return
    end
    local live = pidof(adb, serial, pkg)
    if live and live == pid then
      M._liveness_misses = 0
      return
    end
    -- Tolerate a single transient miss (adb hiccup, brief unauthorized).
    M._liveness_misses = M._liveness_misses + 1
    if M._liveness_misses < 2 then return end

    -- App is gone. Stop everything, notify, snapshot for reattach.
    M._stop_liveness_poller()
    local why
    if live and live ~= pid then
      why = ("App %s restarted (new pid=%d). Detaching."):format(pkg, live)
    else
      why = ("App %s exited on %s. Detaching."):format(pkg, serial)
    end
    vim.notify("[ue.dap.android] " .. why .. "\nUse :UEDAPReattach to reconnect.",
      vim.log.levels.WARN)
    pcall(M.stop_android_debugger)
  end))
end

-- ── public: status (one-line probe for the user) ──────────────────────────
function M.status()
  local ok_dap, dap = pcall(require, "dap")
  local has_sess = ok_dap and dap and dap.session and dap.session() or nil
  local s = M._session
  local lines = {
    "── UE Android DAP status ──",
    ("  session     : %s"):format(has_sess and "ACTIVE" or "idle"),
    ("  attaching   : %s"):format(M._attach_in_progress and "yes" or "no"),
    ("  package     : %s"):format(s.package_name or "-"),
    ("  serial      : %s"):format(s.serial or "-"),
    ("  pid         : %s"):format(s.pid or "-"),
    ("  port        : %s"):format(s.port or "-"),
    ("  symbol_lib  : %s"):format(s.symbol_lib or "-"),
    ("  liveness    : %s (misses=%d)"):format(
      M._liveness_timer and "polling" or "off", M._liveness_misses or 0),
  }
  if M._last_session then
    lines[#lines + 1] = ("  last (reattach target): %s @ %s"):format(
      M._last_session.package_name, M._last_session.serial)
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
end

-- ── test hooks ────────────────────────────────────────────────────────────

function M._pick_lldb_server_for_test(globs)
  return pick_lldb_server_for_tests(globs)
end

function M._lldb_dap_attach_config_for_test(session, source_map)
  return lldb_dap_attach_config(session, source_map)
end

return M
