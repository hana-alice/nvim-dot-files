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
