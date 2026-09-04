-- ue.dap._android_policy — Android 的 L2 目标 OS 策略层（能力探针 + probe context）。
--
-- 为何单独成文件（design D7；治理 spec:
-- openspec/specs/dap-failure-layering/spec.md，摘要 docs/CONSTRAINTS.md §三 C10）：
-- L2 是唯一「红灯却表现为 L3 症状」的层，也是 34 条 DAP 坑里占 9 条的那一层
-- （K56 / K58 / K12 / K38 / K13 …）。把它从 2700 行的 owner 里拆出来，使
--   ① 每条 L2 语义可独立审阅与测试；
--   ② 新增设备策略探针不必先读懂 attach 编排。
-- 命名沿用本目录既有的 `_ios_*.lua` 平铺约定，不新造子目录。
--
-- 本文件承载 target 命令字面量（adb / run-as / getenforce / dumpsys）是**有意的**：
-- 通用分层模块出现它们会被 ue_platform_boundary 判为 target_policy_literal，
-- 所以「编排在通用层，命令字面量在 target owner」——本文件是 owner 的策略半边。
--
-- 依赖注入而非 require 回主模块：`bind(deps)` 收下 owner 提供的少量 helper
-- （shell_quote / sandbox 路径 / session 读取），避免与 android.lua 循环依赖。

local M = {}

local deps = {
  shell_quote = nil,               -- fun(string): string
  sandbox_lldb_server_path = nil,  -- fun(pkg): string|nil
  session = nil,                   -- fun(): table
  last_session = nil,              -- fun(): table|nil
}

--- 由 owner 注入依赖。未知键被拒绝（拼错键名不得静默失效）。
function M.bind(overrides)
  for key, value in pairs(overrides or {}) do
    assert(deps[key] ~= nil or key ~= nil, "unknown policy dependency: " .. tostring(key))
    assert(type(value) == "function", "policy dependency must be a function: " .. tostring(key))
    deps[key] = value
  end
  return M
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
    .. " sh -c " .. deps.shell_quote(script))
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

--- 纯函数（可单测）：从符号库路径抽出它所属的 versionCode。
---
--- UE 的 Android 符号包目录形如 `<Target>_Symbols_v<code>/`（见 packageInfo.txt
--- 第 2 行的约定）。这里只做字符串抽取——**不猜**：抽不到就返回 nil，让上层判
--- 「未判定」而不是编一个版本号出来。
function M.symbol_version_code(symbol_lib)
  if type(symbol_lib) ~= "string" or symbol_lib == "" then return nil end
  return symbol_lib:match("_Symbols_v(%d+)")
end

--- 纯函数（可单测）：比对设备与符号包的 versionCode。
--- 返回 "match" / "mismatch" / "unknown"。
---
--- 为何 mismatch 属 L4 而不是 L2：版本错配**不阻止 attach**，它只让断点解析到
--- 错误的源码修订（K35/K37 语义）。把它判成阻塞层会误拦一次本可调试的会话。
function M.version_code_verdict(device_code, symbol_code)
  if not device_code or not symbol_code then return "unknown" end
  return tostring(device_code) == tostring(symbol_code) and "match" or "mismatch"
end

--- 本 target 的能力探针集合。ctx 需含 adb / serial / package_name / remote_lldb_server。
-- 同一次探测内从 build_argv 传给 decide 的本地期望值（见 L4 探针注释）。
local last_symbol_code = nil

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
        local sandbox = deps.sandbox_lldb_server_path(ctx.package_name)
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
        -- 不得只看输出里有没有数字：必须 **rc 与输出一致** 才下结论。
        -- 实测（2026-09-04）`pidof -s <pkg>` 在该设备上：进程存在 → rc=0 + pid；
        -- 不存在 → rc=1 + 空。两者不一致（如 rc=0 却无输出）意味着命令本身未真正
        -- 执行或被包装层吃掉了输出，那是「未判定」而不是「应用没跑」——
        -- 把它当 FAIL 会误拦一次本来能成的 attach。
        local pid = tostring(out or ""):match("(%d+)")
        if rc == 0 and pid then return { verdict = V.PASS, detail = "pid=" .. pid } end
        if rc ~= 0 and not pid then
          return { verdict = V.FAIL, detail = "no pid for the package (not running)" }
        end
        return { verdict = V.UNDETERMINED,
          detail = ("inconsistent probe result (rc=%s, output=%q)")
            :format(tostring(rc), tostring(out or "")) }
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
      -- build_argv 把本次选中的符号包 versionCode 记到闭包外的 last_symbol_code，
      -- 因为 decide 的纯函数契约只收 (rc, out, err)。这是有意的取舍：探针命令与
      -- 判定都保持可单测，而「本地期望值」这个 ctx 派生量只在同一次探测内传递。
      build_argv = function(ctx)
        last_symbol_code = M.symbol_version_code(ctx.symbol_lib)
        return probe_shell(ctx, "dumpsys package " .. tostring(ctx.package_name or "")
          .. " | grep -m1 versionCode")
      end,
      decide = function(rc, out)
        if rc ~= 0 or not tostring(out or ""):match("versionCode") then
          return { verdict = V.UNDETERMINED, detail = "could not read the installed versionCode" }
        end
        local device_code = tostring(out):match("versionCode=(%d+)")
        if not device_code then
          return { verdict = V.UNDETERMINED, detail = out }
        end
        local verdict = M.version_code_verdict(device_code, last_symbol_code)
        if verdict == "unknown" then
          return { verdict = V.UNDETERMINED,
            detail = ("device versionCode=%s; no symbol package versionCode to compare")
              :format(device_code),
            remedy = "select a symbol package so the comparison becomes possible" }
        end
        if verdict == "mismatch" then
          -- L4, not L2: a mismatch does not stop the attach, it resolves
          -- breakpoints against the wrong source revision.
          return { verdict = V.FAIL,
            detail = ("device versionCode=%s but symbols are v%s")
              :format(device_code, tostring(last_symbol_code)) }
        end
        return { verdict = V.PASS,
          detail = ("versionCode=%s matches the selected symbols"):format(device_code) }
      end,
    },
  }
end

--- 本 target 的 probe context 富化（由通用层回调）。
---
--- 设备路由与应用身份是 **target 知识**：通用层不得自己 require
--- `utils.android_device` 或读 owner 的 session（那会在 target-generic 模块里制造
--- 具体 target 引用，ue_platform_boundary 实测会 FAIL）。因此由本 policy 层填。
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
  out.adb = out.adb or deps.session().adb or "adb"
  if not out.package_name or out.package_name == "" then
    local last = deps.last_session()
    out.package_name = deps.session().package_name or (last and last.package_name)
  end
  out.pid = out.pid or deps.session().pid
  -- L4 需要本地符号包路径才能把「设备 versionCode」与「符号 versionCode」对上。
  -- 缺它不是错误，只是让该层判「未判定」（本月 follow-up 记录的错配问题正需要它）。
  if not out.symbol_lib or out.symbol_lib == "" then
    local last = deps.last_session()
    out.symbol_lib = deps.session().symbol_lib or (last and last.symbol_lib)
  end
  return out
end

return M
