-- tests/cases/structure_spec.lua
-- AI 持久化结构可发现性回归：
--   ① 主要目录本地规则可发现：AGENTS.md（单一内容源）+ CLAUDE.md（@AGENTS.md stub）
--   ② 知识库四根文件存在
--   ③ 关键文档内链不悬空
--   ④ 强制入口（SESSION START + DoD）与三条政策可发现
-- 守护「规则就地可发现」不腐烂。改文档/规则/知识库结构 → filter: structure
--
-- 单一内容源约定：每个主要目录规则只维护 AGENTS.md（Codex 原生读取），
-- 同目录 CLAUDE.md 内容为 `@AGENTS.md` 导入 stub（Claude 由其展开读同一内容）。

local t = require("tests.harness")
local cfg = t.bootstrap()

local function exists(rel)
  return vim.fn.filereadable(cfg .. "/" .. rel) == 1
end
local function isdir(rel)
  return vim.fn.isdirectory(cfg .. "/" .. rel) == 1
end
local function read(rel)
  local p = cfg .. "/" .. rel
  if vim.fn.filereadable(p) ~= 1 then return nil end
  return table.concat(vim.fn.readfile(p), "\n")
end

-- CLAUDE.md 是否为 @AGENTS.md 导入 stub（首个非空行为 @AGENTS.md）。
local function is_agents_stub(rel)
  local c = read(rel)
  if not c then return false end
  return c:match("^%s*@AGENTS%.md%s*") ~= nil or c:match("[\r\n]%s*@AGENTS%.md%s*") ~= nil
end

-- ── ① 主要目录本地规则存在（AGENTS.md 源 + CLAUDE.md stub）─────────────────
-- 冻结清单：新增子系统目录需同步此处（防误删/防漏规则）。
local MAJOR_DIRS = {
  "lua", "lua/ue", "lua/ue/cdb", "lua/ue/core", "lua/ue/dap", "lua/ue/index",
  "lua/ue/targets", "lua/ue/workflows",
  "lua/utils", "lua/utils/ue_goto", "lua/utils/code_search", "lua/utils/platform",
  "lua/config", "lua/plugins", "lua/workarounds", "lua/trouble", "lua/nio",
  "tools", "scripts", "tests", "docs",
}

t.describe("structure: 主要目录本地规则存在", function()
  t.it("根 AGENTS.md 存在（单一内容源）", function()
    t.assert_true(exists("AGENTS.md"), "缺少共用本地规则入口: AGENTS.md")
  end)
  t.it("根 CLAUDE.md 为 @AGENTS.md stub", function()
    t.assert_true(exists("CLAUDE.md"), "缺少 Claude 入口: CLAUDE.md")
    t.assert_true(is_agents_stub("CLAUDE.md"), "根 CLAUDE.md 应为 @AGENTS.md 导入 stub")
  end)

  for _, d in ipairs(MAJOR_DIRS) do
    t.it(d .. " 规则存在（AGENTS.md 源 + CLAUDE.md stub）", function()
      -- 目录本身存在才要求规则（防止清单与实际目录漂移误报）
      t.assert_true(isdir(d), "目录不存在: " .. d)
      t.assert_true(exists(d .. "/AGENTS.md"), "缺少本地规则源: " .. d .. "/AGENTS.md")
      t.assert_true(exists(d .. "/CLAUDE.md"), "缺少 Claude stub: " .. d .. "/CLAUDE.md")
      t.assert_true(is_agents_stub(d .. "/CLAUDE.md"),
        d .. "/CLAUDE.md 应为 @AGENTS.md 导入 stub（单一内容源在 AGENTS.md）")
    end)
  end
end)

-- ── ② 知识库四根文件存在 ──────────────────────────────────────────────────
t.describe("structure: 知识库四根文件存在", function()
  for _, f in ipairs({
    "memory/project_overview.md",
    "decisions/README.md",
    "lessons/README.md",
    "docs/architecture/overview.md",
  }) do
    t.it(f .. " 存在", function()
      t.assert_true(exists(f), "缺少知识库文件: " .. f)
    end)
  end
end)

