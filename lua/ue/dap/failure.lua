-- ue.dap.failure — DAP 失败的归属分层与四元组构造。
--
-- 为何存在（docs/CONSTRAINTS.md §三 C10；权威 spec:
-- openspec/specs/dap-failure-layering/spec.md）：
-- 34 条 DAP 坑（K1–K61）里只有 8 条是本仓自己的 bug——9 条是目标 OS 策略、
-- 10 条是调试引擎、6 条是编辑器管道。也就是说**多数失败不是我们能修的，而是
-- 我们没建模的外部契约**。历史上它们全部以无信息量症状暴露：
--   `attach failed: lost connection`（真因：app uid 无权 ptrace，K56）
--   `attach failed: The parameter is incorrect`（真因：SELinux 可读不可执行，K58）
-- 这两句话**不指向任何层**，于是每条要花数小时现场取证。
--
-- 本模块把「层归属」从习惯变成结构：
--   * new{} 缺 layer 直接 error —— 发出无层失败在开发期就崩，不靠 review 兜。
--   * 层不可判定必须显式传 UNDETERMINED —— 沉默不是选项。
--   * evidence 必须是命令 + 输出（evidence.command），不是结论文本 ——
--     误判时证据本身可以推翻结论。
--   * format() 固定「层 + owner 在前，remedy 在后」。
--
-- SCOPE：本模块是 target-generic 的，**零 target 字面量**（不出现 adb / dumpsys /
-- run-as / devicectl 等）。每层的实际探针由 target owner 注册，见 ue.dap.capability。
-- 这既是 ue_platform_boundary 门禁的要求，也是 iOS 能复用同一分层的前提
-- （L2 对 Apple 是「设备信任 / 开发者模式 / 签名」，对 Android 是 uid/SELinux/ptrace）。

local M = {}

--- 归属层。顺序即依赖顺序：靠前的层不通过时，靠后的层无从判定。
M.L = {
  HOST_TOOLCHAIN = "L0", -- adapter 可解析 / 版本 / python 包        owner: host 驱动
  TRANSPORT      = "L1", -- 设备可达 / 标识捕获 / 端口转发           owner: 设备路由层
  TARGET_POLICY  = "L2", -- 目标 OS 策略：执行权限 / 调试权限 / 沙箱  owner: 各 target
  DEBUG_ENGINE   = "L3", -- 调试引擎连接 / attach / 命令序列          owner: 引擎接线 + 引擎本身
  SYMBOL         = "L4", -- 模块重定位 / 断点解析 / 符号与构建一致性  owner: 各 target
  UNDETERMINED   = "L?", -- 证据不足。显式值，不是缺省。
}

-- 层的人类可读名，用于渲染。顺序表用于 preflight 编排。
M.LAYER_ORDER = {
  M.L.HOST_TOOLCHAIN,
  M.L.TRANSPORT,
  M.L.TARGET_POLICY,
  M.L.DEBUG_ENGINE,
  M.L.SYMBOL,
}

local LAYER_LABEL = {
  [M.L.HOST_TOOLCHAIN] = "host toolchain",
  [M.L.TRANSPORT]      = "transport",
  [M.L.TARGET_POLICY]  = "target OS policy",
  [M.L.DEBUG_ENGINE]   = "debug engine",
  [M.L.SYMBOL]         = "symbol/semantic",
  [M.L.UNDETERMINED]   = "UNDETERMINED",
}

local VALID_LAYER = {}
for _, id in pairs(M.L) do VALID_LAYER[id] = true end

--- 层是否合法。
function M.is_layer(layer)
  return VALID_LAYER[layer] == true
end

--- 层标签（渲染用）。未知层返回 nil，调用方不得静默当成某个层。
function M.layer_label(layer)
  return LAYER_LABEL[layer]
end

--- 构造一条 evidence：命令 + 退出码 + 输出摘要。
---
--- 强制形状的理由：结论文本（"权限不足"）无法被推翻，而命令 + 输出可以。
--- 当层归属判错时，读者能从 evidence 自行重跑并纠正我们。
---@param argv string[]|string 实际执行的命令
---@param rc integer|nil 退出码（nil = 未取得）
---@param out string|nil 输出（stdout/stderr 合并摘要）
function M.command_evidence(argv, rc, out)
  local text
  if type(argv) == "table" then
    text = table.concat(argv, " ")
  else
    text = tostring(argv or "")
  end
  return {
    kind = "command",
    command = text,
    rc = rc,
    output = out and tostring(out):gsub("%s+$", "") or nil,
  }
