-- ue.dap.android — Android DAP attach via lldb-dap + lldb-server platform mode.
--
-- Adapter: LLVM lldb-dap (resolved by ue.dap._common.find_lldb_dap, host 22.1.6).
-- Wire:    nvim-dap → lldb-dap (host) → adb forward → lldb-server platform
--          (device, /data/local/tmp, --listen *:<port>). The host attach runs:
--            platform select remote-android
--            platform connect connect://[<serial>]:<port>   (serial form ONLY)
--            process attach --pid <pid>
--            process handle SIG* --notify false
--            target modules load --file libUE4.so --slide 0x<base>
--          lldb-server platform forks the per-target gdbserver itself.
--
-- This is the WORKING route, real-device verified 5/21 (commit e51cbe6) and
-- re-verified 2026-06-03 (Connected: yes + process attach + threads ok). The
-- constitution records the hard rules — see docs/CONSTRAINTS.md:
--   K30  platform mode + `connect://[<serial>]:<port>` is the only working attach.
--   K31  `lldb-server gdbserver --attach` NEVER binds the listen port — banned.
--   K32  `connect://localhost:N` gets eaten by lldb-dap getopt → `Invalid URL`.
--   K33  source-file `breakpoint set -f` may crash lldb-dap 22.1.6 (re-verify).
--   K3   ART SIGSEGV/SIGBUS need `--notify false` (and the 5/21 working config
--        used `--pass false`); without --notify, per-signal DAP stopped events
--        flood the pipe and kill the adapter on Windows.
--
-- Why lldb-dap (migrated from codelldb 2026-05-21):
--   * codelldb is a VS Code extension carrying a vendored liblldb. lldb-dap
--     ships in the LLVM toolchain we already require for clangd/UE — one
--     adapter, one liblldb, one set of expectations.
--
-- Requirements on the device (auto-bootstrapped):
--   * lldb-server pushed to PUBLIC /data/local/tmp/lldb-server (platform mode
--     does NOT need a sandbox copy — it ptraces via the debug user).
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
  remote_lldb_server = nil, -- device path to app-executable lldb-server
  lldb_server_mode  = nil,  -- "gdbserver" (production) or legacy "platform"
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
    remote_lldb_server = s.remote_lldb_server,
    lldb_server_mode  = s.lldb_server_mode,
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
  -- Preserve the priority order supplied by utils.platform.windows. Do not
  -- collect all hits and sort here: callers may intentionally put a tested
  -- device-side lldb-server first via config or platform policy. Host-side
  -- lldb-dap stays forward-only at 22.1.6+; device-side lldb-server is a
  -- separate probe variable and must be diagnosed from live attach logs.
  for _, pattern in ipairs(globs or {}) do
    local hit = vim.fn.glob(pattern)
    if hit and hit ~= "" then
      for line in (hit .. "\n"):gmatch("([^\n]+)\n") do
        if fs.is_file(line) then return line end
      end
    end
  end
  return nil
end

local function pick_lldb_server()
  local picked = pick_lldb_server_for_tests(default_lldb_server_globs())
  if picked then return picked end
  local typed = vim.fn.input("Path to arm64 lldb-server: ")
  if typed == "" then return nil end
  if not fs.is_file(typed) then
    vim.notify("Not a readable file: " .. typed, vim.log.levels.WARN)
    return nil
  end
  return typed
end

-- ── project root + packageInfo.txt auto-discovery ────────────────────────
--
-- UE's Android packaging writes Source/Client/Binaries/Android/packageInfo.txt
-- on every cook. Layout:
--   line 1: package name      (e.g. com.example.mygame)
--   line 2: versionCode       (e.g. 169723198) — matches Client_Symbols_v<code>/
--   line 3: versionName
--
-- This is the single source of truth for both pick_package and pick_symbol_lib,
-- so we never have to prompt the user when a cooked APK exists on disk. Falls
-- through to ctx/cfg/input only when there is no cooked output.

local function android_marker_path(root)
  if type(root) ~= "string" or root == "" then return nil end
  root = fs.norm(root)
  local direct = root .. "/Source/Client/Binaries/Android"
  if fs.is_file(direct .. "/packageInfo.txt") or fs.is_dir(direct) then
    return direct
  end
  -- Some projects store the .uproject under <repo>/Source/Client, and
  -- ue.resolve_context().project_root points there (for example
  -- E:/.../Source/Client). In that shape the Android marker lives directly
  -- under project_root/Binaries/Android, not project_root/Source/Client/... .
  local in_project = root .. "/Binaries/Android"
  if fs.is_file(in_project .. "/packageInfo.txt") or fs.is_dir(in_project) then
    return in_project
  end
  return nil
end

local function read_package_info(proot)
  local android_dir = android_marker_path(proot)
  if not android_dir then return nil end
  local path = android_dir .. "/packageInfo.txt"
  if not fs.is_file(path) then return nil end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" or #lines < 1 then return nil end
  local trim = function(s) return (tostring(s or ""):gsub("[\r\n%s]+$", ""):gsub("^%s+", "")) end
  return {
    package      = trim(lines[1]),
    version_code = trim(lines[2] or ""),
    path         = path,
    android_dir  = android_dir,
  }
end

-- Walk up from `start` looking for the Android cook output marker. Supports
-- both repo-root layout (<repo>/Source/Client/Binaries/Android) and the
-- common UE project-root layout (<repo>/Source/Client/Binaries/Android where
-- project_root itself is Source/Client).
local function discover_project_root(start)
  if not start or start == "" then return nil end
  local cur = fs.norm(start)
  -- If start is a file, drop to its dir.
  local stat = vim.uv and vim.uv.fs_stat(cur)
  if stat and stat.type == "file" then cur = fs.norm(vim.fn.fnamemodify(cur, ":h")) end
  for _ = 1, 16 do
    if cur == "" or cur == "/" then break end
    if android_marker_path(cur) then
      return cur
    end
    local parent = fs.norm(vim.fn.fnamemodify(cur, ":h"))
    if parent == cur then break end
    cur = parent
  end
  return nil
end

