-- tests/run.lua
-- ----------------------------------------------------------------------------
-- nvim 配置 headless 全量回归统一入口。
--
-- 用法：
--   nvim -l tests/run.lua
--   nvim -l tests/run.lua <filter>     # 只跑文件名匹配 <filter> 的用例
--   FILTER=<pat> nvim -l tests/run.lua # 同上，环境变量形式
--
-- 退出码：
--   0  全部用例通过
--   1  任意用例失败 / 加载错误
--
-- 自动发现：扫描 tests/cases/*_spec.lua，按文件名排序后逐个 loadfile 执行。
--           新增用例只需在 tests/cases/ 下放一个 *_spec.lua，无需改本文件。
-- ----------------------------------------------------------------------------

-- 抑制 LazyVim 的 stdin 启动路径（与 headless_smoke.lua 一致）。
vim.g.started_with_stdin = true

-- 回归中的 probe 调用必须写入临时隔离文件，绝不能污染真实的
-- stdpath('state')/ue_probes.json。probe.lua 也会在测试 seam 切换时取消
-- 尚未触发的防抖 timer，避免旧测试 payload 延迟写到新路径。
local probe_test_dir = vim.fn.tempname():gsub("\\", "/")
vim.fn.mkdir(probe_test_dir, "p")
vim.env.NVIM_UE_PROBE_PATH = probe_test_dir .. "/ue_probes.json"

-- 自举：require("tests.harness") 之前必须先把配置根目录挂上 rtp/package.path，
-- 否则 tests.* / ue / utils.* 均无法解析。这里手工做一次最小自举，
-- 拿到 harness 后由它统一负责后续 require 的解析。
local cfg = vim.fn.stdpath("config")
vim.opt.rtp:prepend(cfg)
do
  local lua_glob = cfg .. "/lua/?.lua;" .. cfg .. "/lua/?/init.lua;"
  -- tests/ 不在 lua/ 下，单独加 tests 根所在目录（配置根）使 require("tests.x") 可解析。
  local tests_glob = cfg .. "/?.lua;" .. cfg .. "/?/init.lua;"
  package.path = lua_glob .. tests_glob .. package.path
end

local harness = require("tests.harness")
harness.bootstrap()

-- ── filter（可选增强）────────────────────────────────────────────────────
-- 优先级：命令行参数 > 环境变量 FILTER。
local filter = nil
if vim.v.argv then
  -- nvim -l 把脚本后的参数透传到 _G.arg
end
if _G.arg and _G.arg[1] and _G.arg[1] ~= "" then
  filter = _G.arg[1]
end
if not filter then
  local env_filter = vim.env.FILTER
  if env_filter and env_filter ~= "" then filter = env_filter end
end

-- ── 自动发现用例文件 ──────────────────────────────────────────────────────
local cases_dir = cfg .. "/tests/cases"
local glob = cases_dir .. "/*_spec.lua"
local files = vim.fn.glob(glob, true, true) -- {nosuf=true, list=true}
table.sort(files)

if filter then
  local kept = {}
  for _, f in ipairs(files) do
    if f:find(filter, 1, true) then kept[#kept + 1] = f end
  end
  files = kept
end

if #files == 0 then
  io.stderr:write("no spec files matched under " .. cases_dir
    .. (filter and (" (filter=" .. filter .. ")") or "") .. "\n")
  vim.cmd("cquit 1")
  return
end

-- ── 执行 ──────────────────────────────────────────────────────────────────
io.write(string.format("Running %d spec file(s)%s\n\n",
  #files, filter and (" [filter=" .. filter .. "]") or ""))

for _, file in ipairs(files) do
  local chunk, load_err = loadfile(file)
  if not chunk then
    -- 文件无法加载：记为一个失败用例，继续其余文件。
    harness.describe(vim.fn.fnamemodify(file, ":t"), function()
      harness.it("<loadfile>", function()
        error(load_err)
      end)
    end)
  else
    local ok, run_err = pcall(chunk)
    if not ok then
      harness.describe(vim.fn.fnamemodify(file, ":t"), function()
        harness.it("<execute>", function()
          error(run_err)
        end)
      end)
    end
  end
end

-- ── 旁路调度：收编 scripts/test_*.lua（ue_goto）的稳定子集 ────────────────
-- 这些脚本沿用旧约定（自行 print "PASS"，并调用 vim.cmd("qa!")/"cq!" 退出）。
-- 它们的 qa!/cq! 会杀掉整个 runner 进程，因此不能在本进程内执行——
-- 改为各自 fork 一个 nvim --headless 子进程，用其退出码判定 PASS/FAIL。
--   * 仅纳入纯 headless（无需 clangd / socket / 真机）且当前稳定通过的脚本，
--     与 scripts/run_all_tests.ps1 的排除逻辑保持一致；
--   * 需要外部资源或仍在开发中的脚本（test_jumper_real / test_jumplist_fix /
--     test_tier2_wireup / test_dependent_name）显式排除。
-- 通过环境变量 NO_LEGACY=1 可跳过本旁路（CI 上若担心子进程开销）。
local LEGACY_STABLE = {
  "test_call_arity.lua",
  "test_declarator_arity.lua",
  "test_syntax_filter.lua",
  "test_pair_picker.lua",
  "test_ranking_sort.lua",
  "test_jumper_headless.lua",
}

local function run_legacy()
  if vim.env.NO_LEGACY == "1" then return end
  if filter then return end -- 带 filter 时只跑匹配的新用例
  local nvim_exe = vim.v.progpath -- 当前 nvim 可执行文件
  harness.describe("legacy: scripts/test_*.lua (ue_goto 稳定子集)", function()
    for _, name in ipairs(LEGACY_STABLE) do
      harness.it(name, function()
        local path = cfg .. "/scripts/" .. name
        local out = vim.fn.system({
          nvim_exe, "--headless",
          "--cmd", "lua vim.g.started_with_stdin=true",
          "-c", "luafile " .. path,
          "-c", "qall!",
        })
        local code = vim.v.shell_error
        -- 旧脚本约定：成功 print PASS 并 qa!(0)，失败 cq!(非0)。
        if code ~= 0 then
          error("子进程退出码=" .. code .. ":\n" .. (out or ""))
        end
        if not (out:find("PASS") or out:find("ALL PASS") or out:find("cases passed")) then
          error("子进程未输出 PASS 标记:\n" .. (out or ""))
        end
      end)
    end
  end)
end

run_legacy()

vim.api.nvim_create_autocmd("VimLeavePre", {
  once = true,
  callback = function()
    pcall(vim.fn.delete, probe_test_dir, "rf")
  end,
})

-- ── 汇总并退出（quit / cquit 1）──────────────────────────────────────────
harness.run()
