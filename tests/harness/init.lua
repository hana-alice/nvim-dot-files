-- tests/harness/init.lua
-- ----------------------------------------------------------------------------
-- 轻量级 headless 测试框架（纯 Lua，无第三方依赖）。
--
-- 设计来源：演进自 scripts/headless_smoke.lua 已验证的
--   check(name, fn) + pcall + 汇总 + quit/cquit 模式。
--
-- 公共接口（供 tests/cases/*_spec.lua require 复用）：
--   local t = require("tests.harness")
--   t.describe("group", function() t.it("does X", function() ... end) end)
--   断言：t.assert_eq / assert_true / assert_false / assert_nil /
--         assert_type / assert_error / assert_match
--   t.run()  → 打印汇总并以 quit / cquit 1 设置退出码
--
-- 隔离保证：单个 it 抛错只标记该用例 FAIL，不中断后续用例。
-- 自举保证：bootstrap() 把配置根目录前置到 rtp/package.path，
--           使 nvim -l 下 require("ue") 等可解析。
-- ----------------------------------------------------------------------------

local M = {}

-- ── runtimepath / package.path 自举 ───────────────────────────────────────
-- nvim -l 不加载完整 init.lua，需手动把配置根目录挂上 rtp，
-- 否则 require("ue") / require("utils.platform") 无法解析。
function M.bootstrap()
  local cfg = vim.fn.stdpath("config")
  -- 防御：stdpath 在极少数 headless 场景可能返回 cwd 以外路径，
  -- 两条都加，确保 lua/ 与 tests/ 在搜索路径上。
  vim.opt.rtp:prepend(cfg)
  -- lua/ 让 require("ue") / require("utils.platform") 可解析；
  -- 配置根让 require("tests.harness") / require("tests.cases.x") 可解析。
  local globs = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;"
    .. cfg .. "/?.lua;" .. cfg .. "/?/init.lua;"
  if not package.path:find(cfg .. "/lua/?.lua;", 1, true) then
    package.path = globs .. package.path
  end
  return cfg
end

-- ── 内部状态 ──────────────────────────────────────────────────────────────
-- results: { { name = "group > case", ok = bool, err = string|nil } }
local results = {}
local current_describe = nil

local function record(name, ok, err)
  results[#results + 1] = { name = name, ok = ok, err = err }
end

-- ── 断言集合 ──────────────────────────────────────────────────────────────
-- 所有断言失败时 error()，由 it() 的 pcall 捕获。
-- error level 2 让报错指向调用断言的用例行。

local function fail(msg)
  error(msg, 3)
end

local function tostr(v)
  if type(v) == "string" then return string.format("%q", v) end
  return tostring(v)
end

function M.assert_true(v, msg)
  if v ~= true and not v then
    fail((msg or "assert_true") .. ": expected truthy, got " .. tostr(v))
  end
end

function M.assert_false(v, msg)
  if v then
    fail((msg or "assert_false") .. ": expected falsy, got " .. tostr(v))
  end
end

function M.assert_nil(v, msg)
  if v ~= nil then
    fail((msg or "assert_nil") .. ": expected nil, got " .. tostr(v))
  end
end

function M.assert_eq(actual, expected, msg)
  if actual ~= expected then
    fail((msg or "assert_eq")
      .. ": expected " .. tostr(expected)
      .. ", got " .. tostr(actual))
  end
end

function M.assert_type(v, ty, msg)
  if type(v) ~= ty then
    fail((msg or "assert_type")
      .. ": expected type " .. ty
      .. ", got " .. type(v) .. " (" .. tostr(v) .. ")")
  end
end

function M.assert_match(s, pat, msg)
  if type(s) ~= "string" or not s:find(pat) then
    fail((msg or "assert_match")
      .. ": expected " .. tostr(s) .. " to match " .. tostr(pat))
  end
end

-- 断言 fn 调用会抛错。返回捕获到的错误信息，便于进一步断言。
function M.assert_error(fn, msg)
  local ok, err = pcall(fn)
  if ok then
    fail((msg or "assert_error") .. ": expected function to error, but it returned")
  end
  return err
end

-- 断言 container 包含 item：
--   * container 为 string  → item 作为子串（plain find）
--   * container 为 table   → item 作为某个数组元素（==）
function M.assert_contains(container, item, msg)
  if type(container) == "string" then
    if not container:find(item, 1, true) then
      fail((msg or "assert_contains")
        .. ": string " .. tostr(container)
        .. " does not contain " .. tostr(item))
    end
    return
  end
  if type(container) == "table" then
    for _, v in ipairs(container) do
      if v == item then return end
    end
    fail((msg or "assert_contains")
      .. ": list does not contain " .. tostr(item))
    return
  end
  fail((msg or "assert_contains")
    .. ": container must be string or table, got " .. type(container))
end

-- ── keymap 查询辅助 ───────────────────────────────────────────────────────
-- 按 (mode, lhs) 检索当前已注册映射。规范化处理：
--   * <leader>/<localleader> 替换为实际 leader（默认空格）
--   * termcode（<F5>/<C-v> 等）经 nvim_replace_termcodes 展开
-- 命中返回该 map 表（含 rhs / callback），否则返回 nil（不抛错）。
function M.get_keymap(mode, lhs)
  local leader = vim.g.mapleader or "\\"
  local llocal = vim.g.maplocalleader or "\\"
  -- nvim_get_keymap 返回的 lhs 已把 <leader> 展开为实际字符，
  -- 但保留 <F5> / <C-v> 这类 special key 的字面记法。
  local want = lhs:gsub("<[lL]eader>", leader):gsub("<[lL]ocalleader>", llocal)
  local want_tc = vim.api.nvim_replace_termcodes(want, true, false, true)
  local maps = vim.api.nvim_get_keymap(mode)
  for _, m in ipairs(maps) do
    if m.lhs == want then return m end
    -- 对 special key：把注册的 lhs 也展开后比较。
    local m_tc = vim.api.nvim_replace_termcodes(m.lhs, true, false, true)
    if m_tc == want_tc then return m end
  end
  return nil
end

-- ── 宙主（host）能力守卫辅助 ────────────────────────────────
-- 有些行为只在特定宙主上存在（如 IOS 工作流仅 macOS 可用；host/target matrix 在
-- 其它宙主上按设计 **fail closed**）。要在任意宙主上验证这类分支，就得把「当前
-- 宙主」显式换成目标宙主而不是伪造工具。
--
-- with_host(id, fn)：在 fn 执行期间把 `utils.platform.id` 换成 id（从而 `driver()`
-- 返回对应宙主驱动），结束后**无论成败都还原**，避免污染后续用例。
-- 注意：这不是「伪造宙主让断言碰巧通过」——目的是验证**目标宙主上的真实契约**；
-- 当前宙主的 fail-closed 语义应另写用例断言。
-- → openspec/specs/spec-authority-loop/spec.md（宙主相关失败按能力守卫）
function M.with_host(id, fn)
  local platform = require("utils.platform")
  local saved = platform.id
  platform.id = id
  local ok, err = pcall(fn)
  platform.id = saved
  if not ok then error(err, 0) end
end

-- 当前宙主是否能解析到可执行的 POSIX shell 脚本（Windows 上 `executable()` 对 .sh 为 0，
-- 因此任何依赖「.sh 可执行」的用例在 Windows 宙主上本质不适用）。
function M.host_runs_posix_scripts()
  local probe = vim.fn.tempname() .. "-posix-probe.sh"
  vim.fn.writefile({ "#!/bin/sh", "exit 0" }, probe)
  pcall(vim.fn.setfperm, probe, "rwxr-xr-x")
  local ok = vim.fn.executable(probe) == 1
  pcall(vim.fn.delete, probe)
  return ok
end

-- ── 分组与用例 ────────────────────────────────────────────────────────────

function M.describe(name, fn)
  local prev = current_describe
  current_describe = prev and (prev .. " > " .. name) or name
  local ok, err = pcall(fn)
  current_describe = prev
  if not ok then
    -- describe 体本身抛错（罕见：通常是文件加载期错误）
    record((name) .. " > <describe body>", false, err)
  end
end

function M.it(name, fn)
  local full = current_describe and (current_describe .. " > " .. name) or name
  local ok, err = pcall(fn)
  record(full, ok, ok and nil or err)
end

-- ── 运行与报告 ────────────────────────────────────────────────────────────

local function printf(fmt, ...)
  if select("#", ...) == 0 then io.write(fmt .. "\n")
  else io.write(string.format(fmt, ...) .. "\n") end
end

local function eprintf(fmt, ...)
  if select("#", ...) == 0 then io.stderr:write(fmt .. "\n")
  else io.stderr:write(string.format(fmt, ...) .. "\n") end
end

-- 收集但不退出，供 run.lua 在合适时机决定退出码（也可直接 M.run）。
function M.results()
  return results
end

function M.reset()
  results = {}
  current_describe = nil
end

-- 打印汇总并设置退出码：全绿 quit(0)，有失败 cquit(1)。
-- opts.exit = false 时只打印不退出（便于测试框架自身）。
function M.run(opts)
  opts = opts or {}
  local fails = 0

  -- 失败优先打印，便于在长输出末尾快速定位。
  for _, r in ipairs(results) do
    if not r.ok then
      fails = fails + 1
      eprintf("FAIL  %s\n        └─ %s", r.name, tostring(r.err))
    end
  end
  for _, r in ipairs(results) do
    if r.ok then printf("OK    %s", r.name) end
  end

  printf("")
  printf("=== %d/%d passed, %d failed ===", #results - fails, #results, fails)

  if opts.exit == false then
    return fails
  end

  if fails == 0 then
    vim.cmd("quit")
  else
    vim.cmd("cquit 1")
  end
  return fails
end

return M
