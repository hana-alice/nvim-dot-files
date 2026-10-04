-- ue.dap.android — Android DAP attach via lldb-dap + lldb-server platform mode.
--
-- Adapter: LLVM lldb-dap (resolved by ue.dap._common.find_lldb_dap, host 22.1.6).
-- Wire:    nvim-dap → lldb-dap (host) → adb forward → lldb-server platform
--          (device app uid, sandbox copy, --listen *:<port>). The host attach runs:
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
--   * lldb-server pushed through /data/local/tmp, then copied into the app
--     sandbox and run as the app uid (K56/K58; the public path is transport only).
--   * Process matching session.package_name running.
--   * App is debuggable and supports run-as so the app-uid server can ptrace it.
--
-- Requirements on the host (one-time):
--   * LLVM 22.1.6+ with lldb-dap.exe on PATH or under
--     C:/tools/lldb-22/install/bin/, or pointed to by
--     ue.config.dap.lldb_dap_path.
--   * A symbol-rich Android module (DWARF) available locally — preferably the
--     current Target/Configuration's unstripped Binaries/Android artifact,
--     otherwise a build-id-matching *_Symbols_v* package. It may also be set via
--     ue.config dap.android_symbol_lib. Without it lldb-dap only sees the stripped
--     device module and source breakpoints cannot resolve.
--   * Optional: source-map entries (DAP "sourceMap") so DWARF build-machine
--     paths (e.g. D:\UE\EngineWorktree\Engine\) resolve to the local checkout.

local C              = require("ue.dap._common")
local fs             = require("ue.core.fs")
local log            = require("utils.log")
local android_device = require("utils.android_device")

-- 符号选择（K64/K65）：构建配置来自引擎 cache，build-id 是符号与产物的权威关联键。
-- 在此处绑定（而不是跟 policy/transport 一起放到文件下方），因为 `pick_symbol_lib`
-- 就在上方不远处使用它；Lua 的 upvalue 必须先定义。
local symbols = require("ue.dap._android_symbols").bind({
  read_build_id = function(path, n)
    return require("ue.dap._android_policy").read_build_id(path, n)
  end,
  resolve_artifact = function(android_dir, target, configuration)
    local project_dir = fs.norm(vim.fn.fnamemodify(android_dir, ":h:h"))
    return require("ue.targets.android").find_symbol_artifact({
      project_dir = project_dir,
      target = target,
      configuration = configuration,
    })
  end,
})

local M = {}

local UE_MODULE_BASENAME = "libUE4.so"
local ATTACH_RESULT_LISTENER_KEY = "ue-android-attach-result"

-- ── shared session state ──────────────────────────────────────────────────
M._session = {
  pid               = nil,
  serial            = nil,
  port              = 5045,
  package_name      = nil,
  adb               = "adb",
  lldb_server_local = nil,  -- host path to NDK lldb-server
  remote_lldb_server = nil, -- device path to app-executable lldb-server
  lldb_server_mode  = nil,  -- current route is app-uid "platform" only
  symbol_lib        = nil,  -- host path to the symbol-rich module
  runtime_module_basename = nil, -- verified DT_SONAME / maps identity (may differ from host file)
  symbol_version_code = nil, -- packageInfo evidence for direct artifacts outside *_Symbols_v*
  attach_succeeded  = nil, -- true only after the DAP attach response succeeds
  source_map        = nil,  -- list of { from, to } pairs
  engine_root       = nil,  -- host engine root, used to wire LLDB UE data formatters
  wait_mode         = nil,  -- true when launched via wait-for-debugger (set-debug-app -w)
  jdwp_port         = nil,  -- host forward port used by the jdb gate-release
}

local function reset_session()
  -- Retire the object captured by async callbacks. Reusing and clearing the
  -- same table would let an old callback mutate the next attempt's fields.
  M._session = { adb = "adb", port = 5045 }
end

local function current_operation(sess)
  local operation = sess and sess._operation
  return not operation or (M._session == sess and operation.current())
end

local function complete_operation(sess, code, detail)
  local operation = sess and sess._operation
  if not operation then return end
  if code ~= 0 then M._cleanup_in_progress = true end
  operation.finish(code, detail or (operation.failure and {
    failure = operation.failure, reason = operation.failure.summary or operation.failure.headline,
  }))
end

function M._begin_operation(opts)
  reset_session()
  local sess = M._session
  local operation = require("ue.dap._operation").new(opts, function(value)
    return M._session == sess and sess._operation == value
  end, function(value)
    if M._session._operation == value then M.stop_android_debugger() end
  end)
  M._session._operation = operation
  return operation
end

function M.initialized_progress()
  if not M._session.attach_succeeded then return "debugger initialized; waiting for attach response …" end
end

-- ── reattach memory ───────────────────────────────────────────────────────
-- Snapshot of the last successful session, kept across stop() so that
-- :UEDAPReattach can replay pkg/serial/symbol_lib without re-prompting.
M._last_session = nil

