-- tests/cases/utils_spec.lua
-- 工具函数加载：utils 下关键模块可 require 且核心导出存在。
-- 注意：utils.ue_goto 是子模块命名空间（无 init.lua），因此测试其具体子模块。

local t = require("tests.harness")
t.bootstrap()

t.describe("utils.code_search", function()
  local cs = require("utils.code_search")
  t.it("返回 table", function() t.assert_type(cs, "table") end)
  t.it("stream 是 function", function() t.assert_type(cs.stream, "function") end)
  t.it("is_indexed 是 function", function() t.assert_type(cs.is_indexed, "function") end)
  t.it("current_backend 是 function", function() t.assert_type(cs.current_backend, "function") end)
  t.it("cindex_uefilter_exe 是 function", function() t.assert_type(cs.cindex_uefilter_exe, "function") end)
  -- 负探测策略：探测失败不得污染整个会话（冷启动 PATH 未就绪不应永久禁用 csearch）。
  t.it("_reset_probe_cache 是 function", function() t.assert_type(cs._reset_probe_cache, "function") end)
  t.it("_reset_probe_cache 幂等可调", function()
    cs._reset_probe_cache()
    cs._reset_probe_cache()  -- 二次调用不报错
  end)
  t.it("is_indexed 在无 index 路径时返回 false 而非抛错", function()
    -- 不存在的索引：不应抛错，应安静返回 false（保证 fall through）。
    local ok, res = pcall(cs.is_indexed, { csearch_idx = "/nonexistent_xyz_123/csearch.idx" })
    t.assert_true(ok, "is_indexed 不应抛错")
    t.assert_false(res, "不存在索引应判 false")
  end)

  t.it("staged csearch.idx~~ 有效而 csearch.idx 为空时自动恢复", function()
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local idx = dir .. "/csearch.idx"
    local staged = idx .. "~~"

    local f0 = io.open(idx, "wb")
    if f0 then f0:write(""); f0:close() end
    local f = io.open(staged, "wb")
    if f then f:write(string.rep("x", 2048)); f:close() end

    t.assert_true(cs._recover_staged_index_for_test(idx), "应提升有效 staged index")
    local stat = vim.loop.fs_stat(idx)
    t.assert_true(stat ~= nil and stat.size == 2048, "最终 index 应变为 staged 内容")
    t.assert_true(vim.loop.fs_stat(staged) == nil, "staged 文件应被 rename 掉")

    pcall(vim.fn.delete, dir, "rf")
  end)

  -- 交付时序契约（2026-06-12 修复 "<leader>/ 丢尾部命中"）：
  -- on_done MUST 严格在所有 on_line 之后触发，且交付条数 == 实际命中数。
  -- 用 rg 后端在临时目录实测（rg 必装；csearch 需索引，时序逻辑与 rg 同源）。
  t.it("stream(rg): on_done 在所有 on_line 之后，且不丢命中", function()
    if vim.fn.executable("rg") ~= 1 then
      return  -- 无 rg 跳过（不算失败）
    end
    -- 构造临时目录，写入已知命中数的文件。
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local N = 25  -- 多文件多行，放大尾部竞态窗口
    for i = 1, N do
      local f = io.open(dir .. "/f" .. i .. ".cpp", "wb")
      if f then f:write("int UNIQ_NEEDLE_TOKEN_42 = " .. i .. ";\n"); f:close() end
    end

    local lines, done_at, done = 0, nil, false
    -- 直接走 rg 后端：传一个不存在的 csearch_idx 使 is_indexed=false。
    cs.stream(
      { workspace_root = dir, csearch_idx = "/nonexistent/csearch.idx", search_dirs = { dir } },
      "UNIQ_NEEDLE_TOKEN_42",
      { regex = false, max_count = 5000, search_dirs = { dir } },
      {
        on_line = function() lines = lines + 1 end,
        on_done = function() done_at = lines; done = true end,
      }
    )
    vim.wait(8000, function() return done end, 50)
    pcall(vim.fn.delete, dir, "rf")

    t.assert_true(done, "on_done 应被调用")
    t.assert_eq(lines, N, "应交付全部 " .. N .. " 条命中（无尾部丢失）")
    t.assert_eq(done_at, lines, "on_done 必须在所有 on_line 之后（done_at==total）")
  end)

  t.it("stream(rg): ignore_case=true 匹配 camelCase 大小写差异", function()
    if vim.fn.executable("rg") ~= 1 then
      return
    end
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    local f = io.open(dir .. "/DefaultDeviceProfiles.ini", "wb")
    if f then
      f:write("+CVars=r.UseLandscapeSrvBuffer=1\n")
      f:close()
    end

    local lines, done = 0, false
    cs.stream(
      { workspace_root = dir, csearch_idx = "/nonexistent/csearch.idx", search_dirs = { dir } },
      "r.useLandscape",
      { regex = false, ignore_case = true, max_count = 5000, search_dirs = { dir } },
      {
        on_line = function() lines = lines + 1 end,
        on_done = function() done = true end,
      }
    )
    vim.wait(8000, function() return done end, 50)
    pcall(vim.fn.delete, dir, "rf")

    t.assert_true(done, "on_done 应被调用")
    t.assert_eq(lines, 1, "ignore_case=true 应匹配 r.UseLandscapeSrvBuffer")
  end)

  t.it("stream(rg): stop 后不再交付 on_line/on_done", function()
    if vim.fn.executable("rg") ~= 1 then
      return
    end
    local dir = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(dir, "p")
    for i = 1, 80 do
      local f = io.open(dir .. "/stop" .. i .. ".cpp", "wb")
      if f then
        f:write("int STOP_NEEDLE_TOKEN_42 = " .. i .. ";\n")
        f:close()
      end
    end

    local lines, done = 0, false
    local stop = cs.stream(
      { workspace_root = dir, csearch_idx = "/nonexistent/csearch.idx", search_dirs = { dir } },
      "STOP_NEEDLE_TOKEN_42",
      { regex = false, max_count = 5000, search_dirs = { dir } },
      {
        on_line = function() lines = lines + 1 end,
        on_done = function() done = true end,
      }
    )
    stop()
    vim.wait(250, function() return done or lines > 0 end, 25)
    pcall(vim.fn.delete, dir, "rf")

    t.assert_eq(lines, 0, "stop 后不应再交付 on_line")
    t.assert_false(done, "stop 后不应再交付 on_done")
  end)
end)

