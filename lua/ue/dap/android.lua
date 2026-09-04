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
--     Binaries/Android/<Target>_Symbols_v* tree or the Intermediate jni
--     output. Pointed to by ue.config dap.android_symbol_lib OR auto-
--     detected from the project root. Strictly optional but strongly
--     recommended: without it lldb-dap will pull stripped libUE4.so from
--     the device into ~/.lldb/module_cache (no source lines).
--   * Optional: source-map entries (DAP "sourceMap") so DWARF build-machine
--     paths (e.g. D:\UE\EngineWorktree\Engine\) resolve to the local checkout.

local C              = require("ue.dap._common")
local fs             = require("ue.core.fs")
local log            = require("utils.log")
local android_device = require("utils.android_device")

local M = {}

local UE_MODULE_BASENAME = "libUE4.so"

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
  wait_mode         = nil,  -- true when launched via wait-for-debugger (set-debug-app -w)
  jdwp_port         = nil,  -- host forward port used by the jdb gate-release
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
  -- K59: `pid` is set only by _finalize_session, i.e. only after an attach
  -- actually reached the device. Without this guard a FAILED attach (pkg/serial/
  -- symbol_lib already picked, pid probe missed) still ran through
  -- stop_android_debugger() → snapshot, poisoning _last_session with a package
  -- that does not exist on the device and making :UEDAPReattach replay it.
  if not (s.package_name and s.serial and s.symbol_lib and s.pid) then return end
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
-- UE's Android packaging writes <Project>/Binaries/Android/packageInfo.txt
-- on every cook. Layout:
--   line 1: package name      (e.g. com.example.mygame)
--   line 2: versionCode       (e.g. 169723198) — matches <Target>_Symbols_v<code>/
--   line 3: versionName
--
-- This is the single source of truth for both pick_package and pick_symbol_lib,
-- so we never have to prompt the user when a cooked APK exists on disk. Falls
-- through to ctx/cfg/input only when there is no cooked output.

