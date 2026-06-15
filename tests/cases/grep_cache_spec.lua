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

  t.it("有 platform_key → csearch/<key>/ 与 gtags/<key>/ 分目录", function()
    local p = ue.cache_paths("/eng", "Android-Development")
    t.assert_match(p.csearch_idx, "/csearch/Android%-Development/csearch%.idx$")
    t.assert_match(p.workspace_all_list, "/gtags/Android%-Development/workspace_all%.files$")
    t.assert_match(p.workspace_list, "/gtags/Android%-Development/workspace%.files$")
    t.assert_match(p.project_list, "/gtags/Android%-Development/project%.files$")
    t.assert_match(p.engine_list, "/gtags/Android%-Development/engine%.files$")
    t.assert_eq(p.platform_key, "Android-Development")
  end)

  t.it("不同平台 key → 不同 csearch 路径（互不覆盖）", function()
    local a = ue.cache_paths("/eng", "Android-Development")
    local w = ue.cache_paths("/eng", "Win64-Development")
    t.assert_true(a.csearch_idx ~= w.csearch_idx, "不同平台索引路径必须不同")
  end)

  t.it("非 grep 类工件（state/cdb/clangd）不随平台分目录", function()
    local a = ue.cache_paths("/eng", "Android-Development")
    local w = ue.cache_paths("/eng", "Win64-Development")
    t.assert_eq(a.state, w.state, "state.json 单一路径")
    t.assert_eq(a.index_current_cdb, w.index_current_cdb, "cdb current 单一路径")
    t.assert_eq(a.active_index, w.active_index, "clangd index 单一路径")
  end)
end)

-- ── fallback 可见性（静态接线回归）──────────────────────────────────────
t.describe("UE grep fallback 可见性", function()
  t.it("snacks fallback 标题明确标记 slow fallback 与 UEPrepare", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/plugins/snacks.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 snacks.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    t.assert_contains(content, "Grep All Code (slow fallback")
    t.assert_contains(content, "run :UEPrepare")
  end)

  t.it("cached_grep fallback WARN 说明可能漏文件", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/ue.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 ue.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    t.assert_contains(content, "slow directory walk that may MISS files")
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
  t.it("默认显式 ignore-case，Alt-C 才切 case-sensitive", function()
    local root = vim.fn.stdpath("config"):gsub("\\", "/")
    local path = root .. "/lua/ue.lua"
    local f = io.open(path, "rb")
    t.assert_true(f ~= nil, "应能读取 ue.lua")
    local content = f and f:read("*a") or ""
    if f then f:close() end

    t.assert_contains(content, "ignore_case = mode_ignore_case")
    t.assert_contains(content, "--ignore-case")
    t.assert_contains(content, "r.useLandscape")
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

-- ── 旧缓存迁移 ───────────────────────────────────────────────────────────
t.describe("ue.migrate_legacy_csearch_if_needed", function()
  t.it("旧单一路径 csearch.idx 被 move 到平台目录，旧路径清空", function()
    local eng = tmpdir()
    local key = "Android-Development"
    local legacy = ue.cache_paths(eng)            -- 旧单一路径
    local active = ue.cache_paths(eng, key)       -- 新平台路径
    -- 构造旧布局：csearch.idx + workspace_all.files
    write_file(legacy.csearch_idx, "INDEX-DATA")
    write_file(legacy.workspace_all_list, "a\nb\nc")
    t.assert_true(is_file(legacy.csearch_idx), "前置：旧索引存在")

    local moved = ue.migrate_legacy_csearch_if_needed(eng, key)
    t.assert_true(moved, "应发生迁移")
    t.assert_true(is_file(active.csearch_idx), "新平台目录应有索引")
    t.assert_false(is_file(legacy.csearch_idx), "旧路径索引应被移走")
    t.assert_true(is_file(active.workspace_all_list), "新平台目录应有 workspace_all")
    t.assert_false(is_file(legacy.workspace_all_list), "旧 workspace_all 应被移走")

    -- 清理
    pcall(vim.fn.delete, eng, "rf")
  end)

  t.it("幂等：第二次调用无迁移（旧路径已空）", function()
    local eng = tmpdir()
    local key = "Win64-Development"
    local legacy = ue.cache_paths(eng)
    write_file(legacy.csearch_idx, "DATA")
    t.assert_true(ue.migrate_legacy_csearch_if_needed(eng, key), "首次迁移")
    t.assert_false(ue.migrate_legacy_csearch_if_needed(eng, key), "二次应无迁移")
    pcall(vim.fn.delete, eng, "rf")
  end)

  t.it("新目录已有索引时不覆盖（不 move）", function()
    local eng = tmpdir()
    local key = "Android-Development"
    local legacy = ue.cache_paths(eng)
    local active = ue.cache_paths(eng, key)
    write_file(legacy.csearch_idx, "OLD")
    write_file(active.csearch_idx, "NEW")  -- 新目录已存在
    ue.migrate_legacy_csearch_if_needed(eng, key)
    -- 新目录内容保持 NEW（未被旧 OLD 覆盖）
    local f = io.open(active.csearch_idx, "rb"); local c = f and f:read("*a"); if f then f:close() end
    t.assert_eq(c, "NEW", "已存在的新索引不应被旧值覆盖")
    pcall(vim.fn.delete, eng, "rf")
  end)

  t.it("空 platform_key → 不迁移（直接用旧布局）", function()
    local eng = tmpdir()
    local legacy = ue.cache_paths(eng)
    write_file(legacy.csearch_idx, "DATA")
    t.assert_false(ue.migrate_legacy_csearch_if_needed(eng, ""), "空 key 不迁移")
    t.assert_true(is_file(legacy.csearch_idx), "旧索引应原地保留")
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