t.describe("utils.log", function()
  local log = require("utils.log")
  t.it("返回 table", function() t.assert_type(log, "table") end)
  for _, fn in ipairs({ "info", "warn", "error", "debug", "install_commands" }) do
    t.it(fn .. " 是 function", function() t.assert_type(log[fn], "function") end)
  end
end)

t.describe("utils.ue_paths", function()
  local up = require("utils.ue_paths")
  t.it("返回 table", function() t.assert_type(up, "table") end)
  t.it("is_blocked 是 function", function() t.assert_type(up.is_blocked, "function") end)
  t.it("is_searchable 是 function", function() t.assert_type(up.is_searchable, "function") end)
  t.it("filter 是 function", function() t.assert_type(up.filter, "function") end)
  t.it("BLOCKLIST_FRAGMENTS 是非空 table", function()
    t.assert_type(up.BLOCKLIST_FRAGMENTS, "table")
    t.assert_true(#up.BLOCKLIST_FRAGMENTS > 0)
  end)
end)

t.describe("utils.ue_goto 子模块", function()
  for _, sub in ipairs({ "jumper", "provider", "location", "symbol", "cache" }) do
    t.it("utils.ue_goto." .. sub .. " 返回 table", function()
      t.assert_type(require("utils.ue_goto." .. sub), "table")
    end)
  end
  t.it("jumper.jump 是 function", function()
    t.assert_type(require("utils.ue_goto.jumper").jump, "function")
  end)
  t.it("provider.sync_locations 是 function", function()
    t.assert_type(require("utils.ue_goto.provider").sync_locations, "function")
  end)
end)
