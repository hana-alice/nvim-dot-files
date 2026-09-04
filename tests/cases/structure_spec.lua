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
  -- spec 权威纪律（spec-authority-loop）：SESSION START 必读 spec + DoD 含一致性 + 红灯优先。
  t.it("根 AGENTS.md 的 SESSION START 含 openspec/specs 必读一步", function()
    local ss = agents:match("SESSION START.-\n## ") or agents:match("SESSION START.*$") or ""
    t.assert_contains(ss, "openspec/specs")
  end)
  t.it("根 AGENTS.md 的 DoD 含 spec 一致性硬条件", function()
    local dod = agents:match("Definition of Done.-\n## ") or agents:match("Definition of Done.*$") or ""
    t.assert_contains(dod, "spec 与实现一致")
  end)
  t.it("根 AGENTS.md 含回归红灯优先", function()
    t.assert_contains(agents, "回归红灯优先")
  end)
  t.it("CONSTRAINTS 含 spec 一致性约束 C9", function()
    t.assert_contains(constraints, "C9")
    t.assert_contains(constraints, "spec-authority-loop")
  end)
  -- 归属分层契约（dap-failure-layering）：必须对三端 agent 第一手可见。
  -- 一份正文（spec）+ 三处指针（根 AGENTS / CONSTRAINTS C10 / dap 本地规则）。
  -- 删掉任一处即 FAIL，防止规则退化回「只存在于源码注释/会话记录」。
  t.it("根 AGENTS.md 的 SESSION START 含归属分层契约指针", function()
    local ss = agents:match("SESSION START.-\n## ") or agents:match("SESSION START.*$") or ""
    t.assert_contains(ss, "dap-failure-layering")
    t.assert_contains(ss, "C10")
  end)
  t.it("CONSTRAINTS 含 DAP 归属分层契约 C10（五层 + 失败先报层）", function()
    t.assert_contains(constraints, "C10")
    t.assert_contains(constraints, "dap-failure-layering")
    for _, layer in ipairs({ "L0", "L1", "L2", "L3", "L4" }) do
      t.assert_contains(constraints, "**" .. layer .. "**")
    end
  end)
  t.it("lua/ue/dap/AGENTS.md 就地声明层表与 owner", function()
    local dap_rules = read("lua/ue/dap/AGENTS.md") or ""
    t.assert_contains(dap_rules, "dap-failure-layering")
    for _, layer in ipairs({ "L0", "L1", "L2", "L3", "L4" }) do
      t.assert_contains(dap_rules, "**" .. layer .. "**")
    end
    t.assert_contains(dap_rules, "owner")
  end)
  t.it("CONSTRAINTS 维护契约要求新 DAP 坑标注归属层", function()
    t.assert_contains(constraints, "MUST 标注其归属层")
  end)
end)

-- ── ⑤ spec 引用完整性 ──────────────────────────────────────
-- spec 与规则文档里的「仓内路径引用」必须真实存在：防止 spec 继续声称产出一个已被
-- 删除/重命名/归档的文件（本次审计的真实故障：docs/plans/... 已随脱敏移除、
-- openspec/changes/<name>/ 已归档到 archive/、scripts/test_cached_grep.lua 已删）。
--
-- 策略（保守，宁漏不误报）：只检查反引号内、首段命中仓内顶层目录白名单的路径 token；
-- 跳过一切模板/通配形态（含 < > * 或 ...）与 §锚点尾巴。未加反引号的路径不检查。
local TOP_DIRS = {
  lua = true, tests = true, docs = true, scripts = true, tools = true,
  openspec = true, memory = true, decisions = true, lessons = true,
  colors = true, data = true,
}

