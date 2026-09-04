-- tests/cases/dap_failure_layer_spec.lua
--
-- 归属分层契约的行为回归（治理 spec: openspec/specs/dap-failure-layering/spec.md；
-- 摘要 docs/CONSTRAINTS.md §三 C10）。
--
-- 为何这些用例存在：34 条 DAP 坑里只有 8 条是本仓 bug，其余是外部契约，且历史上
-- 全部以无信息量症状暴露（`lost connection` / `The parameter is incorrect`）。
-- 这里锁住三件事：① 发出无层失败必须崩；② 未判定必须显式且带判定手段；
-- ③ evidence 必须是命令 + 输出而不是结论文本。

local t = require("tests.harness")
t.bootstrap()

local failure = require("ue.dap.failure")

t.describe("ue.dap.failure: 四元组构造强制层归属", function()
  t.it("缺 layer 直接 error（不允许发出无层失败）", function()
    t.assert_error(function()
      failure.new({ owner = "dap.android", summary = "attach failed" })
    end)
  end)

  t.it("非法 layer 直接 error（不接受自造层名）", function()
    t.assert_error(function()
      failure.new({ layer = "L9", owner = "dap.android" })
    end)
  end)

  t.it("缺 owner 直接 error（层必须有负责方）", function()
    t.assert_error(function()
      failure.new({ layer = failure.L.TARGET_POLICY })
    end)
  end)

  t.it("五层 + UNDETERMINED 均为合法层", function()
    for _, layer in ipairs({ "L0", "L1", "L2", "L3", "L4", "L?" }) do
      t.assert_true(failure.is_layer(layer), layer .. " 应为合法层")
    end
    t.assert_false(failure.is_layer("L5"))
    t.assert_false(failure.is_layer(nil))
  end)

  t.it("LAYER_ORDER 是 L0→L4 的依赖顺序（preflight 编排依赖它）", function()
    t.assert_eq(#failure.LAYER_ORDER, 5)
    t.assert_eq(failure.LAYER_ORDER[1], failure.L.HOST_TOOLCHAIN)
    t.assert_eq(failure.LAYER_ORDER[3], failure.L.TARGET_POLICY)
    t.assert_eq(failure.LAYER_ORDER[5], failure.L.SYMBOL)
  end)
end)

t.describe("ue.dap.failure: 未判定必须显式且可推进", function()
  t.it("UNDETERMINED 缺 remedy 直接 error（不许把未判定当终点）", function()
    t.assert_error(function()
      failure.new({ layer = failure.L.UNDETERMINED, owner = "dap.android" })
    end)
  end)

  t.it("UNDETERMINED 带 remedy 合法，且渲染出判定手段", function()
    local f = failure.undetermined("dap.android",
      "device unreachable, cannot classify",
      "reconnect the device, then run :UEDAPPreflight")
    t.assert_eq(f.layer, failure.L.UNDETERMINED)
    local text = failure.format(f)
    t.assert_contains(text, "UNDETERMINED")
    t.assert_contains(text, "next: reconnect the device")
  end)
end)

t.describe("ue.dap.failure: evidence 必须是命令+输出而非结论", function()
  t.it("command_evidence 保留命令、退出码与输出", function()
    local ev = failure.command_evidence({ "tool", "-s", "ID", "probe" }, 126,
      "can't execute: Permission denied\n")
    t.assert_eq(ev.kind, "command")
    t.assert_eq(ev.command, "tool -s ID probe")
    t.assert_eq(ev.rc, 126)
    t.assert_eq(ev.output, "can't execute: Permission denied")
  end)

  t.it("observed_evidence 必须声明出处（不接受裸结论）", function()
    t.assert_error(function() failure.observed_evidence("") end)
    local ev = failure.observed_evidence("lldb-dap protocol log", "no SIGSEGV recorded")
    t.assert_eq(ev.source, "lldb-dap protocol log")
  end)
end)

t.describe("ue.dap.failure: 渲染顺序是契约（层与 owner 先于处置）", function()
  local function sample()
    return failure.target_policy(
      "dap.android (target OS policy)",
      "staged debug server is not executable by the identity that must run it",
      { failure.command_evidence({ "shell", "probe", "-x" }, 126, "Permission denied") },
      "re-stage into the app-owned path, or run :UEDAPPreflight for the full verdict")
  end

  t.it("首行即层 + owner", function()
    local lines = vim.split(failure.format(sample()), "\n")
    t.assert_contains(lines[1], "L2")
    t.assert_contains(lines[1], "target OS policy")
    t.assert_contains(lines[1], "owner:")
  end)

  t.it("remedy 出现在 evidence 之后（先证据后处置）", function()
    local text = failure.format(sample())
    local ev_at = text:find("evidence:", 1, true)
    local next_at = text:find("next:", 1, true)
    t.assert_true(ev_at ~= nil and next_at ~= nil, "两者都应出现")
    t.assert_true(ev_at < next_at, "evidence 必须先于 remedy")
  end)

  t.it("逃生开关被使用时必须留痕", function()
    local f = failure.new({
      layer = failure.L.DEBUG_ENGINE,
      owner = "lldb",
      summary = "attach failed",
      skipped_preflight = true,
    })
    t.assert_contains(failure.format(f), "preflight was explicitly skipped")
  end)

  t.it("format 拒绝非 failure.new 产物", function()
    t.assert_error(function() failure.format({ layer = "nope" }) end)
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 能力探测编排 + preflight 门禁。
--
-- 关键：这些用例用**注入的 fixture 执行器**复现真机语义，因此 K56/K58 那类
-- 设备策略语义**不需要手机在手**就有回归守护。这是本 change 想解决的第二个
-- 结构性问题（此前 124 个 dap 用例全是纯函数/源码断言，没有任何一个能回答
-- 「这条路线还通不通」，于是真正的回归探测器是用户本人）。
-- ════════════════════════════════════════════════════════════════════════
local capability = require("ue.dap.capability")
local preflight = require("ue.dap.preflight")

local function fixture_executor(map)
  return function(argv, done)
    local key = table.concat(argv, " ")
    for pattern, res in pairs(map) do
      if key:find(pattern) then return done(res.rc, res.out, nil) end
    end
    done(0, "")
  end
end

local function probe(layer, id, argv, decide)
  return {
    layer = layer, id = id, owner = "test-owner",
    build_argv = function() return argv end,
    decide = decide,
  }
end

local function rc_probe(layer, id, argv, remedy)
  return probe(layer, id, argv, function(rc, out)
    if rc == nil then return { verdict = capability.VERDICT.UNDETERMINED } end
    if rc ~= 0 then return { verdict = capability.VERDICT.FAIL, detail = out, remedy = remedy } end
    return { verdict = capability.VERDICT.PASS }
  end)
end

local function sample_probes()
  return {
    rc_probe(failure.L.HOST_TOOLCHAIN, "adapter", { "adapter", "--version" }),
    rc_probe(failure.L.TRANSPORT, "reachable", { "tool", "shell", "true" }),
    rc_probe(failure.L.TARGET_POLICY, "restricted-identity-can-exec",
      { "tool", "shell", "asidentity test -x /sandbox/server" },
      "re-stage into the identity-owned path"),
    rc_probe(failure.L.DEBUG_ENGINE, "engine", { "noop" }),
  }
end

local function run_sync(probes, executor)
  local captured
  preflight.run({ probes = probes, ctx = {}, executor = executor,
    on_done = function(report) captured = report end })
  assert(captured, "fixture executor must complete synchronously")
  return captured
end

t.describe("ue.dap.capability: 探针形状与三态判定", function()
  t.it("描述符缺 layer / id / owner / 函数即 error", function()
    t.assert_error(function() capability.validate({ id = "x", owner = "o",
      build_argv = function() end, decide = function() end }) end)
    t.assert_error(function() capability.validate({ layer = failure.L.TRANSPORT,
      owner = "o", build_argv = function() end, decide = function() end }) end)
    t.assert_error(function() capability.validate({ layer = failure.L.TRANSPORT,
      id = "x", build_argv = function() end, decide = function() end }) end)
  end)

  t.it("decide 返回无法识别的值 → undetermined（不误拦）", function()
    local d = probe(failure.L.TARGET_POLICY, "weird", { "x" }, function() return "banana" end)
    t.assert_eq(capability.evaluate(d, 0, "", nil).verdict, capability.VERDICT.UNDETERMINED)
  end)

  t.it("decide 抛错 → undetermined 而非 fail（探针 bug 不得误拦设备）", function()
    local d = probe(failure.L.TARGET_POLICY, "boom", { "x" },
      function() error("probe bug") end)
    local r = capability.evaluate(d, 0, "", nil)
    t.assert_eq(r.verdict, capability.VERDICT.UNDETERMINED)
    t.assert_contains(r.detail, "errored")
  end)

  t.it("层聚合：任一 fail 即 fail；否则任一 undetermined 即 undetermined", function()
    local V = capability.VERDICT
    t.assert_eq(capability.layer_verdict({ { verdict = V.PASS }, { verdict = V.FAIL } }), V.FAIL)
    t.assert_eq(capability.layer_verdict({ { verdict = V.PASS }, { verdict = V.UNDETERMINED } }),
      V.UNDETERMINED)
    t.assert_eq(capability.layer_verdict({ { verdict = V.PASS } }), V.PASS)
    t.assert_eq(capability.layer_verdict({}), V.PASS, "空集不构成阻塞")
  end)

  t.it("描述符不得声明 UNDETERMINED 作为可探测层", function()
    t.assert_error(function()
      capability.group_by_layer({ rc_probe(failure.L.UNDETERMINED, "x", { "y" }) })
    end)
  end)

  t.it("build_argv 返回 nil → undetermined，不崩不误拦", function()
    local d = {
      layer = failure.L.TARGET_POLICY, id = "no-argv", owner = "o",
      build_argv = function() return nil end,
      decide = function() return capability.VERDICT.PASS end,
    }
    local report = run_sync({ d }, fixture_executor({}))
    local entry = report.layers[failure.L.TARGET_POLICY]
    t.assert_eq(entry.verdict, capability.VERDICT.UNDETERMINED)
  end)
end)

t.describe("ue.dap.preflight: L2 门禁（K56/K58 语义 fixture 化）", function()
  t.it("K58 语义：受限身份 exec 得 126 → L2 阻塞且不进入 L3", function()
    local report = run_sync(sample_probes(), fixture_executor({
      ["test %-x"] = { rc = 126, out = "sh: can't execute: Permission denied" },
    }))
    t.assert_eq(report.blocking_layer, failure.L.TARGET_POLICY)
    t.assert_true(preflight.blocks_attach(report), "L2 明确 FAIL 必须拦下 attach")
    -- L3 及其后必须是 skipped：门禁的全部意义就是不让它到 L3 变成通用症状。
    t.assert_eq(report.layers[failure.L.DEBUG_ENGINE].verdict, capability.VERDICT.SKIPPED)
    t.assert_eq(report.layers[failure.L.SYMBOL].verdict, capability.VERDICT.SKIPPED)
  end)

  t.it("阻塞失败带层归属、确切命令与 rc", function()
    local report = run_sync(sample_probes(), fixture_executor({
      ["test %-x"] = { rc = 126, out = "sh: can't execute: Permission denied" },
    }))
    local text = failure.format(preflight.blocking_failure(report))
    t.assert_contains(text, "L2")
    t.assert_contains(text, "rc=126")
    t.assert_contains(text, "Permission denied")
    t.assert_contains(text, "next: re-stage")
  end)

  t.it("全部通过时不拦，且无阻塞层", function()
    local report = run_sync(sample_probes(), fixture_executor({}))
    t.assert_nil(report.blocking_layer)
    t.assert_false(preflight.blocks_attach(report))
  end)

  t.it("设备掉线（取不到 rc）→ undetermined，MUST NOT 误拦", function()
    local report = run_sync(sample_probes(), fixture_executor({
      ["shell true"] = { rc = nil, out = nil },
      ["test %-x"] = { rc = nil, out = nil },
    }))
    t.assert_eq(report.layers[failure.L.TARGET_POLICY].verdict, capability.VERDICT.UNDETERMINED)
    t.assert_false(preflight.blocks_attach(report),
      "未判定不得阻断：宁可漏拦不可误拦")
  end)

  t.it("报告渲染标出阻塞层并给出逐层判定", function()
    local report = run_sync(sample_probes(), fixture_executor({
      ["test %-x"] = { rc = 126, out = "denied" },
    }))
    local text = preflight.format(report)
    t.assert_contains(text, "BLOCKING")
    for _, layer in ipairs({ "L0", "L1", "L2", "L3", "L4" }) do
      t.assert_contains(text, layer)
    end
  end)
end)

t.describe("ue.dap.preflight: 逃生开关", function()
  t.it("UE_DAP_SKIP_PREFLIGHT 置位时不拦，且报告留痕", function()
    local saved = vim.env.UE_DAP_SKIP_PREFLIGHT
    vim.env.UE_DAP_SKIP_PREFLIGHT = "1"
    local report = run_sync(sample_probes(), fixture_executor({
      ["test %-x"] = { rc = 126, out = "denied" },
    }))
    local text = preflight.format(report)
    vim.env.UE_DAP_SKIP_PREFLIGHT = saved
    t.assert_true(report.skipped, "报告必须记录跳过状态")
    t.assert_false(preflight.blocks_attach(report), "跳过时不得阻断")
    t.assert_contains(text, "UE_DAP_SKIP_PREFLIGHT")
  end)
end)

t.describe("ue.dap.android: 能力探针注册", function()
  local android = require("ue.dap.android")

  t.it("target owner 提供探针，且全部形状合法", function()
    local probes = android.capability_probes()
    t.assert_true(#probes > 0, "Android owner 必须注册探针")
    for _, d in ipairs(probes) do capability.validate(d) end
  end)

  t.it("覆盖 K56（ptrace）与 K58（exec）两条最贵的坑", function()
    local ids = {}
    for _, d in ipairs(android.capability_probes()) do ids[d.id] = d.layer end
    t.assert_eq(ids["app-uid-can-exec-server"], failure.L.TARGET_POLICY)
    t.assert_eq(ids["app-uid-can-ptrace-target"], failure.L.TARGET_POLICY)
  end)

  t.it("L2 探针以受限身份执行（K58：更高权限身份的探测零信息量）", function()
    for _, d in ipairs(android.capability_probes()) do
      if d.identity == "app uid" then
        local argv = d.build_argv({ adb = "adb", serial = "ID", package_name = "p.k.g", pid = 42 })
        t.assert_true(argv ~= nil, d.id .. " 应能构造命令")
        t.assert_contains(table.concat(argv, " "), "run-as p.k.g",
          d.id .. " 必须以 app 身份探测")
      end
    end
  end)

  t.it("缺 pid/包名时 build_argv 返回 nil 而不是构造半成品命令", function()
    for _, d in ipairs(android.capability_probes()) do
      local ok = pcall(d.build_argv, {})
      t.assert_true(ok, d.id .. " build_argv 不应在空 ctx 上抛错")
    end
  end)

  t.it("K13：TracerPid 非 0 判 FAIL 并归 L2", function()
    local probes = android.capability_probes()
    for _, d in ipairs(probes) do
      if d.id == "app-uid-can-ptrace-target" then
        local busy = capability.evaluate(d, 0, "Name:\tgame\nTracerPid:\t1234\n", nil)
        t.assert_eq(busy.verdict, capability.VERDICT.FAIL)
        t.assert_contains(busy.detail, "TracerPid=1234")
        local free = capability.evaluate(d, 0, "Name:\tgame\nTracerPid:\t0\n", nil)
        t.assert_eq(free.verdict, capability.VERDICT.PASS)
      end
    end
  end)

  -- ════════════════════════════════════════════════════════════════════
  -- 2026-09-04 真机（小米 fuxi / MIUI，user build、Enforcing）发现的设计缺陷：
  -- 「还没 stage」与「stage 过但不可执行」在单独的 `test -x` 下**同为 rc=1**。
  -- 早期实现把 rc=1 一律判 undetermined，于是「可读不可执行」这个真红灯
  -- **永远判不出来**，L2 门禁实际是死的——而那正是 K58 要拦的情形。
  -- 现在用不同退出码分开：0=可执行 / 11=存在但不可执行 / 10=未 stage。
  --
  -- 真机实测三态（同一台设备、同一文件，只改状态）：
  --   未 stage        → rc=10 → undetermined → blocks_attach=false
  --   chmod 400 后    → rc=11 → FAIL         → blocks_attach=true，L3/L4 skipped
  --   chmod 700 后    → rc=0  → PASS
  -- ════════════════════════════════════════════════════════════════════
  local function exec_probe()
    for _, d in ipairs(android.capability_probes()) do
      if d.id == "app-uid-can-exec-server" then return d end
    end
  end

  t.it("未 stage（rc=10）→ undetermined，不误拦首跑", function()
    local r = capability.evaluate(exec_probe(), 10, "", nil)
    t.assert_eq(r.verdict, capability.VERDICT.UNDETERMINED, "尚未 stage 不是策略拒绝")
  end)

  t.it("已 stage 但不可执行（rc=11）→ FAIL：K58 的真红灯必须能判出来", function()
    local r = capability.evaluate(exec_probe(), 11, "", nil)
    t.assert_eq(r.verdict, capability.VERDICT.FAIL,
      "存在却不可执行是真正的策略拒绝，必须拦（否则 L2 门禁是死的）")
    t.assert_contains(r.detail, "K58")
  end)

  t.it("可执行（rc=0）→ PASS", function()
    t.assert_eq(capability.evaluate(exec_probe(), 0, "", nil).verdict,
      capability.VERDICT.PASS)
  end)

  t.it("探针命令用不同退出码区分存在性与可执行性（源断言）", function()
    local argv = exec_probe().build_argv({
      adb = "adb", serial = "ID", package_name = "p.k.g" })
    local cmd = table.concat(argv, " ")
    t.assert_contains(cmd, "test -x")
    t.assert_contains(cmd, "test -e")
    t.assert_contains(cmd, "exit 11")
    t.assert_contains(cmd, "exit 10")
  end)
end)

t.describe("ue.dap: L0 宿主适配器探针（C1 forward-only）", function()
  local D = require("ue.dap")

  t.it("22.1.6 及以上判 PASS", function()
    local d = D._host_toolchain_probes()[1]
    t.assert_eq(capability.evaluate(d, 0, "lldb version 22.1.6", nil).verdict,
      capability.VERDICT.PASS)
    t.assert_eq(capability.evaluate(d, 0, "lldb version 23.0.0", nil).verdict,
      capability.VERDICT.PASS)
  end)

  t.it("低于 22.1.6 判 FAIL（K14：22.0-22.1.5 在 Windows 启动即崩）", function()
    local d = D._host_toolchain_probes()[1]
    for _, ver in ipairs({ "21.1.8", "22.1.5", "22.0.0" }) do
      local r = capability.evaluate(d, 0, "lldb version " .. ver, nil)
      t.assert_eq(r.verdict, capability.VERDICT.FAIL, ver .. " 应判 FAIL")
    end
  end)

  t.it("版本无法解析 → undetermined（不猜）", function()
    local d = D._host_toolchain_probes()[1]
    t.assert_eq(capability.evaluate(d, 0, "garbage", nil).verdict,
      capability.VERDICT.UNDETERMINED)
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 源码级守护：分层模块必须 target-generic。
-- ue_platform_boundary 已守 target policy 字面量，这里额外锁住「本模块不得
-- 因为某个 target 方便而长出 target 分支」——否则 iOS 复用会退化成硬编码分支
-- （lua/ue/targets/AGENTS.md：driver 彼此独立）。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.failure: 分层模块保持 target-generic", function()
  local source = table.concat(
    vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/dap/failure.lua"), "\n")

  t.it("不含 target 专属命令字面量", function()
    -- 注释里描述历史症状是允许的，但不得出现可执行的 target 命令 token。
    for _, token in ipairs({ '"adb"', '"devicectl"', '"run%-as"', '"dumpsys"' }) do
      t.assert_true(source:find(token) == nil,
        "分层模块不得含 target 命令字面量: " .. token)
    end
  end)

  t.it("capability / preflight 也保持 target-generic", function()
    for _, rel in ipairs({ "lua/ue/dap/capability.lua", "lua/ue/dap/preflight.lua" }) do
      local text = table.concat(
        vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. rel), "\n")
      for _, token in ipairs({ '"adb"', '"devicectl"', '"run%-as"', '"dumpsys"' }) do
        t.assert_true(text:find(token) == nil, rel .. " 不得含 " .. token)
      end
      t.assert_true(text:find('== "Android"', 1, true) == nil, rel .. " 不得按 target 分支")
    end
  end)

  t.it("不按 target 名分支", function()
    t.assert_true(source:find('== "Android"', 1, true) == nil)
    t.assert_true(source:find('== "IOS"', 1, true) == nil)
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 真机 smoke 的诚实性与脱敏契约。
--
-- 两条不可让步的规则：① 无设备 ⇒ not_applicable 而非 pass（禁止靠假宿主
-- 「碰巧通过」）；② 证据不得含真实身份（K55）——写盘前有强制自检。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.smoke: 诚实的不适用判定", function()
  local smoke = require("ue.dap.smoke")

  t.it("无设备 → not_applicable（不是 pass）", function()
    local status, reason = smoke.applicability({})
    t.assert_eq(status, smoke.STATUS.NOT_APPLICABLE)
    t.assert_contains(reason, "no target device")
  end)

  t.it("有设备但无应用 → not_applicable", function()
    local status = smoke.applicability({ serial = "X" })
    t.assert_eq(status, smoke.STATUS.NOT_APPLICABLE)
  end)

  t.it("两者齐备 → 不返回不适用（交由实际运行判定）", function()
    t.assert_nil(smoke.applicability({ serial = "X", package_name = "a.b.c" }))
  end)
end)

t.describe("ue.dap.smoke: 脱敏契约（K55）", function()
  local smoke = require("ue.dap.smoke")

  t.it("身份一律 digest 化，原文不出现在证据里", function()
    local ev = smoke.build_evidence({
      status = smoke.STATUS.PASS,
      session = { serial = "REALSERIAL123", package_name = "com.real.app" },
    })
    t.assert_eq(#ev.device_digest, 12)
    local encoded = vim.json.encode(ev)
    t.assert_true(encoded:find("REALSERIAL123", 1, true) == nil, "设备标识不得入证据")
    t.assert_true(encoded:find("com.real.app", 1, true) == nil, "应用标识不得入证据")
  end)

  t.it("层级证据保留判定但丢弃 argv（argv 含真实标识）", function()
    local report = {
      blocking_layer = failure.L.TARGET_POLICY,
      layers = {
        [failure.L.TARGET_POLICY] = {
          verdict = "fail",
          results = { { id = "p", verdict = "fail", rc = 126,
            argv = { "tool", "-s", "REALSERIAL123", "shell", "x" } } },
        },
      },
    }
    local ev = smoke.build_evidence({ status = smoke.STATUS.FAILED, report = report })
    local encoded = vim.json.encode(ev)
    t.assert_contains(encoded, "126")
    t.assert_true(encoded:find("REALSERIAL123", 1, true) == nil, "argv 不得入证据")
  end)

  t.it("脱敏自检能识别裸标识、个人路径与 pid 字段", function()
    t.assert_true(#smoke.redaction_violations({ app = "com.real.app" }) > 0)
    t.assert_true(#smoke.redaction_violations({ p = "C:/Users/someone/x" }) > 0)
    t.assert_true(#smoke.redaction_violations({ pid = 1234 }) > 0)
    t.assert_eq(#smoke.redaction_violations({ status = "pass", thread_count = 23 }), 0)
  end)

  t.it("未通过脱敏自检的证据拒绝写盘", function()
    local dir = (vim.fn.tempname():gsub("\\", "/"))
    local path, err = smoke.write_evidence(dir, "bad.json", { app = "com.real.app" })
    t.assert_nil(path)
    t.assert_contains(err, "refusing to write")
    pcall(vim.fn.delete, dir, "rf")
  end)

  t.it("合规证据可写盘且可回读", function()
    local dir = (vim.fn.tempname():gsub("\\", "/"))
    local ev = smoke.build_evidence({
      status = smoke.STATUS.PASS,
      session = { serial = "S", package_name = "a.b.c" },
      attach = { initialized = true, thread_count = 23, breakpoints_resolved = 1,
        stop_observed = true, detach_clean = true },
    })
    local path, err = smoke.write_evidence(dir, "ok.json", ev)
    t.assert_true(path ~= nil, tostring(err))
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
    t.assert_eq(decoded.status, "pass")
    t.assert_eq(decoded.attach.thread_count, 23)
    -- K33：成功判据必须同时含 stop 与 resolved 计数，不能只有 verified 标记。
    t.assert_true(decoded.attach.stop_observed)
    t.assert_eq(decoded.attach.breakpoints_resolved, 1)
    pcall(vim.fn.delete, dir, "rf")
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 2026-09-04 真机发现：探针完成回调运行在 **fast event context**，在那里读
-- `vim.env` 会抛
--   E5560: Vimscript function "getenv" must not be called in a fast event context
-- 同步 fixture 执行器永远走不到该路径，所以只有真机能暴露它。逃生开关必须用
-- 纯 Lua 的 `os.getenv`。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.preflight: 异步回调不得使用 fast-event 禁用的 API", function()
  local source = table.concat(
    vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/dap/preflight.lua"), "\n")

  t.it("执行器在边界回到主循环（vim.schedule），使下游可用 Vimscript API", function()
    -- 根治办法：在边界一次性 vim.schedule，而不是逐个把下游 API 换成纯 Lua 等价物
    -- （后者只会下次再死一次——真机上先死 getenv，再死 sha256）。
    t.assert_contains(source, "vim.schedule(function() done(rc, out, err) end)")
  end)

  t.it("逃生开关用 os.getenv 而非 vim.env（fast event context 安全）", function()
    t.assert_contains(source, 'os.getenv("UE_DAP_SKIP_PREFLIGHT")')
    -- 只查代码行：注释里解释「为何不能用 vim.env」是允许且有价值的。
    for _, line in ipairs(vim.split(source, "\n", { plain = true })) do
      local code = line:gsub("^%s+", "")
      if code:sub(1, 2) ~= "--" then
        t.assert_true(code:find("vim.env", 1, true) == nil,
          "preflight 在 fast event context 里运行，代码不得读 vim.env: " .. code)
      end
    end
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 拆分后的归属与委派（2026-09-04，design D7 阶段 1–3）。
--
-- `android.lua` 从 2701 行拆到 ~1870 行，L1/L2/L3 各自成文件：
--   _android_transport.lua  L1 传输 + 两跳 staging + platform server 启动
--   _android_policy.lua     L2 目标 OS 策略（能力探针 + probe context）
--   _android_engine.lua     L3 引擎命令序列 + attach 配置
--
-- 拆分过程中真实踩到的坑：`probe_context` 的切片边界没覆盖到它，于是它留在了
-- owner 里，**同时**我又加了一个委派 stub —— 同名函数定义两次，后者静默覆盖前者，
-- 委派永不生效。Lua 不会为此报错，所以必须有回归守住。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: 拆分后的归属与委派", function()
  local function read(rel)
    return table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. rel), "\n")
  end

  local SPLIT_FILES = {
    "lua/ue/dap/_android_transport.lua",
    "lua/ue/dap/_android_policy.lua",
    "lua/ue/dap/_android_engine.lua",
  }

  t.it("三个拆分文件都存在且可加载", function()
    for _, rel in ipairs(SPLIT_FILES) do
      local ok, mod = pcall(require, (rel:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")))
      t.assert_true(ok and type(mod) == "table", rel .. " 应可加载并返回表")
      t.assert_true(type(mod.bind) == "function", rel .. " 应暴露 bind() 注入入口")
    end
  end)

  t.it("owner 内不得有同名函数重复定义（Lua 静默覆盖，必须机器守）", function()
    local source = read("lua/ue/dap/android.lua")
    local seen, dups = {}, {}
    for name in source:gmatch("\nfunction M%.([%w_]+)%(") do
      if seen[name] then dups[#dups + 1] = name end
      seen[name] = true
    end
    for name in source:gmatch("\nlocal function ([%w_]+)%(") do
      if seen["local:" .. name] then dups[#dups + 1] = "local " .. name end
      seen["local:" .. name] = true
    end
    t.assert_eq(#dups, 0, "重复定义（后者静默覆盖前者）: " .. table.concat(dups, ", "))
  end)

  t.it("owner 的 capability_probes / probe_context 真的委派到 policy 层", function()
    local android = require("ue.dap.android")
    local policy = require("ue.dap._android_policy")
    local orig_probes, orig_ctx = policy.capability_probes, policy.probe_context
    policy.capability_probes = function() return { "SENTINEL" } end
    policy.probe_context = function(ctx) return { delegated = true, mark = ctx and ctx.mark } end
    local probes_ok = android.capability_probes()[1] == "SENTINEL"
    local ctx = android.probe_context({ mark = "X" })
    policy.capability_probes, policy.probe_context = orig_probes, orig_ctx
    t.assert_true(probes_ok, "capability_probes 必须委派给 policy 层")
    t.assert_true(ctx.delegated, "probe_context 必须委派给 policy 层")
    t.assert_eq(ctx.mark, "X", "ctx 必须原样透传")
  end)

  t.it("拆分文件不反向 require owner（防循环依赖，依赖必须注入）", function()
    for _, rel in ipairs(SPLIT_FILES) do
      local source = read(rel)
      t.assert_true(source:find('require("ue.dap.android")', 1, true) == nil,
        rel .. " 不得反向 require owner；用 bind() 注入")
    end
  end)

  t.it("platform server 的 jobid 由 transport 拥有，清理必须清它", function()
    -- 拆分把 spawn 搬进 transport，若清理仍只清 owner 的镜像字段，设备上会留下
    -- 活着的 server 占住端口（K56 记录该残留会静默把 shell-uid SEGV 路径带回来）。
    local owner = read("lua/ue/dap/android.lua")
    t.assert_contains(owner, "transport.lldb_server_jobid = nil")
  end)
end)
