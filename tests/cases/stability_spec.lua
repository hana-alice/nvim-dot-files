-- tests/cases/stability_spec.lua
-- 稳定性 / 幂等回归：重复加载、重复 setup、多轮 reset 无泄漏。

local t = require("tests.harness")
t.bootstrap()

t.describe("stability: 模块重复 require 幂等", function()
  for _, name in ipairs({ "ue", "ue.config", "utils.platform", "utils.ue_paths" }) do
    t.it(name .. " 两次 require 同一引用", function()
      local a = require(name)
      local b = require(name)
      t.assert_true(a == b, name .. " 两次 require 返回不同引用")
    end)
  end
end)

t.describe("stability: ue.setup 可重复调用", function()
  t.it("两次 setup 无异常且命令仍注册", function()
    require("ue").setup()
    require("ue").setup()
    t.assert_eq(vim.fn.exists(":UEBuild"), 2)
    t.assert_eq(vim.fn.exists(":UEDAPAttach"), 2)
  end)
end)

t.describe("stability: ue.config 多轮 override/reset 无泄漏", function()
  local cfg = require("ue.config")
  t.it("三轮 setup→reset 后恢复默认", function()
    for i = 1, 3 do
      cfg.setup({ index = { idle_cold_ms = 100 + i }, dap = { lldb_dap_path = "/tmp/x" } })
      cfg.reset_for_test()
      t.assert_eq(cfg.get("index.idle_cold_ms"), 120000, "第 " .. i .. " 轮未恢复")
    end
    t.assert_nil(cfg.get("dap.lldb_dap_path"))
  end)
end)

t.describe("stability: DAP 平台注册可重复清空", function()
  local p = require("ue.dap.platforms")
  t.it("两次 _reset_for_test 后注册/查询正常", function()
    p._reset_for_test()
    p._reset_for_test()
    local hit = false
    p.register_attach("stab_test", function() hit = true end)
    local h = p.attach_handler("stab_test")
    t.assert_type(h, "function")
    h()
    t.assert_true(hit, "handler 未触发")
    t.assert_nil(p.launch_handler("stab_test"))
    p._reset_for_test()
    t.assert_nil(p.attach_handler("stab_test"))
  end)
end)

-- ── K40 模式固化（health-check 2026-07 task 7.2）────────────────────────────
-- uv timer 回调里禁止同步 spawn：K40（liveness poller 每 1.5s 同步 adb 往返 →
-- 全天 stall train）的永久防复发。静态扫描 lua/ 全仓：`timer:start(` 后同一
-- 回调窗口（40 行内、遇 `end)` 边界截断的近似）不得出现
-- vim.fn.system / vim.fn.systemlist / io.popen。
-- 近似扫描有误报可能：如出现合法用例，在 ALLOW 表登记 `文件:行号` 并注明理由。
local t4 = require("tests.harness")
t4.describe("stability: timer 回调内禁同步 spawn（K40 固化）", function()
  local cfg_root = vim.fn.stdpath("config")
  local ALLOW = {
    -- "lua/xxx.lua:123", -- 理由
  }
  local function allowed(rel, lnum)
    for _, a in ipairs(ALLOW) do
      if a == (rel .. ":" .. lnum) then return true end
    end
    return false
  end

  t4.it("全仓扫描 0 违例", function()
    local files = vim.fn.glob(cfg_root .. "/lua/**/*.lua", true, true)
    local viols = {}
    for _, path in ipairs(files) do
      local lines = {}
      for l in io.lines(path) do lines[#lines + 1] = l end
      local rel = path:sub(#cfg_root + 2):gsub("\\", "/")
      for i, l in ipairs(lines) do
        if l:find("timer:start(", 1, true) and not l:match("^%s*%-%-") then
          -- 向下最多 40 行找同步 spawn；粗略以缩进回落的 `end)` 截断
          for j = i + 1, math.min(#lines, i + 40) do
            local body = lines[j]
            if body:match("^%s*end%)") and select(2, body:gsub("%s", "")) then
              break
            end
            if not body:match("^%s*%-%-") then
              if (body:find("vim%.fn%.system") or body:find("io%.popen"))
                and not allowed(rel, j) then
                viols[#viols + 1] = ("%s:%d (timer at :%d): %s")
                  :format(rel, j, i, vim.trim(body):sub(1, 70))
              end
            end
          end
        end
      end
    end
    t4.assert_eq(#viols, 0,
      "timer 回调内出现同步 spawn（K40 模式）：\n" .. table.concat(viols, "\n"))
  end)
end)

-- 文件行数：ue.lua 是平台 workflow 迁移的单调下降 ratchet；其他既有
-- 超限文件暂时保留精确白名单。ratchet 只能随迁移下调，不能提高。
t4.describe("stability: ue.lua 单调下降 ratchet 与新增文件 800 行上限", function()
  local cfg_root = vim.fn.stdpath("config")
  local UE_LUA_LIMIT = 10562
  local GRANDFATHERED = {
    ["lua/ue.lua"] = UE_LUA_LIMIT,
    ["lua/ue/dap.lua"] = true,
    ["lua/ue/dap/android.lua"] = true,
    ["lua/utils/cheatsheet.lua"] = true,
    ["lua/utils/ue_goto/symbol.lua"] = true,
  }

  local function line_limit_violation(rel, line_count)
    local allowance = GRANDFATHERED[rel]
    if allowance == true then
      return nil
    end
    local limit = type(allowance) == "number" and allowance or 800
    if line_count <= limit then
      return nil
    end
    return rel .. " (" .. line_count .. " lines; limit " .. limit .. ")"
  end

  t4.it("ue.lua 不超过冻结基线，其他新文件不超 800 行", function()
    local files = vim.fn.glob(cfg_root .. "/lua/**/*.lua", true, true)
    local viols = {}
    for _, path in ipairs(files) do
      local rel = path:sub(#cfg_root + 2):gsub("\\", "/")
      if GRANDFATHERED[rel] ~= true then
        local n = 0
        for _ in io.lines(path) do n = n + 1 end
        local violation = line_limit_violation(rel, n)
        if violation then viols[#viols + 1] = violation end
      end
    end
    t4.assert_eq(#viols, 0,
      "Lua 文件超过行数门禁（ue.lua ratchet 不得上调；新文件须拆分）：\n"
      .. table.concat(viols, "\n"))
  end)

  t4.it("synthetic growth fixtures fail at ue.lua +1 and workflow line 801", function()
    t4.assert_contains(
      line_limit_violation("lua/ue.lua", UE_LUA_LIMIT + 1),
      "limit " .. UE_LUA_LIMIT
    )
    t4.assert_contains(
      line_limit_violation("lua/ue/workflows/android/future.lua", 801),
      "limit 800"
    )
  end)
end)
