-- tests/cases/grep_cache_spec.lua
-- grep 缓存按平台分路径 + 失效逻辑契约（2026-06-11）。
--
-- 覆盖：
--   * cache_paths(root, platform_key) 的平台分路径 vs 空 key 回落布局
--   * platform_key_from_state 生成规则（与 ue.cdb.shards key 同源的平台维度）
--   * migrate_legacy_csearch_if_needed 的 move 语义 + 幂等
--   * engine_root / project_root 在 state.json 的往返持久化
--
-- 这些用例不依赖真实 csearch/UEPrepare —— 只测纯路径推导 + 文件移动逻辑，
-- 用临时目录构造布局，headless 可跑。

local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")
local uv = vim.uv or vim.loop

-- ── 临时目录辅助 ─────────────────────────────────────────────────────────
local function tmpdir()
  -- vim.fn.tempname() 给一个唯一路径；建目录用之。
  local d = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(d, "p")
  return d
end

local function write_file(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "wb")
  if f then f:write(content or "x"); f:close() end
end

local function is_file(path)
  local st = uv.fs_stat(path)
  return st ~= nil and st.type == "file"
end

-- ── cache_paths 平台分路径 ──────────────────────────────────────────────
t.describe("ue.cache_paths 平台分路径", function()
  t.it("空 platform_key → 回落旧单一路径", function()
    local p = ue.cache_paths("/eng")
    t.assert_match(p.csearch_idx, "/csearch/csearch%.idx$")
    t.assert_match(p.workspace_all_list, "/gtags/workspace_all%.files$")
    -- 旧路径不含平台子目录
    t.assert_false(p.csearch_idx:find("/csearch/[^/]+/csearch", 1, false) ~= nil
      and not p.csearch_idx:find("/csearch/csearch", 1, true),
      "空 key 不应有平台子目录")
  end)

  t.it("csearch 索引平台无关：有 platform_key 仍走扁平 csearch/csearch.idx", function()
    -- v3.2 de-platforming: csearch index is shared across all platforms.
    local p = ue.cache_paths("/eng", "Android-Development")
    t.assert_match(p.csearch_idx, "/csearch/csearch%.idx$")
    -- csearch 路径 MUST NOT 含平台子目录
    t.assert_false(p.csearch_idx:find("/csearch/Android", 1, true) ~= nil,
      "csearch 索引不应再含平台子目录")
    -- gtags 仍按平台分目录（编译相关，保持 per-platform）
    t.assert_match(p.workspace_all_list, "/gtags/Android%-Development/workspace_all%.files$")
    t.assert_match(p.workspace_list, "/gtags/Android%-Development/workspace%.files$")
    t.assert_match(p.project_list, "/gtags/Android%-Development/project%.files$")
    t.assert_match(p.engine_list, "/gtags/Android%-Development/engine%.files$")
    t.assert_eq(p.platform_key, "Android-Development")
  end)

  t.it("不同平台 key → csearch 路径相同（共用一份）；gtags 路径不同", function()
    local a = ue.cache_paths("/eng", "Android-Development")
    local w = ue.cache_paths("/eng", "Win64-Development")
    t.assert_eq(a.csearch_idx, w.csearch_idx, "csearch 索引全平台共用一份，路径必须相同")
    t.assert_true(a.workspace_all_list ~= w.workspace_all_list,
      "gtags 仍 per-platform，路径必须不同")
  end)

  t.it("非 grep 类工件（state/cdb/clangd）不随平台分目录", function()
    local a = ue.cache_paths("/eng", "Android-Development")
    local w = ue.cache_paths("/eng", "Win64-Development")
    t.assert_eq(a.state, w.state, "state.json 单一路径")
    t.assert_eq(a.index_current_cdb, w.index_current_cdb, "cdb current 单一路径")
    t.assert_eq(a.active_index, w.active_index, "clangd index 单一路径")
  end)
end)

-- ── <leader>/ csearch-only：从不加 rg（静态接线回归）────────────────────
t.describe("UE grep <leader>/ csearch-only（从不加 rg）", function()
  t.it("ue_project_grep 不再 fall 到 snacks.picker.grep（无 rg 暗门）", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/plugins/snacks.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 snacks.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    -- ue_project_grep 体内必须只调 cached_grep，且不再有 "slow fallback" 暗门
    t.assert_false(content:find("slow fallback", 1, true) ~= nil,
      "ue_project_grep 不应再有 'slow fallback' rg 暗门")
    t.assert_contains(content, "csearch-ONLY")
  end)

  t.it("cached_grep 无索引时弹可见 ERROR 且不开 rg picker", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/ue.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 ue.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    -- 三处 rg 暗门必须已移除
    t.assert_false(content:find('source = "ue_grep_rg"', 1, true) ~= nil,
      "rg fast-path source 'ue_grep_rg' 应已移除")
    t.assert_false(content:find("rg-batched fallback (v2)", 1, true) ~= nil,
      "rg-batched fallback 应已移除")
    -- 新的 csearch-only 错误路径就位
    t.assert_contains(content, "csearch-only and will not")
    t.assert_contains(content, "Run :UEPrepare")
  end)
end)

