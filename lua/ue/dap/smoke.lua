-- ue.dap.smoke — 按需触发的真机端到端验证 + 脱敏证据（target-generic 编排）。
--
-- 为何存在（权威 spec: openspec/specs/dap-failure-layering/spec.md；
-- 摘要 docs/CONSTRAINTS.md §三 C10）：
--
-- 此前 124 个 dap 用例全是纯函数或源码断言，**没有任何一个能回答「这条 attach 路线
-- 现在还通不通」**。唯一的集成测试是用户 + 一台手机 + 他正需要调试的那一刻，
-- 于是真正的回归探测器是用户本人。本模块把它变成一条可主动跑的命令。
--
-- 诚实性契约（与 K55 的 iOS 证据规则同源）：
--   * 无设备 ⇒ 报 **not_applicable**，不是 pass。禁止注入假可执行文件/假宿主让它
--     「碰巧通过」（宿主能力守卫，见根 AGENTS.md 回归红灯优先段）。
--   * 证据只落摘要 / 布尔 / 计数 / digest：不得含真实设备标识、包标识、pid、个人路径。
--   * 逐层记录判定，使失败时能一眼看出卡在哪层，而不是只有一个 false。

local capability = require("ue.dap.capability")
local failure = require("ue.dap.failure")

local M = {}

M.STATUS = {
  PASS           = "pass",
  FAILED         = "failed",
  NOT_APPLICABLE = "not_applicable",
}

--- 短 digest：用于在证据里指代一个真实值而不泄漏它。
--- 12 位足以区分不同值，且不可逆推原文。
function M.digest(value)
  if value == nil or value == "" then return nil end
  return vim.fn.sha256(tostring(value)):sub(1, 12)
end

--- 判定「本次运行是否适用」。
--- 没有设备不是失败——它是不适用。把两者混同会让证据说谎。
function M.applicability(ctx)
  if not ctx or not ctx.serial or ctx.serial == "" then
    return M.STATUS.NOT_APPLICABLE, "no target device selected in this session"
  end
  if not ctx.package_name or ctx.package_name == "" then
    return M.STATUS.NOT_APPLICABLE, "no target application configured"
  end
  return nil
end

--- 由 preflight 报告构建脱敏的层级证据。
--- 只保留层、判定、探针 id 与 rc —— **不保留 argv**（argv 含真实设备标识与包名）。
function M.layer_evidence(report)
  local layers = {}
  for _, layer in ipairs(failure.LAYER_ORDER) do
    local entry = report.layers and report.layers[layer]
    if entry then
      local probes = {}
      for _, r in ipairs(entry.results or {}) do
        probes[#probes + 1] = { id = r.id, verdict = r.verdict, rc = r.rc }
      end
      layers[#layers + 1] = { layer = layer, verdict = entry.verdict, probes = probes }
    end
  end
  return layers
end

--- 组装一份脱敏证据。
---@param spec table { status, reason?, report?, session?, attach? }
function M.build_evidence(spec)
  local ev = {
    schema = "ue-dap-smoke/1",
    status = spec.status,
    reason = spec.reason,
    -- 身份一律 digest 化（K55）。
    device_digest = M.digest(spec.session and spec.session.serial),
    application_digest = M.digest(spec.session and spec.session.package_name),
    blocking_layer = spec.report and spec.report.blocking_layer or nil,
    preflight_skipped = spec.report and spec.report.skipped == true or false,
    layers = spec.report and M.layer_evidence(spec.report) or nil,
  }
  if spec.attach then
    ev.attach = {
      reached_initialized = spec.attach.initialized == true,
      thread_count = spec.attach.thread_count,
      breakpoints_resolved = spec.attach.breakpoints_resolved,
      -- K33：成功判据必须同时含 DAP verified 与 lldb resolved>0。
      -- 只记布尔与计数，不记源文件路径。
      stop_observed = spec.attach.stop_observed == true,
      detach_clean = spec.attach.detach_clean == true,
    }
  end
  return ev
end

--- 脱敏自检：证据里不得出现真实标识形状。
--- 这是**写盘前**的最后一道闸，不依赖人记得检查。
function M.redaction_violations(evidence)
  local violations = {}
  local encoded = vim.json.encode(evidence)
  -- 反向 DNS 形状的应用标识（a.b.c）：证据里只应有 digest。
  if encoded:find("%a+%.%a+%.%a+") then
    violations[#violations + 1] = "possible raw reverse-DNS application identifier"
  end
  -- Windows 个人路径。
  if encoded:find("[A-Za-z]:[/\\]Users[/\\]") then
    violations[#violations + 1] = "personal filesystem path"
  end
  -- 裸 pid 字段。
  if encoded:find('"pid"') then
    violations[#violations + 1] = "raw pid field"
  end
  return violations
end

--- 写证据到磁盘。返回 (path|nil, err)。
--- 拒绝写出未通过脱敏自检的证据：宁可不留证据，也不泄漏身份。
function M.write_evidence(dir, name, evidence)
  local violations = M.redaction_violations(evidence)
  if #violations > 0 then
    return nil, "refusing to write evidence: " .. table.concat(violations, ", ")
  end
  vim.fn.mkdir(dir, "p")
  local path = dir .. "/" .. name
  local ok, err = pcall(function()
    local encoded = vim.json.encode(evidence)
    vim.fn.writefile(vim.split(encoded, "\n", { plain = true }), path)
  end)
  if not ok then return nil, tostring(err) end
  return path
end

return M
