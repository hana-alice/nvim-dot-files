-- tests/cases/ue_watch_csearch_spec.lua
-- ue_watch 的 csearch-add provider 必须经 code_search.build_index{mode="add"}
-- （= -files-from 临时文件），绝不把 dirty 路径逐个拼进 argv。
--
-- 背景：旧实现 `cmd = {cindex}; for p in paths do insert(cmd, p) end` 在一次
-- git checkout / build 批量产生几百个长 UE 路径时，拼出的 argv 超过 Windows
-- ~32KiB 命令行上限 → ENAMETOOLONG（vim/_system.lua:256 spawn 抛错）。
-- 正解是用 cindex-uefilter 的 -files-from 文件列表入口（参 build_index{mode=add}，
-- 与 :UEPrepareIncremental 同源），任意长度都是单文件参数。
--
-- 这些用例用 stub 替换 code_search backend，不触真实 cindex-uefilter / 子进程，
-- headless 可跑。只验证「provider 把活儿交给 build_index{mode=add}，且不自行
-- 构造含每个路径的 argv」这一契约。

local t = require("tests.harness")
t.bootstrap()

local watch = require("utils.ue_watch")

-- ── 静态接线回归（防止 argv 拼接复活）──────────────────────────────────────
t.describe("ue_watch csearch provider 静态接线", function()
  local source
  do
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/utils/ue_watch.lua"
    local f = io.open(path, "rb")
    source = f and f:read("*a") or ""
    if f then f:close() end
  end

  t.it("provider_csearch_add 调用 build_index 且传 mode='add'", function()
    t.assert_contains(source, "code_search.build_index")
    t.assert_contains(source, 'mode = "add"')
  end)

  t.it("不再用裸 cindex argv 拼接（每路径一个 arg 的老写法被移除）", function()
    -- 老实现的两处特征：local cindex = "cindex" 与把 paths 逐个 insert 进 cmd。
    t.assert_false(source:find('local cindex = "cindex"', 1, true) ~= nil,
      "不得再用裸 cindex（应走 cindex-uefilter via build_index）")
    t.assert_false(source:find("for _, p in ipairs(paths) do table.insert(cmd, p)", 1, true) ~= nil,
      "不得把 dirty 路径逐个拼进 argv（会 ENAMETOOLONG）")
  end)

  t.it("经 -files-from 临时列表入口（注释自证意图）", function()
    t.assert_contains(source, "-files-from")
  end)
end)

-- ── 行为回归：provider 路由到 build_index{mode=add}，不构造 per-path argv ──
t.describe("ue_watch csearch provider 行为", function()
  local cs = require("utils.code_search")
  local orig_build = cs.build_index
  local orig_probe = cs.cindex_uefilter_exe

  local function restore()
    cs.build_index = orig_build
    cs.cindex_uefilter_exe = orig_probe
    watch._set_opts_for_test(nil)
  end

  t.it("把 dirty 路径写进 -files-from 文件并以 mode='add' 调 build_index", function()
    local captured = nil
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end  -- 假装可用
    cs.build_index = function(ctx, abs_list_path, cb, opts)
      -- 读回 build_index 收到的列表文件，验证内容就是 dirty 路径（逐行）。
      local lines = {}
      local f = io.open(abs_list_path, "r")
      if f then
        for line in f:lines() do lines[#lines + 1] = line end
        f:close()
      end
      captured = { ctx = ctx, opts = opts, lines = lines, list_path = abs_list_path }
      cb(true, nil, { ms = 1, index_size = 4096 })  -- 模拟成功
    end

    local idx = vim.fn.tempname():gsub("\\", "/") .. "/csearch.idx"
    vim.fn.mkdir(vim.fn.fnamemodify(idx, ":h"), "p")
    watch._set_opts_for_test({ csearch_index = idx })

    local paths = {
      "D:/project/uetemp/Engine/Source/Runtime/VulkanRHI/Private/VulkanCommandBuffer.cpp",
      "D:/project/uetemp/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp",
    }
    local ok = watch._provider_csearch_add_for_test(paths)
    t.assert_true(ok, "provider 应返回 true（fire-and-forget 成功排程）")

    t.assert_true(captured ~= nil, "build_index 应被调用")
    t.assert_eq(captured.opts and captured.opts.mode, "add", "必须 mode='add'（增量 append）")
    t.assert_eq(captured.ctx and captured.ctx.csearch_idx, idx, "应透传 watcher 配置的索引路径")
    t.assert_eq(#captured.lines, 2, "列表文件应含全部 dirty 路径")
    t.assert_eq(captured.lines[1], paths[1])
    t.assert_eq(captured.lines[2], paths[2])
    -- 临时列表文件在回调后应被清理。
    t.assert_nil(vim.loop.fs_stat(captured.list_path), "回调后应删除临时列表文件")

    pcall(vim.fn.delete, vim.fn.fnamemodify(idx, ":h"), "rf")
    restore()
  end)

  t.it("空 paths → no-op，不调 build_index", function()
    local called = false
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end
    cs.build_index = function() called = true end
    watch._set_opts_for_test({ csearch_index = "/x/csearch.idx" })
    local ok = watch._provider_csearch_add_for_test({})
    t.assert_true(ok, "空列表应直接返回 true")
    t.assert_false(called, "空列表不应触发 build_index")
    restore()
  end)

  t.it("未配置 csearch_index → 返回 false 且不调 build_index", function()
    local called = false
    cs.cindex_uefilter_exe = function() return "cindex-uefilter" end
    cs.build_index = function() called = true end
    watch._set_opts_for_test({})  -- 无 csearch_index
    local ok, err = watch._provider_csearch_add_for_test({ "/a.cpp" })
    t.assert_false(ok, "无索引配置应判失败")
    t.assert_match(err or "", "csearch_index", "错误应指明缺索引配置")
    t.assert_false(called)
    restore()
  end)

  t.it("cindex-uefilter 不可用 → 返回 false（不静默吞）", function()
    cs.cindex_uefilter_exe = function() return nil end  -- 模拟缺工具
    cs.build_index = function() error("不应到达 build_index") end
    watch._set_opts_for_test({ csearch_index = "/x/csearch.idx" })
    local ok, err = watch._provider_csearch_add_for_test({ "/a.cpp" })
    t.assert_false(ok, "缺 cindex-uefilter 应判失败")
    t.assert_match(err or "", "cindex%-uefilter", "错误应指明缺工具")
    restore()
  end)
end)