-- ── live grep 启动阈值 ──────────────────────────────────────────────────
t.describe("UE grep live 输入保护", function()
  t.it("空输入与单字符输入不启动重搜索", function()
    t.assert_false(ue._grep_live_search_ready_for_test("", 2), "空输入不应搜索")
    t.assert_false(ue._grep_live_search_ready_for_test(" ", 2), "空白输入不应搜索")
    t.assert_false(ue._grep_live_search_ready_for_test("R", 2), "单字符输入不应搜索")
    t.assert_true(ue._grep_live_search_ready_for_test("RD", 2), "两个字符后才搜索")
    t.assert_true(ue._grep_live_search_ready_for_test("  RD  ", 2), "阈值应按 trim 后内容判断")
  end)
end)

t.describe("UE grep 后端标题", function()
  t.it("调用方传固定 title 时仍追加真实后端", function()
    t.assert_eq(
      ue._grep_backend_title_for_test("Grep All Code (Engine+Project)", "csearch"),
      "Grep All Code (Engine+Project) [csearch]"
    )
    t.assert_eq(
      ue._grep_backend_title_for_test("Grep All Code (Engine+Project)", "rg"),
      "Grep All Code (Engine+Project) [rg]"
    )
  end)

  t.it("已有后端标记时不重复追加", function()
    t.assert_eq(
      ue._grep_backend_title_for_test("Grep All Code [csearch]", "csearch"),
      "Grep All Code [csearch]"
    )
  end)
end)

t.describe("UE grep 大小写模式", function()
  t.it("csearch 路径默认 ignore-case，Alt-C 才切 case-sensitive", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/ue.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 ue.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    -- csearch 路径的大小写接线（rg 路径已随 <leader>/ 去 rg 移除）
    t.assert_contains(content, "ignore_case = mode_ignore_case")
    t.assert_contains(content, "mode_case = _po.case == true")
  end)
end)

t.describe("UE grep csearch drain 队列", function()
  t.it("不用 #pending 统计有洞队列，避免尾部命中丢失", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/ue.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 ue.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    t.assert_contains(content, "local pending_len = 0")
    t.assert_contains(content, "local n = pending_len")
    t.assert_false(content:find("local n = #pending", 1, true) ~= nil,
      "drain 循环不得用 #pending；drained nil holes 会让 Lua 长度不稳定")
    t.assert_false(content:find("for i = read_idx, #pending do", 1, true) ~= nil,
      "final drain 不得用 #pending；否则会漏尾部命中")
  end)
end)

-- ── platform_key_from_state ─────────────────────────────────────────────
t.describe("ue.platform_key_from_state", function()
  t.it("无 platform → 空字符串（回落旧布局）", function()
    t.assert_eq(ue.platform_key_from_state({}), "")
    t.assert_eq(ue.platform_key_from_state({ target_platform = "" }), "")
  end)
  t.it("platform + config → '<Plat>-<Config>'", function()
    t.assert_eq(ue.platform_key_from_state({
      target_platform = "Android", target_configuration = "Development",
    }), "Android-Development")
  end)
  t.it("config 的 ' Editor' 后缀被剥离（与 cdb shard config 段一致）", function()
    t.assert_eq(ue.platform_key_from_state({
      target_platform = "Win64", target_configuration = "Development Editor",
    }), "Win64-Development")
  end)
  t.it("有 platform 无 config → 仅 platform", function()
    t.assert_eq(ue.platform_key_from_state({ target_platform = "IOS" }), "IOS")
  end)
  t.it("前后空白被 trim", function()
    t.assert_eq(ue.platform_key_from_state({
      target_platform = "  Android  ", target_configuration = "  Shipping  ",
    }), "Android-Shipping")
  end)
end)

