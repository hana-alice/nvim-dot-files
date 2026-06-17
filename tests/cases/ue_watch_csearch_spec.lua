-- tests/cases/ue_watch_csearch_spec.lua
-- ue_watch 的 csearch provider 必须是 RECORD-ONLY —— 绝不写 csearch.idx。
--
-- 背景（D9，2026-06-17）：cindex 把 staged 路径硬编码为 <idx>~，watcher 增量与
-- 用户 :UEPrepare 全量并发会抢同一个 idx~，在 merge/rename 窗口互毁 →
-- `corrupt index: remove` + 0 字节死循环。结论：csearch 索引单写者，写者只能是
-- 用户显式触发的 prepare 家族；watcher 退回记账员（只更新 persistent_dirty）。
--
-- 这些用例是【防回归护栏】：若有人把 watcher 重新接回 csearch 写入（build_index /
-- cindex 调用），静态 + 行为断言都会变红。

local t = require("tests.harness")
t.bootstrap()

local watch = require("utils.ue_watch")

-- ── 静态护栏（防止 csearch 写者复活）──────────────────────────────────────
t.describe("ue_watch csearch provider 静态护栏（D9 单写者）", function()
  local source
  do
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/utils/ue_watch.lua"
    local f = io.open(path, "rb")
    source = f and f:read("*a") or ""
    if f then f:close() end
  end

  -- provider_csearch_add 函数体只允许出现在它自己的实现里，整文件不得再调用
  -- build_index / cindex / 写 .incremental.txt。
  -- provider_csearch_add 函数体只允许出现在它自己的实现里，整文件不得再调用
  -- build_index / cindex / 写 .incremental.txt。注意只匹配【调用】形态
  -- `code_search.build_index(`，doc-comment 里提到该名字（"不得 re-add"）不算违规。
  t.it("不调用 code_search.build_index（写者已退役）", function()
    t.assert_false(source:find("code_search%.build_index%s*%(") ~= nil,
      "ue_watch 不得调用 build_index() —— csearch 写入是 prepare 家族的专属职责")
  end)

  t.it("不再写 -files-from 增量列表 / 不 spawn cindex", function()
    t.assert_false(source:find(".incremental.txt", 1, true) ~= nil,
      "不得再写 <idx>.incremental.txt 临时列表")
    t.assert_false(source:find('local cindex = "cindex"', 1, true) ~= nil,
      "不得再用裸 cindex")
    t.assert_false(source:find("%-files%-from") ~= nil,
      "不得再走 -files-from（那是写者路径）")
  end)

  t.it("doc/header 声明 D9 单写者契约", function()
    t.assert_contains(source, "D9")
    t.assert_contains(source, "persistent_dirty")
  end)
end)

-- ── 行为护栏：provider 是 no-op，绝不触发任何 csearch 写 ────────────────────
t.describe("ue_watch csearch provider 行为（record-only no-op）", function()
  local cs = require("utils.code_search")
  local orig_build = cs.build_index
  local orig_probe = cs.cindex_uefilter_exe

  local function restore()
    cs.build_index = orig_build
    cs.cindex_uefilter_exe = orig_probe
    watch._set_opts_for_test(nil)
  end

  t.it("有 dirty 路径时不调用 build_index（不写索引）", function()
    local called = false
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end
    cs.build_index = function() called = true end
    local idx = vim.fn.tempname():gsub("\\", "/") .. "/csearch.idx"
    vim.fn.mkdir(vim.fn.fnamemodify(idx, ":h"), "p")
    watch._set_opts_for_test({ csearch_index = idx })

    local ok = watch._provider_csearch_add_for_test({
      "D:/project/uetemp/Engine/Source/Runtime/VulkanRHI/Private/VulkanCommandBuffer.cpp",
      "D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp",
    })
    t.assert_true(ok, "provider 应返回 true（record-only no-op 成功）")
    t.assert_false(called, "MUST NOT 调用 build_index —— watcher 不是索引器")
    -- 不得留下增量列表临时文件
    t.assert_nil(vim.loop.fs_stat(idx .. ".incremental.txt"),
      "不得写 <idx>.incremental.txt")

    pcall(vim.fn.delete, vim.fn.fnamemodify(idx, ":h"), "rf")
    restore()
  end)

  t.it("空 paths 也是 no-op（不写索引）", function()
    local called = false
    cs.build_index = function() called = true end
    watch._set_opts_for_test({ csearch_index = "/x/csearch.idx" })
    local ok = watch._provider_csearch_add_for_test({})
    t.assert_true(ok)
    t.assert_false(called)
    restore()
  end)
end)