local function is_placeholder(tok)
  -- 模板/通配形态：<capability>、lua/**、docs/plans/...、{a,b}_spec.lua、release_vX.Y.Z.md
  if tok:find("[<>*{}]") ~= nil then return true end
  if tok:find("%.%.%.") ~= nil then return true end
  if tok:find("vX%.Y%.Z") ~= nil then return true end
  return false
end

-- 只把「看起来像文件或目录」的 token 当路径校验：以 / 结尾的目录形态，或末段带
-- 已知文件扩展名。像 `lua/utils/async_launcher.launch` 这类 `module.function` 引用
-- 不是路径，跳过（宁漏不误报）。
local PATH_EXTS = {
  md = true, lua = true, json = true, ps1 = true, yaml = true, yml = true,
  py = true, sh = true, c = true, h = true, txt = true, log = true,
  toml = true, bat = true, files = true,
}

local function looks_like_path(tok)
  if tok:sub(-1) == "/" then return true end
  local ext = tok:match("%.([%w_]+)$")
  return ext ~= nil and PATH_EXTS[ext:lower()] == true
end

-- 从一段文本里抽出所有反引号 token，筛出「仓内路径」形态的。
local function repo_path_refs(content)
  local out = {}
  for tok in content:gmatch("`([^`]+)`") do
    -- 剥掉 §锚点尾巴与尾随标点：`docs/CONSTRAINTS.md §三 C8` -> docs/CONSTRAINTS.md
    local path = tok:gsub("%s*§.*$", ""):gsub("[%s,;:。、]+$", "")
    if path ~= "" and not is_placeholder(path) and path:find("/", 1, true)
      and looks_like_path(path) then
      local first = path:match("^([^/]+)/")
      if first and TOP_DIRS[first] then
        out[#out + 1] = path
      end
    end
  end
  return out
end

t.describe("structure: spec 引用完整性", function()
  local spec_files = vim.fn.globpath(cfg .. "/openspec/specs", "*/spec.md", false, true)

  t.it("openspec/specs 下存在主规格文件", function()
    t.assert_true(#spec_files > 0, "未发现任何 openspec/specs/*/spec.md")
  end)

  t.it("spec 内仓内路径引用均存在", function()
    local dangling = {}
    for _, abs in ipairs(spec_files) do
      local rel = abs:gsub("^" .. vim.pesc(cfg) .. "/", "")
      local content = table.concat(vim.fn.readfile(abs), "\n")
      for _, path in ipairs(repo_path_refs(content)) do
        if not (exists(path) or isdir(path)) then
          dangling[#dangling + 1] = path .. "  ← " .. rel
        end
      end
    end
    t.assert_eq(#dangling, 0,
      "spec 引用了不存在的仓内路径:\n  " .. table.concat(dangling, "\n  "))
  end)

  t.it("规则文档内仓内路径引用均存在", function()
    local docs = { "AGENTS.md", "docs/CONSTRAINTS.md", "memory/project_overview.md" }
    for _, d in ipairs(MAJOR_DIRS) do
      docs[#docs + 1] = d .. "/AGENTS.md"
    end
    local dangling = {}
    for _, rel in ipairs(docs) do
      local content = read(rel)
      if content then
        -- 目录级 AGENTS.md 里的引用多为 ../ 相对形态，已被 TOP_DIRS 过滤掉；
        -- 命中白名单者按「相对仓根」解释（与 spec 一致）。
        for _, path in ipairs(repo_path_refs(content)) do
          if not (exists(path) or isdir(path)) then
            dangling[#dangling + 1] = path .. "  ← " .. rel
          end
        end
      end
    end
    t.assert_eq(#dangling, 0,
      "规则文档引用了不存在的仓内路径:\n  " .. table.concat(dangling, "\n  "))
  end)
end)

-- ── ⑥ capability 覆盖映射 ────────────────────────────────────
-- 守护「从改动目录一步定位治理 spec」这张映射自身不腐烂：
--   · memory/project_overview.md「治理 spec」列里的 capability 必须有主规格文件
--   · tests/AGENTS.md CHANGE-TO-FILTER MAP 里的 filter 必须能匹配到 *_spec.lua
t.describe("structure: capability 覆盖映射", function()
  local overview = read("memory/project_overview.md") or ""
  local tests_rules_txt = read("tests/AGENTS.md") or ""

  -- 速查表行：| 子系统 | 位置 | 本地规则 | 治理 spec | 必跑 filter | 一句话 |
  local function coverage_rows()
    local rows = {}
    for line in overview:gmatch("[^\n]+") do
      if line:find("^|") and not line:find("^|%-") and not line:find("子系统") then
        local cells = {}
        for cell in line:gmatch("|([^|]*)") do cells[#cells + 1] = cell end
        if #cells >= 5 then rows[#rows + 1] = { spec = cells[4], filter = cells[5] } end
      end
    end
    return rows
  end

  local rows = coverage_rows()

  t.it("速查表含治理 spec 列且有数据行", function()
    t.assert_contains(overview, "治理 spec")
    t.assert_true(#rows > 0, "未解析到子系统速查表的数据行")
  end)

  t.it("映射中的 capability 均有主规格文件", function()
    local missing = {}
    local seen = 0
    for _, r in ipairs(rows) do
      for cap in r.spec:gmatch("`([a-z0-9%-]+)`") do
        seen = seen + 1
        if not exists("openspec/specs/" .. cap .. "/spec.md") then
          missing[#missing + 1] = cap
        end
      end
    end
    t.assert_true(seen > 0, "治理 spec 列未解析出任何 capability")
    t.assert_eq(#missing, 0,
      "治理 spec 列引用了不存在的 capability:\n  " .. table.concat(missing, "\n  "))
  end)

  t.it("CHANGE-TO-FILTER MAP 中的 filter 均有对应用例文件", function()
    local cases = vim.fn.globpath(cfg .. "/tests/cases", "*_spec.lua", false, true)
    local names = {}
    for _, abs in ipairs(cases) do
      names[#names + 1] = vim.fn.fnamemodify(abs, ":t:r")
    end
    -- 只解析映射表段落，避免把正文里的反引号词当 filter
    local map = tests_rules_txt:match("CHANGE%-TO%-FILTER MAP(.-)\n## ") or ""
    local missing = {}
    local seen = 0
    for line in map:gmatch("[^\n]+") do
      if line:find("^|") and not line:find("^|%-") and not line:find("改动位置") then
        local last = line:match("|([^|]*)|%s*$") or ""
        for f in last:gmatch("`([a-z0-9_]+)`") do
          seen = seen + 1
          local hit = false
          for _, n in ipairs(names) do
            if n:find(f, 1, true) then hit = true; break end
          end
          if not hit then missing[#missing + 1] = f end
        end
      end
    end
    t.assert_true(seen > 0, "未从 CHANGE-TO-FILTER MAP 解析出任何 filter")
    t.assert_eq(#missing, 0,
      "映射表中的 filter 无对应 tests/cases/*_spec.lua:\n  " .. table.concat(missing, "\n  "))
  end)
end)

-- ── ⑦ 目录规则声明治理 spec ─────────────────────────────────
t.describe("structure: 目录规则声明治理 spec", function()
  for _, d in ipairs(MAJOR_DIRS) do
    t.it(d .. "/AGENTS.md 声明治理 spec 或显式无", function()
      local content = read(d .. "/AGENTS.md")
      t.assert_true(content ~= nil, "读不到 " .. d .. "/AGENTS.md")
      local has_ptr = content:find("openspec/specs/", 1, true) ~= nil
      local has_none = content:find("无对应 capability", 1, true) ~= nil
      t.assert_true(has_ptr or has_none,
        d .. "/AGENTS.md 需在「先读」段列出 openspec/specs/<capability>/spec.md 指针，"
          .. "或显式声明「无对应 capability」")
    end)
  end
end)
