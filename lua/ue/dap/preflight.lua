-- ue.dap.preflight — attach 前的分层能力门禁（target-generic 编排）。
--
-- 为何存在（权威 spec: openspec/specs/dap-failure-layering/spec.md；
-- 摘要 docs/CONSTRAINTS.md §三 C10）：
--
-- L2（目标 OS 策略）是**唯一「红灯却表现为 L3 症状」的层**。历史上它的失败一律
-- 伪装成下游症状：
--   K56  app uid 无权 ptrace   → host 只看到 `attach failed: lost connection`
--   K58  SELinux 可读不可执行  → `platform connect` handshake 失败 +
--                                `attach failed: The parameter is incorrect`
-- 这三种症状**不指向任何根因**，于是每条坑要花数小时现场取证。门禁的全部目的，
-- 就是把这类失败在**发起引擎连接之前**变成一句带层归属和确切拒绝命令的话。
--
-- L0/L1 不硬阻断：它们本来就会失败得很明确（找不到 adapter、设备不可达）。
-- L3/L4 不硬阻断：它们的失败自带协议级或符号级事实。**只有 L2 强制。**
--
-- 设计约束：
--   * 全程异步（P6：不得阻塞主循环；K53：Windows 上光 spawn 就 87ms）。
--   * 宁可漏拦不可误拦：探针自身出错/超时一律 undetermined，只有明确拒绝证据才判红。
--   * 逃生开关 UE_DAP_SKIP_PREFLIGHT=1，使用后必须在后续失败中留痕（否则下次
--     取证会被误导成「门禁放行了它」）。

local capability = require("ue.dap.capability")
local failure = require("ue.dap.failure")

local M = {}

-- 单条探针的墙钟上限。超时按 P6 放行并标 undetermined，绝不为了「判准」而卡住编辑器。
M.PROBE_TIMEOUT_MS = 4000

--- 逃生开关是否开启。
function M.skipped()
  return (vim.env.UE_DAP_SKIP_PREFLIGHT or "") ~= ""
end

--- 生产执行器：异步子进程。
---
--- 注意这是 preflight **唯一**的 spawn 点，且刻意集中在本模块而不是散进 target owner，
--- 使 host_resource_discipline 的 spawn anchor 计数有一个稳定归属。
function M.system_executor()
  return function(argv, done)
    local finished = false
    local function finish(rc, out, err)
      if finished then return end
      finished = true
      done(rc, out, err)
    end
    local ok = pcall(function()
      vim.system(argv, { text = true, timeout = M.PROBE_TIMEOUT_MS }, function(res)
        -- timeout 时 vim.system 给的 code 不代表设备拒绝，统一交给 decide 处理：
        -- 我们把 signal 非空视为「没有可信 rc」，从而落到 undetermined。
        local rc = res.signal ~= 0 and nil or res.code
        finish(rc, (res.stdout or "") .. (res.stderr or ""), res.stderr)
      end)
    end)
    if not ok then
      finish(nil, nil, "could not spawn probe")
    end
  end
end

--- 跑一次完整的 L0→L4 门禁。
---@param opts table { probes, ctx, executor?, on_done }
function M.run(opts)
  local executor = opts.executor or M.system_executor()
  capability.run(opts.probes or {}, opts.ctx or {}, executor, function(report)
    report.skipped = M.skipped()
    opts.on_done(report)
  end)
end

--- L2 门禁判定：报告是否应当拦下 attach。
---
--- 只有 L2 明确 FAIL 才拦。undetermined **不拦**——这是「宁可漏拦不可误拦」的落点：
--- 一台探不出结论的设备仍应允许用户尝试 attach，然后由 L3 给出协议级事实。
function M.blocks_attach(report)
  if not report or report.skipped then return false end
  local entry = report.layers and report.layers[failure.L.TARGET_POLICY]
  return entry ~= nil and entry.verdict == capability.VERDICT.FAIL
end

--- 把一个阻塞报告转成带层归属的 failure（供 attach 终止路径使用）。
function M.blocking_failure(report)
  local entry = report.layers[failure.L.TARGET_POLICY]
  for _, r in ipairs(entry.results or {}) do
    if r.verdict == capability.VERDICT.FAIL then
      return capability.to_failure(r.descriptor, r, r.argv)
    end
  end
  -- 理论不可达（blocks_attach 已确认存在 FAIL），但不得静默返回 nil：
  -- 无层失败正是本 change 要消灭的东西。
  return failure.undetermined("dap.preflight",
    "target OS policy layer reported a failure without an identifiable probe",
    "run :UEDAPPreflight to see the per-layer verdicts")
end

--- 渲染完整报告（命令输出用）。
function M.format(report)
  local lines = {}
  if report.skipped then
    lines[#lines + 1] = "note: UE_DAP_SKIP_PREFLIGHT is set — the gate is disabled"
  end
  lines[#lines + 1] = capability.format_report(report)
  if M.blocks_attach(report) then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "attach would be refused at L2 (target OS policy):"
    lines[#lines + 1] = failure.format(M.blocking_failure(report))
  end
  return table.concat(lines, "\n")
end

return M