end

--- 构造一条 observation evidence：非命令来源的可核验观测（如协议日志字段）。
--- 仍要求 source 指明出处，不接受裸结论。
function M.observed_evidence(source, detail)
  assert(type(source) == "string" and source ~= "",
    "observed evidence requires a source")
  return { kind = "observed", source = source, output = detail and tostring(detail) or nil }
end

local function normalize_evidence(evidence)
  if evidence == nil then return {} end
  -- 单条 evidence 也接受，统一成列表。
  if evidence.kind then return { evidence } end
  return evidence
end

--- 构造一条 DAP 失败。
---
--- layer 缺失或非法时 **error**：这是本模块的核心约束。发出不带层归属的失败
--- 是历史上每月现场取证的直接原因，所以它必须在开发期崩，而不是在用户面前
--- 变成又一句 `attach failed`。层确实无法判定时传 M.L.UNDETERMINED 并给
--- remedy（判定手段），这是合法且被 spec 要求的路径。
---@param spec table { layer, owner, evidence?, remedy?, summary? }
function M.new(spec)
  assert(type(spec) == "table", "failure spec must be a table")
  local layer = spec.layer
  assert(layer ~= nil,
    "DAP failure MUST declare a layer (see docs/CONSTRAINTS.md C10); "
    .. "use failure.L.UNDETERMINED explicitly when evidence is insufficient")
  assert(M.is_layer(layer),
    "unknown DAP failure layer: " .. tostring(layer))
  local owner = spec.owner
  assert(type(owner) == "string" and owner ~= "",
    "DAP failure MUST name the owner of its layer")
  if layer == M.L.UNDETERMINED then
    assert(type(spec.remedy) == "string" and spec.remedy ~= "",
      "an UNDETERMINED layer MUST carry a remedy describing how to determine it")
  end
  return {
    layer = layer,
    owner = owner,
    summary = spec.summary and tostring(spec.summary) or nil,
    evidence = normalize_evidence(spec.evidence),
    remedy = spec.remedy and tostring(spec.remedy) or nil,
    skipped_preflight = spec.skipped_preflight == true,
  }
end

--- 渲染成用户可见文本：**层与 owner 在最前，remedy 在最后**。
---
--- 顺序是契约（spec: 失败反馈 SHALL 先呈现层与 owner，再呈现处置），不是排版偏好：
--- 用户第一眼要能判断「这是不是我能修的」。
function M.format(failure)
  assert(type(failure) == "table" and M.is_layer(failure.layer),
    "format() requires a failure built by failure.new")
  local lines = {}
  lines[#lines + 1] = ("[%s %s] owner: %s"):format(
    failure.layer, LAYER_LABEL[failure.layer], failure.owner)
  if failure.summary then
    lines[#lines + 1] = failure.summary
  end
  for _, ev in ipairs(failure.evidence or {}) do
    if ev.kind == "command" then
      local rc = ev.rc == nil and "?" or tostring(ev.rc)
      lines[#lines + 1] = ("  evidence: `%s` → rc=%s"):format(ev.command, rc)
      if ev.output and ev.output ~= "" then
        lines[#lines + 1] = ("    %s"):format(ev.output)
      end
    elseif ev.kind == "observed" then
      lines[#lines + 1] = ("  evidence (%s): %s"):format(ev.source, ev.output or "-")
    end
  end
  if failure.skipped_preflight then
    -- 逃生开关留痕：不写这行，下一次取证会被误导成「门禁放行了它」。
    lines[#lines + 1] = "  note: preflight was explicitly skipped for this attempt"
  end
  if failure.remedy then
    lines[#lines + 1] = ("  next: %s"):format(failure.remedy)
  end
  return table.concat(lines, "\n")
end

--- 便捷构造：目标 OS 策略拒绝了某个能力。
--- 这是 L2 的标准形状（K56 / K58 / K12 / K38 都属此类）。
function M.target_policy(owner, summary, evidence, remedy)
  return M.new({
    layer = M.L.TARGET_POLICY,
    owner = owner,
    summary = summary,
    evidence = evidence,
    remedy = remedy,
  })
end

--- 便捷构造：证据不足，层未判定。remedy 必填（如何判定）。
function M.undetermined(owner, summary, remedy, evidence)
  return M.new({
    layer = M.L.UNDETERMINED,
    owner = owner,
    summary = summary,
    remedy = remedy,
    evidence = evidence,
  })
end

return M