-- ── 旧缓存迁移（v3.2：csearch 平台无关，迁移仅作用于 gtags lists/DB）─────────
t.describe("ue.migrate_legacy_csearch_if_needed", function()
  t.it("旧单一路径 gtags lists 被 move 到平台目录，旧路径清空", function()
    local eng = tmpdir()
    local key = "Android-Development"
    local legacy = ue.cache_paths(eng)            -- 旧单一路径
    local active = ue.cache_paths(eng, key)       -- 新平台路径
    -- 构造旧布局：gtags workspace_all.files（csearch 现已平台无关，不参与迁移）
    write_file(legacy.workspace_all_list, "a\nb\nc")
    t.assert_true(is_file(legacy.workspace_all_list), "前置：旧 gtags 清单存在")

    local moved = ue.migrate_legacy_csearch_if_needed(eng, key)
    t.assert_true(moved, "应发生迁移（gtags 清单）")
    t.assert_true(is_file(active.workspace_all_list), "新平台目录应有 workspace_all")
    t.assert_false(is_file(legacy.workspace_all_list), "旧 workspace_all 应被移走")

    -- csearch 索引平台无关：legacy 与 active 路径相同，迁移不应触碰它
    t.assert_eq(legacy.csearch_idx, active.csearch_idx, "csearch 索引路径平台无关，应相同")

    -- 清理
    pcall(vim.fn.delete, eng, "rf")
  end)

  t.it("幂等：第二次调用无迁移（旧路径已空）", function()
    local eng = tmpdir()
    local key = "Win64-Development"
    local legacy = ue.cache_paths(eng)
    write_file(legacy.workspace_all_list, "DATA")
    t.assert_true(ue.migrate_legacy_csearch_if_needed(eng, key), "首次迁移")
    t.assert_false(ue.migrate_legacy_csearch_if_needed(eng, key), "二次应无迁移")
    pcall(vim.fn.delete, eng, "rf")
  end)

  t.it("新目录已有 gtags 清单时不覆盖（不 move）", function()
    local eng = tmpdir()
    local key = "Android-Development"
    local legacy = ue.cache_paths(eng)
    local active = ue.cache_paths(eng, key)
    write_file(legacy.workspace_all_list, "OLD")
    write_file(active.workspace_all_list, "NEW")  -- 新目录已存在
    ue.migrate_legacy_csearch_if_needed(eng, key)
    -- 新目录内容保持 NEW（未被旧 OLD 覆盖）
    local f = io.open(active.workspace_all_list, "rb"); local c = f and f:read("*a"); if f then f:close() end
    t.assert_eq(c, "NEW", "已存在的新清单不应被旧值覆盖")
    pcall(vim.fn.delete, eng, "rf")
  end)

  t.it("空 platform_key → 不迁移（直接用旧布局）", function()
    local eng = tmpdir()
    local legacy = ue.cache_paths(eng)
    write_file(legacy.workspace_all_list, "DATA")
    t.assert_false(ue.migrate_legacy_csearch_if_needed(eng, ""), "空 key 不迁移")
    t.assert_true(is_file(legacy.workspace_all_list), "旧清单应原地保留")
    pcall(vim.fn.delete, eng, "rf")
  end)
end)

-- ── engine_root / project_root 往返持久化 ───────────────────────────────
t.describe("ue.read_state 往返 engine_root", function()
  t.it("update_state_field 写入 engine_root 后可读回并归一化", function()
    local eng = tmpdir()
    -- 写入混合分隔符的 engine_root，read_state 应 norm 成正斜杠
    ue.update_state_field(eng, "engine_root", eng)
    ue.update_state_field(eng, "project_root", eng .. "/proj")
    local s = ue.read_state(eng)
    t.assert_eq(s.engine_root, eng:gsub("\\", "/"), "engine_root 归一化往返")
    t.assert_eq(s.project_root, (eng .. "/proj"):gsub("\\", "/"), "project_root 归一化往返")
    pcall(vim.fn.delete, eng, "rf")
  end)
end)

-- ── 面板内 scope 过滤：csearch -f 组合（change refactor-search-system）──────
t.describe("code_search._compose_file_regex（scope + code_only 组合）", function()
  local cs = require("utils.code_search")

  t.it("两者皆无 → nil（不加 -f）", function()
    t.assert_eq(cs._compose_file_regex({}), nil)
    t.assert_eq(cs._compose_file_regex(nil), nil)
    t.assert_eq(cs._compose_file_regex({ path_filter = "" }), nil)
  end)

  t.it("仅 code_only → 扩展名正则", function()
    t.assert_eq(cs._compose_file_regex({ code_only = true }), cs._FILE_EXT_RE)
  end)

  t.it("仅 scope → 原样路径正则", function()
    t.assert_eq(cs._compose_file_regex({ path_filter = "/eng/Source/Foo" }), "/eng/Source/Foo")
  end)

  t.it("scope + code_only → <scope>.*<exts>（单一 RE2，无 lookahead）", function()
    local got = cs._compose_file_regex({ code_only = true, path_filter = "/eng/Source/Foo" })
    t.assert_eq(got, "/eng/Source/Foo" .. ".*" .. cs._FILE_EXT_RE)
  end)
end)
