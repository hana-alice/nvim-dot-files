-- ue.dap._android_transport — Android 的 L1 传输层 + 两跳 staging + platform server 启动。
--
-- 为何单独成文件（design D7；层契约见 docs/CONSTRAINTS.md §三 C10 与
-- openspec/specs/dap-failure-layering/spec.md）：
-- 这一块是「把 device server 弄到设备上并让它跑起来」的完整职责，内部有 6 个纯字符串
-- / 纯判定函数（可独立单测）加一条 staging 编排。从 2700 行的 owner 里拆出来后，
-- 改 staging 不必先读懂 attach 命令序列与 session 生命周期。
-- 命名沿用本目录既有的 `_ios_*.lua` 平铺约定。
--
-- 本文件承载 target 命令字面量（adb / run-as / chmod / killall）是**有意的**：
-- 通用层出现它们会被 ue_platform_boundary 判为 target_policy_literal。
--
-- 依赖注入（不反向 require owner，避免循环依赖）：adb 执行器、shell 引用、日志。

local M = {}

local deps = {
  adb_run = nil,      -- fun(adb, args): string           （失败返回空串）
  adb_run_raw = nil,  -- fun(adb, args): string, integer  （返回输出与退出码）
  shell_quote = nil,  -- fun(string): string
  log = nil,          -- utils.log 兼容对象（需 .warn）
}

--- 由 owner 注入依赖。值必须可调用/为表，拼错键即 assert（不得静默失效）。
function M.bind(overrides)
  for key, value in pairs(overrides or {}) do
    assert(deps[key] ~= nil or key ~= nil, "unknown transport dependency: " .. tostring(key))
    deps[key] = value
  end
  return M
end

-- 由 owner 读写：platform server 的 jobstart id（收尾清理需要它）。
M.lldb_server_jobid = nil

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
function M.lldb_server_stage_plan(size_matches, is_executable)
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
function M.sandbox_stage_plan(size_matches, is_executable)
  if size_matches and is_executable then return "reuse" end
  return "restage"
end

-- Pure helper (unit-tested): the in-sandbox path the app-uid platform server
-- runs from. `run-as <pkg>` lands in /data/data/<pkg> (== /data/user/0/<pkg>).
function M.sandbox_lldb_server_path(pkg)
  if type(pkg) ~= "string" or pkg == "" then return nil end
  return "/data/data/" .. pkg .. "/lldb-server"
end

-- Pure helper (unit-tested): the device-side `sh -c` body that copies the
-- PUBLIC transport copy into the app sandbox and marks it executable.
-- `cat > dst` (not `cp`) because the app uid may not read /data/local/tmp
-- metadata for `cp -p`, and toybox `cp` across that boundary has historically
-- failed with EACCES on this device class.
function M.sandbox_stage_script(public_path, sandbox_path)
  return ("cat %s > %s && chmod 700 %s")
    :format(public_path, sandbox_path, sandbox_path)
end

-- Pure helper (unit-tested): the device-side `sh -c` body that starts the
-- APP-UID platform server from the sandbox copy.
-- The listen wildcard is DOUBLE-QUOTED ("*:N") so the device shell cannot glob
-- it against the sandbox directory contents — `cd`-ing into /data/data/<pkg>
-- first means a bare `*` would expand to the first filename there (K30 note
-- documented the same hazard for the /data/local/tmp form).
function M.platform_server_script(sandbox_path, port)
  return ('%s platform --server --listen "*:%d"'):format(sandbox_path, port)
end

