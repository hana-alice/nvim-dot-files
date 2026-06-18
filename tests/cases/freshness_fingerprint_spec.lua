-- tests/cases/freshness_fingerprint_spec.lua
-- csearch freshness 内容指纹判定（D10 / L2，2026-06-17）。
--
-- freshness 改用 workspace_all.files 的内容 hash（确定性、零噪声）取代所有 mtime
-- 代理 anchor（git index / git commit-state D8 / dir_mtime）。本组测：
--   * list_fingerprint：内容相同→同 hash；内容变→不同 hash；(mtime,size) 缓存
--   * 防回归：prepare_freshness 源不再引用 mtime 代理 anchor
--
-- 纯逻辑 + tmpdir，不需要真实 git/引擎树。

local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")

local function tmpfile(content)
  local p = vim.fn.tempname():gsub("\\", "/")
  local f = io.open(p, "wb"); if f then f:write(content or ""); f:close() end
  return p
end

t.describe("ue.list_fingerprint（D10 内容指纹）", function()
  t.it("内容相同 → 同 hash", function()
    ue._reset_fingerprint_cache_for_test()
    local a = tmpfile("a.cpp\nb.cpp\nc.cpp\n")
    local b = tmpfile("a.cpp\nb.cpp\nc.cpp\n")
    t.assert_eq(ue._list_fingerprint_for_test(a), ue._list_fingerprint_for_test(b),
      "相同内容必须产生相同指纹")
    pcall(os.remove, a); pcall(os.remove, b)
  end)

  t.it("内容不同（集合变）→ 不同 hash", function()
    ue._reset_fingerprint_cache_for_test()
    local a = tmpfile("a.cpp\nb.cpp\n")
    local b = tmpfile("a.cpp\nb.cpp\nNEW.cpp\n")  -- 增了一个文件
    t.assert_true(ue._list_fingerprint_for_test(a) ~= ue._list_fingerprint_for_test(b),
      "文件集合变化必须改变指纹")
    pcall(os.remove, a); pcall(os.remove, b)
  end)

  t.it("缺失文件 → nil", function()
    ue._reset_fingerprint_cache_for_test()
    t.assert_nil(ue._list_fingerprint_for_test("/nonexistent_zzz/workspace_all.files"))
  end)

  t.it("(mtime,size) 缓存命中：内容字节不变时复用同一 hash", function()
    ue._reset_fingerprint_cache_for_test()
    local p = tmpfile("x.cpp\ny.cpp\n")
    local h1 = ue._list_fingerprint_for_test(p)
    local h2 = ue._list_fingerprint_for_test(p)  -- 无变化，应命中缓存
    t.assert_eq(h1, h2, "同一 (mtime,size) 第二次应返回缓存 hash")
    pcall(os.remove, p)
  end)
end)

-- ── 防回归：freshness 源不再依赖 mtime 代理 anchor ────────────────────────
t.describe("prepare_freshness 不再用 mtime 代理（D10 退役 anchor）", function()
  local source
  do
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local f = io.open(root .. "/lua/ue.lua", "rb")
    source = f and f:read("*a") or ""
    if f then f:close() end
  end

  -- 取 prepare_freshness 函数体（从 "function CORE_RT.prepare_freshness" 到下一个
  -- "prepare_freshness = CORE_RT.prepare_freshness"）做局部断言。
  local body
  do
    local s = source:find("function CORE_RT%.prepare_freshness", 1)
    local e = source:find("prepare_freshness = CORE_RT%.prepare_freshness", s or 1)
    body = (s and e) and source:sub(s, e) or ""
  end

  t.it("freshness 函数体引用 csearch_input_hash + list_fingerprint", function()
    t.assert_true(body ~= "", "应能定位 prepare_freshness 函数体")
    t.assert_contains(body, "csearch_input_hash")
    t.assert_contains(body, "list_fingerprint")
  end)

  t.it("freshness 函数体不再调用 git/dir mtime anchor", function()
    t.assert_false(body:find("git_commit_state_mtime", 1, true) ~= nil,
      "freshness 不得再用 git commit-state anchor（D8 已被 D10 取代）")
    t.assert_false(body:find("git_index_mtime", 1, true) ~= nil,
      "freshness 不得再用 git index anchor")
    t.assert_false(body:find("dir_mtime", 1, true) ~= nil,
      "freshness 不得再用 dir_mtime anchor（编译产物 touch 会假 stale）")
  end)

  t.it("全量成功钩子 on_full_csearch_success 记录指纹", function()
    t.assert_contains(source, "on_full_csearch_success")
    t.assert_contains(source, 'update_state_field, ctx.engine_root, "csearch_input_hash"')
  end)
end)
