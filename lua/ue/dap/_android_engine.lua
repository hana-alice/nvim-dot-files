-- ue.dap._android_engine — Android 的 L3 调试引擎层：lldb-dap 命令序列与 attach 配置。
--
-- 为何单独成文件（design D7；层契约见 docs/CONSTRAINTS.md §三 C10 与
-- openspec/specs/dap-failure-layering/spec.md）：
-- 这一块是「对 lldb 说什么、按什么顺序说」的全部知识，也是 34 条坑里 L3 占 10 条的
-- 那一层（K30/K31/K32 连接形态、K11/K37 slide 时序、K3 信号处置、K57 禁裸 script）。
-- 它几乎不碰设备（零 adb 调用），却承载最密集的**时序**约束，因此独立成文件后
-- 改命令序列不必先读懂 staging 与 session 生命周期。
-- 命名沿用本目录既有的 `_ios_*.lua` 平铺约定。
--
-- ⚠️ 本文件的顺序即契约，改动前务必读：
--   * signal disposition 必须在 slide 之前（K3 + K37）
--   * slide 必须在 attach 命令序列内、先于 setBreakpoints（K11）
--   * 符号断点排在 slide 之后（模块重定位后才解析，K60）
--   * 禁止发裸 `script`（K57：22.1.6 pin 上直接打崩 adapter）
--
-- 依赖注入（不反向 require owner，避免循环依赖）。

local M = {}

-- Shared, target-agnostic adapter plumbing (adapter resolution + env sanitation).
-- Required directly rather than injected: it is not target knowledge, and both
-- this module and the owner legitimately depend on it.
local C = require("ue.dap._common")

local deps = {
  log = nil,                       -- utils.log 兼容对象
  find_engine_root_from_cwd = nil, -- fun(): string|nil
}

function M.bind(overrides)
  for key, value in pairs(overrides or {}) do
    assert(deps[key] ~= nil or key ~= nil, "unknown engine dependency: " .. tostring(key))
    deps[key] = value
  end
  return M
end

function M.init_commands(session)
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
  if not er or er == "" then er = deps.find_engine_root_from_cwd() end
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
          vim.deps.log.levels.WARN)
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
        vim.deps.log.levels.INFO)
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
function M.attach_commands(session)
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
function M.post_run_commands(session)
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

function M.current_breakpoint_commands()
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

function M.preseed_breakpoints_into_attach_commands(cfg)
  if not cfg or type(cfg.attachCommands) ~= "table" then return end
  local cmds = M.current_breakpoint_commands()
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

function M.lldb_dap_attach_config(session, source_map)
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
    initCommands   = M.init_commands(session),
    attachCommands = M.attach_commands(session),
    postRunCommands = M.post_run_commands(session),
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

return M
