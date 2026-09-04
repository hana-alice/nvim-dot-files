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
    t.assert_contains(text, "BLOCKS ATTACH")
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

-- ════════════════════════════════════════════════════════════════════════
-- 任务 5.4：L2 门禁的**行为**断言（此前只有真机手工验证覆盖）。
--
-- 门禁的全部意义是「在发起引擎连接之前拦下」。所以要断言的不是「报了错」，
-- 而是**连接从未被发起**——这正是 K56/K58 那两条坑的教训：一旦走到 L3，
-- 同一个策略拒绝就只会表现成 `lost connection` / `The parameter is incorrect`。
--
-- 用注入执行器驱动探针，因此无需设备。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: L2 门禁必须先于引擎连接", function()
  local android = require("ue.dap.android")

  local function fixture(map)
    return function(argv, done)
      local key = table.concat(argv, " ")
      for pattern, res in pairs(map) do
        if key:find(pattern) then return done(res.rc, res.out, nil) end
      end
      done(0, "")
    end
  end

  local function run_gate(map)
    local sess = {
      adb = "adb", serial = "SERIAL-TEST",
      package_name = "test.pkg.name", pid = 4242,
    }
    local continued, refused = false, nil
    -- stop_android_debugger 会碰设备与 nvim-dap；门禁测试只关心「是否推进」。
    local saved_stop = android.stop_android_debugger
    android.stop_android_debugger = function() return {} end
    android._gate_then_start(sess, function() continued = true end, {
      executor = fixture(map),
      on_refused = function(_, text) refused = text end,
    })
    android.stop_android_debugger = saved_stop
    return { continued = continued, refused = refused, sess = sess }
  end

  t.it("L2 明确 FAIL → 不调用 continue（引擎连接从未发起）", function()
    -- rc=11 = staged 但不可执行，K58 的真形状。
    local r = run_gate({ ["test %-x"] = { rc = 11, out = "" } })
    t.assert_false(r.continued,
      "L2 红灯时 MUST NOT 推进到 start_lldb_server_platform / platform connect")
    t.assert_true(r.refused ~= nil, "必须产出带层归属的拒绝")
    t.assert_contains(r.refused, "L2")
  end)

  t.it("拒绝文本含确切命令与 rc，且处置在证据之后", function()
    local r = run_gate({ ["test %-x"] = { rc = 11, out = "" } })
    t.assert_contains(r.refused, "rc=11")
    t.assert_contains(r.refused, "run-as test.pkg.name")
    local ev = r.refused:find("evidence:", 1, true)
    local nx = r.refused:find("next:", 1, true)
    t.assert_true(ev and nx and ev < nx, "evidence 必须先于 remedy")
  end)

  t.it("L2 全通过 → 正常推进", function()
    local r = run_gate({})
    t.assert_true(r.continued, "无阻塞层时必须继续 attach")
    t.assert_nil(r.refused)
  end)

  t.it("L2 未判定（设备掉线）→ 仍推进，不误拦", function()
    local r = run_gate({
      ["test %-x"] = { rc = nil, out = nil },
      ["cat /proc/"] = { rc = nil, out = nil },
    })
    t.assert_true(r.continued, "未判定不得阻断：宁可漏拦不可误拦")
  end)

  t.it("逃生开关：跳过门禁并在 session 上留痕", function()
    local saved = vim.env.UE_DAP_SKIP_PREFLIGHT
    vim.env.UE_DAP_SKIP_PREFLIGHT = "1"
    local r = run_gate({ ["test %-x"] = { rc = 11, out = "" } })
    vim.env.UE_DAP_SKIP_PREFLIGHT = saved
    t.assert_true(r.continued, "显式跳过时必须放行")
    t.assert_true(r.sess._preflight_skipped,
      "跳过必须留痕，否则后续失败取证会被误导成「门禁已放行」")
  end)

  t.it("门禁只跑 L2 探针（不在 attach 前跑 L0/L1/L3/L4）", function()
    local seen = {}
    local sess = { adb = "adb", serial = "S", package_name = "p.k.g", pid = 1 }
    local saved_stop = android.stop_android_debugger
    android.stop_android_debugger = function() return {} end
    android._gate_then_start(sess, function() end, {
      executor = function(argv, done)
        seen[#seen + 1] = table.concat(argv, " ")
        done(0, "")
      end,
    })
    android.stop_android_debugger = saved_stop
    -- L0 是宿主 adapter 版本探测；它不该出现在 attach 前的 L2 子集里。
    for _, cmd in ipairs(seen) do
      t.assert_true(cmd:find("--version", 1, true) == nil,
        "attach 门禁不得跑 L0 adapter 探针: " .. cmd)
    end
    t.assert_true(#seen > 0, "L2 子集不应为空")
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 探针必须 rc 与输出一致才下结论（2026-09-04 由 5.4 的行为测发现）。
--
-- 原实现只看「输出里有没有数字」：rc=0 且输出为空时被判 FAIL，于是一次本该
-- 通过的门禁把 attach 拦掉了。rc 与输出**不一致**说明命令没真正执行（或输出被
-- 包装层吃掉），那是「未判定」而不是「应用没跑」——判 FAIL 会误拦。
--
-- 真机语义（同机实测）：进程存在 → rc=0 + pid；不存在 → rc=1 + 空。
-- 顺带排除了一个假信号：`pgrep -f <pat>` 会匹配到**自己的命令行**，对不存在的
-- 模式也返回 pid，因此不能用它替代 pidof。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: 探针需 rc 与输出一致（不一致即未判定）", function()
  local android = require("ue.dap.android")
  local capability = require("ue.dap.capability")

  local function probe_by_id(id)
    for _, d in ipairs(android.capability_probes()) do
      if d.id == id then return d end
    end
  end

  t.it("rc=0 + pid → PASS", function()
    local r = capability.evaluate(probe_by_id("target-process-running"), 0, "32129\n", nil)
    t.assert_eq(r.verdict, capability.VERDICT.PASS)
    t.assert_contains(r.detail, "32129")
  end)

  t.it("rc≠0 + 空输出 → FAIL（应用确实没跑）", function()
    local r = capability.evaluate(probe_by_id("target-process-running"), 1, "", nil)
    t.assert_eq(r.verdict, capability.VERDICT.FAIL)
    t.assert_contains(r.detail, "not running")
  end)

  t.it("rc=0 但无输出 → undetermined，MUST NOT 误判为「没跑」", function()
    local r = capability.evaluate(probe_by_id("target-process-running"), 0, "", nil)
    t.assert_eq(r.verdict, capability.VERDICT.UNDETERMINED,
      "rc 与输出不一致时判 FAIL 会误拦一次本可成功的 attach")
    t.assert_contains(r.detail, "inconsistent")
  end)

  t.it("rc≠0 但有 pid → undetermined（同样不一致）", function()
    local r = capability.evaluate(probe_by_id("target-process-running"), 1, "999\n", nil)
    t.assert_eq(r.verdict, capability.VERDICT.UNDETERMINED)
  end)

  t.it("其余 L2 探针都以 rc 为主判据（源断言，防同类回归）", function()
    local source = table.concat(
      vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/dap/_android_policy.lua"), "\n")
    -- 不得再出现「只看输出有没有数字就判 FAIL」的形状。
    t.assert_true(
      source:find('if tostring(out or ""):match("%d+") then return { verdict = V.PASS', 1, true) == nil,
      "探针不得只凭输出含数字下结论，必须与 rc 一致")
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 任务 2.4：源码级守护——DAP owner 不得新增「无层归属」的用户可见失败。
--
-- 四元组构造器已在**运行期**强制 layer（缺 layer 直接 error），但那只覆盖
-- 已经走 failure.* 的路径。新增一个裸 `P.error("...")` / `notify_error("...")`
-- 会绕过它，且 Lua 不会报错——所以需要源码扫描把「发出点」也守住。
--
-- 白名单只能缩小，不能扩大：每一项都要写明为何它不是无层失败。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap: 失败发出点必须带层归属（源码守护）", function()
  local function read(rel)
    return table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. rel), "\n")
  end

  -- 允许的裸发出点，每条附理由。缩小即可，扩大需在此写清为何无需层归属。
  local ALLOWED = {
    -- report_failure 自己就是层归属的实现者：它先构造四元组再渲染。
    ["P.error(spec.headline or spec.summary or \"attach failed\")"] =
      "report_failure 内部：层归属由 failure.new 强制",
    -- 门禁自身的 headline；紧随其后就 notify 出完整四元组文本。
    ["P.error(\"attach refused at L2 (target OS policy)\")"] =
      "L2 门禁：层已在 headline 与随后的 failure.format 文本中",
  }

  t.it("android owner 的裸 P.error 均在白名单内", function()
    local source = read("lua/ue/dap/android.lua")
    local unlisted = {}
    for line in source:gmatch("[^\n]+") do
      local trimmed = line:gsub("^%s+", "")
      -- 只看代码行，注释里引用历史写法是允许的。
      if trimmed:sub(1, 2) ~= "--" and trimmed:find("P.error(", 1, true) then
        if not ALLOWED[trimmed] then unlisted[#unlisted + 1] = trimmed end
      end
    end
    t.assert_eq(#unlisted, 0,
      "新增的裸失败发出点必须改用 report_failure/failure.new（C10：失败先报层）：\n"
      .. table.concat(unlisted, "\n"))
  end)

  t.it("attach 主路径的失败点已迁到带层归属的上报", function()
    local source = read("lua/ue/dap/android.lua")
    t.assert_contains(source, "local function report_failure(spec)")
    -- 迁移过的关键点：每个都必须声明层。
    for _, marker in ipairs({
      "headline = \"no device selected\"",
      "headline = \"lldb-server bootstrap failed\"",
      "headline = \"target process is not running\"",
      "headline = \"lldb-server platform failed\"",
      "headline = \"am set-debug-app failed\"",
      "headline = \"lldb-server re-stage failed\"",
    }) do
      t.assert_contains(source, marker)
    end
  end)

  t.it("report_failure 必经 failure.new（构造期强制 layer）", function()
    local source = read("lua/ue/dap/android.lua")
    local body = source:match("local function report_failure%(spec%)(.-)\nend")
    t.assert_true(body ~= nil, "report_failure 应存在")
    t.assert_contains(body, "F.new(spec)")
    t.assert_contains(body, "F.format(fail)")
  end)

  t.it("每个迁移点都声明了 layer（无层的 spec 会在运行期 error）", function()
    local source = read("lua/ue/dap/android.lua")
    -- 数一下 report_failure 调用次数与其中 layer= 的出现次数是否匹配。
    local calls = select(2, source:gsub("report_failure%(%{", ""))
    local layers = select(2, source:gsub("layer = require%(\"ue%.dap%.failure\"%)%.L%.", ""))
    t.assert_true(calls > 0, "应存在 report_failure 调用")
    t.assert_eq(layers, calls,
      ("每个 report_failure 都必须声明 layer（calls=%d, layer=%d）"):format(calls, layers))
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 任务 4.3：L4 符号一致性判定接通（此前只忠实上报设备值，不做比对）。
--
-- 这正是 2026-09-03 记录、当时未闭环的 follow-up：设备 versionCode=178739401
-- 与本地两个符号包（v178130152 / v178228633）都不匹配，而当时没有任何机制会
-- 提示这件事——断点会静默解析到错误的源码修订（K35/K37 语义）。
--
-- 归 L4 而非 L2 的理由：版本错配**不阻止 attach**，所以它不该拦下会话。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: L4 符号包与设备 versionCode 一致性", function()
  local policy = require("ue.dap._android_policy")
  local capability = require("ue.dap.capability")

  t.it("从符号包路径抽 versionCode（纯函数）", function()
    t.assert_eq(policy.symbol_version_code("C:/x/Client_Symbols_v178130152/libUE4.so"),
      "178130152")
    t.assert_eq(policy.symbol_version_code("/a/Game_Symbols_v42/lib/libUE4.so"), "42")
  end)

  t.it("抽不到就返回 nil（不猜一个版本号出来）", function()
    t.assert_nil(policy.symbol_version_code("C:/x/libUE4.so"))
    t.assert_nil(policy.symbol_version_code(""))
    t.assert_nil(policy.symbol_version_code(nil))
  end)

  t.it("比对三态：match / mismatch / unknown", function()
    t.assert_eq(policy.version_code_verdict("111", "111"), "match")
    t.assert_eq(policy.version_code_verdict("111", "222"), "mismatch")
    t.assert_eq(policy.version_code_verdict("111", nil), "unknown")
    t.assert_eq(policy.version_code_verdict(nil, "111"), "unknown")
  end)

  local function symbol_probe()
    for _, d in ipairs(policy.capability_probes()) do
      if d.id == "symbol-build-matches-device" then return d end
    end
  end

  t.it("真实错配形状（本月 follow-up）被判 FAIL 并归 L4", function()
    local d = symbol_probe()
    t.assert_eq(d.layer, require("ue.dap.failure").L.SYMBOL,
      "错配不阻止 attach，所以必须是 L4 而不是 L2")
    d.build_argv({ adb = "adb", serial = "S", package_name = "p",
      symbol_lib = "/x/Client_Symbols_v178130152/libUE4.so" })
    local r = capability.evaluate(d, 0, "    versionCode=178739401 minSdk=29", nil)
    t.assert_eq(r.verdict, capability.VERDICT.FAIL)
    t.assert_contains(r.detail, "178739401")
    t.assert_contains(r.detail, "178130152")
  end)

  t.it("一致时 PASS", function()
    local d = symbol_probe()
    d.build_argv({ adb = "adb", serial = "S", package_name = "p",
      symbol_lib = "/x/Client_Symbols_v111/libUE4.so" })
    t.assert_eq(capability.evaluate(d, 0, "    versionCode=111", nil).verdict,
      capability.VERDICT.PASS)
  end)

  t.it("未选符号包 → undetermined（不编造比对结果）", function()
    local d = symbol_probe()
    d.build_argv({ adb = "adb", serial = "S", package_name = "p" })
    local r = capability.evaluate(d, 0, "    versionCode=178739401", nil)
    t.assert_eq(r.verdict, capability.VERDICT.UNDETERMINED)
    t.assert_contains(r.detail, "no symbol package versionCode")
  end)

  t.it("probe_context 会带上 symbol_lib（否则比对永远 unknown）", function()
    local android = require("ue.dap.android")
    android._session.symbol_lib = "/tmp/Client_Symbols_v777/libUE4.so"
    local ctx = android.probe_context({})
    android._session.symbol_lib = nil
    t.assert_eq(policy.symbol_version_code(ctx.symbol_lib), "777")
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- 报告措辞不得自相矛盾（2026-09-04 真机发现）。
--
-- L4 符号错配曾被标 `<== BLOCKING`，而同一份输出里 `blocks_attach` 是 false ——
-- 因为只有 L2 真的拦 attach。两个说法互相打脸，读者无法判断会不会被拦。
-- 现在分两种标记：L2 → BLOCKS ATTACH；其他层 → FIRST FAILING (does not block)。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.capability: 阻塞标记必须与 blocks_attach 一致", function()
  local cap = require("ue.dap.capability")
  local pre = require("ue.dap.preflight")

  local function report_with_fail(layer)
    local report = { blocking_layer = layer, layers = {} }
    for _, l in ipairs(failure.LAYER_ORDER) do
      report.layers[l] = { verdict = (l == layer) and cap.VERDICT.FAIL or cap.VERDICT.PASS,
        results = {} }
    end
    return report
  end

  t.it("L2 失败 → 标 BLOCKS ATTACH，且 blocks_attach 为真", function()
    local r = report_with_fail(failure.L.TARGET_POLICY)
    t.assert_contains(cap.format_report(r), "BLOCKS ATTACH")
    t.assert_true(pre.blocks_attach(r))
  end)

  t.it("L4 失败 → 明说不阻断，且 blocks_attach 为假（不得自相矛盾）", function()
    local r = report_with_fail(failure.L.SYMBOL)
    local text = cap.format_report(r)
    t.assert_contains(text, "does not block attach")
    t.assert_false(pre.blocks_attach(r),
      "只有 L2 拦 attach；符号错配只影响断点解析到哪个修订")
  end)

  t.it("L0/L1/L3 失败同样不标成阻断 attach", function()
    for _, l in ipairs({ failure.L.HOST_TOOLCHAIN, failure.L.TRANSPORT, failure.L.DEBUG_ENGINE }) do
      local r = report_with_fail(l)
      t.assert_contains(cap.format_report(r), "does not block attach")
      t.assert_false(pre.blocks_attach(r))
    end
  end)
end)
