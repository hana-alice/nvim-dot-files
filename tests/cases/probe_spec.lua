-- tests/cases/probe_spec.lua
-- utils/probe 探针系统：生命周期（arm/sleep/TTL/洪水自停）+ 去重压缩 +
-- compaction（TTL 淘汰 / cap 淘汰 / 空 topic 移除）。
-- 权威规格：openspec/specs/probe-feedback-loop/spec.md

local t = require("tests.harness")
t.bootstrap()

local probe = require("utils.probe")

local function fresh(fn)
  local dir = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(dir, "p")
  probe._set_path_for_test(dir .. "/probes.json")
  fn(dir)
  probe._set_path_for_test(nil)
  pcall(vim.fn.delete, dir, "rf")
end

t.describe("probe: 写时去重压缩", function()
  t.it("同 (topic,key) 1000 次 record → 单条 count=1000", function()
    fresh(function()
      for _ = 1, 1000 do probe.record("dedup-topic", "same-key", "payload") end
      local lines = table.concat(probe.report(), "\n")
      t.assert_contains(lines, "1000x", "重复事件必须压缩为单条计数")
      -- 不应出现多条 same-key
      local _, n = lines:gsub("same%-key", "")
      t.assert_eq(n, 1, "same-key 应只出现一次")
    end)
  end)

  t.it("不同 key 各自独立计数", function()
    fresh(function()
      probe.record("multi", "a"); probe.record("multi", "a"); probe.record("multi", "b")
      local lines = table.concat(probe.report(), "\n")
      t.assert_contains(lines, "2x")
      t.assert_contains(lines, "1x")
    end)
  end)
end)

t.describe("probe: 生命周期（arm / sleep / 洪水自停）", function()
  t.it("首次 record 自动 arm；sleep 后 record 变 no-op", function()
    fresh(function()
      t.assert_true(probe.record("lifecycle", "k1"), "首次 record 应成功（自动 arm）")
      t.assert_true(probe.is_armed("lifecycle"))
      probe.sleep("lifecycle")
      t.assert_false(probe.is_armed("lifecycle"))
      t.assert_false(probe.record("lifecycle", "k2"), "休眠后 record 必须 no-op")
      -- 历史记录保留
      t.assert_contains(table.concat(probe.report(), "\n"), "k1")
    end)
  end)

  t.it("re-arm 恢复记录（迭代）", function()
    fresh(function()
      probe.record("rearm", "k1")
      probe.sleep("rearm")
      probe.arm("rearm", { days = 7 })
      t.assert_true(probe.record("rearm", "k2"), "re-arm 后应恢复记录")
    end)
  end)

  t.it("distinct key 达 max_records → 自动休眠 + _overflow 聚合", function()
    fresh(function()
      probe.arm("flood", { days = 7, max_records = 5 })
      for i = 1, 5 do probe.record("flood", "key" .. i) end
      t.assert_false(probe.record("flood", "key6"), "超上限的新 key 应被拒")
      t.assert_false(probe.is_armed("flood"), "洪水后 topic 必须自动休眠")
      t.assert_contains(table.concat(probe.report(), "\n"), "_overflow",
        "必须留下 _overflow 聚合记录（打满可见）")
    end)
  end)
end)

t.describe("probe: compaction（TTL / 空 topic 移除）", function()
  t.it("超 30 天记录被 compact 淘汰", function()
    fresh(function()
      probe.record("ttl-topic", "old-key")
      probe.record("ttl-topic", "new-key")
      probe._now_shift_for_test("ttl-topic", "old-key", -31 * 86400)
      probe._compact_for_test()
      local lines = table.concat(probe.report(), "\n")
      t.assert_true(lines:find("old%-key") == nil, "31 天前的记录应被淘汰")
      t.assert_contains(lines, "new-key")
    end)
  end)

  t.it("空且休眠的 topic 整体移除", function()
    fresh(function()
      probe.record("ghost", "only-key")
      probe._now_shift_for_test("ghost", "only-key", -31 * 86400)
      probe.sleep("ghost")
      probe._compact_for_test()
      t.assert_true(table.concat(probe.report(), "\n"):find("ghost") == nil,
        "空休眠 topic 应从存储移除（防腐烂）")
    end)
  end)

  t.it("pending_summary 统计非空 topic/record 数", function()
    fresh(function()
      probe.record("s1", "a"); probe.record("s1", "b"); probe.record("s2", "c")
      local s = probe.pending_summary()
      t.assert_eq(s.topics, 2)
      t.assert_eq(s.records, 3)
    end)
  end)
end)

t.describe("probe: 持久化往返", function()
  t.it("save→重载→记录仍在（count/键保形）", function()
    fresh(function(dir)
      probe.record("persist", "k", { x = 1 })
      probe.record("persist", "k")
      probe._flush_for_test()
      -- 模拟新会话：重置内存态、同一路径重载
      probe._set_path_for_test(dir .. "/probes.json")
      local lines = table.concat(probe.report(), "\n")
      t.assert_contains(lines, "2x")
      t.assert_contains(lines, "k")
    end)
  end)
end)