local function snapshot_last_session()
  local s = M._session
  -- K59/K69: package/serial/symbol/pid are all known before the asynchronous
  -- L2 gate and DAP attach response. None proves an attached debugger; even a
  -- failed adapter may emit `initialized` first. Only the successful `attach`
  -- response listener sets attach_succeeded, so half-sessions never poison
  -- :UEDAPReattach.
  if not (s.package_name and s.serial and s.symbol_lib and s.pid
      and s.attach_succeeded == true) then return end
  M._last_session = {
    package_name      = s.package_name,
    serial            = s.serial,
    symbol_lib        = s.symbol_lib,
    runtime_module_basename = s.runtime_module_basename,
    symbol_version_code = s.symbol_version_code,
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
  if ctx and ctx._frozen then
    return type(ctx.project_root) == "string" and ctx.project_root ~= "" and fs.norm(ctx.project_root)
      or (ctx.uproject and fs.dirname(ctx.uproject))
  end
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
  -- 4. Nothing known: the caller offers a device package picker (async).
  return nil
end

local function pick_symbol_lib(ctx)
  local function selected(path, required_runtime_identity)
    local soname = symbols.read_soname(path)
    local runtime_basename = soname or vim.fs.basename(path)
    if required_runtime_identity
      and soname ~= UE_MODULE_BASENAME and soname ~= "libUnreal.so" then
      return nil
    end
    return path, runtime_basename
  end

  -- 0. Explicit attach/context/default override. This path is used by
  -- agent-driven and reattach flows; do not prompt for a symbol path that is
  -- already known for the current UE Android workspace.
  local ctx_sym = ctx and (ctx.android_symbol_lib or ctx.symbol_lib)
  if type(ctx_sym) == "string" and ctx_sym ~= "" and fs.is_file(ctx_sym) then
    return selected(ctx_sym, false)
  end
  -- 1. Config override.
  local cfg_sym = ue_cfg_get("dap.android_symbol_lib")
  if type(cfg_sym) == "string" and cfg_sym ~= "" and fs.is_file(cfg_sym) then
    return selected(cfg_sym, false)
  end

  local function discover_symbol_packages(android_dir, required_suffix)
    local found = {}
    if not android_dir or not fs.is_dir(android_dir) then return found end
    for name, kind in vim.fs.dir(android_dir) do
      local suffix_matches = not required_suffix
        or (#name >= #required_suffix and name:sub(-#required_suffix) == required_suffix)
      if kind == "directory" and name:find("Symbols", 1, true) and suffix_matches then
        local package_dir = android_dir .. "/" .. name
        for arch_name, arch_kind in vim.fs.dir(package_dir) do
          if arch_kind == "directory" and arch_name:lower():match("%-arm64$") then
            local arch_dir = package_dir .. "/" .. arch_name
            local preferred = arch_dir .. "/libUE4.so"
            local fallback = arch_dir .. "/libUnreal.so"
            if fs.is_file(preferred) then
              found[#found + 1] = preferred
            elseif fs.is_file(fallback) then
              found[#found + 1] = fallback
            end
          end
        end
      end
    end
    table.sort(found)
    return found
  end

  local proot = effective_project_root(ctx)
  if proot then
    local android_dir = android_marker_path(proot, ctx and ctx.uproject or nil)
    local info = read_package_info(proot, ctx and ctx.uproject or nil)
    -- 配置来自引擎 cache（ctx.state）——**不猜、不硬编码某个配置**。
    local configuration = ctx and (ctx.configuration
      or (ctx.state and ctx.state.target_configuration)) or nil
    local target_name = ctx and (ctx.target or ctx.target_name) or nil
    -- Project name and Target name are independent (K45). Normal DAP entrypoints
    -- inject the build planner's Target.cs-derived identity; a lower-level caller
    -- that omits it may use weak package matching, but MUST NOT guess from .uproject.

    local expected, artifact_so = nil, nil
    if android_dir and configuration and target_name then
      expected, artifact_so = symbols.expected_build_id(android_dir, target_name, configuration)
    end

    -- 2. K66：该配置的**未 strip 产物 so 自己就是符号源**（实测含 1.2GB
    -- `.debug_info` + `.symtab`，且 build-id 与同配置 APK 内 lib 逐字相同）。
    -- 它比从 `*_Symbols_v*` 反推配置更直接；该判定不依赖 packageInfo/versionCode，
    -- 因为那些是打包元数据，而这里消费的是当前配置自己的链接产物。
    if artifact_so and symbols.has_debug_symbols(artifact_so) then
      local selected_path, runtime_basename = selected(artifact_so, true)
      if selected_path then
        return selected_path, runtime_basename, info and info.version_code or nil
      end
    end

    -- 3. 有 packageInfo 时，versionCode 先收窄符号包，再用 build-id 定案（K64/K65）。
    -- versionCode 相等只是一条弱证据；已知 build-id 时不允许退回 mtime 猜测。
    if android_dir and info and info.version_code ~= "" then
      local exact = discover_symbol_packages(android_dir, "_Symbols_v" .. info.version_code)
      local chosen, verdict = symbols.select_by_build_id(exact, expected)
      if chosen then return selected(chosen, false) end
      if verdict == "no-match" or verdict == "ambiguous" then
        log.notify("dap.android",
          ("no symbols match the %s build (%s); build that configuration, or set "
            .. "ue.config dap.android_symbol_lib explicitly")
            :format(tostring(configuration), verdict),
          vim.log.levels.WARN)
        return nil
      end
      -- 拿不到期望 build-id 时，versionCode 最强只能算弱匹配，并且必须唯一。
      if #exact == 1 then return selected(exact[1], false) end
      log.notify("dap.android",
        ("no unique symbol source for versionCode %s; build the selected configuration, "
          .. "or set ue.config dap.android_symbol_lib explicitly")
          :format(info.version_code),
        vim.log.levels.WARN)
      return nil
    end

    -- 4. 没有 packageInfo 时扫描全部符号包/Intermediate。若当前配置产物提供了
    -- expected build-id，仍只接受 build-id 命中；只有 expected 也拿不到时才按 mtime
    -- 做历史兼容的 best guess。
    local discovered = discover_symbol_packages(android_dir)
    local project_dir = android_dir and fs.norm(vim.fn.fnamemodify(android_dir, ":h:h")) or proot
    local intermediate = {
      project_dir .. "/Intermediate/Android/arm64/jni/arm64-v8a/libUE4.so",
      project_dir .. "/Intermediate/Android/arm64/jni/arm64-v8a/libUnreal.so",
    }
    for _, path in ipairs(intermediate) do
      if fs.is_file(path) then discovered[#discovered + 1] = path end
    end
    if expected then
      local chosen, verdict = symbols.select_by_build_id(discovered, expected)
      if chosen then return selected(chosen, false) end
      log.notify("dap.android",
        ("no symbols match the %s build (%s); build that configuration, or set "
          .. "ue.config dap.android_symbol_lib explicitly")
          :format(tostring(configuration), verdict),
        vim.log.levels.WARN)
      return nil
    end

    local best_path, best_mtime = nil, -1
    for _, path in ipairs(discovered) do
      local st = vim.uv and vim.uv.fs_stat(path)
      local mt = (st and st.mtime and st.mtime.sec) or 0
      if mt > best_mtime then best_path, best_mtime = path, mt end
    end
    if best_path then return selected(best_path, false) end
  end
  -- 5. Last resort: prompt.
  local typed = vim.fn.input("Path to host libUE4.so (with DWARF): ", "", "file")
  if typed == "" then return nil end
  if not fs.is_file(typed) then
    vim.notify("Not a readable file: " .. typed, vim.log.levels.WARN)
    return nil
  end
  return selected(typed, false)
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

-- Asynchronous adb round-trip for interactive attach/launch paths (K53: a
-- synchronous spawn on Windows costs >= 87 ms before adb even connects).
-- done(out, code) runs on the main loop; a spawn failure reports code -1.
local function adb_async(adb, args, done, operation)
  local cmd = { adb }
  vim.list_extend(cmd, args)
  local release = operation and operation.hold()
  local ok, err = pcall(vim.system, cmd, { text = true, timeout = 10000 }, function(res)
    vim.schedule(function()
      local out = ((res and res.stdout) or "") .. ((res and res.code ~= 0 and res.stderr) or "")
      if not operation or operation.current() then done(out:gsub("[\r\n]+$", ""), res and res.code or -1) end
      if release then release() end
    end)
  end)
  if not ok then
    vim.schedule(function()
      if not operation or operation.current() then done(tostring(err), -1) end
      if release then release() end
    end)
  elseif operation then
    operation.resource(function() if err and err.kill then err:kill(15) end end)
  end
end

-- Run adb steps in order without blocking; stops at the first nonzero exit
-- unless the step is marked optional. done(ok, out, code, failed_index).
local function adb_sequence(adb, steps, done, operation)
  local index = 0
  local function nxt()
    index = index + 1
    local step = steps[index]
    if not step then return done(true) end
    adb_async(adb, step.args, function(out, code)
      if code ~= 0 and not step.optional then return done(false, out, code, index) end
      nxt()
    end, operation)
  end
  nxt()
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
local function pidof_async(adb, serial, pkg, timeout_ms, done, operation)
  local timer = vim.uv.new_timer()
  if not timer then
    -- Degenerate fallback: single synchronous probe.
    done(pidof(adb, serial, pkg))
    return
  end
  local deadline = vim.uv.now() + (timeout_ms or 10000)
  local in_flight, finished = false, false
  local release = operation and operation.hold()
  local function finish(pid)
    if finished then return end
    finished = true
    pcall(function() timer:stop() end)
    pcall(function() timer:close() end)
    if not operation or operation.current() then done(pid) end
    if release then release() end
  end
  if operation then operation.resource(function() finish(nil) end) end
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

local function runtime_module_candidates(symbol_lib, runtime_basename)
  local candidates = {}
  local verified = type(runtime_basename) == "string" and runtime_basename ~= ""
    and runtime_basename or nil
  local fallback = symbol_lib and vim.fs.basename(symbol_lib) or UE_MODULE_BASENAME
  -- K66 keeps these identities separate. For a differently named UBT artifact,
  -- runtime_basename comes from its verified ELF DT_SONAME; otherwise preserve
  -- the historical same-basename behavior rather than guessing a device name.
  candidates[1] = verified or fallback
  return candidates
end

local function parse_runtime_module_base(maps, symbol_lib, runtime_basename)
  for _, basename in ipairs(runtime_module_candidates(symbol_lib, runtime_basename)) do
    local base_hex = parse_maps_base_hex(maps, basename)
    if base_hex then return base_hex, basename end
  end
  return nil
end

local function read_so_base_hex(adb, serial, pkg, pid, symbol_lib, runtime_basename)
  if not (adb and serial and pkg and pid and symbol_lib) then return nil end
  local maps = adb_run(adb, {
    "-s", serial, "shell", "run-as", pkg, "cat", "/proc/" .. tostring(pid) .. "/maps",
  })
  return parse_runtime_module_base(maps, symbol_lib, runtime_basename)
end

-- Non-blocking variant used by attach: done(base_hex|nil, runtime_basename|nil).
local function read_so_base_hex_async(adb, serial, pkg, pid, symbol_lib, runtime_basename, done)
  if not (adb and serial and pkg and pid and symbol_lib) then return done(nil) end
  adb_async(adb, {
    "-s", serial, "shell", "run-as", pkg, "cat", "/proc/" .. tostring(pid) .. "/maps",
  }, function(maps, code)
    if code ~= 0 then return done(nil) end
    done(parse_runtime_module_base(maps, symbol_lib, runtime_basename))
  end)
end

-- Build the LLDB command that relocates the symbol-rich host module to the
-- device ASLR base. The command names the HOST module created by `target create`,
-- while the base lookup accepts the distinct APK runtime basename (K66).
-- Returns nil when base resolution failed (caller skips the rebase but does NOT
-- abort the attach).
local function build_module_rebase_command(symbol_lib, base_hex)
  if not symbol_lib or symbol_lib == "" or not base_hex or base_hex == "" then return nil end
  local symbol_basename = vim.fs.basename(symbol_lib)
  if not symbol_basename or symbol_basename == "" then return nil end
  -- Concatenation only — never string.format("%x", ...) for 64-bit addresses.
  return 'target modules load --file "' .. symbol_basename .. '" --slide 0x' .. base_hex
end

local function module_rebase_command(adb, serial, pkg, pid, symbol_lib, runtime_basename)
  if not symbol_lib or symbol_lib == "" then return nil end
  local base_hex, mapped_basename = read_so_base_hex(
    adb, serial, pkg, pid, symbol_lib, runtime_basename)
  if not base_hex then return nil end
  return build_module_rebase_command(symbol_lib, base_hex), base_hex, mapped_basename
end

-- ── L1 传输 + 两跳 staging + platform server → ue.dap._android_transport ──
--
-- 「把 device server 弄到设备上并让它跑起来」整块拆出（design D7）：内部 6 个纯函数
-- 可独立单测，改 staging 不必先读懂 attach 命令序列。K56（app uid 运行）与 K58
-- （run path 复用只能以 app uid 判定）的实证与推理全部随代码搬到该文件。
local transport = require("ue.dap._android_transport").bind({
  adb_run = adb_run,
  adb_run_raw = adb_run_raw,
  shell_quote = shell_quote,
  log = log,
})

-- 保持原有的 local 名字，使下游调用点与测试钩子零改动。
local lldb_server_stage_plan     = transport.lldb_server_stage_plan
local sandbox_stage_plan         = transport.sandbox_stage_plan
local sandbox_lldb_server_path   = transport.sandbox_lldb_server_path
local sandbox_stage_script       = transport.sandbox_stage_script
local platform_server_script     = transport.platform_server_script
local ensure_lldb_server_pushed  = transport.ensure_lldb_server_pushed
local start_lldb_server_platform = transport.start_lldb_server_platform

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
  adb_async(sess.adb, { "-s", sess.serial, "forward", "tcp:" .. port, "jdwp:" .. sess.pid },
    function(fwd_out, fwd_code)
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
  end)
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
  local symbol_so = sess.symbol_lib and vim.fs.basename(sess.symbol_lib) or UE_MODULE_BASENAME
  local runtime_names = runtime_module_candidates(sess.symbol_lib, sess.runtime_module_basename)
  local pid, serial, pkg, adb = sess.pid, sess.serial, sess.package_name, sess.adb
  local attempts, in_flight = 0, false
  local max_attempts = 90 -- × 700ms ≈ 63s of app init budget
  local timer = vim.uv.new_timer()
  if not timer then return end
  M._late_rebase_timer = timer

  local function finish_with_base(base_hex, runtime_so)
    local ok_dap, dap = pcall(require, "dap")
    local session = ok_dap and dap and dap.session and dap.session() or nil
    if not session then return end
    sess._runtime_module_basename = runtime_so
    -- Concatenation only — never string.format("%x") on 64-bit values (P7/K4).
    -- Rebase the host symbol module at the base found under the APK runtime name.
    local cmd = 'target modules load --file "' .. symbol_so .. '" --slide 0x' .. base_hex
    append_bp_diag({
      "== late ASLR rebase (wait-mode) ==",
      "runtime_module=" .. tostring(runtime_so),
      cmd,
    })
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
        (("none of [%s] appeared in /proc/%%d/maps within ~60s of launch — ")
          :format(table.concat(runtime_names, ", "))
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
          local base, runtime_so
          if res and res.code == 0 then
            base, runtime_so = parse_runtime_module_base(
              res.stdout or "", sess.symbol_lib, sess.runtime_module_basename)
          end
          if base then
            M._stop_late_rebase_poller()
            finish_with_base(base, runtime_so)
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

-- ── L3 引擎命令序列 / attach 配置 → ue.dap._android_engine ────────────────
--
-- 「对 lldb 说什么、按什么顺序说」整块拆出（design D7）。该文件零 adb 调用，
-- 却承载最密集的时序契约（K3 信号处置 → K11/K37 slide → K60 符号断点；K57 禁裸
-- script）。改命令序列前请读该文件顶部的顺序契约说明。
local engine = require("ue.dap._android_engine").bind({
  log = log,
  find_engine_root_from_cwd = find_engine_root_from_cwd,
})

-- 保持原有 local 名字，使下游调用点与测试钩子零改动。
local init_commands       = engine.init_commands
local attach_commands     = engine.attach_commands
local post_run_commands   = engine.post_run_commands
local lldb_dap_attach_config = engine.lldb_dap_attach_config
local current_breakpoint_commands = engine.current_breakpoint_commands
local preseed_breakpoints_into_attach_commands = engine.preseed_breakpoints_into_attach_commands

-- ── public: stop / cleanup ────────────────────────────────────────────────

function M.stop_android_debugger(opts)
  opts = opts or {}
  local stopped_session = M._session
  local operation = stopped_session._operation
  if operation and not operation.cancelled
      and (not operation.finished or (operation.code ~= 0 and operation.pending > 0)) then
    if operation.finished then operation.abort("failed attempt stopped") else operation.cancel("debugger stopped") end
    return { disconnected = false, adapter_killed = false, orphan_killed = 0, cancellation_requested = true }
  end
  M._cleanup_in_progress = true
  local result = { disconnected = false, adapter_killed = false, orphan_killed = 0 }

  -- Stop the liveness poller FIRST so it can't race with reset_session.
  if M._stop_liveness_poller then pcall(M._stop_liveness_poller) end
  pcall(function()
    local dap = require("dap")
    if dap.listeners and dap.listeners.after and dap.listeners.after.attach then
      dap.listeners.after.attach[ATTACH_RESULT_LISTENER_KEY] = nil
    end
  end)
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
    if M._session ~= stopped_session then return end
    M._cleanup_device_side()
    result.adapter_killed = sess_active ~= nil
    reset_session()
    M._attach_in_progress = false
    M._cleanup_in_progress = false
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
  -- Stop the host-side `adb shell run-as ... lldb-server platform` job we
  -- spawned via jobstart. Killing the adb client closes the shell, which the
  -- device propagates to lldb-server.
  --
  -- The id lives on the transport module (that is where the spawn happens).
  -- `M._lldb_server_jobid` is kept as a read-only mirror for :UEDAPDiag and for
  -- any external caller that used to read it — cleanup MUST clear the owning
  -- field, or the device keeps a live server holding the port (K56 notes the
  -- residue then silently reintroduces the shell-uid SEGV path).
  local jobid = transport.lldb_server_jobid
  if jobid and jobid > 0 then
    pcall(vim.fn.jobstop, jobid)
    transport.lldb_server_jobid = nil
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
  complete_operation(M._session, 1, { stage = "attach", reason = "debug session ended before attach completed" })
  if M._stop_liveness_poller then pcall(M._stop_liveness_poller) end
  snapshot_last_session()
  M._cleanup_device_side()
  reset_session()
  M._attach_in_progress = false
  M._cleanup_in_progress = false
  return { device_cleaned = true }
end

-- ── L0–L4 能力探针 / probe context → ue.dap._android_policy ───────────────
--
-- L2（目标 OS 策略）已拆到 `_android_policy.lua`：它是 34 条 DAP 坑里占 9 条的那一层，
-- 独立成文件后可单独审阅与测试，且新增设备策略探针不必先读懂 attach 编排。
-- 依赖以注入方式给出（不让 policy 反向 require 本模块，避免循环依赖）。
-- ── 带层归属的失败上报（C10：失败先报层，再给处置）────────────────────────
--
-- 每个用户可见的失败都必须能回答「这是哪一层的问题、谁负责、证据是什么」。
-- 之前这些点只发裸文本（`P.error("lldb-server bootstrap failed: …")`），读者无法
-- 判断该找设备、找 lldb、还是找我们——那正是每月现场取证的起点。
local function report_failure(spec)
  local F = require("ue.dap.failure")
  local P = require("ue.dap._progress")
  local fail = F.new(spec)
  local operation = M._session._operation
  if operation then operation.failure = fail end
  local text = F.format(fail)
  P.error(spec.headline or spec.summary or "attach failed")
  -- A failure with a concrete command fix is offered as one keypress
  -- (<leader>uk) instead of only text the user has to retype.
  if spec.fix then
    require("utils.ue_hub").offer_fix(spec.fix, spec.headline)
    text = text .. "\n→ <leader>uk runs :" .. spec.fix
  end
  log.notify_error("dap.android", text)
  -- Field evidence for the report-first loop: which layer blocks real attaches.
  pcall(function()
    require("utils.probe").record("android-attach",
      ("fail:%s:%s"):format(tostring(fail.layer or spec.layer), tostring(spec.headline or "?")),
      { owner = spec.owner, serial = M._session and M._session.serial })
  end)
  return fail
end

local policy = require("ue.dap._android_policy").bind({
  shell_quote = shell_quote,
  sandbox_lldb_server_path = sandbox_lldb_server_path,
  session = function() return M._session end,
  last_session = function() return M._last_session end,
})

--- 本 target 的能力探针集合（委派给 policy 层）。
function M.capability_probes()
  return policy.capability_probes()
end

--- 本 target 的 probe context 富化（委派给 policy 层）。
function M.probe_context(ctx)
  return policy.probe_context(ctx)
end

-- ── public: attach / launch ───────────────────────────────────────────────

local function bootstrap_session(opts, on_ready)
  opts = opts or {}
  -- Never write session choices back into resolve_context()'s cached table:
  -- doing so would pin the first serial in ctx.android_serial and make a later
  -- :UESetAndroidDevice switch lose to that stale "explicit" value.
  local ctx = vim.tbl_extend("force", {}, opts.context or {})
  ctx._frozen = opts.owner ~= nil
  ctx.configuration = opts.configuration or ctx.configuration
  ctx.target = opts.target or ctx.target
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
  -- Leave it nil when no explicit source is known so pick_symbol_lib consumes
  -- the current target/configuration and artifact identity. Normal attach MUST
  -- NOT replay `_last_session.symbol_lib`; only reattach freezes and reuses the
  -- previous session explicitly.
  ctx.android_symbol_lib = ctx.android_symbol_lib or ctx.symbol_lib or opts.symbol_lib
    or opts.android_symbol_lib
  local P = require("ue.dap._progress")

  local sess = M._session
  local operation = sess._operation
  sess.adb  = "adb"
  sess.port = pick_port()
  sess.engine_root = ctx and ctx.engine_root or nil
  sess.project_root = ctx.project_root
  sess.target, sess.configuration = ctx.target, ctx.configuration

  P.step("1/6  picking package …")
  local pkg = pick_package(ctx)
  sess.package_name = pkg

  P.step("2/6  picking device …")
  if ctx and ctx.android_serial then
    sess.serial = ctx.android_serial
  end

  local function after_serial(serial)
    if not current_operation(sess) then return end
    if not serial then
      report_failure({
        layer = require("ue.dap.failure").L.TRANSPORT,
        owner = "utils.android_device",
        headline = "no device selected",
        summary = "no Android device was selected for this session",
        remedy = "run :UESetAndroidDevice and pick a ready device",
        fix = "UESetAndroidDevice",
      })
      on_ready(false, -1); return
    end
    sess.serial = serial
    if not sess.package_name then
      -- No persisted/config/cook package: pick from the device's installed
      -- packages instead of a blank prompt, then remember it for this project.
      local release = operation and operation.hold()
      return require("utils.android_package").pick({ adb = sess.adb, serial = serial,
        prompt = "Android package to debug:" }, function(picked)
        if not current_operation(sess) then if release then release() end; return end
        if not picked then
          P.hide()
          if release then release() end
          return on_ready(false, -1)
        end
        sess.package_name = picked
        local engine_root = ctx and ctx.engine_root
        if engine_root then
          pcall(function() require("ue").update_state_field(engine_root, "android_package", picked) end)
        end
        after_serial(serial)
        if release then release() end
      end)
    end

    P.step("3/6  locating lldb-server …")
    local server_src = pick_lldb_server()
    if not server_src then P.hide(); on_ready(false); return end
    sess.lldb_server_local = server_src

    P.step("4/6  picking symbol lib …")
    local sym, runtime_basename, symbol_version_code = pick_symbol_lib(ctx)
    if not sym then P.hide(); on_ready(false); return end
    sess.symbol_lib = sym
    sess.runtime_module_basename = runtime_basename
    sess.symbol_version_code = symbol_version_code

    sess.source_map = pick_source_map(ctx)

    P.step("5/6  pushing lldb-server to device …")
    local ok_push, push_msg = ensure_lldb_server_pushed(sess.adb, serial, sess.package_name, server_src)
    if not ok_push then
      -- The selected device was unplugged: re-selecting is the fix, not preflight.
      if android_device.is_gone_output(push_msg) then
        -- The selected device is unplugged, not a staging defect: the layer
        -- owner changes and re-selecting (not preflight) is the fix.
        report_failure({
          layer = require("ue.dap.failure").L.TRANSPORT,
          owner = "utils.android_device",
          headline = "device " .. tostring(serial) .. " is not connected",
          summary = "the selected device was gone before the debug server could be staged",
          evidence = require("ue.dap.failure").observed_evidence("staging", tostring(push_msg)),
          remedy = "reconnect it or run :UESetAndroidDevice to pick another device",
          fix = "UESetAndroidDevice",
        })
        on_ready(false); return
      end
      report_failure({
        layer = require("ue.dap.failure").L.TRANSPORT,
        owner = "dap.android (staging transport)",
        headline = "lldb-server bootstrap failed",
        summary = "could not stage the debug server onto the device",
        evidence = require("ue.dap.failure").observed_evidence("staging", tostring(push_msg)),
        remedy = "run :UEDAPPreflight to see which layer blocks, then re-try the attach",
        fix = "UEDAPPreflight",
      })
      on_ready(false); return
    end
    sess.remote_lldb_server = push_msg
    sess.lldb_server_mode = "platform"

    on_ready(true)
  end

  if sess.serial then
    after_serial(sess.serial)
  else
    local release = operation and operation.hold()
    pick_serial_async(sess.adb, function(serial)
      after_serial(serial)
      if release then release() end
    end)
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
  if not current_operation(sess) then return end
  local P = require("ue.dap._progress")
  sess.pid = pid
  sess.lldb_server_mode = "platform"
  if sess._operation then sess._operation.stage("attach", { state = "running", pid = pid }) end

  -- The gate is async (P6) and deliberately fail-open: only an explicit denial
  -- blocks. See preflight.blocks_attach — undetermined never blocks.
  M._gate_then_start(sess, function()
    M._finalize_session_after_gate(sess, pid, cfg_name, run_label)
  end)
end

--- Run the L2 subset of the capability probes, then continue or refuse.
--- Split out so the gate itself stays testable without a device.
---
--- `opts.executor` exists for regression only: the gate's whole point is that it
--- runs BEFORE any engine connection, and the only way to assert "no connection
--- was initiated" without a device is to drive the probes from recorded output.
--- Production callers pass nothing and get the real async executor.
function M._gate_then_start(sess, continue_fn, opts)
  if not current_operation(sess) then return end
  local preflight = require("ue.dap.preflight")
  local F = require("ue.dap.failure")
  local P = require("ue.dap._progress")
  opts = opts or {}

  if preflight.skipped() then
    -- Escape-hatch trace: without this flag a later failure cannot tell the user
    -- the gate was bypassed, and the next forensics round is misled into
    -- believing the gate cleared this attempt.
    sess._preflight_skipped = true
    return continue_fn()
  end

  local l2 = {}
  for _, d in ipairs(M.capability_probes()) do
    if d.layer == F.L.TARGET_POLICY then l2[#l2 + 1] = d end
  end

  P.step("checking target OS policy (L2) …")
  local release = sess._operation and sess._operation.hold()
  preflight.run({
    probes = l2,
    executor = opts.executor,
    ctx = {
      adb = sess.adb, serial = sess.serial,
      package_name = sess.package_name, pid = sess.pid,
    },
    on_done = function(report)
      if not current_operation(sess) then if release then release() end; return end
      if not preflight.blocks_attach(report) then
        continue_fn()
        if release then release() end
        return
      end
      local fail = preflight.blocking_failure(report)
      local text = F.format(fail)
      sess._gate_refusal = text
      P.error("attach refused at L2 (target OS policy)")
      log.notify_error("dap.android",
        "attach refused before connecting the debug engine:\n" .. text
        .. "\n(run :UEDAPPreflight for all layers; UE_DAP_SKIP_PREFLIGHT=1 overrides)")
      M._attach_in_progress = false
      complete_operation(sess, 1, fail)
      M.stop_android_debugger()
      if opts.on_refused then opts.on_refused(fail, text) end
      if release then release() end
    end,
  })
end

function M._finalize_session_after_gate(sess, pid, cfg_name, run_label)
  if not current_operation(sess) then return end
  local P = require("ue.dap._progress")

  P.step(("starting lldb-server platform (port=%d) …"):format(sess.port))
  local ok_srv, srv_err = start_lldb_server_platform(
    sess.adb, sess.serial, sess.port, sess.package_name, sess.remote_lldb_server)
  -- Mirror the spawn id onto the owner so :UEDAPDiag and legacy readers keep
  -- seeing it; the transport module remains the authority for cleanup.
  M._lldb_server_jobid = transport.lldb_server_jobid
  if not ok_srv then
    report_failure({
      layer = require("ue.dap.failure").L.DEBUG_ENGINE,
      owner = "dap.android (device platform server)",
      headline = "lldb-server platform failed",
      summary = "the device-side platform server did not start",
      evidence = require("ue.dap.failure").observed_evidence("server start", tostring(srv_err)),
      remedy = "run :UEDAPPreflight; a target-policy denial at L2 is the usual cause",
      fix = "UEDAPPreflight",
    })
    complete_operation(sess, 1)
    M.stop_android_debugger()
    return
  end

  P.step("attaching …")

  -- Compute the libUE4.so ASLR rebase command BEFORE building the attach config
  -- (attach_commands appends it). Failure is non-fatal: log + continue so a
  -- maps-read hiccup never blocks attach. The actual `target modules load
  -- --slide` runs inside attachCommands, right after signal disposition.
  sess._module_rebase_cmd = nil
  if not (sess.symbol_lib and sess.symbol_lib ~= "") then
    return M._finalize_attach_config(sess, pid, cfg_name, run_label)
  end
  -- Read /proc/<pid>/maps asynchronously so the editor stays responsive while
  -- the adb round-trip runs; the attach config is built once it returns.
  read_so_base_hex_async(sess.adb, sess.serial, sess.package_name, pid, sess.symbol_lib,
    sess.runtime_module_basename, function(base_hex, runtime_so)
    if not current_operation(sess) then return end
    local rebase_cmd = build_module_rebase_command(sess.symbol_lib, base_hex)
    if rebase_cmd then
      sess._module_rebase_cmd = rebase_cmd
      sess._runtime_module_basename = runtime_so
      P.step(("module base resolved: %s -> %s @ 0x%s"):format(
        vim.fs.basename(sess.symbol_lib), tostring(runtime_so), base_hex))
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
        "ASLR base unresolved for runtime candidates ["
        .. table.concat(runtime_module_candidates(
          sess.symbol_lib, sess.runtime_module_basename), ", ")
        .. "]; breakpoints may not resolve (continuing attach)",
        vim.log.levels.WARN)
    end
    M._finalize_attach_config(sess, pid, cfg_name, run_label)
  end)
end

function M._finalize_attach_config(sess, pid, cfg_name, run_label)
  if not current_operation(sess) then return end
  local cfg = lldb_dap_attach_config(sess, sess.source_map)
  cfg.name = cfg_name
  cfg._ue_session_owner = "android"
  cfg._ue_session_operation = cfg_name:find("Launch", 1, true) and "launch" or "attach"
  cfg._ue_device_id = sess.serial
  cfg._ue_process_id = pid
  cfg._ue_operation_id = sess._operation and sess._operation.id
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
  sess.attach_succeeded = false
  pcall(function()
    local dap = require("dap")
    dap.listeners.after.attach[ATTACH_RESULT_LISTENER_KEY] = function(session, err)
      local config = session and session.config or nil
      if not config or config._ue_session_owner ~= "android"
        or tonumber(config._ue_process_id) ~= tonumber(pid)
        or config._ue_operation_id ~= cfg._ue_operation_id or not current_operation(sess) then
        return
      end
      dap.listeners.after.attach[ATTACH_RESULT_LISTENER_KEY] = nil
      M._attach_in_progress = false
      if err then
        complete_operation(sess, 1, { stage = "attach", reason = err.message or tostring(err) })
        M.stop_android_debugger()
        return
      end
      sess.attach_succeeded = true
      snapshot_last_session()
      if sess._operation then sess._operation.stage("attach", { state = "done", pid = pid }) end
      complete_operation(sess, 0, { stage = "attach", reason = "attach response succeeded", pid = pid })
      pcall(function() require("ue.dap._progress").done("debugger attached") end)
      pcall(function()
        require("utils.probe").record("android-attach", "ok:" .. tostring(cfg._ue_session_operation),
          { state = "ok", serial = sess.serial, symbols = sess.symbol_lib and "yes" or "no",
            rebase = sess._module_rebase_cmd and "yes" or (sess.wait_mode and "late" or "no") })
      end)
    end
  end)
  local started = C.run(cfg, run_label, nil, nil, {
    -- nvim-dap's run opts.after is a no-argument close callback, not a
    -- session-start callback. It also covers adapter death without an event.
    after = function()
      vim.schedule(function()
        if current_operation(sess) and not sess.attach_succeeded then
          complete_operation(sess, 1, { stage = "attach", reason = "adapter closed before attach response" })
          M.stop_android_debugger()
        end
      end)
    end,
  })
  if not started then
    complete_operation(sess, 1, { stage = "attach", reason = "DAP adapter could not start" })
    M.stop_android_debugger()
    return
  end
  -- Progress popup finalized by ue.dap.lua's event_initialized listener
  -- (P.done) or by stop_android_debugger / on_session_end (P.hide).
  -- If the adapter exits before nvim-dap installs/keeps a session (observed
  -- with a broken device-side attach), the normal
  -- session-end listeners may not get a chance to clear our bootstrap flag.
  -- Release the mutex after a short grace window when there is no live DAP
  -- session, so the next <space>da is a real retry instead of a stale-block.
  vim.defer_fn(function()
    if not current_operation(sess) then return end
    if not M._attach_in_progress then return end
    local ok_dap, dap = pcall(require, "dap")
    local has_session = ok_dap and dap and dap.session and dap.session() or nil
    if not has_session then
      M._attach_in_progress = false
      complete_operation(sess, 1, { stage = "attach", reason = "no live DAP session after adapter start" })
      M.stop_android_debugger()
      pcall(function() require("ue.dap._progress").hide() end)
    end
  end, 10000)
end

local function reject_operation(opts, reason)
  vim.notify("[ue.dap.android] " .. reason, vim.log.levels.WARN)
  if type(opts.on_complete) == "function" then
    opts.on_complete(-1, { owner = opts.owner, stage = "launch", reason = reason })
  end
  return nil, reason
end

local function can_begin_operation()
  if M._cleanup_in_progress then return false, "debug cleanup is still in progress" end
  local operation = M._session._operation
  if operation and (not operation.finished or operation.pending > 0 or (operation.cancelled and not operation.cleaned)) then
    return false, "attach already in progress; wait or stop the current attempt"
  end
  local ok, dap = pcall(require, "dap")
  if ok and dap.session and dap.session() then return false, "DAP session already active; :UEDAPStop first" end
  return true
end

function M.attach(opts)
  opts = vim.deepcopy(opts or {})
  local ready, reason = can_begin_operation()
  if not ready then return reject_operation(opts, reason) end
  M._attach_in_progress = true
  local operation = M._begin_operation(opts)
  local sess = M._session
  operation.stage("attach", { state = "running" })
  bootstrap_session(opts, function(ok, code)
    if not current_operation(sess) then return end
    if not ok then
      complete_operation(sess, code or 1, { stage = "attach", reason = "debug attach setup failed", failure = operation.failure })
      M.stop_android_debugger()
      return
    end
    local P = require("ue.dap._progress")
    P.step("6/6  finding pid for " .. (sess.package_name or "?") .. " …")
    pidof_async(sess.adb, sess.serial, sess.package_name, 2500, function(pid)
      if not pid then
        report_failure({
          layer = require("ue.dap.failure").L.TARGET_POLICY,
          owner = "dap.android (Android target policy)",
          headline = "target process is not running",
          summary = "the application has no live process to attach to",
          evidence = require("ue.dap.failure").command_evidence(
            { "<adb>", "shell", "pidof", "-s", "<package>" }, nil, "no pid returned"),
          remedy = "start the app first, or use :UEDAPLaunch for wait-for-debugger launch",
          fix = "UEDAPLaunch",
        })
        complete_operation(sess, 1)
        M.stop_android_debugger()
        return
      end
      _finalize_session(sess, pid, "UE Android Attach (lldb-dap)", "UEDAP android attach")
      M._start_liveness_poller()
    end, operation)
  end)
  return operation.handle
end

function M.launch(opts)
  opts = vim.deepcopy(opts or {})
  local ready, reason = can_begin_operation()
  if not ready then return reject_operation(opts, reason) end
  M._attach_in_progress = true
  local operation = M._begin_operation(opts)
  local sess = M._session
  operation.stage("launch", { state = "running" })
  -- Fresh session → failures should be reported once again (the dedup is
  -- per-session, not forever).
  M._wait_notice_seen = {}
  bootstrap_session(opts, function(ok, code)
    if not current_operation(sess) then return end
    if not ok then
      complete_operation(sess, code or 1, { stage = "launch", reason = "debug launch setup failed", failure = operation.failure })
      M.stop_android_debugger()
      return
    end
    local P = require("ue.dap._progress")
    local pkg = sess.package_name or "?"
    local steps = wait_launch_device_steps(sess.package_name)
    -- Set before sending the command so every cancellation/failure clears it.
    sess.wait_mode = true

    -- Android-Studio-debug-button semantics: freeze the app at the JDWP
    -- "Waiting for debugger" gate from the very first instruction, attach
    -- lldb while NOTHING of the app has run, then release the gate after
    -- the user's first continue. Catches earliest-init crashes that the
    -- old "start, then attach when pid appears" flow always missed.
    P.step("6/6  set-debug-app -w " .. pkg .. " …")
    local on_serial = function(args) return vim.list_extend({ "-s", sess.serial }, args) end
    adb_sequence(sess.adb, {
      { args = on_serial(steps.force_stop), optional = true },
      { args = on_serial(steps.set_wait) },
    }, function(armed, sd_out, sd_code)
    if not current_operation(sess) then return end
    if not armed then
      -- User policy: fail with a recorded reason, do NOT silently fall back.
      -- L2: the debug-app gate is an Android policy mechanism; a non-debuggable
      -- build is a policy denial, not a debugger defect.
      report_failure({
        layer = require("ue.dap.failure").L.TARGET_POLICY,
        owner = "dap.android (wait-for-debugger launch)",
        headline = "am set-debug-app failed",
        summary = "the device refused to arm the debug-app gate",
        evidence = require("ue.dap.failure").command_evidence(
          { "<adb>", "shell", "am", "set-debug-app", "-w", "<package>" },
          sd_code, tostring(sd_out)),
        remedy = "confirm the installed build is debuggable, or use :UEDAPAttach on a "
          .. "running process instead",
      })
      wait_notice("set-debug-app",
        ("am set-debug-app -w %s failed (exit %s): %s — wait-for-debugger launch aborted. "
          .. "Is the app debuggable? Use :UEDAPAttach for a running process instead.")
          :format(pkg, tostring(sd_code), tostring(sd_out)),
        vim.log.levels.ERROR)
      complete_operation(sess, 1)
      M.stop_android_debugger()
      return
    end

    P.step("starting activity (waiting at debugger gate) …")
    adb_async(sess.adb, on_serial(steps.start), function(start_out, start_code)
    if start_code ~= 0 then
      report_failure({
        layer = require("ue.dap.failure").L.TARGET_POLICY,
        owner = "dap.android (wait-for-debugger launch)",
        headline = "application activity did not start",
        evidence = require("ue.dap.failure").command_evidence(steps.start, start_code, start_out),
        remedy = "check the installed package and launch activity with :UEDAPPreflight",
      })
      complete_operation(sess, 1)
      M.stop_android_debugger()
      return
    end

    -- Async pid poll (F4): does not freeze user input while the process spawns.
    pidof_async(sess.adb, sess.serial, sess.package_name, 10000, function(pid)
      -- One-shot: clear the debug-app flag as soon as the process exists (or
      -- we give up), so a later manual launch of the app is NOT gated. The
      -- already-spawned process keeps waiting regardless.
      if not pid then
        report_failure({
          layer = require("ue.dap.failure").L.TARGET_POLICY,
          owner = "dap.android (wait-for-debugger launch)",
          headline = ("%s did not start within 10s"):format(pkg),
          summary = "the application never appeared after the debug-app gate was armed",
          remedy = "confirm the app is debuggable and launchable; see ue-dap-bp-diag.log",
        })
        wait_notice("wait-launch-no-pid",
          ("%s did not appear within 10s after set-debug-app -w + start "
            .. "(serial=%s). See ue-dap-bp-diag.log."):format(pkg, sess.serial),
          vim.log.levels.ERROR)
        complete_operation(sess, 1)
        M.stop_android_debugger()
        return
      end

      adb_async(sess.adb, on_serial(steps.clear_wait), function(clear_out, clear_code)
        if clear_code ~= 0 then
          complete_operation(sess, 1, { stage = "launch", reason = "debug-app gate could not be cleared", evidence = clear_out })
          M.stop_android_debugger()
          return
        end
        operation.stage("launch", { state = "done", pid = pid })
        _finalize_session(sess, pid, "UE Android Launch (wait-for-debugger)", "UEDAP android launch")
        arm_wait_mode_followup(sess)
        M._start_liveness_poller()
        vim.notify(
        "[ue.dap.android] launched " .. pkg .. " frozen at the debugger gate.\n"
        .. "Set breakpoints, then F5: the JDWP gate is released automatically and\n"
        .. "the earliest engine init runs under the debugger.",
        vim.log.levels.INFO)
      end, operation)
    end, operation)
    end, operation)
    end, operation)
  end)
  return operation.handle
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
  sess.runtime_module_basename = last.runtime_module_basename
  sess.symbol_version_code = last.symbol_version_code
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
      report_failure({
        layer = require("ue.dap.failure").L.TARGET_POLICY,
        owner = "dap.android (Android target policy)",
        headline = "target process did not appear within 10s",
        summary = "reattach timed out waiting for the application process",
        remedy = "start the app, then run :UEDAPReattach again",
      })
      M._attach_in_progress = false
      return
    end

    -- Ensure lldb-server is still in the sandbox (Android may have cleared
    -- /data/data/<pkg> on user-data wipe / reinstall).
    local ok_push, push_msg = ensure_lldb_server_pushed(
      sess.adb, sess.serial, sess.package_name, sess.lldb_server_local)
    if not ok_push then
      report_failure({
        layer = require("ue.dap.failure").L.TRANSPORT,
        owner = "dap.android (staging transport)",
        headline = "lldb-server re-stage failed",
        summary = "could not re-stage the debug server for reattach",
        evidence = require("ue.dap.failure").observed_evidence("staging", tostring(push_msg)),
        remedy = "run :UEDAPPreflight to identify the blocking layer",
      })
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

--- Symbol library for the current build (build-id authority, K64/K65/K66).
--- Returns (path, runtime_basename, version_code) or nil.
function M.symbol_lib(ctx)
  return pick_symbol_lib(ctx)
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

function M._runtime_module_candidates_for_test(symbol_lib, runtime_basename)
  return runtime_module_candidates(symbol_lib, runtime_basename)
end

function M._parse_runtime_module_base_for_test(maps, symbol_lib, runtime_basename)
  return parse_runtime_module_base(maps, symbol_lib, runtime_basename)
end

function M._adb_sequence_for_test(adb, steps, done)
  return adb_sequence(adb, steps, done)
end

function M._read_so_base_hex_async_for_test(...)
  return read_so_base_hex_async(...)
end

function M._build_module_rebase_command_for_test(symbol_lib, base_hex)
  return build_module_rebase_command(symbol_lib, base_hex)
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
