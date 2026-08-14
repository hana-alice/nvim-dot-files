-- tests/cases/cheatsheet_spec.lua
-- Cheatsheet 双 surface 一致性回归：
--   ① float 版 (lua/utils/cheatsheet.lua M.tabs) 与 markdown 版
--      (docs/ue_lazyvim_cheatsheet.md) 引用的 :UE* 命令必须在 commands_spec
--      的 UE* 冻结清单内（抓死链 / 过期命令）。
--   ② 两个 surface 不漂移：float DAP/UE tab 的关键键位，markdown 必须也有。
--   ③ markdown 不残留已废弃的 :UEAndroidDAP* 旧路线。
-- 改 cheatsheet（任一 surface）或动 UE 命令 → filter: cheatsheet
--
-- 为什么只校验 UE*（不校验 Theme/NvimLog/Markdown）：后者是 lazy-loaded，
-- headless 下 vim.fn.exists 不可靠（前缀歧义 + 未加载），而 UE* 有 commands_spec
-- 的权威冻结清单可直接比对，确定性强、零误报。

local t = require("tests.harness")
local cfg = t.bootstrap()

local function read(rel)
  local p = cfg .. "/" .. rel
  if vim.fn.filereadable(p) ~= 1 then return nil end
  return table.concat(vim.fn.readfile(p), "\n")
end

-- UE* 命令权威集合：commands_spec 的 UE_COMMANDS 冻结清单（lua/ue.lua）
-- ＋ UEDef* 系列（在 lua/utils/lsp_fallback.lua 注册，不在 ue.lua 冻结清单）。
-- 后者通过 keymaps.lua 顶部的 eager require 注册，headless 下 exists 可靠。
local UE_COMMANDS = {}
do
  local ok, src = pcall(read, "tests/cases/commands_spec.lua")
  if ok and src then
    local block = src:match("local UE_COMMANDS = {(.-)}")
    if block then
      for name in block:gmatch('"(UE[%w]+)"') do
        UE_COMMANDS[name] = true
      end
    end
  end
  -- 合并 lsp_fallback 注册的 UEDef* 命令（真实存在、非死链）。
  vim.g.mapleader = " "
  vim.g.maplocalleader = " "
  pcall(function() require("ue").setup() end)
  pcall(require, "utils.lsp_fallback")
  pcall(dofile, cfg .. "/lua/config/keymaps.lua")
  for _, c in ipairs({
    "UEDefStatus", "UEDefTrace", "UEDefSelfTest", "UEDefDiag",
    "UEDefReload", "UEDefCacheClear", "UEDefCancel", "UEDefContextClear",
  }) do
    if vim.fn.exists(":" .. c) == 2 then UE_COMMANDS[c] = true end
  end
end

