-- tests/cases/csearch_build_guard_spec.lua
-- csearch 索引「单写者 + 韧性」契约（D9，2026-06-17）。
--
-- 覆盖两条：
--   Policy A（顺序层）：csearch 构建串行——同一时刻只允许一个构建，第二个被
--     拒绝（不排队）；完成回调无条件清标志（成功/失败都清），失败不卡死。
--   韧性层：增量 build_index{mode="add"} 在目标 idx 不可用（0 字节/缺失）时
--     拒绝、不 spawn；全量 mode="reset" 不受此约束。
--
-- 逻辑/stub 守卫始终运行；工具链存在时另跑一次真实 Lua → cindex → csearch
-- 增量替换，避免 mock 掩盖原生 merge 契约回归。

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

t.describe("csearch 原生增量 merge", function()
  local function build(ctx, list_path, mode)
    local done, ok_result, error_result = false, false, nil
    cs.build_index(ctx, list_path, function(ok, err)
      ok_result, error_result, done = ok, err, true
    end, { mode = mode })
    t.assert_true(vim.wait(10000, function() return done end, 20), mode .. " build timeout")
    t.assert_true(ok_result, error_result or (mode .. " build failed"))
  end

  local function search(ctx, pattern)
    local matches, done, exit_code = {}, false, nil
    cs.stream(ctx, pattern, { regex = false, case = true, code_only = true }, {
      on_line = function(file, line)
        matches[#matches + 1] = { file = file, line = line }
      end,
      on_done = function(code)
        exit_code, done = code, true
      end,
    })
    t.assert_true(vim.wait(5000, function() return done end, 20), "search timeout")
    return matches, exit_code
  end

  t.it("新增与修改文件替换旧 trigram，且路径可含空格", function()
    if not cs.csearch_exe() or not cs.cindex_uefilter_exe() then return end
    local function fixture_lines(token, prefix)
      local lines = { "int " .. token .. " = 1;" }
      for index = 1, 400 do
        lines[#lines + 1] = ("int %s_filler_%04d = %d;"):format(prefix, index, index)
      end
      return lines
    end
    local root = vim.fn.tempname():gsub("\\", "/") .. "_native merge"
    local source_dir = root .. "/Source With Spaces"
    local keep = source_dir .. "/Keep.cpp"
    local replace = source_dir .. "/Replace.cpp"
    local added = source_dir .. "/Added.cpp"
    local idx = root .. "/csearch.idx"
    local initial_list = root .. "/initial.files"
    local update_list = root .. "/update.files"
    vim.fn.mkdir(source_dir, "p")
    vim.fn.writefile(fixture_lines("KEEP_NATIVE_TOKEN", "keep"), keep)
    vim.fn.writefile(fixture_lines("OLD_NATIVE_TOKEN", "old"), replace)
    vim.fn.writefile({ keep, replace }, initial_list)
    local ctx = { workspace_root = root, csearch_idx = idx }
    build(ctx, initial_list, "reset")

    vim.fn.writefile(fixture_lines("FRESH_NATIVE_TOKEN", "fresh"), replace)
    vim.fn.writefile(fixture_lines("ADDED_NATIVE_TOKEN", "added"), added)
    vim.fn.writefile({ added, replace, added }, update_list)
    build(ctx, update_list, "add")

    local fresh = search(ctx, "FRESH_NATIVE_TOKEN")
    local added_hits = search(ctx, "ADDED_NATIVE_TOKEN")
    local old, old_code = search(ctx, "OLD_NATIVE_TOKEN")
    t.assert_eq(#fresh, 1, "modified file must expose fresh trigrams")
    t.assert_eq(#added_hits, 1, "new file must be searchable after add")
    t.assert_eq(#old, 0, "replacement must remove stale trigrams")
    t.assert_true(old_code == 0 or old_code == 1, "no-hit csearch should exit cleanly")
    pcall(vim.fn.delete, root, "rf")
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

-- ── D11：智能增量构建决策 + smart_build 端到端（mock build_index）──────────
t.describe("csearch 智能增量决策（D11 csearch_build_mode）", function()
  local function mode(stats) return (ue._csearch_build_mode_for_test(stats)) end

  t.it("forced → reset", function()
    t.assert_eq(mode({ forced = true, has_snapshot = true, added_n = 1, total_n = 100 }), "reset")
  end)

  t.it("无快照 → reset（没有 diff 基准）", function()
    t.assert_eq(mode({ has_snapshot = false, added_n = 0, total_n = 100 }), "reset")
  end)

  t.it("有删除 → reset（cindex 不能删；ghost 命中是正确性问题）", function()
    t.assert_eq(mode({ has_snapshot = true, added_n = 1, removed_n = 1, total_n = 1000 }),
      "reset")
  end)

  t.it("零变化 → skip", function()
    t.assert_eq(mode({ has_snapshot = true, added_n = 0, removed_n = 0, dirty_n = 0, total_n = 1000 }),
      "skip")
  end)

  t.it("小增量 → add", function()
    t.assert_eq(mode({ has_snapshot = true, added_n = 5, removed_n = 0, dirty_n = 3, total_n = 10000 }),
      "add")
  end)

  t.it("超过 30% 阈值 → reset（切分支场景）", function()
    t.assert_eq(mode({ has_snapshot = true, added_n = 4000, removed_n = 0, dirty_n = 0, total_n = 10000 }),
      "reset")
  end)
end)

t.describe("csearch smart_build 端到端（D11，mock build_index）", function()
  local function setup_dir()
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    assert(require("ue.project_state").select(
      dir, dir .. "/project", dir .. "/project/Test.uproject", { persist_default = false }))
    return dir
  end
  local function write_lines(path, lines)
    local f = assert(io.open(path, "w"))
    for _, l in ipairs(lines) do f:write(l, "\n") end
    f:close()
  end
  local function read_lines(path)
    local out = {}
    for l in io.lines(path) do out[#out + 1] = l end
    return out
  end

  -- mock code_search.build_index：记录调用（mode + 喂入清单），立即成功。
  local calls
  local orig_build
  local function install_mock()
    calls = {}
    orig_build = cs.build_index
    cs.build_index = function(_ctx, list_path, cb, opts)
      calls[#calls + 1] = {
        mode = (opts and opts.mode) or "reset",
        lines = read_lines(list_path),
      }
      vim.schedule(function() cb(true, nil, { ms = 1, index_size = 4096 }) end)
    end
  end
  local function restore_mock() cs.build_index = orig_build end

  local function run_smart(ctx, abs_list)
    local done, res = false, nil
    ue._csearch_smart_build_for_test(ctx, { csearch_idx = ctx.paths.csearch_idx }, abs_list,
      function(ok, err, stats) res = { ok = ok, err = err, stats = stats }; done = true end)
    vim.wait(2000, function() return done end, 20)
    t.assert_true(done, "smart_build 回调应被调用")
    return res
  end

  t.it("首次（无快照）→ reset 全量 + 落快照", function()
    install_mock()
    local dir = setup_dir()
    local ctx = { paths = { csearch_idx = dir .. "/csearch.idx" } }
    local abs_list = dir .. "/list.txt"
    write_lines(abs_list, { "D:/w/A.cpp", "D:/w/B.cpp" })

    local res = run_smart(ctx, abs_list)
    t.assert_true(res.ok)
    t.assert_eq(res.stats.mode, "reset")
    t.assert_eq(#calls, 1)
    t.assert_eq(calls[1].mode, "reset")
    local snap = ue._csearch_snapshot_path_for_test(ctx)
    t.assert_true(vim.loop.fs_stat(snap) ~= nil, "成功后应写快照 <idx>.files")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)

  t.it("快照旁车丢失但索引+指纹一致 → bootstrap skip，不做 reset", function()
    install_mock()
    local dir = setup_dir()
    local workspace_list = dir .. "/workspace_all.files"
    local abs_list = dir .. "/list.txt"
    write_lines(workspace_list, { "Engine/A.cpp", "Engine/B.cpp" })
    write_lines(abs_list, { "D:/w/Engine/A.cpp", "D:/w/Engine/B.cpp" })
    ue._reset_fingerprint_cache_for_test()
    ue.update_state_field(dir, "csearch_input_hash", ue._list_fingerprint_for_test(workspace_list))

    local orig_is_indexed = cs.is_indexed
    cs.is_indexed = function() return true end
    local ctx = {
      engine_root = dir,
      paths = {
        csearch_idx = dir .. "/csearch.idx",
        workspace_all_list = workspace_list,
      },
    }
    local res = run_smart(ctx, abs_list)
    cs.is_indexed = orig_is_indexed

    t.assert_true(res.ok)
    t.assert_eq(res.stats.mode, "skip")
    t.assert_eq(#calls, 0, "已有可用索引且内容指纹一致时不应全量重建")
    t.assert_true(vim.loop.fs_stat(ue._csearch_snapshot_path_for_test(ctx)) ~= nil,
      "bootstrap skip 应补回 <idx>.files 快照")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)

  t.it("快照旁车丢失且主索引不可用 → 即使指纹一致也 reset", function()
    install_mock()
    local dir = setup_dir()
    local workspace_list = dir .. "/workspace_all.files"
    local abs_list = dir .. "/list.txt"
    write_lines(workspace_list, { "Engine/A.cpp" })
    write_lines(abs_list, { "D:/w/Engine/A.cpp" })
    ue._reset_fingerprint_cache_for_test()
    ue.update_state_field(dir, "csearch_input_hash", ue._list_fingerprint_for_test(workspace_list))

    local orig_is_indexed = cs.is_indexed
    cs.is_indexed = function() return false end
    local res = run_smart({
      engine_root = dir,
      paths = {
        csearch_idx = dir .. "/csearch.idx",
        workspace_all_list = workspace_list,
      },
    }, abs_list)
    cs.is_indexed = orig_is_indexed

    t.assert_true(res.ok)
    t.assert_eq(res.stats.mode, "reset")
    t.assert_eq(#calls, 1, "不能仅凭历史指纹信任缺失/损坏的主索引")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)

  t.it("集合不变 → skip（不调 build_index）", function()
    install_mock()
    local dir = setup_dir()
    local ctx = { paths = { csearch_idx = dir .. "/csearch.idx" } }
    local abs_list = dir .. "/list.txt"
    write_lines(abs_list, { "D:/w/A.cpp", "D:/w/B.cpp" })
    write_lines(ue._csearch_snapshot_path_for_test(ctx), { "D:/w/A.cpp", "D:/w/B.cpp" })

    local res = run_smart(ctx, abs_list)
    t.assert_true(res.ok)
    t.assert_eq(res.stats.mode, "skip")
    t.assert_eq(#calls, 0, "skip 不应触发任何 cindex 调用")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)

  t.it("少量新增 → add 且只喂 delta", function()
    install_mock()
    local dir = setup_dir()
    local ctx = { paths = { csearch_idx = dir .. "/csearch.idx" } }
    local abs_list = dir .. "/list.txt"
    -- 快照 = 10 个旧文件；新清单 = 旧 10 + 新 2
    local old = {}
    for i = 1, 10 do old[i] = ("D:/w/f%02d.cpp"):format(i) end
    write_lines(ue._csearch_snapshot_path_for_test(ctx), old)
    local new_list = vim.list_extend(vim.list_extend({}, old), { "D:/w/new1.cpp", "D:/w/new2.cpp" })
    write_lines(abs_list, new_list)

    local res = run_smart(ctx, abs_list)
    t.assert_true(res.ok)
    t.assert_eq(res.stats.mode, "add")
    t.assert_eq(#calls, 1)
    t.assert_eq(calls[1].mode, "add")
    t.assert_eq(#calls[1].lines, 2, "add 只喂 2 个新增文件，不重喂全量")
    -- 快照应更新为新清单（含新增）
    local snap_lines = read_lines(ue._csearch_snapshot_path_for_test(ctx))
    t.assert_eq(#snap_lines, 12, "快照应与新清单同步")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)

  t.it("有删除 → reset（不留 ghost）", function()
    install_mock()
    local dir = setup_dir()
    local ctx = { paths = { csearch_idx = dir .. "/csearch.idx" } }
    local abs_list = dir .. "/list.txt"
    write_lines(ue._csearch_snapshot_path_for_test(ctx), { "D:/w/A.cpp", "D:/w/B.cpp", "D:/w/C.cpp" })
    write_lines(abs_list, { "D:/w/A.cpp", "D:/w/B.cpp" })  -- C 被删

    local res = run_smart(ctx, abs_list)
    t.assert_true(res.ok)
    t.assert_eq(res.stats.mode, "reset", "有删除必须全量（cindex 无删除能力）")
    t.assert_eq(calls[1].mode, "reset")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)

  t.it("add 失败 → 自动回退 reset（一次，成功收尾）", function()
    calls = {}
    orig_build = cs.build_index
    cs.build_index = function(_ctx, list_path, cb, opts)
      local m = (opts and opts.mode) or "reset"
      calls[#calls + 1] = { mode = m, lines = read_lines(list_path) }
      vim.schedule(function()
        if m == "add" then cb(false, "csearch index unusable", {})
        else cb(true, nil, { ms = 1, index_size = 4096 }) end
      end)
    end
    local dir = setup_dir()
    local ctx = { paths = { csearch_idx = dir .. "/csearch.idx" } }
    local abs_list = dir .. "/list.txt"
    -- 基数要够大：delta 必须 < 30% 阈值才会走 add 路径（1/11 ≈ 9%）。
    local old = {}
    for i = 1, 10 do old[i] = ("D:/w/g%02d.cpp"):format(i) end
    write_lines(ue._csearch_snapshot_path_for_test(ctx), old)
    write_lines(abs_list, vim.list_extend(vim.list_extend({}, old), { "D:/w/B.cpp" }))

    local res = run_smart(ctx, abs_list)
    t.assert_true(res.ok, "回退 reset 成功后整体应报成功")
    t.assert_eq(res.stats.mode, "reset")
    t.assert_eq(#calls, 2, "应先试 add 再回退 reset")
    t.assert_eq(calls[1].mode, "add")
    t.assert_eq(calls[2].mode, "reset")

    pcall(vim.fn.delete, dir, "rf")
    restore_mock()
  end)
end)