local function android_marker_path(root, uproject)
  if type(root) ~= "string" or root == "" then return nil end
  root = fs.norm(root)

  local function output_dir(project_dir)
    if type(project_dir) ~= "string" or project_dir == "" then return nil end
    local candidate = fs.norm(project_dir) .. "/Binaries/Android"
    if fs.is_file(candidate .. "/packageInfo.txt") or fs.is_dir(candidate) then
      return candidate
    end
    return nil
  end

  -- An explicit .uproject is authoritative when context carries one.
  if type(uproject) == "string" and uproject ~= "" then
    local explicit = output_dir(vim.fn.fnamemodify(fs.norm(uproject), ":h"))
    if explicit then return explicit end
  end

  local direct = output_dir(root)
  if direct then return direct end

  -- Repository-root layout: <repo>/Source/<Project>/<Project>.uproject.
  -- Accept only one cooked nested project; multiple matches are ambiguous and
  -- must be resolved by the explicit ctx.uproject path instead of guessing.
  local source_dir = root .. "/Source"
  if not fs.is_dir(source_dir) then return nil end
  local nested = {}
  for name, kind in vim.fs.dir(source_dir) do
    if kind == "directory" then
      local project_dir = source_dir .. "/" .. name
      local has_uproject = false
      for child, child_kind in vim.fs.dir(project_dir) do
        if child_kind == "file" and child:lower():match("%.uproject$") then
          has_uproject = true
          break
        end
      end
      if has_uproject then
        local candidate = output_dir(project_dir)
        if candidate then nested[#nested + 1] = candidate end
      end
    end
  end
  table.sort(nested)
  return #nested == 1 and nested[1] or nil
end

local function read_package_info(proot, uproject)
  local android_dir = android_marker_path(proot, uproject)
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
-- both repo-root layout (<repo>/Source/<Project>/Binaries/Android) and the
-- common UE project-root layout (<project>/Binaries/Android).
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
    -- project root: otherwise an engine buffer can resolve an unrelated
    -- nested game project and prompt unnecessarily.
    local from_engine = ctx.engine_root and discover_project_root(ctx.engine_root) or nil
    add(from_engine)
  end
  add(ue_cfg_get("project_root"))
  add(ue_cfg_get("dap.project_root"))
  local bufname = vim.api.nvim_buf_get_name(0)
  if bufname and bufname ~= "" then add(discover_project_root(bufname)) end
  add(discover_project_root(vim.fn.getcwd()))

  for _, root in ipairs(roots) do
    if android_marker_path(root, ctx and ctx.uproject or nil) then return root end
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
  local info = read_package_info(proot, ctx and ctx.uproject or nil)
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
    local android_dir = android_marker_path(proot, ctx and ctx.uproject or nil)
    -- 2. Exact match against packageInfo.txt versionCode — guarantees the
    --    symbols correspond to the installed APK.
    local info = read_package_info(proot, ctx and ctx.uproject or nil)
    if android_dir and info and info.version_code ~= "" then
      local suffix = "_Symbols_v" .. info.version_code
      local exact = {}
      for name, kind in vim.fs.dir(android_dir) do
        if kind == "directory" and #name >= #suffix
            and name:sub(-#suffix) == suffix then
          local package_dir = android_dir .. "/" .. name
          for arch_name, arch_kind in vim.fs.dir(package_dir) do
            if arch_kind == "directory" and arch_name:lower():match("%-arm64$") then
              local arch_dir = package_dir .. "/" .. arch_name
              local preferred = arch_dir .. "/libUE4.so"
              local fallback = arch_dir .. "/libUnreal.so"
              if fs.is_file(preferred) then
                exact[#exact + 1] = preferred
              elseif fs.is_file(fallback) then
                exact[#exact + 1] = fallback
              end
            end
          end
        end
      end
      table.sort(exact)
      if #exact == 1 then return exact[1] end
    end
    -- 3. Scan all symbol packages, pick the newest by mtime (best guess
    --    when no packageInfo or no exact match). Use fs.dir for the immediate
    --    package directories: vim.fn.glob wildcard expansion is unreliable
    --    for Windows short (8.3) temp paths, including headless tests.
    local discovered = {}
    if android_dir and fs.is_dir(android_dir) then
      for name, kind in vim.fs.dir(android_dir) do
        if kind == "directory" and name:find("Symbols", 1, true) then
          local package_dir = android_dir .. "/" .. name
          for arch_name, arch_kind in vim.fs.dir(package_dir) do
            if arch_kind == "directory" and arch_name:lower():match("%-arm64$") then
              local arch_dir = package_dir .. "/" .. arch_name
              local preferred = arch_dir .. "/libUE4.so"
              local fallback = arch_dir .. "/libUnreal.so"
              if fs.is_file(preferred) then
                discovered[#discovered + 1] = preferred
              elseif fs.is_file(fallback) then
                discovered[#discovered + 1] = fallback
              end
            end
          end
        end
      end
    end
    local project_dir = android_dir and fs.norm(vim.fn.fnamemodify(android_dir, ":h:h")) or proot
    local glob_patterns = {
      project_dir .. "/Intermediate/Android/arm64/jni/arm64-v8a/libUE4.so",
      project_dir .. "/Intermediate/Android/arm64/jni/arm64-v8a/libUnreal.so",
    }
    local best_path, best_mtime = nil, -1
    for _, path in ipairs(discovered) do
      if fs.is_file(path) then
        local st = vim.uv and vim.uv.fs_stat(path)
        local mt = (st and st.mtime and st.mtime.sec) or 0
        if mt > best_mtime then best_path, best_mtime = path, mt end
      end
    end
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

local function alloc_free_port()
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
  return nil
end

local function pick_port()
  local cfg_port = ue_cfg_get("dap.android_port")
  if type(cfg_port) == "number" and cfg_port > 0 then return cfg_port end
  return alloc_free_port() or 5045
end

local function pick_source_map(ctx)
  -- ue.config.dap.android_source_map = { { from, to }, ... }
  local cfg_sm = ue_cfg_get("dap.android_source_map")
  if type(cfg_sm) == "table" and #cfg_sm > 0 then return cfg_sm end
  -- DWARF on UE Android builds may bake the build-machine root into
  -- DW_AT_comp_dir. Configure dap.android_build_root when that root differs
  -- from the selected project root.
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
    or proot)
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
    local path = vim.fn.stdpath("cache") .. ("/ue-dap-bp-diag.%d.log"):format(vim.fn.getpid())
    local fh = io.open(path, "a")
    if not fh then return end
    for _, line in ipairs(lines) do
      fh:write(tostring(line), "\n")
    end
    fh:close()
  end)
end


-- Device discovery/selection is shared with install, launch, and logcat.
-- It always presents model/name + serial, even when only one device is ready,
-- and persists the user's choice in vim.g.ue_android_device_serial.
local function pick_serial_async(adb, done)
  android_device.select({
    adb = adb,
    prompt = "Select Android device for DAP attach:",
  }, function(serial)
    done(serial)
  end)
end

local function resolve_session_serial(ctx, opts)
  ctx = ctx or {}
  opts = opts or {}
  return ctx.android_serial or opts.serial or opts.android_serial
    or android_device.get()
end

-- K59: package resolution for a normal attach/launch. Explicit callers win;
-- everything else stays nil so pick_package() can consult PERSISTED state
-- (which `:UESetAndroidPackage` rewrites). Deliberately NOT sourced from
-- M._last_session — see the comment in bootstrap_session.
local function resolve_session_package(ctx, opts)
  ctx = ctx or {}
  opts = opts or {}
  return ctx.android_package or opts.package_name or opts.package
end

local function pidof(adb, serial, pkg)
  local out = adb_run(adb, { "-s", serial, "shell", "pidof", "-s", pkg })
  local digits = (out or ""):match("(%d+)")
  return digits and tonumber(digits) or nil
end

-- Async pid poll (F4, health-check 2026-07): the old launch/reattach paths
-- looped `pidof + vim.wait(200)` up to 50 times — a half-blocking wait
-- (fast events run, but user input freezes for up to 10s while each
-- synchronous adb round-trip stacks on top). Same fix pattern as K40:
-- uv timer + vim.system, `in_flight` against overlap, done() on main loop.
-- done(pid|nil) fires exactly once — pid found, or nil after timeout_ms.
local function pidof_async(adb, serial, pkg, timeout_ms, done)
  local timer = vim.uv.new_timer()
  if not timer then
    -- Degenerate fallback: single synchronous probe.
    done(pidof(adb, serial, pkg))
    return
  end
  local deadline = vim.uv.now() + (timeout_ms or 10000)
  local in_flight, finished = false, false
  local function finish(pid)
    if finished then return end
    finished = true
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    done(pid)
  end
  timer:start(0, 200, function()
    -- FAST EVENT CONTEXT: spawn only; results handled on the main loop.
    if finished or in_flight then return end
    if vim.uv.now() >= deadline then
      vim.schedule(function() finish(nil) end)
      return
    end
    in_flight = true
    local ok_spawn = pcall(vim.system,
      { adb, "-s", serial, "shell", "pidof", "-s", pkg },
      { text = true },
      function(res)
        vim.schedule(function()
          in_flight = false
          if finished then return end
          local digits = res and res.code == 0 and (res.stdout or ""):match("(%d+)") or nil
          if digits then finish(tonumber(digits)) end
        end)
      end)
    if not ok_spawn then in_flight = false end
  end)
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
-- ANDROID-SERIAL-A; plain `adb shell cat` fails under hidepid on Android 10+).
--
-- CRITICAL: the returned value is a STRING built by text extraction, never via
-- string.format("%x", n) — LuaJIT truncates %x to 32 bits and a UE .so base
-- like 0x6c9fe21000 would be mangled (docs/CONSTRAINTS.md K4/P7).
-- Pure parser (unit-tested): find the ASLR load base of `so_basename` in a
-- /proc/<pid>/maps dump. Returns lowercase hex string WITHOUT "0x", or nil.
-- CRITICAL: string extraction only — never string.format("%x", n) on 64-bit
-- values (LuaJIT truncates to 32 bits, docs/CONSTRAINTS.md K4/P7).
local function parse_maps_base_hex(maps, so_basename)
  if type(maps) ~= "string" or maps == "" then return nil end
  if type(so_basename) ~= "string" or so_basename == "" then return nil end
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

local function read_so_base_hex(adb, serial, pkg, pid, so_basename)
  if not (adb and serial and pkg and pid and so_basename) then return nil end
  local maps = adb_run(adb, {
    "-s", serial, "shell", "run-as", pkg, "cat", "/proc/" .. tostring(pid) .. "/maps",
  })
  return parse_maps_base_hex(maps, so_basename)
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

-- Stage lldb-server for an APP-UID platform server (K56). This block documents
-- the whole staging pipeline below (the plan helpers, the script builders, and
-- `ensure_lldb_server_pushed` which drives them).
--
-- Two hops, because `adb push` can only write world-reachable paths and the
-- app sandbox is only reachable through `run-as`:
--   1. adb push  → /data/local/tmp/lldb-server   (PUBLIC transport, shell uid)
--   2. run-as <pkg> sh -c 'cat <public> > /data/data/<pkg>/lldb-server
--                          && chmod 700 …'       (app uid, app sandbox)
-- The platform server is then launched from the sandbox copy AS THE APP UID.
--
-- WHY the app uid and not the shell uid (K56, docs/CONSTRAINTS.md):
-- On this `user` build (`ro.debuggable=0`, no `su`, no Yama ptrace_scope file)
-- the shell user (uid 2000) CANNOT ptrace the app process even though the app
-- is `pkgFlags=[DEBUGGABLE]`. NDK 27 LLDB 18's lldb-server does not surface
-- that denial as an error — its forked per-target gdbserver child SIGSEGVs
-- inside `vAttach`, and the host sees only `error: attach failed: lost
-- connection`. Measured truth table (2026-09-03, 139=SIGSEGV, 124=`timeout`
-- expired i.e. server still alive and serving = success):
--     shell-uid server → shell-owned `sleep`    rc=124  ok
--     shell-uid server → root-owned init (pid 1) rc=139  SEGV
--     shell-uid server → app-owned game         rc=139  SEGV
--     app-uid   server → app-owned game         rc=124  ok
-- A control against a NONEXISTENT pid returns a clean rc=1 "No such process",
-- so the SEGV is specific to permission-denied ptrace, not to bad input.
-- End-to-end A/B on one healthy target (156 threads), same host, same device
-- server build, only the server uid differing:
--     shell-uid  3/3  rc=1  "attach failed: lost connection"  (~1s)
--     app-uid    3/3  rc=0  full 155-thread stop + clean detach (6-7s)
-- Device-server VERSION is NOT the variable (LLDB 9 / 14 / 18 all fail under
-- the shell uid) — do NOT "fix" this by downgrading the pinned NDK 27 LLDB 18
-- (docs/CONSTRAINTS.md C1).
--
-- `ensure_lldb_server_pushed` returns (ok, sandbox_path_or_err).

-- Pure decision helper (unit-tested): given whether the remote copy matches
-- the local binary size and whether it is already executable, decide the
-- staging action.
--   "reuse"  — same size AND executable: nothing to do. Covers the root-owned
--              residue case (a file pushed under an old `adb root` session is
--              root:root; `chmod` from the shell user EPERMs, but the file is
--              already 0755 so chmod is unnecessary — see nvim-debug.log
--              `chmod ... Operation not permitted` 2026-07-24).
--   "chmod"  — same size but not executable: chmod only (no re-push).
--   "repush" — size differs: rm -f the residue first (the /data/local/tmp
--              DIRECTORY is shell-owned, so the shell user can unlink even a
--              root-owned file), then push + chmod.
--
-- SCOPE (K58): this decides only the TRANSPORT hop. "reuse" means "skip the
-- adb push", NOT "the server is ready to run" — the run path is the sandbox
-- copy, decided by sandbox_stage_plan below.
local function lldb_server_stage_plan(size_matches, is_executable)
  if size_matches and is_executable then return "reuse" end
  if size_matches then return "chmod" end
  return "repush"
end

-- Pure decision helper (unit-tested): whether the APP-UID run path — the
-- sandbox copy — can be reused, or must be re-staged from the transport copy.
--
-- K58: only `test -x` UNDER `run-as` counts. The public transport copy is
-- labelled `u:object_r:shell_data_file:s0`, which the app SELinux domain may
-- read but MUST NOT execute, so a shell-side `test -x` on the public path says
-- nothing about whether the app uid can run it. Measured 2026-09-03:
--     app uid, /data/local/tmp/lldb-server  → test -x rc=1,
--       exec → `sh: …: can't execute: Permission denied` (rc=126)
--     app uid, /data/data/<pkg>/lldb-server → test -x rc=0, `lldb-server v` ok
local function sandbox_stage_plan(size_matches, is_executable)
  if size_matches and is_executable then return "reuse" end
  return "restage"
end

-- Pure helper (unit-tested): the in-sandbox path the app-uid platform server
-- runs from. `run-as <pkg>` lands in /data/data/<pkg> (== /data/user/0/<pkg>).
local function sandbox_lldb_server_path(pkg)
  if type(pkg) ~= "string" or pkg == "" then return nil end
  return "/data/data/" .. pkg .. "/lldb-server"
end

-- Pure helper (unit-tested): the device-side `sh -c` body that copies the
-- PUBLIC transport copy into the app sandbox and marks it executable.
-- `cat > dst` (not `cp`) because the app uid may not read /data/local/tmp
-- metadata for `cp -p`, and toybox `cp` across that boundary has historically
-- failed with EACCES on this device class.
local function sandbox_stage_script(public_path, sandbox_path)
  return ("cat %s > %s && chmod 700 %s")
    :format(public_path, sandbox_path, sandbox_path)
end

-- Pure helper (unit-tested): the device-side `sh -c` body that starts the
-- APP-UID platform server from the sandbox copy.
-- The listen wildcard is DOUBLE-QUOTED ("*:N") so the device shell cannot glob
-- it against the sandbox directory contents — `cd`-ing into /data/data/<pkg>
-- first means a bare `*` would expand to the first filename there (K30 note
-- documented the same hazard for the /data/local/tmp form).
local function platform_server_script(sandbox_path, port)
  return ('%s platform --server --listen "*:%d"'):format(sandbox_path, port)
end

local function ensure_lldb_server_pushed(adb, serial, pkg, src)
  local local_size = vim.fn.getfsize(src)
  if local_size <= 0 then
    return false, "lldb-server source not readable: " .. tostring(src)
  end

  local remote = "/data/local/tmp/lldb-server"
  local remote_size = adb_run(adb, { "-s", serial, "shell", "stat", "-c", "%s", remote })
  local size_matches = tostring(remote_size):match("(%d+)%s*$") == tostring(local_size)
  local function remote_is_executable()
    local _, code = adb_run_raw(adb, { "-s", serial, "shell", "test", "-x", remote })
    return code == 0
  end

  local plan = lldb_server_stage_plan(size_matches, size_matches and remote_is_executable())

  -- K58: `reuse` skips only the TRANSPORT push. It MUST NOT return the public
  -- path as the run path — the app uid cannot execute a `shell_data_file`
  -- (SELinux), so `start_lldb_server_platform` would emit
  --   run-as <pkg> sh -c '/data/local/tmp/lldb-server platform --server …'
  -- which dies with `can't execute: Permission denied` (rc=126). The device
  -- then has no listener, `platform connect` reports "Connection shut down by
  -- remote side while waiting for reply to initial handshake packet", and
  -- `process attach` fails with "The parameter is incorrect" — the exact
  -- <Space>da failure measured 2026-09-03. Fall through to the sandbox hop.
  local skip_transport = (plan == "reuse")

  if plan == "repush" then
    pcall(adb_run, adb, { "-s", serial, "shell", "killall lldb-server 2>/dev/null; true" })
    -- Remove any residue first: `adb push` onto an existing root-owned file
    -- fails with EACCES, but unlinking works because the parent directory is
    -- shell-owned. Harmless when the file does not exist.
    pcall(adb_run_raw, adb, { "-s", serial, "shell", "rm", "-f", remote })
    local push_out, push_code = adb_run_raw(adb, { "-s", serial, "push", src, remote })
    if push_code ~= 0 then
      return false, ("adb push failed on %s (exit %s): %s")
        :format(tostring(serial), tostring(push_code), tostring(push_out))
    end
  end

  if not skip_transport then
    local chmod_out, chmod_code = adb_run_raw(adb, { "-s", serial, "shell", "chmod", "755", remote })
    if chmod_code ~= 0 then
      -- chmod can EPERM on files we do not own. That is only fatal when the
      -- binary is genuinely not executable; otherwise log once and proceed.
      if remote_is_executable() then
        log.warn("dap.android",
          "chmod lldb-server EPERM (not owner) but binary already executable — proceeding: "
          .. tostring(chmod_out))
      else
        return false, ("chmod lldb-server failed on %s (exit %s): %s")
          :format(tostring(serial), tostring(chmod_code), tostring(chmod_out))
      end
    end
    local check = adb_run(adb, { "-s", serial, "shell", "ls", remote })
    if not check:match("lldb%-server") then
      return false, "lldb-server not present after push"
    end
  end

  -- Hop 2 (K56): copy the PUBLIC transport binary into the app sandbox so the
  -- platform server can run AS THE APP UID. See the block comment above for
  -- the measured evidence that a shell-uid server cannot ptrace the app on
  -- this build (its forked gdbserver SIGSEGVs inside vAttach).
  local sandbox = sandbox_lldb_server_path(pkg)
  if not sandbox then
    return false, "cannot derive sandbox lldb-server path (empty package name)"
  end

  -- K58: probe the SANDBOX copy under `run-as` — size AND `test -x` as the app
  -- uid. Both must hold to skip the re-stage; a public-path `test -x` from the
  -- shell uid proves nothing about app-uid execute permission (SELinux domain).
  local function sandbox_probe()
    local size_out = adb_run(adb, { "-s", serial, "shell",
      "run-as " .. pkg .. " sh -c " .. shell_quote("stat -c %s " .. sandbox) })
    local same = tostring(size_out):match("(%d+)%s*$") == tostring(local_size)
    local _, x_code = adb_run_raw(adb, { "-s", serial, "shell",
      "run-as " .. pkg .. " sh -c " .. shell_quote("test -x " .. sandbox) })
    return same, x_code == 0
  end

  local sb_size_ok, sb_exec_ok = sandbox_probe()
  if sandbox_stage_plan(sb_size_ok, sb_exec_ok) == "reuse" then
    return true, sandbox
  end

  local stage_out, stage_code = adb_run_raw(adb, { "-s", serial, "shell",
    "run-as " .. pkg .. " sh -c " .. shell_quote(sandbox_stage_script(remote, sandbox)) })
  if stage_code ~= 0 then
    return false, ("staging lldb-server into %s sandbox failed (exit %s): %s")
      :format(pkg, tostring(stage_code), tostring(stage_out))
  end
  local _, sandbox_x = adb_run_raw(adb, { "-s", serial, "shell",
    "run-as " .. pkg .. " sh -c " .. shell_quote("test -x " .. sandbox) })
  if sandbox_x ~= 0 then
    return false, "sandbox lldb-server not executable after staging: " .. sandbox
  end
  return true, sandbox
end

-- Spawn `lldb-server platform --server --listen "*:<port>"` AS THE APP UID
-- from the app sandbox copy, and set up adb forward. Returns (ok, err).
--
-- This is the WORKING attach route (K30 platform mode + K56 app uid), NOT
-- gdbserver --attach (K31: --attach never binds the listen port). The host then
-- issues
--   platform select remote-android
--   platform connect connect://[<serial>]:<port>   (K30/K32: serial form only)
--   process attach --pid N
-- and the device-side platform server forks the per-target gdbserver itself.
--
-- K56: the server MUST run as the app uid via `run-as <pkg>`. A shell-uid
-- server cannot ptrace the app on this `user` build and its forked gdbserver
-- child SIGSEGVs inside vAttach, surfacing to the host only as
-- `error: attach failed: lost connection`. Measured 3/3 fail (shell uid) vs
-- 3/3 pass (app uid) against the same healthy target — see the evidence table
-- on ensure_lldb_server_pushed above. Do NOT "fix" a lost-connection attach by
-- changing the device-server VERSION: LLDB 9 / 14 / 18 all fail identically
-- under the shell uid, and NDK 27 LLDB 18 is pinned by docs/CONSTRAINTS.md C1.
--
-- Kill BOTH uids' servers first: a stale shell-uid server from an older build
-- of this function would keep the port and silently reintroduce the SEGV path.
-- `--listen "*:N"` is double-quoted so the device shell cannot glob it.
-- Use jobstart (detached, no callbacks) — adb shell does NOT see stdout closed
-- even with nohup on Android 14+, so vim.fn.system would block forever
-- (e51cbe6 note).
local function start_lldb_server_platform(adb, serial, port, pkg, sandbox_path)
  pcall(adb_run, adb, { "-s", serial, "shell", "killall lldb-server 2>/dev/null; true" })
  if pkg then
    pcall(adb_run, adb, { "-s", serial, "shell",
      "run-as " .. pkg .. " sh -c " .. shell_quote("killall lldb-server 2>/dev/null || true") })
  end
  vim.wait(150)

  adb_run(adb, { "-s", serial, "forward", "--remove", "tcp:" .. port })
  if adb_run(adb, { "-s", serial, "forward", "tcp:" .. port, "tcp:" .. port }) == "" then
    if vim.v.shell_error ~= 0 then return false, "adb forward failed" end
  end

  local sandbox = sandbox_path or sandbox_lldb_server_path(pkg)
  if not sandbox then
    return false, "no sandbox lldb-server path for app-uid platform server"
  end
  local cmd = "run-as " .. pkg .. " sh -c "
    .. shell_quote(platform_server_script(sandbox, port))
  local jobid = vim.fn.jobstart({ adb, "-s", serial, "shell", cmd }, { detach = false })
  if not jobid or jobid <= 0 then
    return false, "failed to spawn lldb-server platform (jobstart=" .. tostring(jobid) .. ")"
  end
  M._lldb_server_jobid = jobid
  vim.wait(800)
  return true, nil
end

-- ── wait-for-debugger launch (Android Studio debug-button semantics) ──────
--
-- Goal: catch crashes in the EARLIEST app init (JNI_OnLoad, module static
-- init, engine PreInit) that a plain "monkey start → attach when pid shows
-- up" launch always misses. The Android Studio debug button does:
--   am set-debug-app -w <pkg>  → next launch of <pkg> blocks in a JDWP
--                                "Waiting for debugger" gate BEFORE
--                                Application.onCreate — before libUE4.so
--                                is even loaded.
--   start activity             → process spawns, waits at the gate.
--   attach native debugger     → lldb attaches while nothing of the app has
--                                run yet; file:line breakpoints are planted
--                                as pending against the symbol-rich target.
--   release the JDWP gate      → jdb attach over `adb forward tcp:N jdwp:PID`
--                                satisfies the gate; app proceeds through
--                                init and hits the earliest breakpoints.
--
-- K37 nuance: at attach time libUE4.so is NOT mapped, so the explicit ASLR
-- `target modules load --slide` cannot be computed (read_so_base_hex finds
-- nothing). That is EXPECTED here, not a failure: pending breakpoints
-- re-resolve when the dynamic linker loads the module, and belt-and-braces
-- we run a late-rebase poller that watches /proc/<pid>/maps and issues the
-- explicit slide over the lldb-dap evaluate channel (K36-proven) as soon as
-- the module appears. Failures are reported ONCE with full context to
-- ue-dap-bp-diag.log + a single notify — no repeated spam (user policy).

-- Pure command-shape helper (unit-tested): device-side steps of the
-- wait-for-debugger launch, WITHOUT the adb/-s prefix.
local function wait_launch_device_steps(pkg)
  return {
    force_stop = { "shell", "am", "force-stop", pkg },
    set_wait   = { "shell", "am", "set-debug-app", "-w", pkg },
    start      = { "shell", "monkey", "-p", pkg,
                   "-c", "android.intent.category.LAUNCHER", "1" },
    clear_wait = { "shell", "am", "clear-debug-app" },
  }
end

-- Pure command-shape helper (unit-tested): the jdb invocation that releases
-- the "Waiting for debugger" JDWP gate once the inferior's threads run.
local function jdb_connect_argv(jdb, port)
  return { jdb, "-connect",
    ("com.sun.jdi.SocketAttach:hostname=localhost,port=%d"):format(port) }
end

local function find_jdb()
  local cfg_path = ue_cfg_get("dap.jdb_path")
  if type(cfg_path) == "string" and cfg_path ~= "" and fs.is_file(cfg_path) then
    return cfg_path
  end
  local platform = require("utils.platform")
  local resolved = platform.resolve_tool({
    name = "jdb",
    driver_candidates = function(driver)
      return platform.java_debugger_candidates(driver)
    end,
  })
  return resolved.ok and resolved.path or nil
end

-- One-shot diagnostics for the wait-launch path. Every failure is recorded
-- exactly once per session (key-deduped) to both the rotating log and
-- ue-dap-bp-diag.log so it can be reviewed later without popup spam.
M._wait_notice_seen = {}

local function wait_notice(key, msg, level)
  if M._wait_notice_seen[key] then return end
  M._wait_notice_seen[key] = true
  append_bp_diag({ "== wait-for-debugger notice ==", "key=" .. key, msg })
  -- Probe: wait-launch failures are exactly the evidence the next session
  -- must read before touching this file (probe-feedback-loop spec #1).
  pcall(function()
    require("utils.probe").record("android-wait-launch", key, msg:sub(1, 120))
  end)
  log.notify("dap.android", msg, level or vim.log.levels.WARN)
end

-- Release the JDWP "Waiting for debugger" gate: forward a host port to the
-- app's jdwp transport and attach jdb. The jdb handshake only completes once
-- the inferior's threads are running (i.e. after the user's first F5), which
-- is exactly when we want the gate to open. jdb stays attached (harmless);
-- it is killed in _cleanup_device_side.
local function start_jdwp_release(sess)
  local jdb = find_jdb()
  if not jdb then
    wait_notice("jdb-missing",
      "jdb not found (PATH / JAVA_HOME / ue.config.dap.jdb_path). "
      .. "Release the waiting-gate manually:\n"
      .. ("  adb -s %s forward tcp:8700 jdwp:%d\n"):format(sess.serial, sess.pid)
      .. "  jdb -connect com.sun.jdi.SocketAttach:hostname=localhost,port=8700")
    return
  end
  local port = alloc_free_port() or 8700
  local fwd_out, fwd_code = adb_run_raw(sess.adb,
    { "-s", sess.serial, "forward", "tcp:" .. port, "jdwp:" .. sess.pid })
  if fwd_code ~= 0 then
    wait_notice("jdwp-forward",
      ("jdwp forward failed (exit %s): %s — waiting-gate NOT released; "
        .. "app will stay in 'Waiting for debugger' until you attach jdb manually.")
        :format(tostring(fwd_code), tostring(fwd_out)))
    return
  end
  sess.jdwp_port = port
  local jobid = vim.fn.jobstart(jdb_connect_argv(jdb, port), {
    on_exit = function(_, code)
      append_bp_diag({ ("jdb exited (code=%s)"):format(tostring(code)) })
    end,
  })
  if not jobid or jobid <= 0 then
    wait_notice("jdb-spawn",
      "failed to spawn jdb (jobstart=" .. tostring(jobid) .. ") — release the waiting-gate manually.")
    return
  end
  M._jdb_jobid = jobid
  append_bp_diag({
    "== jdwp release armed ==",
    ("jdb=%s port=%d pid=%d"):format(jdb, port, sess.pid),
  })
end

-- Late ASLR rebase poller (wait-mode only). Watches /proc/<pid>/maps
-- asynchronously (vim.system — never blocks the UI, P6) until libUE4.so is
-- mapped, then issues the explicit `target modules load --slide` over the
-- lldb-dap evaluate channel (K36) and dumps `breakpoint list` to the diag
-- log. K37 keeps the explicit slide load-bearing on this device; in wait
-- mode it simply arrives late instead of at attach time.
M._late_rebase_timer = nil

function M._stop_late_rebase_poller()
  if M._late_rebase_timer then
    pcall(function() M._late_rebase_timer:stop() end)
    pcall(function() M._late_rebase_timer:close() end)
    M._late_rebase_timer = nil
  end
end

function M._start_late_rebase_poller(sess)
  M._stop_late_rebase_poller()
  if not (sess and sess.wait_mode and sess.pid and sess.serial and sess.package_name) then return end
  local so = sess.symbol_lib and vim.fs.basename(sess.symbol_lib) or UE_MODULE_BASENAME
  local pid, serial, pkg, adb = sess.pid, sess.serial, sess.package_name, sess.adb
  local attempts, in_flight = 0, false
  local max_attempts = 90 -- × 700ms ≈ 63s of app init budget
  local timer = vim.uv.new_timer()
  if not timer then return end
  M._late_rebase_timer = timer

  local function finish_with_base(base_hex)
    local ok_dap, dap = pcall(require, "dap")
    local session = ok_dap and dap and dap.session and dap.session() or nil
    if not session then return end
    -- Concatenation only — never string.format("%x") on 64-bit values (P7/K4).
    local cmd = 'target modules load --file "' .. so .. '" --slide 0x' .. base_hex
    append_bp_diag({ "== late ASLR rebase (wait-mode) ==", cmd })
    session:request("evaluate", { expression = "`" .. cmd, context = "repl" },
      function(err, res)
        append_bp_diag({
          "late rebase response:",
          "error=" .. tostring(err and (err.message or err) or "nil"),
          "result=" .. tostring(res and res.result or ""),
        })
        session:request("evaluate", { expression = "`breakpoint list", context = "repl" },
          function(_lerr, lres)
            append_bp_diag({ "late rebase breakpoint list:", tostring(lres and lres.result or "") })
          end)
        if err then
          wait_notice("late-rebase-cmd",
            ("late ASLR rebase command failed (%s) — breakpoints may not resolve; "
              .. "see ue-dap-bp-diag.log."):format(tostring(err.message or err)))
        end
      end)
  end

  timer:start(1000, 700, vim.schedule_wrap(function()
    if in_flight then return end
    attempts = attempts + 1
    if attempts > max_attempts then
      M._stop_late_rebase_poller()
      wait_notice("late-rebase-timeout",
        (so .. " never appeared in /proc/%d/maps within ~60s of launch — "
          .. "explicit ASLR slide NOT issued (K37); breakpoints may not resolve. "
          .. "Context: serial=%s pkg=%s. See ue-dap-bp-diag.log."):format(pid, serial, pkg))
      return
    end
    -- Session gone (user stopped / adapter died) → stop silently.
    local ok_dap, dap = pcall(require, "dap")
    if not (ok_dap and dap and dap.session and dap.session()) then
      M._stop_late_rebase_poller()
      return
    end
    in_flight = true
    vim.system(
      { adb, "-s", serial, "shell", "run-as", pkg, "cat", "/proc/" .. pid .. "/maps" },
      { text = true },
      function(res)
        vim.schedule(function()
          in_flight = false
          if not M._late_rebase_timer then return end
          local base = res and res.code == 0
            and parse_maps_base_hex(res.stdout or "", so) or nil
          if base then
            M._stop_late_rebase_poller()
            finish_with_base(base)
          end
        end)
      end)
  end))
end

-- Arm the post-attach follow-up for wait mode: on the FIRST `continued`
-- event (the user's F5 after the entry stop), release the JDWP gate and
-- start the late-rebase poller. One-shot; deregistered after firing and in
-- cleanup paths.
local WAIT_LISTENER_KEY = "ue_android_wait_followup"

local function disarm_wait_mode_followup()
  pcall(function()
    require("dap").listeners.after.event_continued[WAIT_LISTENER_KEY] = nil
  end)
end

local function arm_wait_mode_followup(sess)
  local ok_dap, dap = pcall(require, "dap")
  if not ok_dap or not dap then return end
  dap.listeners.after.event_continued[WAIT_LISTENER_KEY] = function(session)
    if dap.session() ~= session then return end
    disarm_wait_mode_followup()
    -- Probe: success-path evidence — wait-launch reached the gate-release
    -- stage (pairs with the failure records from wait_notice; both feed
    -- the next session's report-first workflow).
    pcall(function()
      require("utils.probe").record("android-wait-launch", "gate-release-ok",
        { pkg = sess.package_name, pid = sess.pid })
    end)
    start_jdwp_release(sess)
    M._start_late_rebase_poller(sess)
  end
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
      for _, sub in ipairs(require("utils.platform").driver().lldb_python_relative_paths()) do
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
  -- ── Fatal-crash catchability (see docs/CONSTRAINTS.md K3) ───────────────
  -- K3 forces SIGSEGV/SIGBUS to `--stop false` because ART uses userspace
  -- SIGSEGV/SIGBUS traps (JIT read barriers, compacting-GC card-table
  -- protect/unprotect, heap poisoning) through libsigchain.so; stopping on
  -- them makes the app unusable. The cost is that a GENUINE UE fatal signal is
  -- also hidden, so a crash looks like "the debugger just exited".
  --
  -- Signal NUMBER cannot separate the two, but the SYMBOL can: UE routes every
  -- fatal signal through FFatalSignalHandler. Measured with NDK 27 llvm-nm on
  -- the shipped symbol libUE4.so (1,178,567 defined symbols):
  --   FFatalSignalHandler::OnTargetSignal(int, siginfo*, void*)      present
  --   FFatalSignalHandler::HandleTargetSignal(int, siginfo*, void*)  present
  -- OnTargetSignal runs ON THE FAULTING THREAD (installed via sigaction with
  -- SA_SIGINFO|SA_ONSTACK), so breaking there yields the real crash stack,
  -- while ART's benign traps never reach it.
  --
  -- The `?` prefix marks the command as non-fatal for lldb-dap: a build whose
  -- symbols differ must not abort the whole attach.
  --
  -- Escape hatch: UE_DAP_NO_FATAL_BP=1 restores the pre-K60 behaviour.
  -- Caveat (待验证): the forwarded handler thread polls
  -- WaitForSignalHandlerToFinishOrExit() and calls exit(0) once
  -- GAndroidSignalTimeOut elapses, so sitting at this breakpoint for a long
  -- time may still let the app self-exit.
  if (vim.env.UE_DAP_NO_FATAL_BP or "") == "" then
    cmds[#cmds + 1] = '?breakpoint set --shlib libUE4.so --name "FFatalSignalHandler::OnTargetSignal"'
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
    result.adapter_killed = sess_active ~= nil
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
  -- Wait-mode follow-ups must die with the session.
  if M._stop_late_rebase_poller then pcall(M._stop_late_rebase_poller) end
  disarm_wait_mode_followup()
  if M._jdb_jobid and M._jdb_jobid > 0 then
    pcall(vim.fn.jobstop, M._jdb_jobid)
    M._jdb_jobid = nil
  end
  -- Stop the host-side `adb shell run-as ... lldb-server gdbserver` job we
  -- spawned via jobstart. Killing the adb client closes the shell, which the
  -- device propagates to lldb-server.
  if M._lldb_server_jobid and M._lldb_server_jobid > 0 then
    pcall(vim.fn.jobstop, M._lldb_server_jobid)
    M._lldb_server_jobid = nil
  end
  if sess and sess.serial and sess.adb then
    -- Safety: never leave the device with a sticky debug-app gate (a stale
    -- `am set-debug-app -w` would freeze every future manual app launch).
    if sess.wait_mode then
      pcall(adb_run, sess.adb, { "-s", sess.serial, "shell", "am", "clear-debug-app" })
    end
    if sess.jdwp_port then
      pcall(adb_run, sess.adb, { "-s", sess.serial, "forward",
        "--remove", "tcp:" .. sess.jdwp_port })
    end
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

-- ── L0–L4 能力探针（capability probes，注册给 ue.dap.capability）─────────
--
-- 为何在这里而不是在通用模块里（docs/CONSTRAINTS.md §三 C10、
-- openspec/specs/dap-failure-layering/spec.md）：
-- `adb` / `run-as` / `getenforce` 这些都是 target policy 字面量，通用分层模块出现它们
-- 会被 ue_platform_boundary 判为 target_policy_literal（本月实测 FAIL 过），而且把它们
-- 写进通用层会让 iOS 复用退化成硬编码 target 分支（lua/ue/targets/AGENTS.md）。
-- 所以：**编排在通用层，命令字面量在 target owner。**
--
-- 每条 L2 探针都对应一条真实付过代价的坑。它们存在的唯一目的，是让那条坑下次
-- 在 5 秒内自报层，而不是再次表现为 `lost connection` / `The parameter is incorrect`。
--
-- 最小权限视角（K58）：判定「app uid 能否执行」必须以 `run-as <pkg>` 探测；
-- shell uid 的 `test -x` 对 app uid 的执行权限**零信息量**（实测：shell 通过、
-- app uid exec 得 126，标签分别是 shell_data_file 与 app_data_file）。

local function probe_shell(ctx, script)
  return { ctx.adb or "adb", "-s", tostring(ctx.serial or ""), "shell", script }
end

local function probe_run_as(ctx, script)
  return probe_shell(ctx, "run-as " .. tostring(ctx.package_name or "")
    .. " sh -c " .. shell_quote(script))
end

-- rc==0 ⇒ pass；有明确非零 rc ⇒ fail；rc 取不到（设备掉线等）⇒ undetermined。
-- 「宁可漏拦不可误拦」在这里落地：没有明确拒绝证据就不判红。
local function verdict_from_rc(rc, out, fail_remedy)
  local V = require("ue.dap.capability").VERDICT
  if rc == nil then
    return { verdict = V.UNDETERMINED, detail = "no exit code (device unreachable?)" }
  end
  if rc == 0 then return { verdict = V.PASS } end
  return { verdict = V.FAIL, detail = out, remedy = fail_remedy }
end

--- 本 target 的能力探针集合。ctx 需含 adb / serial / package_name / remote_lldb_server。
function M.capability_probes()
  local cap = require("ue.dap.capability")
  local F = require("ue.dap.failure")
  local V = cap.VERDICT
  local OWNER = "dap.android (Android target policy)"

  return {
    -- ── L1 传输 ──────────────────────────────────────────────────────────
    {
      layer = F.L.TRANSPORT, id = "device-reachable",
      owner = "utils.android_device",
      summary = "selected device answers a shell command",
      remedy = "reconnect the device (USB or wifi ADB) and re-select it with :UESetAndroidDevice",
      build_argv = function(ctx) return probe_shell(ctx, "true") end,
      decide = function(rc, out) return verdict_from_rc(rc, out) end,
    },
    -- ── L2 目标 OS 策略 ─────────────────────────────────────────────────
    {
      -- K47：root 是设备能力而非固定命令形状；`run-as` 可用性必须实测。
      layer = F.L.TARGET_POLICY, id = "run-as-available",
      owner = OWNER, identity = "app uid",
      summary = "the app identity can be entered via run-as",
      remedy = "confirm the installed package is debuggable; a non-debuggable build cannot be attached on a user build",
      build_argv = function(ctx) return probe_run_as(ctx, "id -u") end,
      decide = function(rc, out) return verdict_from_rc(rc, out) end,
    },
    {
      -- K58：run path 就绪只能以 app uid 判定。这条探针就是那条「差 5 秒命令」。
      layer = F.L.TARGET_POLICY, id = "app-uid-can-exec-server",
      owner = OWNER, identity = "app uid",
      summary = "the app identity can execute the staged debug server",
      remedy = "re-stage the server into the app sandbox path (the public transport copy is "
        .. "labelled shell_data_file and is readable-but-not-executable by the app domain)",
      -- 两个问题必须分开问（2026-09-04 真机实测发现的设计缺陷）：
        --   「还没 stage」与「stage 过但不可执行」在单独的 `test -x` 下**同为 rc=1**。
        -- 早期实现把 rc=1 一律当成「还没 stage」判 undetermined，于是「可读不可执行」
        -- 这个**真红灯永远判不出来**，L2 门禁实际上是死的——而那正是 K58 要拦的情形。
        -- 改法：先问存在性再问可执行性，用不同退出码把两者分开。
        --   rc=0  → 存在且可执行              → pass
        --   rc=10 → 不存在（尚未 stage）        → undetermined（不误拦首跑）
        --   rc=11 → 存在但不可执行            → FAIL（真红灯，K58 形状）
      build_argv = function(ctx)
        local sandbox = sandbox_lldb_server_path(ctx.package_name)
        if not sandbox then return nil end
        return probe_run_as(ctx, ("test -x %s && exit 0; test -e %s && exit 11; exit 10")
          :format(sandbox, sandbox))
      end,
      decide = function(rc, out)
        if rc == nil then
          return { verdict = V.UNDETERMINED, detail = "no exit code (device unreachable?)" }
        end
        if rc == 0 then return { verdict = V.PASS } end
        if rc == 11 then
          -- 存在却不可执行 = 真正的策略拒绝（K58 的形状）。必须拦。
          return { verdict = V.FAIL,
            detail = "staged copy exists but is NOT executable by the app identity "
              .. "(SELinux label or mode); this is the K58 shape" }
        end
        if rc == 10 then
          return { verdict = V.UNDETERMINED,
            detail = "not staged yet (staging happens later in bootstrap)",
            remedy = "no action needed before a first attach; re-run after one attach attempt" }
        end
        return { verdict = V.UNDETERMINED, detail = out }
      end,
    },
    {
      -- K56：这条是本月最贵的坑。shell uid 无权 ptrace app，LLDB 把该拒绝暴露成
      -- 子进程 SIGSEGV，host 只看到 `lost connection`。用 app uid 直接问内核。
      layer = F.L.TARGET_POLICY, id = "app-uid-can-ptrace-target",
      owner = OWNER, identity = "app uid",
      summary = "the app identity can read the target process, a prerequisite for ptrace",
      remedy = "the debug server must run under the app identity (run-as); a shell-uid server "
        .. "cannot ptrace the app on a user build and surfaces only as `lost connection`",
      build_argv = function(ctx)
        if not ctx.pid then return nil end
        return probe_run_as(ctx, "cat /proc/" .. tostring(ctx.pid) .. "/status")
      end,
      decide = function(rc, out)
        if rc == nil then
          return { verdict = V.UNDETERMINED, detail = "no exit code (device unreachable?)" }
        end
        if rc ~= 0 then
          return { verdict = V.FAIL, detail = out }
        end
        -- K13：目标已被别的 tracer 占用时 attach 也会失败，这同属 L2 策略层。
        local tracer = tostring(out or ""):match("TracerPid:%s*(%d+)")
        if tracer and tracer ~= "0" then
          return { verdict = V.FAIL,
            detail = "TracerPid=" .. tracer .. " (already being traced)",
            remedy = "stop the other debugger/tracer, or run :UEDAPStop to clean up a stale session" }
        end
        return { verdict = V.PASS }
      end,
    },
    {
      -- 只作 evidence：Enforcing 本身不是失败，但它是解释 K58 的关键上下文。
      layer = F.L.TARGET_POLICY, id = "mandatory-access-control-mode",
      owner = OWNER, identity = "shell",
      summary = "mandatory access control mode (context for execute-permission denials)",
      build_argv = function(ctx) return probe_shell(ctx, "getenforce") end,
      decide = function(rc, out)
        if rc ~= 0 then
          return { verdict = V.UNDETERMINED, detail = "could not read enforcement mode" }
        end
        return { verdict = V.PASS, detail = out }
      end,
    },
    {
      layer = F.L.TARGET_POLICY, id = "target-process-running",
      owner = OWNER, identity = "shell",
      summary = "the target process exists on the device",
      remedy = "start the app first, or use :UEDAPLaunch for wait-for-debugger launch",
      build_argv = function(ctx)
        return probe_shell(ctx, "pidof -s " .. tostring(ctx.package_name or ""))
      end,
      decide = function(rc, out)
        if rc == nil then
          return { verdict = V.UNDETERMINED, detail = "no exit code (device unreachable?)" }
        end
        if tostring(out or ""):match("%d+") then return { verdict = V.PASS, detail = out } end
        return { verdict = V.FAIL, detail = "no pid for the package" }
      end,
    },
    -- ── L4 符号语义 ─────────────────────────────────────────────────────
    {
      -- 本月未闭环的 follow-up：设备 versionCode 与本地符号包不匹配。
      -- 它不阻断 attach（断点解析才受影响），所以是 L4 而不是 L2。
      layer = F.L.SYMBOL, id = "symbol-build-matches-device",
      owner = "dap.android (symbols)",
      summary = "the selected symbol library matches the installed build",
      remedy = "pick the symbol package whose versionCode equals the installed one; "
        .. "a mismatch resolves breakpoints against the wrong source revision",
      build_argv = function(ctx) return probe_shell(ctx, "dumpsys package " .. tostring(ctx.package_name or "")
          .. " | grep -m1 versionCode") end,
      -- decide 只能看到 rc/out（纯函数契约），拿不到 ctx。本地符号包的
      -- versionCode 因此由 preflight 在报告层比对；这里只忻实报设备值。
      decide = function(rc, out)
        if rc ~= 0 or not tostring(out or ""):match("versionCode") then
          return { verdict = V.UNDETERMINED, detail = "could not read the installed versionCode" }
        end
        local device_code = tostring(out):match("versionCode=(%d+)")
        if not device_code then
          return { verdict = V.UNDETERMINED, detail = out }
        end
        return { verdict = V.PASS, detail = "device versionCode=" .. device_code }
      end,
    },
  }
end

--- 本 target 的 probe context 富化（由通用层回调）。
---
--- 设备路由与应用身份是 **target 知识**：通用层不得自己 require
--- `utils.android_device` 或读 `M._session`（那会在 target-generic 模块里制造具体
--- target 引用，ue_platform_boundary 实测会 FAIL）。因此由本 owner 填。
function M.probe_context(ctx)
  ctx = ctx or {}
  local out = vim.tbl_extend("force", {}, ctx)
  if not out.serial or out.serial == "" then
    local ok_dev, dev = pcall(require, "utils.android_device")
    if ok_dev and dev then
      local ok_get, serial = pcall(dev.get)
      if ok_get then out.serial = serial end
      if not out.adb then
        local ok_adb, adb = pcall(dev.adb_executable)
        if ok_adb then out.adb = adb end
      end
    end
  end
  out.adb = out.adb or M._session.adb or "adb"
  if not out.package_name or out.package_name == "" then
    out.package_name = M._session.package_name
      or (M._last_session and M._last_session.package_name)
  end
  out.pid = out.pid or M._session.pid
  return out
end

-- ── public: attach / launch ───────────────────────────────────────────────

local function bootstrap_session(opts, on_ready)
  opts = opts or {}
  -- Never write session choices back into resolve_context()'s cached table:
  -- doing so would pin the first serial in ctx.android_serial and make a later
  -- :UESetAndroidDevice switch lose to that stale "explicit" value.
  local ctx = vim.tbl_extend("force", {}, opts.context or {})
  -- Programmatic/headless retries should not block forever on vim.fn.input()
  -- for values that are stable for this workspace and already known.
  -- Priority: explicit context/opts -> session-global selected device. A normal
  -- attach/launch never guesses from last-session history; without either it
  -- opens the shared device picker below. Reattach has its own explicit replay.
  --
  -- K59: MUST NOT fall back to `M._last_session.package_name` here. That
  -- snapshot is written by snapshot_last_session() on EVERY teardown — a failed
  -- attach ("process <pkg> not running") runs stop_android_debugger() and
  -- therefore persists the wrong package into process memory. Once seeded, it
  -- short-circuits pick_package()'s whole chain, so a later
  -- `:UESetAndroidPackage <corrected>` (which writes persisted state) stays
  -- invisible for the rest of the Neovim session and <Space>da keeps reporting
  -- the OLD package as "not running". Persisted state must win.
  ctx.android_package = resolve_session_package(ctx, opts)
  -- When none of the above sources provides a package name, leave it nil
  -- so pick_package() falls through to persisted state → project discovery
  -- → config → user prompt, instead of treating a placeholder as a real
  -- Android package name.
  ctx.android_serial = resolve_session_serial(ctx, opts)
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
--
-- C10 L2 GATE: the target-OS-policy probes run HERE, immediately before the
-- device server is started and `platform connect` is issued. This is the last
-- point at which an L2 denial can still be reported as an L2 denial. Past this
-- line the very same denial only ever surfaced as `attach failed: lost
-- connection` (K56) or `The parameter is incorrect` (K58) — symptoms that point
-- at nothing and cost hours of forensics each.
local function _finalize_session(sess, pid, cfg_name, run_label)
  local P = require("ue.dap._progress")
  sess.pid = pid
  sess.lldb_server_mode = "platform"

  -- The gate is async (P6) and deliberately fail-open: only an explicit denial
  -- blocks. See preflight.blocks_attach — undetermined never blocks.
  M._gate_then_start(sess, function()
    M._finalize_session_after_gate(sess, pid, cfg_name, run_label)
  end)
end

--- Run the L2 subset of the capability probes, then continue or refuse.
--- Split out so the gate itself stays testable without a device.
function M._gate_then_start(sess, continue_fn)
  local preflight = require("ue.dap.preflight")
  local F = require("ue.dap.failure")
  local P = require("ue.dap._progress")

  if preflight.skipped() then
    sess._preflight_skipped = true
    return continue_fn()
  end

  local l2 = {}
  for _, d in ipairs(M.capability_probes()) do
    if d.layer == F.L.TARGET_POLICY then l2[#l2 + 1] = d end
  end

  P.step("checking target OS policy (L2) …")
  preflight.run({
    probes = l2,
    ctx = {
      adb = sess.adb, serial = sess.serial,
      package_name = sess.package_name, pid = sess.pid,
    },
    on_done = function(report)
      if not preflight.blocks_attach(report) then return continue_fn() end
      local fail = preflight.blocking_failure(report)
      local text = F.format(fail)
      P.error("attach refused at L2 (target OS policy)")
      log.notify_error("dap.android",
        "attach refused before connecting the debug engine:\n" .. text
        .. "\n(run :UEDAPPreflight for all layers; UE_DAP_SKIP_PREFLIGHT=1 overrides)")
      M._attach_in_progress = false
      M.stop_android_debugger()
    end,
  })
end

function M._finalize_session_after_gate(sess, pid, cfg_name, run_label)
  local P = require("ue.dap._progress")

  P.step(("starting lldb-server platform (port=%d) …"):format(sess.port))
  local ok_srv, srv_err = start_lldb_server_platform(
    sess.adb, sess.serial, sess.port, sess.package_name, sess.remote_lldb_server)
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
    elseif sess.wait_mode then
      -- EXPECTED in wait-for-debugger launch: the app is frozen at the JDWP
      -- gate before libUE4.so is loaded, so there is no maps entry yet. The
      -- late-rebase poller issues the explicit slide once the module appears
      -- (armed on first continue). Log only — no scary warning.
      append_bp_diag({
        "== wait-mode: ASLR base not yet available (module not loaded) ==",
        "late-rebase poller will issue the slide after first continue.",
      })
    else
      log.notify("dap.android",
        "ASLR base unresolved for " .. vim.fs.basename(sess.symbol_lib)
        .. "; breakpoints may not resolve (continuing attach)",
        vim.log.levels.WARN)
    end
  end

  local cfg = lldb_dap_attach_config(sess, sess.source_map)
  cfg.name = cfg_name
  cfg._ue_session_owner = "android"
  cfg._ue_session_operation = cfg_name:find("Launch", 1, true) and "launch" or "attach"
  cfg._ue_device_id = sess.serial
  cfg._ue_process_id = pid
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
  opts = opts or {}
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
  -- Fresh session → failures should be reported once again (the dedup is
  -- per-session, not forever).
  M._wait_notice_seen = {}
  bootstrap_session(opts, function(ok)
    if not ok then M._attach_in_progress = false; return end
    local sess = M._session
    local P = require("ue.dap._progress")
    local pkg = sess.package_name or "?"
    local steps = wait_launch_device_steps(sess.package_name)

    -- Android-Studio-debug-button semantics: freeze the app at the JDWP
    -- "Waiting for debugger" gate from the very first instruction, attach
    -- lldb while NOTHING of the app has run, then release the gate after
    -- the user's first continue. Catches earliest-init crashes that the
    -- old "start, then attach when pid appears" flow always missed.
    P.step("6/6  set-debug-app -w " .. pkg .. " …")
    pcall(adb_run, sess.adb, vim.list_extend({ "-s", sess.serial }, steps.force_stop))
    local sd_out, sd_code = adb_run_raw(sess.adb,
      vim.list_extend({ "-s", sess.serial }, steps.set_wait))
    if sd_code ~= 0 then
      -- User policy: fail with a recorded reason, do NOT silently fall back.
      P.error("am set-debug-app failed")
      wait_notice("set-debug-app",
        ("am set-debug-app -w %s failed (exit %s): %s — wait-for-debugger launch aborted. "
          .. "Is the app debuggable? Use :UEDAPAttach for a running process instead.")
          :format(pkg, tostring(sd_code), tostring(sd_out)),
        vim.log.levels.ERROR)
      M._attach_in_progress = false
      M.stop_android_debugger()
      return
    end

    P.step("starting activity (waiting at debugger gate) …")
    pcall(adb_run, sess.adb, vim.list_extend({ "-s", sess.serial }, steps.start))

    -- Async pid poll (F4): does not freeze user input while the process spawns.
    pidof_async(sess.adb, sess.serial, sess.package_name, 10000, function(pid)
      -- One-shot: clear the debug-app flag as soon as the process exists (or
      -- we give up), so a later manual launch of the app is NOT gated. The
      -- already-spawned process keeps waiting regardless.
      pcall(adb_run, sess.adb, vim.list_extend({ "-s", sess.serial }, steps.clear_wait))
      if not pid then
        P.error(("%s did not start within 10s"):format(pkg))
        wait_notice("wait-launch-no-pid",
          ("%s did not appear within 10s after set-debug-app -w + start "
            .. "(serial=%s). See ue-dap-bp-diag.log."):format(pkg, sess.serial),
          vim.log.levels.ERROR)
        M._attach_in_progress = false
        M.stop_android_debugger()
        return
      end

      sess.wait_mode = true
      _finalize_session(sess, pid, "UE Android Launch (wait-for-debugger)", "UEDAP android launch")
      arm_wait_mode_followup(sess)
      M._attach_in_progress = false
      M._start_liveness_poller()
      vim.notify(
        "[ue.dap.android] launched " .. pkg .. " frozen at the debugger gate.\n"
        .. "Set breakpoints, then F5: the JDWP gate is released automatically and\n"
        .. "the earliest engine init runs under the debugger.",
        vim.log.levels.INFO)
    end)
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
  sess.serial            = android_device.get() or last.serial
  sess.package_name      = last.package_name
  sess.symbol_lib        = last.symbol_lib
  sess.lldb_server_local = last.lldb_server_local
  sess.remote_lldb_server = last.remote_lldb_server
  sess.lldb_server_mode  = last.lldb_server_mode
  sess.source_map        = last.source_map
  sess.engine_root       = last.engine_root
  sess.port              = pick_port()

  local P = require("ue.dap._progress")
  P.step(("reattach: waiting for %s on %s …"):format(sess.package_name, sess.serial))

  -- Async pid poll up to 10s (F4 — no half-blocking vim.wait loop).
  pidof_async(sess.adb, sess.serial, sess.package_name, 10000, function(pid)
    if not pid then
      P.error(("%s not running on %s after 10s"):format(sess.package_name, sess.serial))
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
  end)
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

-- Explain WHY the debugged app died, instead of the old generic
-- "App <pkg> exited on <serial>. Detaching.".
--
-- Two authorities are consulted:
--   * lldb's own exit status, captured by ue.dap.exit_reason from the DAP
--     `exited` event / console line ("Process N exited with status = 9").
--   * Android's ApplicationExitInfo, via `dumpsys activity exit-info <pkg>`,
--     which is the only source that names the KILLER (e.g.
--     "reason=10 (USER REQUESTED) subreason=21 (FORCE STOP)
--      description=stop <pkg> due to from pid 1976 (system)").
--
-- dumpsys accepts a package only (`dumpsys activity -h` documents
-- `exit-info [PACKAGE_NAME]`), so the pid match happens in exit_reason.
-- The probe is async and best-effort: an unreachable device (wifi ADB drop is
-- exactly when this fires) must still produce the lldb half of the report.
---@param ctx table { adb, serial, pkg, pid }
function M._report_exit_reason(ctx)
  local ok_er, er = pcall(require, "ue.dap.exit_reason")
  local note = ok_er and er.take() or nil
  local status = note and note.status or nil

  local function emit(record)
    local body = ok_er and er.compose({
      status = status,
      record = record,
      -- Target-specific tooling literal is owned HERE, not in the generic
      -- exit_reason module (ue_platform_boundary: target_policy_literal).
      no_record_hint = ("No device exit record found for this pid. Check: "
        .. "adb shell dumpsys activity exit-info %s"):format(ctx.pkg),
    }) or nil
    local msg = ("[ue.dap.android] App %s died on %s. Detaching."):format(ctx.pkg, ctx.serial)
    if body and body ~= "" then msg = msg .. "\n" .. body end
    msg = msg .. "\nUse :UEDAPReattach to reconnect."
    vim.notify(msg, vim.log.levels.WARN)
    pcall(function()
      require("utils.probe").record("android-session-exit",
        ("status=%s reason=%s"):format(tostring(status), record and record.reason or "unknown"),
        (body or ""):sub(1, 200))
    end)
  end

  local ok_spawn = pcall(vim.system,
    { ctx.adb, "-s", ctx.serial, "shell", "dumpsys", "activity", "exit-info", ctx.pkg },
    { text = true },
    function(res)
      vim.schedule(function()
        local record = nil
        if res and res.code == 0 and ok_er then
          record = er.find_exit_info(res.stdout, ctx.pid)
        end
        emit(record)
      end)
    end)
  if not ok_spawn then emit(nil) end
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
  -- P6: the pid probe MUST NOT run synchronously on the main loop. The old
  -- implementation called pidof() (vim.fn.system → blocking adb round-trip,
  -- 300–1000ms over USB) inside vim.schedule_wrap every 1.5s — that showed
  -- up as a continuous ~p50 400ms main-loop stall train in stall_probe logs
  -- (2026-07-24, ~50 stalls/min for the whole debug session). Use vim.system
  -- with a callback instead; `in_flight` prevents overlapping probes when
  -- adb is slower than the poll interval.
  local in_flight = false
  local function on_pid_result(live)
    -- Runs on the main loop (scheduled). Re-check state: the timer may have
    -- been stopped, or the session replaced, while the probe was in flight.
    if M._liveness_timer ~= timer then return end
    local ok_dap, dap = pcall(require, "dap")
    local has_sess = ok_dap and dap and dap.session and dap.session() or nil
    if not has_sess or M._session.pid ~= pid then
      M._stop_liveness_poller()
      return
    end
    if live and live == pid then
      M._liveness_misses = 0
      return
    end
    -- Tolerate a single transient miss (adb hiccup, brief unauthorized).
    M._liveness_misses = M._liveness_misses + 1
    if M._liveness_misses < 2 then return end

    -- App is gone. Stop everything, notify, snapshot for reattach.
    M._stop_liveness_poller()
    if live and live ~= pid then
      vim.notify(("[ue.dap.android] App %s restarted (new pid=%d). Detaching."):format(pkg, live)
        .. "\nUse :UEDAPReattach to reconnect.", vim.log.levels.WARN)
      pcall(M.stop_android_debugger)
      return
    end
    -- The app died. "exited. Detaching." on its own is what made a SIGKILL
    -- look like "the debugger just exited", so ask the two authorities why:
    --   1. lldb's console/exited status, recorded by ue.dap.exit_reason
    --   2. Android's own post-mortem: dumpsys activity exit-info <pkg>
    -- The adb round-trip is async so it never stalls the main loop; teardown
    -- runs regardless of whether the probe answers.
    M._report_exit_reason({ adb = adb, serial = serial, pkg = pkg, pid = pid })
    pcall(M.stop_android_debugger)
  end
  timer:start(2000, 1500, function()
    -- FAST EVENT CONTEXT: spawn only; all state handling is scheduled.
    if in_flight then return end
    in_flight = true
    local ok_spawn = pcall(vim.system,
      { adb, "-s", serial, "shell", "pidof", "-s", pkg },
      { text = true },
      function(res)
        vim.schedule(function()
          in_flight = false
          local live = nil
          if res and res.code == 0 then
            local digits = (res.stdout or ""):match("(%d+)")
            live = digits and tonumber(digits) or nil
          end
          on_pid_result(live)
        end)
      end)
    if not ok_spawn then in_flight = false end
  end)
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

-- Build attachCommands from a synthetic session table (no device / adb). Guards
-- the load-bearing attach ordering: K34 symbol-rich `target create` FIRST, K30
-- serial-form `platform connect connect://[<serial>]:<port>`, K37 explicit ASLR
-- `target modules load --slide` honoured/skipped per session._module_rebase_cmd
-- and the UE_DAP_NO_SLIDE switch.
function M._attach_commands_for_test(session)
  return attach_commands(session)
end

-- Pure helpers exposed for headless specs (no device / adb / dap needed).
function M._lldb_server_stage_plan_for_test(size_matches, is_executable)
  return lldb_server_stage_plan(size_matches, is_executable)
end

-- K58: run-path (sandbox) reuse decision — only app-uid `test -x` counts.
function M._sandbox_stage_plan_for_test(size_matches, is_executable)
  return sandbox_stage_plan(size_matches, is_executable)
end

-- K56 app-uid platform server: sandbox path + the two device-side sh -c bodies.
function M._sandbox_lldb_server_path_for_test(pkg)
  return sandbox_lldb_server_path(pkg)
end

function M._sandbox_stage_script_for_test(public_path, sandbox_path)
  return sandbox_stage_script(public_path, sandbox_path)
end

function M._platform_server_script_for_test(sandbox_path, port)
  return platform_server_script(sandbox_path, port)
end

function M._parse_maps_base_hex_for_test(maps, so_basename)
  return parse_maps_base_hex(maps, so_basename)
end

function M._wait_launch_device_steps_for_test(pkg)
  return wait_launch_device_steps(pkg)
end

function M._resolve_session_serial_for_test(ctx, opts)
  return resolve_session_serial(ctx, opts)
end

function M._resolve_session_package_for_test(ctx, opts)
  return resolve_session_package(ctx, opts)
end

function M._snapshot_last_session_for_test()
  return snapshot_last_session()
end

function M._jdb_connect_argv_for_test(jdb, port)
  return jdb_connect_argv(jdb, port)
end

return M