-- 从文本提取完整的 :UEXxx 命令引用。排除两类非命令写法：
--   * `:UEDAP*` / `:UE*` 通配前缀（后跟 `*`）——这是「一类命令」的说明性写法
--   * `:UEDAPAttach android` 仍会被正确抓为 UEDAPAttach（后跟空格，合法边界）
local function extract_ue_commands(text)
  local seen, out = {}, {}
  for name, tail in text:gmatch(":(UE[%w]+)(.?)") do
    if tail ~= "*" and not seen[name] then
      seen[name] = true
      out[#out + 1] = name
    end
  end
  return out
end

-- ── ① float 版命令在冻结清单内 ────────────────────────────────────────────
t.describe("cheatsheet: float 版 UE 命令不死链", function()
  local sheet = require("utils.cheatsheet")
  t.it("M.tabs 可读且非空", function()
    t.assert_type(sheet.tabs, "table")
    t.assert_true(#sheet.tabs > 0, "M.tabs 为空")
  end)
  t.it("UE_COMMANDS 冻结清单已成功解析", function()
    t.assert_true(next(UE_COMMANDS) ~= nil, "无法从 commands_spec 解析 UE_COMMANDS")
  end)

  local cmds, seen = {}, {}
  for _, tab in ipairs(sheet.tabs or {}) do
    for _, sec in ipairs(tab.sections or {}) do
      for _, m in ipairs(sec.mappings or {}) do
        for _, cell in ipairs({ m[1], m[2] }) do
          for _, name in ipairs(extract_ue_commands(tostring(cell or ""))) do
            if not seen[name] then seen[name] = true; cmds[#cmds + 1] = name end
          end
        end
      end
    end
  end

  for _, c in ipairs(cmds) do
    t.it("float :" .. c .. " 在冻结清单", function()
      t.assert_true(UE_COMMANDS[c] == true,
        ":" .. c .. " 在 float cheatsheet 引用但不在 UE_COMMANDS 冻结清单（死链/过期）")
    end)
  end
end)

-- ── 快捷键发现：混合大小写组合必须直接命中并保留分类 ───────────────────────
t.describe("cheatsheet: 快捷键搜索与界面分类", function()
  local sheet = require("utils.cheatsheet")

  local function first_exact(query, key)
    for _, hit in ipairs(sheet.search(query)) do
      if hit.key == key then return hit end
    end
    return nil
  end

  t.it("wW 直接命中 word/WORD motion，并标出 Basics › Motions", function()
    local hit = first_exact("wW", "w / W")
    t.assert_true(hit ~= nil, "wW 应直接找到 w / W")
    t.assert_eq(hit.tab, "Basics")
    t.assert_eq(hit.section, "Motions")
    t.assert_eq(hit.group, "Basics › Motions")
  end)

  t.it("aA 直接命中 insert-after/line-end mode，并标出 Basics › Modes", function()
    local hit = first_exact("aA", "a / A")
    t.assert_true(hit ~= nil, "aA 应直接找到 a / A")
    t.assert_eq(hit.tab, "Basics")
    t.assert_eq(hit.section, "Modes")
    t.assert_eq(hit.group, "Basics › Modes")
  end)

  t.it("搜索不区分大小写，且所有结果都有 tab/section 分类", function()
    local lower = sheet.search("ww")
    local mixed = sheet.search("wW")
    t.assert_true(#mixed > 0, "wW 应有结果")
    t.assert_eq(#lower, #mixed, "ww 与 wW 的命中集合应一致")
    for _, hit in ipairs(mixed) do
      t.assert_true(type(hit.tab) == "string" and hit.tab ~= "", "结果缺 tab 分类")
      t.assert_true(type(hit.section) == "string" and hit.section ~= "", "结果缺 section 分类")
    end
  end)

  t.it("全部 cheatsheet 条目都可按原键位找回，且分类/说明非空", function()
    for _, tab in ipairs(sheet.tabs) do
      t.assert_true(type(tab.name) == "string" and tab.name ~= "", "存在无名 tab")
      for _, section in ipairs(tab.sections or {}) do
        t.assert_true(type(section.title) == "string" and section.title ~= "", "存在无名 section")
        for _, mapping in ipairs(section.mappings or {}) do
          local key, desc = tostring(mapping[1] or ""), tostring(mapping[2] or "")
          t.assert_true(key ~= "", tab.name .. " › " .. section.title .. " 存在空键位")
          t.assert_true(desc ~= "", tab.name .. " › " .. section.title .. " › " .. key .. " 缺说明")
          local found = false
          for _, hit in ipairs(sheet.search(key)) do
            if hit.key == key and hit.tab == tab.name and hit.section == section.title then
              found = true
              break
            end
          end
          t.assert_true(found, tab.name .. " › " .. section.title .. " › " .. key .. " 无法按原键位找回")
        end
      end
    end
  end)

  t.it("搜索结果按分类生成界面 section，不退化成无分类平铺", function()
    local sections, count = sheet.search_sections("wW")
    t.assert_true(count > 0, "wW 应有界面结果")
    t.assert_true(#sections > 0, "搜索界面应至少有一个分类")
    t.assert_eq(sections[1].title, "Basics › Motions")
    t.assert_true(#sections[1].mappings > 0, "分类内应有快捷键")
  end)

  t.it("帮助浮窗把 / 暴露为搜索入口", function()
    sheet.open()
    local state = sheet._state_for_test()
    t.assert_true(state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf), "cheatsheet buffer 未创建")
    local found = false
    for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(state.buf, "n")) do
      if mapping.lhs == "/" then found = true; break end
    end
    t.assert_true(found, "cheatsheet 内 / 应启动快捷键搜索")
    sheet.close()
  end)

  t.it("真实按键 /wW<CR> 与 /aA<CR> 都落到带分类的搜索界面", function()
    for _, case in ipairs({
      { query = "wW", group = "Basics › Motions", key = "w / W" },
      { query = "aA", group = "Basics › Modes", key = "a / A" },
    }) do
      sheet.open()
      local keys = vim.api.nvim_replace_termcodes("/" .. case.query .. "<CR>", true, false, true)
      vim.api.nvim_feedkeys(keys, "xt", false)
      vim.wait(500, function()
        return sheet._state_for_test().query == case.query
      end, 10)

      local state = sheet._state_for_test()
      t.assert_eq(state.query, case.query, "真实输入没有进入 cheatsheet 搜索状态")
      local visible = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(state.buf, state.ns, 0, -1, { details = true })) do
        for _, chunk in ipairs(mark[4].virt_text or {}) do
          visible[#visible + 1] = chunk[1]
        end
      end
      visible = table.concat(visible, "\n")
      t.assert_contains(visible, case.group)
      t.assert_contains(visible, case.key)
      sheet.close()
    end
  end)
end)

-- ── ② markdown 版命令在冻结清单内 ─────────────────────────────────────────
t.describe("cheatsheet: markdown 版 UE 命令不死链", function()
  local md = read("docs/ue_lazyvim_cheatsheet.md")
  t.it("markdown 文件存在", function()
    t.assert_true(md ~= nil, "缺少 docs/ue_lazyvim_cheatsheet.md")
  end)

  local cmds = md and extract_ue_commands(md) or {}
  for _, c in ipairs(cmds) do
    t.it("markdown :" .. c .. " 在冻结清单", function()
      t.assert_true(UE_COMMANDS[c] == true,
        ":" .. c .. " 在 cheatsheet markdown 引用但不在 UE_COMMANDS 冻结清单（过期/死链）")
    end)
  end
end)

-- ── ③ 两 surface 不漂移：关键键位 markdown 必含 ────────────────────────────
t.describe("cheatsheet: 双 surface 不漂移", function()
  local md = read("docs/ue_lazyvim_cheatsheet.md") or ""

  local ANCHORS = {
    "<leader>da", "<leader>db", "<leader>dB", "<leader>dL", "<leader>dC",
    "<leader>dW", "<leader>dt", "<leader>dR", "<leader>d1", "<leader>d4",
    "<leader>uA", "<leader>uB", "<leader>ub", "<leader>us", "<leader>uq", "<leader>uP", "<leader>uC",
    -- background-task management keys
    "<leader>X", "<leader>Xs", "<leader>XA",
    -- search-refinement keys the user asked to surface
    "<leader>sx", "<leader>sX", "<leader>sw", "<leader>sy",
    "-- -w", "-- -s", "sonokai-espresso",
  }
  for _, key in ipairs(ANCHORS) do
    t.it("markdown 含关键键位 " .. key, function()
      t.assert_true(md:find(key, 1, true) ~= nil,
        key .. " 在 float cheatsheet 有，但 markdown 缺（两 surface 漂移）")
    end)
  end

  -- 已废弃路线：markdown 正文不得再把 UEAndroidDAP 当作活命令引用。
  -- 用 ":UEAndroidDAP" 形式判定（命令引用），避免与说明性散文冲突。
  t.it("markdown 不把 :UEAndroidDAP 当活命令引用", function()
    t.assert_true(md:find(":UEAndroidDAP", 1, true) == nil,
      "markdown 仍以命令形式引用已废弃的 :UEAndroidDAP*（应统一到 :UEDAP*）")
  end)
end)
