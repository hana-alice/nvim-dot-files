-- tests/cases/cpu_admission_spec.lua
-- 宿主 CPU 压力下的后台工作准入控制
-- （change: throttle-background-work-under-cpu-pressure）
--
-- 背景（用户报告）：平时机器正常，一开 Neovide，一分钟内 clangd + rustc 就把 CPU 挤满。
-- 根因不是我们算错了并发度，而是**并发预算是静态的**：`ue.clangd_jobs` 在启动时按 RAM+核数
-- 一次性算出 -j（本机 24 核 → -j=20，保留 4 核给 UI），此后不再调整。而实测该机器 top CPU
-- 进程里没有一个是我们的（rustc / 多个 zellij / Chrome / AppControl）——我们"保留"的 4 核
-- 在别人也满载时根本不存在。
--
-- 静态预算只能防"我们自己占满"，防不住"在别人已占满时我们继续加压"。
--
-- 这里断言的是**判定逻辑与采样算术**，不是真实负载时序（时序在不同宿主上不稳定，
-- 会变成假红灯）。真实端到端由用户在自身会话观察。

local t = require("tests.harness")
t.bootstrap()

local cpu_load = require("utils.cpu_load")
local host_admission = require("utils.host_admission")
local idx = require("ue.index")

-- 只扫描**可执行代码**：注释里说明"为何不用 vim.fn.system / uv.loadavg / renice"
-- 是有价值的文档，不该被禁止模式误判。剥掉行注释后再匹配。
local function code_only(relpath)
  local lines = vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. relpath)
  local out = {}
  for _, line in ipairs(lines) do
    -- 去掉整行注释与行尾注释（本仓无 -- 出现在字符串内的情况）
    local stripped = line:gsub("%-%-.*$", "")
    out[#out + 1] = stripped
  end
  return table.concat(out, " ")
end

t.describe("cpu_load: 常驻轻量 CPU 感知（禁止 spawn 子进程）", function()
  local function install_manual()
    local now_ns, host_i, editor_i = 0, 0, 0
    local hosts = {
      { idle = 100, total = 1000, cpus = 4 },
      { idle = 110, total = 1100, cpus = 4 }, -- host = 90%
      { idle = 190, total = 1200, cpus = 4 }, -- host = 60%
    }
    local editor_ms = { 0, 200, 220 }
    cpu_load.reset()
    local ok = cpu_load.setup({
      force = true,
      manual = true,
      now = function() return now_ns end,
      host_reader = function()
        host_i = host_i + 1
        return hosts[math.min(host_i, #hosts)]
      end,
      editor_reader = function()
        editor_i = editor_i + 1
        return editor_ms[math.min(editor_i, #editor_ms)]
      end,
    })
    t.assert_true(ok)
    return {
      advance = function(ms, force_host)
        now_ns = now_ns + ms * 1e6
        cpu_load._tick(force_host)
      end,
      calls = function() return host_i, editor_i end,
    }
  end

  t.it("暴露 lifecycle / reading / host+editor pure functions", function()
    for _, k in ipairs({
      "setup", "stop", "reading", "snapshot", "rusage_cpu_ms", "busy",
      "busy_from_samples", "process_busy_from_samples", "update_signal",
      "reset", "status", "_tick",
    }) do
      t.assert_type(cpu_load[k], "function", "cpu_load." .. k)
    end
  end)

  t.it("MUST NOT 通过子进程测负载（K40：周期性同步 spawn 会钉住主循环）", function()
    local src = code_only("lua/utils/cpu_load.lua")
    for _, bad in ipairs({ "vim%.fn%.system", "vim%.fn%.systemlist", "jobstart", "vim%.system" }) do
      t.assert_nil(src:match(bad), "负载采样不得 spawn 子进程：" .. bad)
    end
  end)

  t.it("MUST NOT 使用 uv.loadavg（Windows 上恒为 0，会误报空闲）", function()
    t.assert_nil(code_only("lua/utils/cpu_load.lua"):match("uv%.loadavg%("),
      "不得调用 uv.loadavg 作为判据")
  end)

  t.it("感知层 MUST NOT 持有准入水位、推迟上限或进程动作", function()
    local src = code_only("lua/utils/cpu_load.lua")
    for _, bad in ipairs({
      "high_pct", "low_pct", "max_deferrals", "admit_background_phase",
      "SetPriorityClass", "ProcessorAffinity", "jobstop", "terminate",
    }) do
      t.assert_nil(src:find(bad, 1, true), "感知层混入策略：" .. bad)
    end
  end)

  t.it("host 差分正常；无进展/回退必须 unknown", function()
    t.assert_eq(cpu_load.busy_from_samples({ idle = 100, total = 200 }, { idle = 110, total = 300 }), 90)
    t.assert_eq(cpu_load.busy_from_samples({ idle = 0, total = 0 }, { idle = 100, total = 100 }), 0)
    t.assert_eq(cpu_load.busy_from_samples({ idle = 0, total = 0 }, { idle = 0, total = 100 }), 100)
    t.assert_nil(cpu_load.busy_from_samples({ idle = 1, total = 2 }, { idle = 1, total = 2 }))
    t.assert_nil(cpu_load.busy_from_samples({ idle = 10, total = 20 }, { idle = 5, total = 30 }))
    t.assert_nil(cpu_load.busy_from_samples(nil, { idle = 1, total = 2 }))
  end)

  t.it("editor process 差分同时给出单核与整机份额", function()
    local value = cpu_load.process_busy_from_samples(
      { cpu_ms = 100, at_ns = 0, cpus = 4 },
      { cpu_ms = 300, at_ns = 1e9, cpus = 4 })
    t.assert_eq(value.core_pct, 20)
    t.assert_eq(value.machine_pct, 5)
    t.assert_nil(cpu_load.process_busy_from_samples(
      { cpu_ms = 300, at_ns = 1e9, cpus = 4 },
      { cpu_ms = 200, at_ns = 2e9, cpus = 4 }))
    t.assert_nil(cpu_load.process_busy_from_samples(
      { cpu_ms = 100, at_ns = 1e9, cpus = 4 },
      { cpu_ms = 200, at_ns = 1e9, cpus = 4 }))
  end)

  t.it("首个差分间隔明确 warming；之后首次查询直接读缓存", function()
    local env = install_manual()
    local warm = cpu_load.reading()
    t.assert_eq(warm.status, "warming")
    t.assert_nil(warm.host_pct, "warming 不得伪装成 idle=0")
    t.assert_nil(cpu_load.busy())

    env.advance(1000, true)
    local ready = cpu_load.reading()
    t.assert_eq(ready.status, "ready")
    t.assert_eq(ready.host_pct, 90)
    t.assert_eq(ready.editor_core_pct, 20)
    t.assert_eq(ready.editor_pct, 5)
    t.assert_eq(ready.unattributed_pct, 85)
  end)

  t.it("查询只读缓存，不得触发新采样", function()
    local env = install_manual()
    env.advance(1000, true)
    local host_before, editor_before = env.calls()
    for _ = 1, 100 do
      cpu_load.reading()
      cpu_load.busy()
      cpu_load.status()
    end
    local host_after, editor_after = env.calls()
    t.assert_eq(host_after, host_before)
    t.assert_eq(editor_after, editor_before)
  end)

  t.it("整机与 Neovim 信号独立可见；差值只能叫 unattributed", function()
    local env = install_manual()
    env.advance(1000, true)
    local reading = cpu_load.reading()
    t.assert_eq(reading.host_pct, 90)
    t.assert_eq(reading.editor_pct, 5)
    t.assert_eq(reading.unattributed_pct, 85)
    t.assert_nil(reading.external_pct, "getrusage 不含 live children，不得虚构 external 归属")
  end)

  t.it("EMA 抑制单次尖峰并暴露回落趋势", function()
    local base = cpu_load.update_signal(nil, 20, 0.25)
    local spike = cpu_load.update_signal(base.smoothed_pct, 100, 0.25)
    local back = cpu_load.update_signal(spike.smoothed_pct, 20, 0.25)
    t.assert_eq(base.smoothed_pct, 20)
    t.assert_eq(spike.smoothed_pct, 40)
    t.assert_true(spike.smoothed_pct < spike.raw_pct, "尖峰必须被 EMA 抑制")
    t.assert_eq(spike.trend, "rising")
    t.assert_eq(back.trend, "falling")
  end)

  t.it("计数器不推进后状态 unknown，旧缓存不得冒充当前读数", function()
    local now_ns, calls = 0, 0
    cpu_load.reset()
    cpu_load.setup({
      force = true,
      manual = true,
      now = function() return now_ns end,
      host_reader = function()
        calls = calls + 1
        if calls == 1 then return { idle = 10, total = 100, cpus = 4 } end
        if calls == 2 then return { idle = 20, total = 200, cpus = 4 } end
        return { idle = 20, total = 200, cpus = 4 }
      end,
      editor_reader = function() return 0 end,
    })
    now_ns = 1e9
    cpu_load._tick(true)
    t.assert_eq(cpu_load.reading().status, "ready")
    now_ns = 2e9
    cpu_load._tick(true)
    local unknown = cpu_load.reading()
    t.assert_eq(unknown.status, "unknown")
    t.assert_nil(unknown.host_pct)
  end)

  t.it("一个计时器分层采样：editor 4Hz，host 1Hz", function()
    local now_ns, host_calls, editor_calls, callback = 0, 0, 0, nil
    local fake_timer = { closed = false }
    function fake_timer:start(_, _, cb) callback = cb end
    function fake_timer:stop() end
    function fake_timer:close() self.closed = true end

    cpu_load.reset()
    local ok = cpu_load.setup({
      force = true,
      now = function() return now_ns end,
      host_reader = function()
        host_calls = host_calls + 1
        return { idle = host_calls * 10, total = host_calls * 100, cpus = 4 }
      end,
      editor_reader = function() editor_calls = editor_calls + 1; return editor_calls end,
      timer_factory = function() return fake_timer end,
    })
    t.assert_true(ok)
    t.assert_type(callback, "function")
    for _ = 1, 4 do
      now_ns = now_ns + 250e6
      callback()
    end
    t.assert_eq(host_calls, 2, "baseline + 1Hz host sample")
    t.assert_eq(editor_calls, 5, "baseline + 4Hz editor samples")
    cpu_load.reset()
    t.assert_true(fake_timer.closed)
  end)

  t.it("headless 不常驻；UIEnter 接入点位于 init.lua", function()
    cpu_load.reset()
    local timer_requested = false
    local started, reason = cpu_load.setup({ timer_factory = function()
      timer_requested = true
      return nil
    end })
    t.assert_false(started)
    t.assert_eq(reason, "no-ui")
    t.assert_false(timer_requested)
    local init = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/init.lua"), "\n")
    local ui_at = init:find('nvim_create_autocmd%("UIEnter"')
    local awareness_at = init:find('require%("utils%.cpu_load"%)%.setup%(%)')
    t.assert_type(ui_at, "number")
    t.assert_type(awareness_at, "number")
    t.assert_true(ui_at < awareness_at, "感知层只能在 UIEnter 后常驻")
  end)

  t.it("缓存查询稳态开销低于 0.05ms/call", function()
    local env = install_manual()
    env.advance(1000, true)
    local count, started = 10000, vim.uv.hrtime()
    for _ = 1, count do cpu_load.reading() end
    local per_call_ms = (vim.uv.hrtime() - started) / 1e6 / count
    t.assert_true(per_call_ms < 0.05,
      ("reading() 必须是轻量缓存读取，实际 %.5fms/call"):format(per_call_ms))
    t.assert_true(cpu_load.HOST_INTERVAL_MS >= 1000, "昂贵的 cpu_info 不得高频调用")
  end)

  t.it("真实宿主/rusage 能力守卫", function()
    local host = cpu_load.snapshot()
    if host ~= nil then
      t.assert_type(host.total, "number")
      t.assert_true(host.cpus >= 1)
    end
    local editor_ms = cpu_load.rusage_cpu_ms()
    if editor_ms ~= nil then t.assert_true(editor_ms >= 0) end
    -- Full suite shares one Neovim process; synthetic 90% cache must not leak
    -- into later CDB/csearch tests and legitimately defer their fake spawns.
    cpu_load.reset()
  end)
end)

t.describe("通用准入判定：高负载推迟、前台优先、滞回、防饿死", function()
  local A = idx.admit_background_phase
  local base = { enabled = true, high_pct = 85, low_pct = 70, max_deferrals = 20 }

  t.it("index 只做通用策略的薄委派（函数引用相同，防阈值漂移）", function()
    t.assert_eq(idx.admit_background_phase, host_admission.admit)
    t.assert_eq(idx.admission_opts, host_admission.options)
    t.assert_type(idx.ADMISSION_RETRY_MS, "number")
    local source = code_only("lua/ue/index/_admission.lua")
    for _, forbidden in ipairs({ "85", "70", "high_pct", "low_pct", "max_deferrals" }) do
      t.assert_nil(source:find(forbidden, 1, true), "index delegate 不得保留策略：" .. forbidden)
    end
  end)

  t.it("高于高水位 → 推迟（不在别人满载时加压）", function()
    local allow, reason = A(95, 0, base)
    t.assert_false(allow)
    t.assert_eq(reason, "host-cpu-above-high-watermark")
    -- 用户指定的 85% 边界必须是"达到即推迟"。
    t.assert_false((A(85, 0, base)), "恰好 85% 应推迟")
  end)

  t.it("低于低水位 → 允许", function()
    local allow, reason = A(60, 0, base)
    t.assert_true(allow)
    t.assert_eq(reason, "host-cpu-below-low-watermark")
  end)

  t.it("滞回带：维持上一决策，避免单阈值抖动启停", function()
    -- 78% 落在 70..85 之间。
    t.assert_true((A(78, 0, vim.tbl_extend("force", base, { was_deferring = false }))),
      "此前未推迟 → 继续允许")
    t.assert_false((A(78, 3, vim.tbl_extend("force", base, { was_deferring = true }))),
      "此前在推迟 → 继续推迟（滞回）")
  end)

  t.it("推迟有上限：宿主长期繁忙不得饿死交付", function()
    local allow, reason = A(99, 20, base)
    t.assert_true(allow, "达到推迟上限后必须放行")
    t.assert_eq(reason, "defer-cap-reached")
  end)

  t.it("负载不可测 → 允许（监控缺口不得变成永久停摆）", function()
    local allow, reason = A(nil, 0, base)
    t.assert_true(allow)
    t.assert_eq(reason, "load-unknown")
    local unknown_allow, unknown_reason = A({ status = "unknown", host_pct = nil }, 0, base)
    t.assert_true(unknown_allow)
    t.assert_eq(unknown_reason, "load-unknown")
  end)

  t.it("warming 与 unsupported 分开：冷态短暂让路，不冒充 idle", function()
    local allow, reason = A({
      status = "warming",
      host_pct = nil,
      editor_pct = nil,
      host_trend = "unknown",
    }, 0, base)
    t.assert_false(allow)
    t.assert_eq(reason, "load-awareness-warming")
    -- 即便传入完整 reading，ready 后仍按同一高水位策略判断。
    t.assert_false((A({ status = "ready", host_pct = 95, editor_pct = 1, host_trend = "rising" }, 0, base)))
  end)

  t.it("用户前台任务优先：CPU defer cap/关闭 sensor 都不得穿透 active build", function()
    local allow, reason = A(10, 999, vim.tbl_extend("force", base, { foreground_active = true }))
    t.assert_false(allow)
    t.assert_eq(reason, "foreground-work-active")
    local disabled = A(10, 0, { enabled = false, foreground_active = true })
    t.assert_false(disabled, "关闭 CPU gate 不等于关闭前台互斥")
  end)

  t.it("关闭开关 → 恒允许且不做判定", function()
    local allow, reason = A(99, 0, { enabled = false })
    t.assert_true(allow)
    t.assert_eq(reason, "admission-disabled")
  end)

  t.it("倒置配置（low > high）不得让滞回带崩塌成误放行", function()
    local allow = A(95, 0, { enabled = true, high_pct = 85, low_pct = 99, max_deferrals = 20 })
    t.assert_false(allow, "95% 高于 high=85 仍必须推迟")
  end)

  t.it("默认阈值符合用户要求（85% 高水位）", function()
    local o = idx.admission_opts()
    t.assert_eq(o.high_pct, 85)
    t.assert_true(o.low_pct < o.high_pct, "必须是双水位滞回")
    t.assert_true(o.enabled ~= false, "默认启用")
    t.assert_true(o.max_deferrals > 0, "必须有推迟上限")
  end)

  t.it("通用环境变量优先，旧 UE_INDEX 变量仍兼容", function()
    local old = {
      h = vim.env.NVIM_HOST_CPU_HIGH_PCT,
      e = vim.env.NVIM_HOST_CPU_ADMISSION,
      legacy_h = vim.env.UE_INDEX_CPU_HIGH_PCT,
      legacy_e = vim.env.UE_INDEX_CPU_ADMISSION,
    }
    vim.env.UE_INDEX_CPU_HIGH_PCT = "50"
    vim.env.UE_INDEX_CPU_ADMISSION = "0"
    t.assert_eq(idx.admission_opts().high_pct, 50)
    t.assert_false(idx.admission_opts().enabled)
    vim.env.NVIM_HOST_CPU_HIGH_PCT = "60"
    vim.env.NVIM_HOST_CPU_ADMISSION = "1"
    local general = idx.admission_opts()
    vim.env.NVIM_HOST_CPU_HIGH_PCT, vim.env.NVIM_HOST_CPU_ADMISSION = old.h, old.e
    vim.env.UE_INDEX_CPU_HIGH_PCT, vim.env.UE_INDEX_CPU_ADMISSION = old.legacy_h, old.legacy_e
    t.assert_eq(general.high_pct, 60)
    t.assert_true(general.enabled)
  end)

  t.it("foreground lifecycle 是引用计数；最后一个完成时立即唤醒 queued batch", function()
    host_admission._reset_for_test()
    local token_a = host_admission.foreground_begin("build")
    local token_b = host_admission.foreground_begin("install")
    t.assert_eq(host_admission.foreground_status().count, 2)

    local callback, starts = nil, 0
    local fake_timer = {}
    function fake_timer:start(_, _, cb) callback = cb end
    function fake_timer:stop() end
    function fake_timer:close() end
    local started, _, _, control = host_admission.run_when_allowed({
      name = "test batch",
      reading = function() return { status = "ready", host_pct = 10 } end,
      timer_factory = function() return fake_timer end,
      schedule = function(fn) fn() end,
      start = function() starts = starts + 1; return "started" end,
    })
    t.assert_false(started)
    t.assert_true(control.pending)
    t.assert_eq(control.deferrals, 0, "foreground 等待不得消耗 CPU defer cap")
    t.assert_type(callback, "function")
    host_admission.foreground_done(token_a)
    t.assert_eq(starts, 0, "仍有 install 时不得唤醒")
    host_admission.foreground_done(token_b)
    t.assert_eq(starts, 1, "最后一个前台任务完成后立即重试")
    t.assert_false(host_admission.foreground_active())
  end)

  t.it("长前台任务不消耗 CPU cap；结束后若仍高负载继续等", function()
    host_admission._reset_for_test()
    local token = host_admission.foreground_begin("long build")
    local callback, starts = nil, 0
    local fake_timer = {}
    function fake_timer:start(_, _, cb) callback = cb end
    function fake_timer:stop() end
    function fake_timer:close() end
    local _, _, _, control = host_admission.run_when_allowed({
      reading = function() return { status = "ready", host_pct = 95 } end,
      timer_factory = function() return fake_timer end,
      schedule = function(fn) fn() end,
      start = function() starts = starts + 1 end,
    })
    for _ = 1, 25 do callback() end
    t.assert_eq(control.deferrals, 0)
    host_admission.foreground_done(token)
    t.assert_eq(starts, 0)
    t.assert_eq(control.deferrals, 1, "前台结束后才开始计 CPU deferral")
    control:cancel()
  end)

  t.it("通用 queue 在 CPU 回落前不调用 start，回落后只调用一次", function()
    host_admission._reset_for_test()
    local busy, callback, starts = 95, nil, 0
    local fake_timer = {}
    function fake_timer:start(_, _, cb) callback = cb end
    function fake_timer:stop() end
    function fake_timer:close() end
    local started, _, _, control = host_admission.run_when_allowed({
      reading = function() return { status = "ready", host_pct = busy } end,
      options = { high_pct = 85, low_pct = 70, max_deferrals = 20 },
      timer_factory = function() return fake_timer end,
      schedule = function(fn) fn() end,
      start = function() starts = starts + 1; return function() end end,
    })
    t.assert_false(started)
    t.assert_eq(starts, 0)
    busy = 60
    callback()
    t.assert_eq(starts, 1)
    t.assert_true(control.started)
    t.assert_false(control.pending)
    -- stale timer/callback delivery must not double-start.
    callback()
    t.assert_eq(starts, 1)
  end)
end)

t.describe("调度接入：推迟不得丢阶段、不得杀在跑的构建", function()
  local src
  local function sched_src()
    if not src then
      src = table.concat(vim.fn.readfile(
        vim.fn.stdpath("config") .. "/lua/ue/index/_schedule.lua"), "\n")
    end
    return src
  end

  t.it("启动前消费完整 awareness reading", function()
    local s = sched_src()
    local reading_at = s:find("cpu_load%.reading")
    local admit_at = s:find("M%.admit_background_phase%(load, deferred, policy%)")
    local start_at = s:find("M%.build_phase_async%(ctx, phase%)")
    t.assert_type(reading_at, "number", "调度必须读取常驻缓存")
    t.assert_type(admit_at, "number", "调度必须调用准入判定")
    t.assert_type(start_at, "number", "未找到构建启动点")
    t.assert_true(reading_at < admit_at and admit_at < start_at,
      "读取 → 准入 → 启动的顺序不得颠倒")
    t.assert_match(s, "editor_pct = reading%.editor_pct", "诊断必须携带 editor 信号")
    t.assert_match(s, "host_trend = reading%.host_trend", "诊断必须携带趋势")
  end)

  t.it("queued-drain 第二启动路径也必须先过同一 gate", function()
    local build = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue/index/_build.lua"), "\n")
    local queue_at = assert(build:find("M.try_start_queued_build", 1, true))
    local gate_at = assert(build:find("M.admit_index_phase_start", queue_at, true))
    local start_at = assert(build:find("M.build_phase_async(picked_ctx, picked_phase)", queue_at, true))
    t.assert_true(gate_at < start_at, "queued phase 不得绕过 admission")
    t.assert_match(sched_src(), 'reason == "foreground%-work%-active" and deferred or deferred %+ 1')
  end)

  t.it("推迟后重排（阶段不得丢失）", function()
    t.assert_match(sched_src(), "M%.schedule_index_phase%(ctx, phase, M%.ADMISSION_RETRY_MS",
      "推迟必须重排，否则该阶段永远不再启动")
  end)

  t.it("重排保持原有 protect 级别（不得丢失反饿死保证）", function()
    t.assert_match(sched_src(), "protect = protect_again",
      "受保护的交付 deadline 在推迟重排后必须仍受保护")
  end)

  t.it("MUST NOT 杀掉已在运行的构建（否则已完成工作被浪费）", function()
    local s = code_only("lua/ue/index/_schedule.lua")
    for _, bad in ipairs({ "kill", "jobstop", "terminate" }) do
      t.assert_nil(s:match(bad), "调度层不得终止在跑的构建：" .. bad)
    end
  end)

  t.it("推迟原因可观测（可诊断，且遵守 P5 不刷屏）", function()
    local s = sched_src()
    t.assert_match(s, "deferred index phase under host CPU pressure",
      "推迟必须留下可诊断记录")
    -- 用 debug 级别而非 notify：这是常态调节，不该反复弹窗打扰用户。
    t.assert_match(s, "debug_ctx", "常态推迟应走 debug 日志而非 notify")
  end)
end)

t.describe("边界诚实性：只抑制自己的工作", function()
  t.it("不得尝试挂起/降级/终止外部进程（rustc 等不是我们的）", function()
    for _, f in ipairs({ "lua/ue/index/_admission.lua", "lua/utils/cpu_load.lua" }) do
      local src = code_only(f)
      for _, bad in ipairs({ "taskkill", "Stop%-Process", "SetPriorityClass", "renice" }) do
        t.assert_nil(src:match(bad), f .. " 不得操作外部进程：" .. bad)
      end
    end
  end)
end)
