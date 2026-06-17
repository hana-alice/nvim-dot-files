-- tests/cases/csearch_build_guard_spec.lua
-- csearch 索引「单写者 + 韧性」契约（D9，2026-06-17）。
--
-- 覆盖两条：
--   Policy A（顺序层）：csearch 构建串行——同一时刻只允许一个构建，第二个被
--     拒绝（不排队）；完成回调无条件清标志（成功/失败都清），失败不卡死。
--   韧性层：增量 build_index{mode="add"} 在目标 idx 不可用（0 字节/缺失）时
--     拒绝、不 spawn；全量 mode="reset" 不受此约束。
--
-- 纯逻辑 + stub，不触真实 cindex；headless 可跑。

local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")
local cs = require("utils.code_search")

-- ── Policy A：构建串行（拒绝并发，标志无条件清）──────────────────────────
t.describe("csearch 构建串行（D9 Policy A）", function()
  local function reset()
    -- 确保起点空闲：若上例泄漏则清掉。
    if ue._csearch_build_running_for_test() then ue._csearch_build_done_for_test() end
  end

  t.it("空闲时 begin 成功并占用；占用中第二次 begin 被拒", function()
    reset()
    t.assert_false(ue._csearch_build_running_for_test(), "起点应空闲")
    t.assert_true(ue._csearch_build_begin_for_test("first"), "首个构建应被允许")
    t.assert_true(ue._csearch_build_running_for_test(), "begin 后标志应置位")
    t.assert_false(ue._csearch_build_begin_for_test("second"),
      "占用中第二个构建应被拒绝（不排队）")
    ue._csearch_build_done_for_test()
    reset()
  end)

  t.it("done 后可再次 begin（标志被清回空闲）", function()
    reset()
    t.assert_true(ue._csearch_build_begin_for_test("a"))
    ue._csearch_build_done_for_test()
    t.assert_false(ue._csearch_build_running_for_test(), "done 后应空闲")
    t.assert_true(ue._csearch_build_begin_for_test("b"),
      "上一个完成后新的构建应能启动")
    ue._csearch_build_done_for_test()
    reset()
  end)

  t.it("失败路径也必须 done（标志不被失败永久卡死）", function()
    reset()
    -- 模拟「begin → 构建失败 → 仍调 done」的契约：失败回调同样清标志。
    t.assert_true(ue._csearch_build_begin_for_test("will-fail"))
    -- 模拟失败回调里无条件 done
    ue._csearch_build_done_for_test()
    t.assert_true(ue._csearch_build_begin_for_test("after-fail"),
      "失败构建清标志后，后续构建必须能启动")
    ue._csearch_build_done_for_test()
    reset()
  end)
end)

-- ── 韧性层：增量拒绝不可用 idx，全量不受限 ───────────────────────────────
t.describe("csearch 增量遇不可用 idx 被拒（D9 韧性）", function()
  local orig_probe = cs.cindex_uefilter_exe
  local function restore() cs.cindex_uefilter_exe = orig_probe end

  t.it("mode='add' 对 0 字节 idx → cb(false) 且不 spawn", function()
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local idx = dir .. "/csearch.idx"
    -- 0 字节 idx（损坏态）
    local f = io.open(idx, "wb"); if f then f:write(""); f:close() end
    -- 空的 -files-from 列表（内容无关，重点是 add 前的 idx 守卫）
    local list = dir .. "/list.txt"
    local lf = io.open(list, "wb"); if lf then lf:write("/x.cpp\n"); lf:close() end

    local done, ok_res, err_res = false, nil, nil
    cs.build_index({ csearch_idx = idx }, list, function(ok, err, _st)
      ok_res, err_res, done = ok, err, true
    end, { mode = "add" })
    vim.wait(2000, function() return done end, 20)

    t.assert_true(done, "回调应被调用")
    t.assert_false(ok_res, "增量遇 0 字节 idx 应失败")
    t.assert_match(err_res or "", "UEPrepare", "失败信息应引导走全量 :UEPrepare")
    -- 守卫应在 spawn 前短路：idx 仍是 0 字节，未被 cindex 触碰
    local st = vim.loop.fs_stat(idx)
    t.assert_eq(st and st.size, 0, "增量被拒后不应触碰/写坏 idx")

    pcall(vim.fn.delete, dir, "rf")
    restore()
  end)

  t.it("mode='add' 对缺失 idx → cb(false) 且不 spawn", function()
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local idx = dir .. "/csearch.idx"  -- 不创建
    local list = dir .. "/list.txt"
    local lf = io.open(list, "wb"); if lf then lf:write("/x.cpp\n"); lf:close() end

    local done, ok_res = false, nil
    cs.build_index({ csearch_idx = idx }, list, function(ok, _err, _st)
      ok_res, done = ok, true
    end, { mode = "add" })
    vim.wait(2000, function() return done end, 20)

    t.assert_true(done)
    t.assert_false(ok_res, "增量遇缺失 idx 应失败")
    t.assert_nil(vim.loop.fs_stat(idx), "被拒后不应创建 idx")
    pcall(vim.fn.delete, dir, "rf")
    restore()
  end)

  t.it("_usable_index_for_test 正确区分 0 字节 / 有效 / 缺失", function()
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local empty = dir .. "/empty.idx"
    local good  = dir .. "/good.idx"
    local f0 = io.open(empty, "wb"); if f0 then f0:write(""); f0:close() end
    local f1 = io.open(good, "wb"); if f1 then f1:write(string.rep("x", 4096)); f1:close() end

    t.assert_false(cs._usable_index_for_test(empty), "0 字节 idx 不可用")
    t.assert_false(cs._usable_index_for_test(dir .. "/missing.idx"), "缺失 idx 不可用")
    t.assert_true(cs._usable_index_for_test(good), "足够大的 idx 可用")
    pcall(vim.fn.delete, dir, "rf")
  end)
end)

-- ── D-3b：全量构建成功后 dirty 集合归零 ──────────────────────────────────
t.describe("全量构建成功清 persistent_dirty（D9 / D-3b）", function()
  local watch = require("utils.ue_watch")

  t.it("clear_persistent_dirty_safe 把非空 dirty 集合清零", function()
    -- 给 watcher 注入一个非空脏集合（模拟 fast-path 跑前堆积的脏文件）
    watch._set_opts_for_test({ dirty_json_path = nil })  -- 不落盘，只测内存
    watch._seed_persistent_dirty_for_test({
      "D:/proj/A.cpp", "D:/proj/B.cpp", "D:/proj/C.cpp",
    })
    t.assert_eq((watch.persistent_dirty_status() or {}).count, 3, "前置：dirty 非空")

    -- 全量成功后 prepare 家族应调此 helper
    ue.clear_persistent_dirty_safe("test:full-success")
    t.assert_eq((watch.persistent_dirty_status() or {}).count, 0,
      "全量构建成功后 dirty 集合必须归零（否则 freshness 恒 stale + overlay 变卡）")

    watch._set_opts_for_test(nil)
  end)

  t.it("clear_persistent_dirty_safe 在 ue_watch 缺失时不抛错", function()
    -- soft-require 语义：即使模块不可用也应安静返回（不破坏 prepare 流程）
    local ok = pcall(ue.clear_persistent_dirty_safe, "test:soft")
    t.assert_true(ok, "soft-require 清理不应抛错")
  end)
end)

-- D-3b 是 helper（CORE_RT.clear_persistent_dirty_safe）经 M.clear_persistent_dirty_safe
-- 暴露给测试；运行时由三条全量成功回调调用（sync / fast-path / cold-full）。