local function effective_project_root(ctx)
  local roots = {}
  local function add(root)
    if type(root) == "string" and root ~= "" then roots[#roots + 1] = fs.norm(root) end
  end
  if ctx then
    add(ctx.project_root)
    add(ctx.uproject and vim.fn.fnamemodify(ctx.uproject, ":h") or nil)
    if type(ctx.project_root) == "string" and ctx.project_root ~= "" then
      local project_parent = fs.norm(vim.fn.fnamemodify(ctx.project_root, ":h"))
      local project_grandparent = fs.norm(vim.fn.fnamemodify(project_parent, ":h"))
      add(project_parent)
      add(project_grandparent)
    end
    -- Only use engine_root as a discovery START point, never as an immediate
    -- project root: otherwise buffers opened under D:/project/uetemp make us
    -- build D:/project/uetemp/Source/Client/... and prompt unnecessarily.
    local from_engine = ctx.engine_root and discover_project_root(ctx.engine_root) or nil
    add(from_engine)
  end
  add(ue_cfg_get("project_root"))
  add(ue_cfg_get("dap.project_root"))
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname and bufname ~= "" then add(discover_project_root(bufname)) end
  add(discover_project_root(vim.fn.getcwd()))

  for _, root in ipairs(roots) do
    if android_marker_path(root) then return root end
  end
  return roots[1]
end

local function pick_package(ctx)
  if ctx and type(ctx.android_package) == "string" and ctx.android_package ~= "" then
    return ctx.android_package
  end
  -- 1. Persisted per-engine_root state (set on previous attach).
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
  -- 2. Config override.
  local cfg_pkg = ue_cfg_get("dap.android_package")
  if type(cfg_pkg) == "string" and cfg_pkg ~= "" then return cfg_pkg end
  -- 3. packageInfo.txt under the discovered project root — written by
  --    UE on every Android cook, single source of truth.
  local proot = effective_project_root(ctx)
  local info = read_package_info(proot)
  if info and info.package ~= "" then
    -- Persist for next time so we never re-discover. Best-effort, ignore
    -- failures (no engine_root, immutable FS, etc).
    if engine_root then
      local ok_ue, ue = pcall(require, "ue")
      if ok_ue and ue and ue.update_state_field then
        pcall(ue.update_state_field, engine_root, "android_package", info.package)
      end
    end
    return info.package
  end
  -- 4. Last resort: prompt.
  local typed = vim.fn.input("Android package name: ", "")
  if typed == "" then return nil end
  return typed
end

local function pick_symbol_lib(ctx)
  -- 0. Explicit attach/context/default override. This path is used by
  -- agent-driven and reattach flows; do not prompt for a symbol path that is
  -- already known for the current UE Android workspace.
  local ctx_sym = ctx and (ctx.android_symbol_lib or ctx.symbol_lib)
  if type(ctx_sym) == "string" and ctx_sym ~= "" and fs.is_file(ctx_sym) then
    return ctx_sym
  end
  -- 1. Config override.
  local cfg_sym = ue_cfg_get("dap.android_symbol_lib")
  if type(cfg_sym) == "string" and cfg_sym ~= "" and fs.is_file(cfg_sym) then
    return cfg_sym
  end
  local proot = effective_project_root(ctx)
  if proot then
    local android_dir = android_marker_path(proot)
    -- 2. Exact match against packageInfo.txt versionCode — guarantees the
    --    symbols correspond to the installed APK.
    local info = read_package_info(proot)
    if android_dir and info and info.version_code ~= "" then
      local exact = {
        android_dir .. "/Client_Symbols_v" .. info.version_code .. "/Client-arm64/libUE4.so",
        android_dir .. "/Client_Symbols_v" .. info.version_code .. "/Client-arm64/libUnreal.so",
      }
      for _, p in ipairs(exact) do
        if fs.is_file(p) then return p end
      end
    end
    -- 3. Glob over all symbol packages, pick the newest by mtime (best
    --    guess when no packageInfo or no exact match).
    local glob_patterns = {}
    if android_dir then
      vim.list_extend(glob_patterns, {
        android_dir .. "/*Symbols*/Client-arm64/libUE4.so",
        android_dir .. "/*Symbols*/Client-arm64/libUnreal.so",
      })
    end
    vim.list_extend(glob_patterns, {
      proot .. "/Source/Client/Intermediate/Android/arm64/jni/arm64-v8a/libUE4.so",
      proot .. "/Source/Client/Intermediate/Android/arm64/jni/arm64-v8a/libUnreal.so",
      proot .. "/Intermediate/Android/arm64/jni/arm64-v8a/libUE4.so",
      proot .. "/Intermediate/Android/arm64/jni/arm64-v8a/libUnreal.so",
    })
    local best_path, best_mtime = nil, -1
    for _, pat in ipairs(glob_patterns) do
      local hit = vim.fn.glob(pat)
      if hit and hit ~= "" then
        for line in (hit .. "\n"):gmatch("([^\n]+)\n") do
          if fs.is_file(line) then
            local st = vim.uv and vim.uv.fs_stat(line)
            local mt = (st and st.mtime and st.mtime.sec) or 0
            if mt > best_mtime then
              best_path, best_mtime = line, mt
            end
          end
        end
      end
    end
    if best_path then return best_path end
  end
  -- 4. Last resort: prompt.
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
  -- DW_AT_comp_dir (observed: "D:\project\uetemp\Engine\Source").
  --
  -- We only register the BACKSLASH form of the build root, not both
  -- backslash and forward-slash variants. lldb-dap on Windows normalizes
  -- `from` keys to backslashes internally, so sending both variants
  -- results in two identical entries in `target.source-map` and lldb
  -- traverses the same mapping twice on every source resolve (visible
  -- via UEDAPDiag section E, follow-up #9 root cause). One canonical
  -- backslash entry matches DWARF emitted with either separator.
  --
  -- Engine sources are resolvable when either project_root/Engine exists
  -- or the original build-machine Engine root exists locally. The broad
  -- build-root -> project-root mapping is still useful for project source,
  -- but without the more specific Engine entry it can rewrite valid Engine
  -- DWARF paths into nonexistent project_root/Engine paths.
  local proot = effective_project_root(ctx)
  if not proot then return nil end
  local build_root = fs.norm((ctx and ctx.android_build_root)
    or ue_cfg_get("dap.android_build_root")
    or "D:/project/uetemp")
  local sm = {}
  local build_engine = build_root .. "/Engine"
  local project_engine = proot .. "/Engine"
  if fs.is_dir(project_engine) then
    -- Prefer explicit Engine→Engine mapping if the user has source locally.
    table.insert(sm, { from = build_engine, to = project_engine })
  elseif fs.is_dir(build_engine) then
    -- Keep local Engine DWARF paths local instead of letting the broader
    -- build-root mapping rewrite them to a nonexistent project Engine path.
    table.insert(sm, { from = build_engine, to = build_engine })
  end
  table.insert(sm, { from = build_root, to = proot })
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

local function adb_run_raw(adb, args)
  local cmd = { adb }
  vim.list_extend(cmd, args)
  local out = vim.fn.system(cmd)
  return (out or ""):gsub("[\r\n]+$", ""), vim.v.shell_error
end

local function shell_quote(s)
  return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function append_bp_diag(lines)
  if type(lines) == "string" then lines = { lines } end
  if type(lines) ~= "table" then return end
  pcall(function()
    local path = vim.fn.stdpath("cache") .. "/ue-dap-bp-diag.log"
    local fh = io.open(path, "a")
    if not fh then return end
    for _, line in ipairs(lines) do
      fh:write(tostring(line), "\n")
    end
    fh:close()
  end)
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

-- Read the ASLR load base of a shared object from the device process maps.
-- Returns the base as a lowercase hex string WITHOUT the "0x" prefix, or nil.
--
-- WHY this exists: Android remote attach can leave the symbol-rich host module
-- without the device ASLR load address. Without an explicit
-- `target modules load --file <so> --slide 0x<base>`, every file:line
-- breakpoint resolves against the .so's preferred (file) base and lands at the
-- wrong runtime address — F9 silently never fires. (See
-- docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md §5 and
-- docs/CONSTRAINTS.md K2/K11.)
--
-- The base is the start of the FIRST mapping of the .so in /proc/<pid>/maps.
-- We read it via `run-as <pkg> cat /proc/<pid>/maps` (verified readable on
-- a3ad86f3; plain `adb shell cat` fails under hidepid on Android 10+).
--
-- CRITICAL: the returned value is a STRING built by text extraction, never via
-- string.format("%x", n) — LuaJIT truncates %x to 32 bits and a UE .so base
-- like 0x6c9fe21000 would be mangled (docs/CONSTRAINTS.md K4/P7).
local function read_so_base_hex(adb, serial, pkg, pid, so_basename)
  if not (adb and serial and pkg and pid and so_basename) then return nil end
  local maps = adb_run(adb, {
    "-s", serial, "shell", "run-as", pkg, "cat", "/proc/" .. tostring(pid) .. "/maps",
  })
  if not maps or maps == "" then return nil end
  -- Lua patterns have no alternation; escape the basename and scan line by line
  -- for the first mapping whose path ends with the .so name.
  local needle = so_basename:gsub("([%-%.%+%[%]%(%)%$%^%%%?%*])", "%%%1")
  for line in maps:gmatch("[^\r\n]+") do
    if line:find(needle .. "$") or line:find(needle .. "%s*$") then
      -- format: "<startHex>-<endHex> <perms> <off> <dev> <inode> <path>"
      local start_hex = line:match("^(%x+)%-%x+%s")
      if start_hex and start_hex ~= "" then
        return start_hex:lower()
      end
    end
  end
  return nil
end

-- Build the LLDB command that relocates the symbol-rich host libUE4.so to the
-- device ASLR base. Returns nil when base resolution failed (caller skips the
-- rebase but does NOT abort the attach).
local function module_rebase_command(adb, serial, pkg, pid, symbol_lib)
  if not symbol_lib or symbol_lib == "" then return nil end
  local so_basename = vim.fs.basename(symbol_lib)
  if not so_basename or so_basename == "" then return nil end
  local base_hex = read_so_base_hex(adb, serial, pkg, pid, so_basename)
  if not base_hex then return nil end
  -- Concatenation only — never string.format("%x", ...) for 64-bit addresses.
  return string.format('target modules load --file "%s" --slide 0x%s', so_basename, base_hex), base_hex
end

-- Push lldb-server → /data/local/tmp/lldb-server (PUBLIC). Idempotent: skip
-- push when remote size matches. Platform mode does NOT need the server inside
-- the app sandbox — the platform server speaks to the host on one TCP port and
-- forks per-target gdbserver children itself; PUBLIC /data/local/tmp/ is
-- sufficient (verified 2026-06-03, docs/CONSTRAINTS.md K30). This restores the
-- 5/21 e51cbe6 working path. Returns (ok, remote_path_or_err).
local function ensure_lldb_server_pushed(adb, serial, pkg, src)
  local local_size = vim.fn.getfsize(src)
  if local_size <= 0 then
    return false, "lldb-server source not readable: " .. tostring(src)
  end

  local remote = "/data/local/tmp/lldb-server"
  local remote_size = adb_run(adb, { "-s", serial, "shell", "stat", "-c", "%s", remote })
  if tostring(remote_size):match("(%d+)%s*$") ~= tostring(local_size) then
    pcall(adb_run, adb, { "-s", serial, "shell", "killall lldb-server 2>/dev/null; true" })
    local push_out, push_code = adb_run_raw(adb, { "-s", serial, "push", src, remote })
    if push_code ~= 0 then
      return false, ("adb push failed on %s (exit %s): %s")
        :format(tostring(serial), tostring(push_code), tostring(push_out))
    end
  end
  local chmod_out, chmod_code = adb_run_raw(adb, { "-s", serial, "shell", "chmod", "755", remote })
  if chmod_code ~= 0 then
    return false, ("chmod lldb-server failed on %s (exit %s): %s")
      :format(tostring(serial), tostring(chmod_code), tostring(chmod_out))
  end
  local check = adb_run(adb, { "-s", serial, "shell", "ls", remote })
  if not check:match("lldb%-server") then
    return false, "lldb-server not present after push"
  end
  return true, remote
end

-- Spawn `lldb-server platform --server --listen *:<port>` from PUBLIC
-- /data/local/tmp as a never-exiting background process; set up adb forward.
-- Returns (ok, err).
--
-- This is the WORKING attach route (K30): platform mode, NOT gdbserver --attach
-- (K31: --attach never binds the listen port). The host then issues
--   platform select remote-android
--   platform connect connect://[<serial>]:<port>   (K30/K32: serial form only)
--   process attach --pid N
-- and the device-side platform server forks the per-target gdbserver itself.
--
-- DO NOT use `cd files && ./` (K: runas_app cd fails) nor a sandbox copy — the
-- public binary runs as the shell/debug user, which can ptrace a debuggable app.
-- `--listen *:N` wildcard works for platform mode. Use jobstart (detached, no
-- callbacks) — adb shell does NOT see stdout closed even with nohup on
-- Android 14+, so vim.fn.system would block forever (e51cbe6 note).
local function start_lldb_server_platform(adb, serial, port)
  pcall(adb_run, adb, { "-s", serial, "shell", "killall lldb-server 2>/dev/null; true" })
  vim.wait(150)

  adb_run(adb, { "-s", serial, "forward", "--remove", "tcp:" .. port })
  if adb_run(adb, { "-s", serial, "forward", "tcp:" .. port, "tcp:" .. port }) == "" then
    if vim.v.shell_error ~= 0 then return false, "adb forward failed" end
  end

  local cmd = string.format(
    "cd /data/local/tmp && ./lldb-server platform --server --listen \\*:%d", port)
  local jobid = vim.fn.jobstart({ adb, "-s", serial, "shell", cmd }, { detach = false })
  if not jobid or jobid <= 0 then
    return false, "failed to spawn lldb-server platform (jobstart=" .. tostring(jobid) .. ")"
  end
  M._lldb_server_jobid = jobid
  vim.wait(800)
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
    -- gdb-remote needs a high packet timeout on slow USB cables /
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
  --
  -- IMPORTANT: Epic's formatter is pure-Python (uses lldb.SBValue API).
  -- LLVM 22.1.6 Windows minimal builds (the one we ship lldb-dap from)
  -- DO NOT include the `lldb` Python module — only liblldb.dll + the
  -- DAP front-end. `command script import` against that build emits
  --   ModuleNotFoundError: No module named 'lldb'
  -- to the console (non-fatal, attach continues). To still get *some*
  -- pretty-printing for the single most common type (FString), we fall
  -- back to a native `type summary --summary-string` rule which lldb's
  -- C++ summary engine handles without any Python interpreter.
  -- FName / TArray / TMap / FVector lose their summaries on that build —
  -- those types require SBValue.ReadMemory / decode logic that can't be
  -- expressed in the summary-string mini-language.
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

  -- Detect whether the configured lldb-dap.exe ships the `lldb` Python
  -- module. Standard LLVM Windows installer layout puts it at
  --   <install_root>/lib/site-packages/lldb/__init__.py
  -- (or Lib/site-packages/lldb on python.org-style trees). The minimal
  -- 22.1.6 build we use has none of those — so we treat missing dir as
  -- "no Python". This file probe is fast and cached per attach.
  local dap_exe = (C.find_lldb_dap and C.find_lldb_dap()) or nil
  local has_python = false
  if dap_exe and dap_exe ~= "" then
    local install_root = vim.fs.dirname(vim.fs.dirname(dap_exe))  -- strip /bin/lldb-dap.exe
    if install_root and install_root ~= "" then
      for _, sub in ipairs({ "lib/site-packages/lldb", "Lib/site-packages/lldb",
                              "lib/python3/dist-packages/lldb" }) do
        local probe = install_root .. "/" .. sub
        local st = vim.uv and vim.uv.fs_stat(probe) or vim.loop.fs_stat(probe)
        if st and st.type == "directory" then
          has_python = true
          break
        end
      end
    end
  end

  if formatter and formatter ~= "" and has_python then
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
  elseif formatter and formatter ~= "" and not has_python then
    -- No Python in lldb-dap → fall back to native `type summary` rules.
    -- These can express anything that's a simple `${var.field}` template;
    -- they CAN'T express the FName index→string lookup or TArray element
    -- iteration that Epic's Python formatter does, so we cover only the
    -- types that have purely-data layouts.
    --
    -- Layout references (UE5 stock, 2-byte TCHAR builds):
    --   FString { TArray<TCHAR> Data }                    where TArray = { AllocatorInstance.Data : TCHAR*, ArrayNum, ArrayMax }
    --   FVector       { float X, Y, Z }                   (float = double in 5.0+, layout still has X/Y/Z)
    --   FVector2D     { float X, Y }
    --   FVector4      { float X, Y, Z, W }
    --   FIntVector    { int32 X, Y, Z }
    --   FRotator      { float Pitch, Yaw, Roll }
    --   FQuat         { float X, Y, Z, W }
    --   FColor        { uint8 B, G, R, A } (BGRA on disk)
    --   FLinearColor  { float R, G, B, A }
    --   FBox          { FVector Min, Max; uint8 IsValid }
    --   TArray<T>     { Data, ArrayNum, ArrayMax }        — we show count only
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "${var.Data.AllocatorInstance.Data%s}" FString')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(X=${var.X} Y=${var.Y} Z=${var.Z})" FVector')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(X=${var.X} Y=${var.Y})" FVector2D')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(X=${var.X} Y=${var.Y} Z=${var.Z} W=${var.W})" FVector4')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(X=${var.X} Y=${var.Y} Z=${var.Z})" FIntVector')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(Pitch=${var.Pitch} Yaw=${var.Yaw} Roll=${var.Roll})" FRotator')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(X=${var.X} Y=${var.Y} Z=${var.Z} W=${var.W})" FQuat')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(R=${var.R} G=${var.G} B=${var.B} A=${var.A})" FColor')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "(R=${var.R} G=${var.G} B=${var.B} A=${var.A})" FLinearColor')
    table.insert(cmds,
      'type summary add -w UEFallback --summary-string "Min=(${var.Min.X},${var.Min.Y},${var.Min.Z}) Max=(${var.Max.X},${var.Max.Y},${var.Max.Z}) Valid=${var.IsValid}" FBox')
    -- TArray<T>: regex match, show element count + capacity. For element
    -- VALUES the user can expand the Variables panel — lldb already does
    -- per-element child rendering, so we only need to add a useful summary
    -- on the parent. -x is regex match, ^TArray<.+>$ catches all instantiations.
    table.insert(cmds,
      'type summary add -w UEFallback -x "^TArray<.+>$" --summary-string "size=${var.ArrayNum} cap=${var.ArrayMax}"')
    -- TWeakObjectPtr<T>: show whether it's pointing at anything (ObjectIndex==-1
    -- means null). Layout: { ObjectIndex, ObjectSerialNumber }.
    table.insert(cmds,
      'type summary add -w UEFallback -x "^TWeakObjectPtr<.+>$" --summary-string "idx=${var.ObjectIndex} serial=${var.ObjectSerialNumber}"')
    -- TSharedPtr / TSharedRef: show ref count. Layout: { Object, SharedReferenceCount }
    -- where SharedReferenceCount is { ReferenceController* } pointing at a
    -- struct with SharedReferenceCount/WeakReferenceCount. We can only
    -- safely show the inner pointer.
    table.insert(cmds,
      'type summary add -w UEFallback -x "^TSharedPtr<.+>$" --summary-string "obj=${var.Object}"')
    table.insert(cmds,
      'type summary add -w UEFallback -x "^TSharedRef<.+>$" --summary-string "obj=${var.Object}"')
    table.insert(cmds, 'type category enable UEFallback')
    vim.schedule(function()
      vim.notify(
        "[ue.dap] lldb-dap has no Python module — using native UE summary fallback.\n" ..
        "Covered: FString, FVector*, FRotator, FQuat, FColor*, FBox, TArray, TWeakObjectPtr, TSharedPtr/Ref.\n" ..
        "FName / UObject->GetName() still require Python bindings or :UEDAPWatchFName command.",
        vim.log.levels.INFO)
    end)
  end
  return cmds
