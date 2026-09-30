-- ue.dap.capability — 分层能力探测编排（target-generic）。
--
-- 为何存在（权威 spec: openspec/specs/dap-failure-layering/spec.md；
-- 摘要 docs/CONSTRAINTS.md §三 C10）：
--
-- 历史上代码把**单台设备的结论写死**（沙箱布局、受限身份可用性、某 OEM 的强制访问
-- 控制策略、某个 NDK 的 server 版本），于是换设备/换 OS 版本就等于换一个月的排查。
-- 更糟的是，K56 与 K58 这两条最贵的坑各自离自诊断只差**一条 5 秒命令**，但那条命令
-- 从未被执行过——失败只以 `lost connection` / `The parameter is incorrect` 暴露。
--
-- 本模块把「能力」变成**探测结果**而不是假设：
--   * 探针 = build_argv(ctx)（纯函数）+ decide(rc, out, err)（纯函数）
--   * 执行器由调用方注入（生产 vim.system，测试用 recorded fixture 表）
--     ⇒ 每条设备语义都能 headless 测，不需要手机在手
--   * 判定三态：pass / fail / undetermined。**宁可漏拦不可误拦**：
--     只有明确的拒绝证据才判 fail；探针自身出错一律 undetermined。
--
-- SCOPE：本模块**零 target 字面量**。argv 由 target owner 在描述符里提供
-- （ue_platform_boundary 要求，且这是 iOS 复用同一编排的前提）。
--
-- 最小权限视角（K58 的核心教训）：判定「某身份能否执行某动作」必须**以该身份探测**。
-- 更高权限身份的同名探测结果零信息量——历史上 shell uid 的 `test -x` 通过，而 app uid
-- 执行得 126。描述符因此带 `identity` 字段，仅作声明与渲染，实际身份由 argv 体现。

local failure = require("ue.dap.failure")

local M = {}

M.VERDICT = {
  PASS         = "pass",
  FAIL         = "fail",
  UNDETERMINED = "undetermined",
  SKIPPED      = "skipped", -- 前置层已阻塞，本层不再探测
}

--- 校验一个探针描述符的形状。形状错误必须立刻崩，而不是在设备上表现成怪异行为。
---@param d table { layer, id, owner, identity?, build_argv, decide, remedy? }
function M.validate(d)
  assert(type(d) == "table", "capability probe must be a table")
  assert(failure.is_layer(d.layer), "probe requires a valid layer: " .. tostring(d.id))
  assert(type(d.id) == "string" and d.id ~= "", "probe requires an id")
  assert(type(d.owner) == "string" and d.owner ~= "", "probe requires an owner")
  assert(type(d.build_argv) == "function", "probe requires build_argv(ctx)")
  assert(type(d.decide) == "function", "probe requires decide(rc, out, err)")
  return d
end

--- 归一化 decide 的返回值，并强制「宁可漏拦不可误拦」。
---
--- decide 可以返回：
---   verdict 字符串，或 { verdict = ..., detail = ..., remedy = ... }
--- 任何无法识别的返回值一律视为 undetermined —— 探针作者写错不应该把一台
--- 本可调试的设备判成红灯。
function M.normalize_verdict(value)
  local verdict, detail, remedy
  if type(value) == "string" then
    verdict = value
  elseif type(value) == "table" then
    verdict, detail, remedy = value.verdict, value.detail, value.remedy
  end
  if verdict ~= M.VERDICT.PASS
    and verdict ~= M.VERDICT.FAIL
    and verdict ~= M.VERDICT.UNDETERMINED
    and verdict ~= M.VERDICT.SKIPPED
  then
    verdict = M.VERDICT.UNDETERMINED
    detail = detail or "probe returned an unrecognized verdict"
  end
  return { verdict = verdict, detail = detail, remedy = remedy }
end

--- 以保护调用跑一个探针的 decide，异常也归为 undetermined（不误拦）。
function M.evaluate(descriptor, rc, out, err)
  local ok, value = pcall(descriptor.decide, rc, out, err)
  if not ok then
    return M.normalize_verdict({
      verdict = M.VERDICT.UNDETERMINED,
      detail = "probe decide() errored: " .. tostring(value),
    })
  end
  return M.normalize_verdict(value)
end