-- ── ③ 关键文档内链不悬空 ──────────────────────────────────────────────────
-- 提取 [text](path) 的相对路径链接（跳过 http(s)、纯锚点、绝对路径），
-- 去掉 #anchor 后用 filereadable/isdirectory 校验目标存在。
local function extract_links(content)
  local links = {}
  for target in content:gmatch("%]%(([^)]+)%)") do
    links[#links + 1] = target
  end
  return links
end

local function is_internal_rel(target)
  if target:match("^https?://") then return false end
  if target:match("^#") then return false end
  if target:match("^/") then return false end          -- 绝对路径不校验
  if target:match("^%a+://") then return false end       -- 其它协议
  return true
end

-- 把链接目标解析为相对仓库根的路径（基于其所在文件的目录）。
local function resolve(base_dir, target)
  target = target:gsub("#.*$", "")                       -- 去锚点
  if target == "" then return nil end
  local path = base_dir == "" and target or (base_dir .. "/" .. target)
  -- 归一化 ../ 与 ./
  local parts = {}
  for seg in path:gmatch("[^/]+") do
    if seg == ".." then
      if #parts > 0 then table.remove(parts) end
    elseif seg ~= "." then
      parts[#parts + 1] = seg
    end
  end
  return table.concat(parts, "/")
end

local KEY_DOCS = {
  "AGENTS.md",
  "docs/CONSTRAINTS.md",
  "memory/project_overview.md",
  "docs/architecture/overview.md",
}

t.describe("structure: 关键文档内链不悬空", function()
  for _, doc in ipairs(KEY_DOCS) do
    t.it(doc .. " 的相对链接均可解析", function()
      local content = read(doc)
      t.assert_true(content ~= nil, "读不到 " .. doc)
      local base = doc:match("(.*)/[^/]+$") or ""
      local dangling = {}
      for _, target in ipairs(extract_links(content)) do
        if is_internal_rel(target) then
          local rel = resolve(base, target)
          if rel and rel ~= "" and not (exists(rel) or isdir(rel)) then
            dangling[#dangling + 1] = target .. " → " .. rel
          end
        end
      end
      t.assert_eq(#dangling, 0,
        doc .. " 悬空链接:\n  " .. table.concat(dangling, "\n  "))
    end)
  end
end)

-- ── ④ 强制入口与政策可发现 ────────────────────────────────────────────────
t.describe("structure: 强制入口与政策可发现", function()
  local agents = read("AGENTS.md") or ""
  local root_claude = read("CLAUDE.md") or ""
  local constraints = read("docs/CONSTRAINTS.md") or ""
  local tests_rules = read("tests/AGENTS.md") or ""

  t.it("根 CLAUDE.md 为 @AGENTS.md stub（内容源在 AGENTS.md）", function()
    t.assert_true(is_agents_stub("CLAUDE.md"), "根 CLAUDE.md 应为 @AGENTS.md 导入 stub")
  end)
  t.it("根 AGENTS.md 含 SESSION START 协议块", function()
    t.assert_contains(agents, "SESSION START")
  end)
  t.it("根 AGENTS.md 含 Definition of Done", function()
    t.assert_contains(agents, "Definition of Done")
  end)
  t.it("根 AGENTS.md 含共用入口与完成标准", function()
    t.assert_contains(agents, "single source of truth")
    t.assert_contains(agents, "SESSION START")
    t.assert_contains(agents, "Definition of Done")
  end)
  t.it("tests/AGENTS.md 含 change→filter 映射表", function()
    t.assert_contains(tests_rules, "CHANGE-TO-FILTER MAP")
  end)
  t.it("CONSTRAINTS 含回归政策 C6", function()
    t.assert_contains(constraints, "C6")
    t.assert_contains(constraints, "testing-regression.md")
  end)
  t.it("CONSTRAINTS 含改动记录政策 C7", function()
    t.assert_contains(constraints, "C7")
    t.assert_contains(constraints, "changelog.md")
  end)
  t.it("CONSTRAINTS 含 milestone 政策 C8", function()
    t.assert_contains(constraints, "C8")
  end)
  t.it("根 AGENTS.md 引用 changelog 与 milestone", function()
    t.assert_contains(agents, "changelog.md")
    t.assert_contains(agents, "milestone")
  end)
end)