function M.ensure_lldb_server_pushed(adb, serial, pkg, src)
  local local_size = vim.fn.getfsize(src)
  if local_size <= 0 then
    return false, "lldb-server source not readable: " .. tostring(src)
  end

  local remote = "/data/local/tmp/lldb-server"
  local remote_size = deps.adb_run(adb, { "-s", serial, "shell", "stat", "-c", "%s", remote })
  local size_matches = tostring(remote_size):match("(%d+)%s*$") == tostring(local_size)
  local function remote_is_executable()
    local _, code = deps.adb_run_raw(adb, { "-s", serial, "shell", "test", "-x", remote })
    return code == 0
  end

  local plan = M.lldb_server_stage_plan(size_matches, size_matches and remote_is_executable())

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
    local push_out, push_code = deps.adb_run_raw(adb, { "-s", serial, "push", src, remote })
    if push_code ~= 0 then
      return false, ("adb push failed on %s (exit %s): %s")
        :format(tostring(serial), tostring(push_code), tostring(push_out))
    end
  end

  if not skip_transport then
    local chmod_out, chmod_code = deps.adb_run_raw(adb, { "-s", serial, "shell", "chmod", "755", remote })
    if chmod_code ~= 0 then
      -- chmod can EPERM on files we do not own. That is only fatal when the
      -- binary is genuinely not executable; otherwise log once and proceed.
      if remote_is_executable() then
        deps.log.warn("dap.android",
          "chmod lldb-server EPERM (not owner) but binary already executable — proceeding: "
          .. tostring(chmod_out))
      else
        return false, ("chmod lldb-server failed on %s (exit %s): %s")
          :format(tostring(serial), tostring(chmod_code), tostring(chmod_out))
      end
    end
    local check = deps.adb_run(adb, { "-s", serial, "shell", "ls", remote })
    if not check:match("lldb%-server") then
      return false, "lldb-server not present after push"
    end
  end

  -- Hop 2 (K56): copy the PUBLIC transport binary into the app sandbox so the
  -- platform server can run AS THE APP UID. See the block comment above for
  -- the measured evidence that a shell-uid server cannot ptrace the app on
  -- this build (its forked gdbserver SIGSEGVs inside vAttach).
  local sandbox = M.sandbox_lldb_server_path(pkg)
  if not sandbox then
    return false, "cannot derive sandbox lldb-server path (empty package name)"
  end

  -- K58: probe the SANDBOX copy under `run-as` — size AND `test -x` as the app
  -- uid. Both must hold to skip the re-stage; a public-path `test -x` from the
  -- shell uid proves nothing about app-uid execute permission (SELinux domain).
  local function sandbox_probe()
    local size_out = deps.adb_run(adb, { "-s", serial, "shell",
      "run-as " .. pkg .. " sh -c " .. deps.shell_quote("stat -c %s " .. sandbox) })
    local same = tostring(size_out):match("(%d+)%s*$") == tostring(local_size)
    local _, x_code = deps.adb_run_raw(adb, { "-s", serial, "shell",
      "run-as " .. pkg .. " sh -c " .. deps.shell_quote("test -x " .. sandbox) })
    return same, x_code == 0
  end

  local sb_size_ok, sb_exec_ok = sandbox_probe()
  if M.sandbox_stage_plan(sb_size_ok, sb_exec_ok) == "reuse" then
    return true, sandbox
  end

  local stage_out, stage_code = deps.adb_run_raw(adb, { "-s", serial, "shell",
    "run-as " .. pkg .. " sh -c " .. deps.shell_quote(sandbox_stage_script(remote, sandbox)) })
  if stage_code ~= 0 then
    return false, ("staging lldb-server into %s sandbox failed (exit %s): %s")
      :format(pkg, tostring(stage_code), tostring(stage_out))
  end
  local _, sandbox_x = deps.adb_run_raw(adb, { "-s", serial, "shell",
    "run-as " .. pkg .. " sh -c " .. deps.shell_quote("test -x " .. sandbox) })
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
function M.start_lldb_server_platform(adb, serial, port, pkg, sandbox_path)
  pcall(adb_run, adb, { "-s", serial, "shell", "killall lldb-server 2>/dev/null; true" })
  if pkg then
    pcall(adb_run, adb, { "-s", serial, "shell",
      "run-as " .. pkg .. " sh -c " .. deps.shell_quote("killall lldb-server 2>/dev/null || true") })
  end
  vim.wait(150)

  deps.adb_run(adb, { "-s", serial, "forward", "--remove", "tcp:" .. port })
  if deps.adb_run(adb, { "-s", serial, "forward", "tcp:" .. port, "tcp:" .. port }) == "" then
    if vim.v.shell_error ~= 0 then return false, "adb forward failed" end
  end

  local sandbox = sandbox_path or M.sandbox_lldb_server_path(pkg)
  if not sandbox then
    return false, "no sandbox lldb-server path for app-uid platform server"
  end
  local cmd = "run-as " .. pkg .. " sh -c "
    .. deps.shell_quote(platform_server_script(sandbox, port))
  local jobid = vim.fn.jobstart({ adb, "-s", serial, "shell", cmd }, { detach = false })
  if not jobid or jobid <= 0 then
    return false, "failed to spawn lldb-server platform (jobstart=" .. tostring(jobid) .. ")"
  end
  M.lldb_server_jobid = jobid
  vim.wait(800)
  return true, nil
end

return M
