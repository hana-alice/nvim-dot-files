-- tests/cases/stall_probe_spec.lua
-- utils/stall_probe 回归：纯逻辑（阈值判定 / ring buffer）+ 记录捕获 +
-- 生命周期（setup/stop 幂等、命令注册）。timer 本身不在 headless 下验证
-- （probe 由 UIEnter 启动，headless 不触发——这里直接调用内部 API）。

local t = require("tests.harness")
t.bootstrap()

local probe = require("utils.stall_probe")

t.describe("stall_probe: 阈值判定 _over_threshold", function()
  t.it("gap 未超 interval+threshold → nil", function()
    t.assert_nil(probe._over_threshold(200, 100, 150))
    t.assert_nil(probe._over_threshold(249.9, 100, 150))
  end)
  t.it("gap 恰好等于 interval+threshold → 返回超出量", function()
    t.assert_eq(probe._over_threshold(250, 100, 150), 150)
  end)
  t.it("gap 大幅超出 → 返回超出量", function()
    t.assert_eq(probe._over_threshold(1100, 100, 150), 1000)
  end)
end)

t.describe("stall_probe: 归属判定 _verdict（回答「谁占的」）", function()
  -- 这组用例锁的是 2026-08-25 那次排查的**决定性证据**：光知道「卡了 250ms」
  -- 无法定位，必须知道这段 gap 里本进程烧了多少 CPU。缺这个比值时，6 次
  -- 实验都追错了方向（见 K52）。
  t.it("cpu 占满整个 gap → in-process（我们自己阻塞了主循环）", function()
    local v, share = probe._verdict(250, 250)
    t.assert_eq(v, "in-process")
    t.assert_eq(share, 1.0)
  end)

  t.it("gap 里几乎没烧 cpu → descheduled（宿主超订/被剥夺调度）", function()
    local v, share = probe._verdict(0, 250)
    t.assert_eq(v, "descheduled")
    t.assert_eq(share, 0.0)
    t.assert_eq(probe._verdict(50, 250), "descheduled") -- 0.2 边界内
  end)

  t.it("中间带 → mixed（不强行二分，避免假自信）", function()
    t.assert_eq(probe._verdict(100, 250), "mixed")
  end)

  t.it("rusage 不可用时 → unknown，而不是默认猜一个", function()
    t.assert_eq(probe._verdict(nil, 250), "unknown")
    t.assert_eq(probe._verdict(250, 0), "unknown") -- gap 非法
    t.assert_nil(select(2, probe._verdict(nil, 250)))
  end)

  t.it("share 上限限幅到 1.0（rusage 粒度可能略超）", function()
    local _, share = probe._verdict(400, 250)
    t.assert_eq(share, 1.0)
  end)

  t.it("_cpu_ms_now 在本宿主可用（否则归属永远是 unknown）", function()
    local v = probe._cpu_ms_now()
    -- 宿主能力守卫：不支持 getrusage 的宿主允许 nil，但不得报错。
    if v ~= nil then
      t.assert_type(v, "number")
      t.assert_true(v >= 0, "CPU 时间不得为负")
    end
  end)
end)

t.describe("stall_probe: 记录携带归属 + 聚合报告", function()
  t.it("_capture_stall 写入 verdict / cpu_share / cpu_ms", function()
    probe.clear()
    local rec = probe._capture_stall(300, { cpu_ms = 290, gap_ms = 300 })
    t.assert_eq(rec.verdict, "in-process")
    t.assert_type(rec.cpu_share, "number")
    t.assert_eq(rec.cpu_ms, 290)
  end)

  t.it("缺少归属数据时降级为 unknown，不抛错（向后兼容旧调用）", function()
    probe.clear()
    local rec = probe._capture_stall(200)
    t.assert_eq(rec.verdict, "unknown")
    t.assert_nil(rec.cpu_share)
  end)

  t.it("summary 聚合各 verdict 计数与最差值", function()
    probe.clear()
    probe._capture_stall(300, { cpu_ms = 295, gap_ms = 300 }) -- in-process
    probe._capture_stall(500, { cpu_ms = 5, gap_ms = 500 })   -- descheduled
    probe._capture_stall(250, { cpu_ms = 100, gap_ms = 250 }) -- mixed
    local s = probe.summary()
    t.assert_eq(s.count, 3)
    t.assert_eq(s.by_verdict["in-process"], 1)
    t.assert_eq(s.by_verdict.descheduled, 1)
    t.assert_eq(s.by_verdict.mixed, 1)
    t.assert_eq(s.worst_ms, 500)
  end)

  t.it("summary 区分「有无新鲜按键」——区分前台动作与后台成因", function()
    -- 8643 条里 8518 条无新鲜按键，正是靠这个区分才判定为「后台周期性」。
    probe.clear()
    local rec = probe._capture_stall(200, { cpu_ms = 10, gap_ms = 200 })
    rec.keys = "j(0.0s) k(1.4s)" -- 模拟刚按下
    local s1 = probe.summary()
    t.assert_eq(s1.with_recent_key, 1)
    t.assert_eq(s1.no_recent_key, 0)

    probe.clear()
    local rec2 = probe._capture_stall(200, { cpu_ms = 10, gap_ms = 200 })
    rec2.keys = "j(4.2s) k(9.9s)" -- 全是陈旧按键
    local s2 = probe.summary()
    t.assert_eq(s2.with_recent_key, 0)
    t.assert_eq(s2.no_recent_key, 1)
  end)
end)

t.describe("stall_probe: ring buffer", function()
  t.it("超过 cap 丢最旧", function()
    local ring = {}
    for i = 1, 5 do
      probe._ring_push(ring, i, 3)
    end
    t.assert_eq(#ring, 3)
    t.assert_eq(ring[1], 3)
    t.assert_eq(ring[3], 5)
  end)
end)

t.describe("stall_probe: 记录捕获与生命周期", function()
  t.it("setup 注册 :StallProbe / :StallReport 并启用", function()
    probe.setup({ interval_ms = 100, threshold_ms = 150 })
    t.assert_eq(vim.fn.exists(":StallProbe"), 2, ":StallProbe 未注册")
    t.assert_eq(vim.fn.exists(":StallReport"), 2, ":StallReport 未注册")
    t.assert_true(probe.status().enabled, "setup 后应 enabled")
  end)

  t.it("_capture_stall 产出完整记录并进 ring", function()
    probe.clear()
    local rec = probe._capture_stall(320.4)
    t.assert_eq(rec.over_ms, 320)
    t.assert_type(rec.time, "string")
    t.assert_type(rec.mode, "string")
    t.assert_type(rec.buf, "string")
    t.assert_eq(#probe.get_stalls(), 1)
  end)

  t.it("clear 清空记录", function()
    probe._capture_stall(200)
    probe.clear()
    t.assert_eq(#probe.get_stalls(), 0)
  end)

  t.it("stop 幂等且关闭 enabled", function()
    probe.stop()
    probe.stop() -- 第二次不得抛错
    t.assert_false(probe.status().enabled, "stop 后应 disabled")
  end)

  t.it("stop 后可重新 setup", function()
    probe.setup({ interval_ms = 100, threshold_ms = 150 })
    t.assert_true(probe.status().enabled)
    probe.stop()
  end)
end)