end

-- Commands batched inside the `attach` request. Order matters:
--   1. platform select remote-android       → switches lldb to talk Android
--   2. platform connect connect://[serial]:port  → opens the wire
--   3. process attach --pid N                → ptraces the target
--   4. process handle SIG*  --notify FALSE   → suppress per-signal DAP
--      stopped events on stdout. The pass/stop disposition still matters
--      for inferior correctness — see the SIGSEGV/SIGBUS note below.
--
-- Signal disposition for Android ART/JIT:
--   SIGSEGV / SIGBUS — `--pass TRUE` is mandatory. Android ART uses
--   userspace SIGSEGV (and SIGBUS) handlers as part of its normal
--   operation:
--     * Read barriers in JIT-compiled code (MessageQueue.nextLegacy
--       and friends): a load on a page mprotect'd to PROT_NONE
--       triggers SIGSEGV, ART's handler rewrites the reference, retry.
--     * Concurrent compacting GC uses the same mechanism to redirect
--       loads to moved objects.
--     * GC card table / heap poisoning uses SIGBUS the same way.
--   If lldb intercepts these and DROPS them (`--pass false`), ART's
--   handler never runs → the faulting thread spins on the same
--   instruction forever and the whole process appears hung. We verified
--   this by attaching bare `lldb` to the running game: with `--pass
--   false` many Java handler threads stop at JIT(MessageQueue.nextLegacy
--   + 760), and `process continue` cannot make progress.
--   With `--pass true`, lldb forwards the signal to inferior, ART's
--   sigsegv handler runs, the page is unprotected, and the thread
--   continues. We still keep `--stop false` so lldb does not surface
--   these as user-visible stops (they happen continuously during normal
--   execution and would flood the UI).
--
--   SIGPIPE — `--pass false` is fine; ART does not rely on it and the
--   game has its own SIGPIPE policy (typically ignored).
--
-- See skill lldb-dap-22-platform-mode-breakpoint-crash for the
-- per-signal stdout flooding story (`--notify false`) and
-- probe_bp_v13.py for the original contract test.
-- Commands batched inside the `attach` request. This is the K30 WORKING
-- platform-mode flow (real-device verified 5/21 e51cbe6 + 2026-06-03):
--   1. platform select remote-android
--   2. platform connect connect://[<serial>]:<port>   ← serial form ONLY (K30/K32)
--   3. process attach --pid N
--   4. process handle SIG* ...                         ← K3 signal disposition
--   5. target modules load --file libUE4.so --slide 0x<base>  ← K2/K11 ASLR rebase
--
-- WHY serial-form URL: lldb treats a non-localhost hostname as the device
-- serial (PlatformAndroidRemoteGDBServer::ConnectRemote `m_device_id =
-- hostname`), then auto adb-forwards and qLaunchGDBServer-spawns the per-target
-- gdbserver itself. `connect://localhost:N` instead hits the getopt-permute bug
-- that empties the URL → `Invalid URL` (K32). NEVER use localhost form here.
--
-- Signal disposition (K3 — non-negotiable): ART uses SIGSEGV/SIGBUS as
-- intentional userspace traps (JIT read barriers, compacting GC card-table
-- protect/unprotect, heap poisoning). They MUST be `--pass true` so the kernel
-- actually delivers the signal to the inferior and ART's handler runs; with
-- `--pass false` lldb swallows the signal, ART's handler never runs, the
-- faulting thread spins on the same instruction forever, and the whole app
-- appears hung after `process continue` / F5. (The 5/21 e51cbe6 config used
-- `--pass false` and *looked* fine only because it reached `threads` BEFORE any
-- continue — the hang only manifests on resume. K3 is the later, real-device,
-- post-continue lesson and overrides that.) `--stop false` keeps these benign
-- internal traps invisible to the DAP client; `--notify false` suppresses the
-- per-signal DAP stopped-event stdout flood that crashes the adapter on Windows.
local function attach_commands(session)
  local cmds = {}
  -- CRITICAL (K34): create the target from the SYMBOL-RICH host libUE4.so FIRST.
  -- This is the source of DWARF. Without it, platform attach only has the
  -- device's stripped libUE4.so (`symbolStatus: Symbols not found`) and every
  -- file:line breakpoint resolves to `no locations (pending)` → verified=false
  -- → `R`, and the app runs straight through. Verified by bp_truth.txt (5/22):
  -- with `target create <symbol so>` the bp resolved to
  -- `libUE4.so`FMobileSceneRenderer::Render + 124 ... resolved`; the later
  -- post-attach `target symbols add` / `target modules add` experiments
  -- (sym_add/img_add/load_at_addr.txt) ALL failed (`no modules found` / still
  -- pending). The symbol module MUST exist before attach so gdb-remote/platform
  -- relocates it. (docs/CONSTRAINTS.md K34.)
  if session and session.symbol_lib and session.symbol_lib ~= "" then
    cmds[#cmds + 1] = string.format('target create "%s"', session.symbol_lib)
  end
  vim.list_extend(cmds, {
    "platform select remote-android",
    string.format("platform connect connect://[%s]:%d", session.serial, session.port),
    string.format("process attach --pid %d", session.pid),
    "process handle SIGSEGV --notify false --pass true  --stop false",
    "process handle SIGBUS  --notify false --pass true  --stop false",
    "process handle SIGPIPE --notify false --pass false --stop false",
  })
  -- ASLR rebase (belt-and-suspenders): explicitly relocate the symbol module
  -- to the device load base. NOTE: 5/22 bp_truth.txt resolved breakpoints
  -- WITHOUT a manual slide — `target create` + gdb-remote/platform attach
  -- auto-relocates the module. This explicit `target modules load --slide` is
  -- redundant-but-harmless (idempotent if the base matches). If it ever causes
  -- a "multiple modules match" error (seen in load_at_addr.txt when a stray
  -- stripped copy also loaded), drop it and rely on auto-relocation.
  --
  -- D5 verification hook: set UE_DAP_NO_SLIDE=1 to skip the explicit slide so a
  -- real-device run can confirm `breakpoint list resolved=1` + hit WITHOUT it
  -- (the precondition for permanently removing this plumbing).
  if session and session._module_rebase_cmd and session._module_rebase_cmd ~= ""
    and (vim.env.UE_DAP_NO_SLIDE or "") == "" then
    cmds[#cmds + 1] = session._module_rebase_cmd
  end
  return cmds
end

-- postRunCommands run between attach completion and `configurationDone`.
-- Per lldb-dap 22 source (AttachRequestHandler.cpp L138-145):
--   1. WaitForProcessToStop (process must end up stopped)
--   2. RunPostRunCommands  ← us
--   3. (later) ConfigurationDoneRequestHandler L36-37 verifies process
--      is STILL in a stopped state, else throws:
--      "Expected process to be stopped. Process is in an unexpected
--       state and may have missed an initial configuration."
--
-- Therefore postRunCommands MUST NOT resume the inferior. `process
-- continue` here triggers the exact error above. Keep this empty (or
-- limited to read-only / settings-tweaking commands). The actual resume
-- postRunCommands run between attach completion and `configurationDone`.
-- They run AFTER the target is attached + stopped and AFTER attachCommands
-- (incl. the ASLR rebase), but BEFORE nvim-dap's setBreakpoints. We MUST NOT
-- resume here. We DO use them to dump breakpoint-diagnosis state to a host file
-- via `command script` is unavailable (nopython host), so instead we emit the
-- info into the lldb-dap console which the protocol log captures; additionally
-- we write a focused report by running `image lookup` for the configured
-- probe file and logging `breakpoint list` — all non-mutating / non-resuming.
--
-- The diagnosis lines land in stdpath('cache')/ue-dap-bp-diag.log written by
-- the on-console listener in lua/ue/dap.lua (D._dap_bp_diag_*). Here we just
-- issue the read-only probe commands so that listener has something to capture.
local function post_run_commands(session)
  local cmds = {}
  -- Breakpoint diagnosis (K33). These do NOT resume the inferior.
  -- `image list libUE4.so` → confirms module loaded + ASLR base.
  -- `image lookup` + `breakpoint list` shows whether symbols and preseeded
  -- breakpoints resolve without planting an extra diagnostic breakpoint.
  local probe_file = session and session._bp_probe_file or nil
  local probe_line = session and session._bp_probe_line or nil
  cmds[#cmds + 1] = "image list libUE4.so"
  cmds[#cmds + 1] = "image lookup --name FEngineLoop::Tick"  -- cheap symbol/DWARF presence probe
  if probe_file and probe_line then
    cmds[#cmds + 1] = string.format('image lookup --file "%s" --line %d', probe_file, probe_line)
  end
  cmds[#cmds + 1] = "breakpoint list"
  return cmds
end

-- Build the lldb-dap DAP config for the current session.
--
-- lldb-dap uses the DAP `attach` request with custom `attachCommands` for
-- non-trivial attach flows. Android uses the K30 platform route here:
-- platform select remote-android -> platform connect connect://[serial]:port
-- -> process attach --pid. nvim-dap just hands the command list to lldb-dap
-- which executes it in order.

local function current_breakpoint_commands()
  local ok_bps, bps_mod = pcall(require, "dap.breakpoints")
  if not ok_bps or not bps_mod or type(bps_mod.get) ~= "function" then return {} end
  local all = bps_mod.get()
  if type(all) ~= "table" then return {} end
  local cmds = {}
  local seen = {}
  local function path_from_key(key)
    if type(key) == "string" then return key end
    if type(key) == "number" and vim.api.nvim_buf_is_valid(key) then
      return vim.api.nvim_buf_get_name(key)
    end
    return nil
  end
  local function add_cmd(path, line)
    line = tonumber(line)
    if type(path) ~= "string" or path == "" or not line or line < 1 then return end
    local file = vim.fs.basename(path)
    if not file or file == "" then return end
    local cmd = string.format('?breakpoint set -f "%s" -l %d', file, line)
    if seen[cmd] then return end
    seen[cmd] = true
    cmds[#cmds + 1] = cmd
  end
  for key, list in pairs(all) do
    local path = path_from_key(key)
    if path and type(list) == "table" then
      for _, bp in ipairs(list) do
        add_cmd(path, bp.line)
      end
    end
  end
  table.sort(cmds)
  return cmds
end

local function preseed_breakpoints_into_attach_commands(cfg)
  if not cfg or type(cfg.attachCommands) ~= "table" then return end
  local cmds = current_breakpoint_commands()
  if #cmds == 0 then return end
  local insert_at = #cfg.attachCommands + 1
  for i, cmd in ipairs(cfg.attachCommands) do
    -- Breakpoints must be inserted after the target is attached and after
    -- signal disposition. If an ASLR rebase command is present, continue
    -- scanning so file:line breakpoints are inserted after the rebase.
    if tostring(cmd):find("process handle SIGPIPE", 1, true) then
      insert_at = i + 1
      -- keep scanning: if an ASLR rebase command follows, breakpoints MUST be
      -- inserted AFTER it so file:line resolves against the relocated module.
    end
    if tostring(cmd):find("target modules load", 1, true) then
      insert_at = i + 1
      break
    end
  end
  for i = #cmds, 1, -1 do
    table.insert(cfg.attachCommands, insert_at, cmds[i])
  end
  table.insert(cfg.attachCommands, insert_at + #cmds, "breakpoint list")
end

local function lldb_dap_attach_config(session, source_map)
  local cfg = {
    name           = "UE Android Attach (lldb-dap)",
    type           = "lldb",  -- matches dap.adapters.lldb wired by _common.ensure_adapter
    request        = "attach",
    -- stopOnEntry=true required by lldb-dap 22 attach protocol: lldb-dap
    -- needs the inferior PAUSED while it processes `configurationDone`
    -- (breakpoints, exception filters, etc.). With stopOnEntry=false,
    -- lldb-dap auto-resumes the process before configurationDone arrives
    -- and errors out: "Expected process to be stopped. Process is in an
    -- unexpected state and may have missed an initial configuration."
    --
    -- nvim-dap consumes the lldb-dap 22 per-thread entry-stop burst with
    -- auto_continue_if_many_stopped=false and waits. The user resumes with
    -- F5 / :DapContinue after breakpoints and exception filters are armed.
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
    postRunCommands = post_run_commands(session),
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
  local sess_active = ok_dap and dap and dap.session and dap.session() or nil

  -- Two-phase teardown to avoid leaking a ptrace lock on the inferior:
  --   1. Send DAP `disconnect terminateDebuggee=false` and WAIT for the
  --      response. lldb-dap forwards this to the on-device gdbserver
  --      child which calls `PT_DETACH` (kernel-side ptrace release)
  --      before its own socket close. If we kill lldb-server here
  --      before the response round-trips, the gdbserver child dies
  --      with the ptrace lock still held → inferior left in state `T`
  --      (orphan SIGSTOP, TracerPid=0) and unrecoverable except by
  --      `kill -9` on the game.
  --   2. Only AFTER the disconnect ACK (or a short timeout) tear down
  --      the device-side processes + adb forward.
  --
  -- The callback approach: dap.session():request(cmd, args, cb) invokes
  -- cb(err, body) when the response arrives. We schedule the device
  -- cleanup from the callback. Belt-and-braces: a 1.5s safety timer
  -- runs cleanup even if the response never comes (dead adapter, etc.)
  -- to guarantee idempotent behavior of repeated :UEDAPStop calls.
  local cleanup_done = false
  local function finalize()
    if cleanup_done then return end
    cleanup_done = true
    M._cleanup_device_side()
    result.adapter_killed = true
    reset_session()
  end

  if sess_active then
    local ok_req = pcall(function()
      sess_active:request("disconnect", { terminateDebuggee = false }, function(_err, _body)
        -- lldb-dap may close stdio before the callback fires (it
        -- does the response then exits in the same tick); pcall the
        -- finalize to swallow any nvim-dap internal error.
        vim.schedule(function() pcall(finalize) end)
      end)
    end)
    if ok_req then
      result.disconnected = true
    else
      -- request() itself blew up (very rare — adapter already gone).
      -- Just clean up synchronously.
      finalize()
      return result
    end
    -- Safety timer: if lldb-dap never replies (it's already dead),
    -- finalize anyway so the user can retry attach immediately.
    vim.defer_fn(function() pcall(finalize) end, 1500)
  else
    -- No active session — just cleanup device side and exit.
    finalize()
  end

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
  -- Stop the host-side `adb shell run-as ... lldb-server gdbserver` job we
  -- spawned via jobstart. Killing the adb client closes the shell, which the
  -- device propagates to lldb-server.
  if M._lldb_server_jobid and M._lldb_server_jobid > 0 then
    pcall(vim.fn.jobstop, M._lldb_server_jobid)
    M._lldb_server_jobid = nil
  end
  if sess and sess.serial and sess.adb then
    if sess.package_name then
      pcall(adb_run, sess.adb, { "-s", sess.serial, "shell",
        "run-as " .. sess.package_name .. " sh -c " .. shell_quote("killall lldb-server 2>/dev/null || true") })
    end
    pcall(adb_run, sess.adb, { "-s", sess.serial, "shell",
      "killall lldb-server 2>/dev/null; true" })
    pcall(adb_run, sess.adb, { "-s", sess.serial, "forward",
      "--remove", "tcp:" .. (sess.port or 5039) })
    -- If the target was left in a plain SIGSTOP state after a broken detach,
    -- only the app uid can signal it on production Android builds.
    if sess.pid and sess.package_name then
      pcall(adb_run, sess.adb, { "-s", sess.serial, "shell",
        "run-as", sess.package_name, "kill", "-CONT", tostring(sess.pid) })
    elseif sess.pid then
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
  local ctx = opts.context or {}
  -- Programmatic/headless retries should not block forever on vim.fn.input()
  -- for values that are stable for this workspace and already known.
  -- Priority: explicit context/opts -> last successful session -> workspace default.
  ctx.android_package = ctx.android_package or opts.package_name or opts.package
    or (M._last_session and M._last_session.package_name)
  -- When none of the above sources provides a package name, leave it nil
  -- so pick_package() falls through to persisted state → project discovery
  -- → config → user prompt, instead of treating a placeholder as a real
  -- Android package name.
  ctx.android_serial = ctx.android_serial or opts.serial or opts.android_serial
    or (M._last_session and M._last_session.serial)
  -- NOTE: do NOT hardcode a symbol_lib fallback here. A literal path short-
  -- circuits pick_symbol_lib() (its step 0 returns any existing ctx path
  -- verbatim, skipping the packageInfo.txt versionCode exact-match step), so a
  -- stale build-id lib would attach and resolve breakpoints to the WRONG source
  -- revision (the 3.4 `ad3d4e7c…` false-lead in docs/CONSTRAINTS.md / handoff).
  -- Leave it nil when no explicit/last-session source is known so pick_symbol_lib
  -- falls through to: ue.config.dap.android_symbol_lib → packageInfo versionCode
  -- exact match → newest-by-mtime glob → prompt. Mirrors the pick_package nil
  -- fallthrough (commit 361b9e7).
  ctx.android_symbol_lib = ctx.android_symbol_lib or ctx.symbol_lib or opts.symbol_lib
    or opts.android_symbol_lib or (M._last_session and M._last_session.symbol_lib)
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
    local ok_push, push_msg = ensure_lldb_server_pushed(sess.adb, serial, sess.package_name, server_src)
    if not ok_push then
      P.error("lldb-server bootstrap failed: " .. tostring(push_msg))
      log.notify_error("dap.android", "lldb-server bootstrap failed: " .. push_msg)
      on_ready(false); return
    end
    sess.remote_lldb_server = push_msg
    sess.lldb_server_mode = "platform"

    on_ready(true)
  end

  if sess.serial then
    after_serial(sess.serial)
  else
    pick_serial_async(sess.adb, after_serial)
  end
end

-- Common tail of attach/launch: spin up lldb-server gdbserver, then hand the
-- lldb-dap config to nvim-dap. Mutates sess (records pid).
local function _finalize_session(sess, pid, cfg_name, run_label)
  local P = require("ue.dap._progress")
  sess.pid = pid
  sess.lldb_server_mode = "platform"

  P.step(("starting lldb-server platform (port=%d) …"):format(sess.port))
  local ok_srv, srv_err = start_lldb_server_platform(sess.adb, sess.serial, sess.port)
  if not ok_srv then
    P.error("lldb-server platform failed: " .. tostring(srv_err))
    log.notify_error("dap.android", "lldb-server platform failed: " .. tostring(srv_err))
    M.stop_android_debugger()
    return
  end

  P.step("attaching …")

  -- Compute the libUE4.so ASLR rebase command BEFORE building the attach config
  -- (attach_commands appends it). Failure is non-fatal: log + continue so a
  -- maps-read hiccup never blocks attach. The actual `target modules load
  -- --slide` runs inside attachCommands, right after signal disposition.
  sess._module_rebase_cmd = nil
  if sess.symbol_lib and sess.symbol_lib ~= "" then
    local rebase_cmd, base_hex = module_rebase_command(
      sess.adb, sess.serial, sess.package_name, pid, sess.symbol_lib)
    if rebase_cmd then
      sess._module_rebase_cmd = rebase_cmd
      P.step(("module base resolved: %s @ 0x%s"):format(
        vim.fs.basename(sess.symbol_lib), base_hex))
    else
      log.notify("dap.android",
        "ASLR base unresolved for " .. vim.fs.basename(sess.symbol_lib)
        .. "; breakpoints may not resolve (continuing attach)",
        vim.log.levels.WARN)
    end
  end

  local cfg = lldb_dap_attach_config(sess, sess.source_map)
  cfg.name = cfg_name
  -- K33 diagnosis: pick the first current nvim breakpoint as the post-attach
  -- probe so post_run_commands logs `image lookup` + `breakpoint list` to
  -- stdpath('cache')/ue-dap-bp-diag.log. Non-mutating, does not resume.
  do
    local ok_c, cur = pcall(current_breakpoint_commands)
    if ok_c and type(cur) == "table" and #cur > 0 then
      local first = tostring(cur[1]):gsub("^%?", "")
      local f, l = first:match('breakpoint set %-f "([^"]+)" %-l (%d+)')
      if f and l then sess._bp_probe_file = f; sess._bp_probe_line = tonumber(l) end
    end
  end
  -- Preseed file:line breakpoints as attachCommands, inserted AFTER the ASLR
  -- `target modules load --slide` so they resolve against the relocated module.
  -- NOTE (K33): source-file `breakpoint set -f` has been observed to crash
  -- lldb-dap 22.1.6 (3221226505) on prior Android routes; under the current
  -- K30 platform route this needs real-device re-verification. If it crashes,
  -- switch to address breakpoints (image lookup --line -> breakpoint set
  -- --address) only with semantic-equivalence proof.
  preseed_breakpoints_into_attach_commands(cfg)
  -- post_run_commands needs the probe fields, so rebuild it now that they're set.
  cfg.postRunCommands = post_run_commands(sess)
  do
    local lines = {
      "== UE Android DAP attach breakpoint audit ==",
      ("serial=%s pid=%s port=%s package=%s"):format(
        tostring(sess.serial), tostring(sess.pid), tostring(sess.port), tostring(sess.package_name)),
      "symbol_lib=" .. tostring(sess.symbol_lib),
      "module_rebase_cmd=" .. tostring(sess._module_rebase_cmd),
      "-- attachCommands --",
    }
    for i, cmd in ipairs(cfg.attachCommands or {}) do
      lines[#lines + 1] = ("%02d %s"):format(i, tostring(cmd))
    end
    lines[#lines + 1] = "-- postRunCommands --"
    for i, cmd in ipairs(cfg.postRunCommands or {}) do
      lines[#lines + 1] = ("%02d %s"):format(i, tostring(cmd))
    end
    append_bp_diag(lines)
  end
  C.run(cfg, run_label)
  -- Progress popup finalized by ue.dap.lua's event_initialized listener
  -- (P.done) or by stop_android_debugger / on_session_end (P.hide).
  -- If the adapter exits before nvim-dap installs/keeps a session (observed
  -- with a broken device-side attach), the normal
  -- session-end listeners may not get a chance to clear our bootstrap flag.
  -- Release the mutex after a short grace window when there is no live DAP
  -- session, so the next <space>da is a real retry instead of a stale-block.
  vim.defer_fn(function()
    if not M._attach_in_progress then return end
    local ok_dap, dap = pcall(require, "dap")
    local has_session = ok_dap and dap and dap.session and dap.session() or nil
    if not has_session then
      M._attach_in_progress = false
      pcall(function() require("ue.dap._progress").hide() end)
    end
  end, 10000)
end

function M.attach(opts)
  opts = opts or {}
  -- A previous attach can fail before nvim-dap creates a session while still
  -- leaving the bootstrap flag set (for example lldb-dap dies after
  -- `process attach --pid` reports `lost connection`). In that state a second
  -- <space>da should be able to retry instead of being blocked forever by our
  -- own stale mutex. Keep the mutex only while a real dap session exists.
  if M._attach_in_progress then
    local ok_dap, dap = pcall(require, "dap")
    local has_session = ok_dap and dap and dap.session and dap.session() or nil
    -- Keep the mutex only for a real live DAP session. A stale/failed early
    -- bootstrap can leave a half-filled M._session (for example only adb/port,
    -- or a serial but no DAP session); a second <space>da should retry.
    if has_session then
      vim.notify("[ue.dap.android] attach already in progress — wait for it to finish or :UEDAPStop",
        vim.log.levels.WARN)
      return
    end
    M._attach_in_progress = false
  end
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap and dap.session and dap.session() then
    vim.notify("[ue.dap.android] DAP session already active — :UEDAPStop first, or :UEDAPReattach",
      vim.log.levels.WARN)
    return
  end
  -- Clear stale notifier popups from a previous session so this attach's
  -- diagnostics aren't drowned in old warnings that have already been
  -- fixed. snacks.notifier accumulates active toasts forever by default
  -- (history is the dict behind get_history); without this the user sees
  -- the same popup wall on every attach and can't tell whether errors are
  -- current or historical. We hide each toast by id (the only public API)
  -- rather than mutating the internal history dict.
  pcall(function()
    local snacks = require("snacks")
    if not (snacks and snacks.notifier and snacks.notifier.get_history) then return end
    local hist = snacks.notifier.get_history()
    for _, item in ipairs(hist) do
      if item.id then pcall(snacks.notifier.hide, item.id) end
    end
  end)
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
  sess.remote_lldb_server = last.remote_lldb_server
  sess.lldb_server_mode  = last.lldb_server_mode
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
    sess.adb, sess.serial, sess.package_name, sess.lldb_server_local)
  if not ok_push then
    P.error("lldb-server re-stage failed: " .. tostring(push_msg))
    M._attach_in_progress = false
    return
  end
  sess.remote_lldb_server = push_msg
  sess.lldb_server_mode = "platform"

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
    ("  server mode : %s"):format(s.lldb_server_mode or "-"),
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

function M._current_breakpoint_commands_for_test()
  return current_breakpoint_commands()
end

function M._preseed_breakpoints_into_attach_commands_for_test(cfg)
  return preseed_breakpoints_into_attach_commands(cfg)
end

function M._pick_package_for_test(ctx)
  return pick_package(ctx)
end

function M._pick_symbol_lib_for_test(ctx)
  return pick_symbol_lib(ctx)
end

function M._pick_source_map_for_test(ctx)
  return pick_source_map(ctx)
end

function M._effective_project_root_for_test(ctx)
  return effective_project_root(ctx)
end

return M