--- 把一个 fail/undetermined 的探针结果转成带层归属的 failure。
---
--- 注意 remedy 的来源顺序：探针结果 > 描述符默认。UNDETERMINED 必须有 remedy
--- （failure.new 会强制），所以这里给一个诚实的兜底：如何取得判定。
function M.to_failure(descriptor, result, argv)
  local evidence = {}
  if argv then
    evidence[#evidence + 1] = failure.command_evidence(argv, result.rc, result.detail)
  elseif result.detail then
    evidence[#evidence + 1] = failure.observed_evidence(descriptor.id, result.detail)
  end
  local remedy = result.remedy or descriptor.remedy
  if result.verdict == M.VERDICT.UNDETERMINED then
    remedy = remedy
      or ("re-run the probe `" .. descriptor.id .. "` with the device attached to determine this layer")
    return failure.undetermined(descriptor.owner, descriptor.summary or descriptor.id,
      remedy, evidence)
  end
  return failure.new({
    layer = descriptor.layer,
    owner = descriptor.owner,
    summary = descriptor.summary or descriptor.id,
    evidence = evidence,
    remedy = remedy,
  })
end

--- 按层分组一组描述符，保持 failure.LAYER_ORDER 的依赖顺序。
function M.group_by_layer(descriptors)
  local by_layer = {}
  for _, layer in ipairs(failure.LAYER_ORDER) do by_layer[layer] = {} end
  for _, d in ipairs(descriptors or {}) do
    M.validate(d)
    local bucket = by_layer[d.layer]
    -- UNDETERMINED 不是可探测层，描述符不得声明它。
    assert(bucket, "probe declares a non-probeable layer: " .. tostring(d.layer))
    bucket[#bucket + 1] = d
  end
  return by_layer
end

--- 判定一层的聚合结果：任一 fail ⇒ fail；否则任一 undetermined ⇒ undetermined；
--- 全 pass ⇒ pass；空集 ⇒ pass（无可探测项不构成阻塞）。
function M.layer_verdict(results)
  local seen_undetermined = false
  for _, r in ipairs(results or {}) do
    if r.verdict == M.VERDICT.FAIL then return M.VERDICT.FAIL end
    if r.verdict == M.VERDICT.UNDETERMINED then seen_undetermined = true end
  end
  return seen_undetermined and M.VERDICT.UNDETERMINED or M.VERDICT.PASS
end

--- 顺序编排：逐层探测，首个 fail 层标为阻塞层，其后各层标 skipped。
---
--- executor(argv, done) 由调用方注入：生产实现用异步 vim.system（P6：不得在主循环
--- 同步等待子进程，K53：Windows 上光 spawn 就 87ms），测试实现用 fixture 表。
--- 本模块不自己 spawn，因此不受 host_resource_discipline 的 spawn 计数棘轮影响。
---@param descriptors table[] 探针描述符
---@param ctx table 传给 build_argv 的上下文
---@param executor fun(argv: string[], done: fun(rc: integer|nil, out: string|nil, err: string|nil))
---@param on_done fun(report: table)
function M.run(descriptors, ctx, executor, on_done)
  local by_layer = M.group_by_layer(descriptors)
  local report = { layers = {}, blocking_layer = nil }

  local function finish()
    on_done(report)
  end

  local layer_index = 0

  local function run_layer()
    layer_index = layer_index + 1
    local layer = failure.LAYER_ORDER[layer_index]
    if not layer then return finish() end

    local probes = by_layer[layer]
    -- 已有阻塞层：其后各层标 skipped，不再探测（spec: 其后各层 MAY 标注为未判定）。
    if report.blocking_layer then
      report.layers[layer] = { verdict = M.VERDICT.SKIPPED, results = {} }
      return run_layer()
    end

    local results = {}
    local pending = #probes
    if pending == 0 then
      report.layers[layer] = { verdict = M.VERDICT.PASS, results = results }
      return run_layer()
    end

    local function probe_done()
      pending = pending - 1
      if pending > 0 then return end
      local verdict = M.layer_verdict(results)
      report.layers[layer] = { verdict = verdict, results = results }
      if verdict == M.VERDICT.FAIL then
        report.blocking_layer = layer
      end
      run_layer()
    end

    -- 同层并行：彼此独立的能力问题没有顺序依赖。
    for _, d in ipairs(probes) do
      local ok_argv, argv = pcall(d.build_argv, ctx)
      if not ok_argv or type(argv) ~= "table" or #argv == 0 then
        results[#results + 1] = {
          id = d.id, descriptor = d, argv = nil, rc = nil,
          verdict = M.VERDICT.UNDETERMINED,
          detail = "could not build probe command: " .. tostring(argv),
        }
        probe_done()
      else
        executor(argv, function(rc, out, err)
          local decided = M.evaluate(d, rc, out, err)
          results[#results + 1] = {
            id = d.id, descriptor = d, argv = argv, rc = rc,
            verdict = decided.verdict,
            detail = decided.detail or out,
            remedy = decided.remedy,
          }
          probe_done()
        end)
      end
    end
  end

  run_layer()
end

--- 渲染报告：逐层 ✓ / ✗ / ? / -，阻塞层显式标注，附 evidence 与 remedy。
function M.format_report(report)
  local lines = {}
  local mark = {
    [M.VERDICT.PASS] = "OK  ",
    [M.VERDICT.FAIL] = "FAIL",
    [M.VERDICT.UNDETERMINED] = "?   ",
    [M.VERDICT.SKIPPED] = "-   ",
  }
  for _, layer in ipairs(failure.LAYER_ORDER) do
    local entry = report.layers[layer]
    if entry then
      -- 只有 L2 会真的拦下 attach（preflight.blocks_attach）。其他层的 FAIL 仍然
      -- 终止后续探测，但**不阻断会话**——比如 L4 的符号错配只影响断点解析
      -- 到哪个修订，不影响能不能 attach。标 BLOCKING 会与 blocks_attach=false
      -- 自相矛盾（真机实测到这个措辞缺陷），所以分两种标记。
      local suffix = ""
      if report.blocking_layer == layer then
        suffix = (layer == failure.L.TARGET_POLICY)
          and "   <== BLOCKS ATTACH"
          or "   <== FIRST FAILING (does not block attach)"
      end
      lines[#lines + 1] = ("%s %s %s%s"):format(
        mark[entry.verdict] or "?   ", layer, failure.layer_label(layer) or "?", suffix)
      for _, r in ipairs(entry.results) do
        if r.verdict ~= M.VERDICT.PASS then
          lines[#lines + 1] = ("       %s: %s"):format(r.id, r.verdict)
          if r.argv then
            lines[#lines + 1] = ("         `%s` → rc=%s"):format(
              table.concat(r.argv, " "), tostring(r.rc))
          end
          if r.detail and r.detail ~= "" then
            lines[#lines + 1] = ("         %s"):format(
              tostring(r.detail):gsub("%s+$", ""))
          end
          local remedy = r.remedy or (r.descriptor and r.descriptor.remedy)
          if remedy then
            lines[#lines + 1] = ("         next: %s"):format(remedy)
          end
        end
      end
    end
  end
  if not report.blocking_layer then
    lines[#lines + 1] = "no blocking layer detected"
  end
  return table.concat(lines, "\n")
end

return M
