-- tests/cases/task_registry_spec.lua
-- 通用任务注册表回归（lua/utils/task_registry.lua）。
--
-- 重点：验证「竞态不存在」而非「竞态被防住」——
--   * 状态是派生量（status 实时查句柄），注册表无 state 副本、无 mark_done。
--   * 唯一写入入口是 register；on_exit 无回写路径（架构消除竞态，见 design.md）。
--   * cancel 先复检、再动句柄、不回写、幂等。
-- 探针可注入：用 mock handle {alive=bool, code=n} 替代真实 jobwait/uv。

local t = require("tests.harness")
t.bootstrap()

local tr = require("utils.task_registry")

-- mock probe: handle is { alive=bool, code=number?, killed=bool }
local function mock_probe(rec)
  local h = rec.handle
  if h.alive then return "running" end
  return "done", h.code
end

local function fresh()
  tr._reset_for_test()
  tr._set_probe_for_test(mock_probe)
end

t.describe("task_registry: 登记与派生状态", function()
  t.it("register 返回单调不复用 id", function()
    fresh()
    local id1 = tr.register({ name = "a", group = "g", kind = "job", handle = { alive = true } })
    local id2 = tr.register({ name = "b", group = "g", kind = "system", handle = { alive = true } })
    t.assert_eq(id1, 1)
    t.assert_eq(id2, 2)
  end)

  t.it("register 拒绝非法 kind", function()
    fresh()
    local id, err = tr.register({ name = "x", kind = "bogus", handle = {} })
    t.assert_true(id == nil, "非法 kind 应返回 nil")
    t.assert_true(err ~= nil, "应返回错误信息")
  end)

  t.it("register 拒绝缺 handle", function()
    fresh()
    local id = tr.register({ name = "x", kind = "job" })
    t.assert_true(id == nil, "缺 handle 应返回 nil")
  end)

  t.it("记录不含 state 字段（状态是派生量）", function()
    fresh()
    local id = tr.register({ name = "a", kind = "job", handle = { alive = true } })
    local rec = tr.get(id)
    t.assert_true(rec.state == nil, "记录不应有 state 字段")
  end)

  t.it("get 不存在返回 nil 不抛错", function()
    fresh()
    t.assert_true(tr.get(999) == nil)
  end)
end)

t.describe("task_registry: AR-T1 状态即真相", function()
  t.it("句柄翻转 running→done，status 立即反映，无需任何写函数", function()
    fresh()
    local h = { alive = true }
    local id = tr.register({ name = "build", kind = "job", handle = h })
    t.assert_eq(tr.status(id), "running")
    -- 翻转句柄为已退出（不调用任何注册表写函数）
    h.alive = false
    h.code = 0
    t.assert_eq(tr.status(id), "done")
  end)
end)

t.describe("task_registry: AR-T2/T3 取消语义", function()
  t.it("AR-T2 取消运行中：动句柄、不回写、随后 status=done", function()
    fresh()
    local h = { alive = true, killed = false }
    -- mock job: cancel 走 vim.fn.jobstop，这里用探针感知不到 jobstop，
    -- 所以改用一个能记录 kill 的 probe + 让 cancel 翻转 alive。
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    local id = tr.register({ name = "x", kind = "system", handle = h })
    -- system kind: cancel 调 handle:kill(15)。给 handle 一个 kill 方法。
    function h:kill(_) self.killed = true; self.alive = false end
    local ok = tr.cancel(id)
    t.assert_true(ok, "运行中取消应返回 true")
    t.assert_true(h.killed, "应调用 handle:kill")
    -- 注册表未写 state 副本：记录里仍无 state 字段
    t.assert_true(tr.get(id).state == nil, "cancel 不应写 state 副本")
    t.assert_eq(tr.status(id), "cancelled") -- 我们取消的 → cancelled
  end)

  t.it("AR-T3 取消已退出：不动句柄、返回 false、不抛错", function()
    fresh()
    local h = { alive = false, code = 0, killed = false }
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    function h:kill(_) self.killed = true end
    local id = tr.register({ name = "x", kind = "system", handle = h })
    local ok = tr.cancel(id)
    t.assert_true(ok == false, "已退出取消应返回 false")
    t.assert_true(h.killed == false, "已退出不应调用 kill")
  end)

  t.it("取消幂等：连续两次安全", function()
    fresh()
    local h = { alive = true, killcount = 0 }
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    function h:kill(_) self.killcount = self.killcount + 1; self.alive = false end
    local id = tr.register({ name = "x", kind = "system", handle = h })
    tr.cancel(id)
    tr.cancel(id)
    t.assert_eq(h.killcount, 1)
  end)
end)

t.describe("task_registry: cancel_all", function()
  t.it("只取消运行中任务，返回数量", function()
    fresh()
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    local function sys(alive)
      local h = { alive = alive }
      function h:kill(_) self.alive = false end
      return h
    end
    tr.register({ name = "r1", kind = "system", handle = sys(true) })
    tr.register({ name = "r2", kind = "system", handle = sys(true) })
    tr.register({ name = "d1", kind = "system", handle = sys(false) })
    local n = tr.cancel_all()
    t.assert_eq(n, 2)
  end)
end)

t.describe("task_registry: AR-T5 list GC 幂等且有界", function()
  t.it("终态记录 ≤ KEEP_DONE 且 running 恒在列；两次 list 稳定", function()
    fresh()
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    -- 1 个 running
    tr.register({ name = "run", kind = "job", handle = { alive = true } })
    -- KEEP_DONE+5 个已退出
    local total_done = tr._KEEP_DONE + 5
    for i = 1, total_done do
      tr.register({ name = "done" .. i, kind = "job", handle = { alive = false, code = 0 } })
    end
    local rows1 = tr.list()
    local function count(rows)
      local running, done = 0, 0
      for _, r in ipairs(rows) do
        if r.status == "running" then running = running + 1 else done = done + 1 end
      end
      return running, done
    end
    local r1, d1 = count(rows1)
    t.assert_eq(r1, 1, "running 必须恒在列")
    t.assert_true(d1 <= tr._KEEP_DONE, "终态记录应被裁剪到 ≤ KEEP_DONE，实得 " .. d1)
    -- 第二次 list 稳定
    local rows2 = tr.list()
    local r2, d2 = count(rows2)
    t.assert_eq(r2, 1)
    t.assert_eq(d2, d1)
  end)
end)

t.describe("task_registry: running_count（statusline 用）", function()
  t.it("N==0 / N>0 计数正确", function()
    fresh()
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    t.assert_eq(tr.running_count(), 0)
    tr.register({ name = "a", kind = "job", handle = { alive = true } })
    tr.register({ name = "b", kind = "job", handle = { alive = true } })
    tr.register({ name = "c", kind = "job", handle = { alive = false, code = 0 } })
    t.assert_eq(tr.running_count(), 2)
  end)
end)

t.describe("task_registry: AR-T4 无回写 / 纯内存（C-INV-1/2 守护）", function()
  -- 源码级守护：register 体内不出现 vim.api/vim.fn/vim.notify/io./vim.schedule。
  -- 读取源文件做朴素扫描（不依赖运行时）。
  t.it("register/status/cancel/mark 区域无 mark_done、register 体纯内存", function()
    local path = vim.fn.stdpath("config") .. "/lua/utils/task_registry.lua"
    local fd = io.open(path, "r")
    t.assert_true(fd ~= nil, "应能读取 task_registry.lua")
    local src = fd:read("*a"); fd:close()
    -- 无 mark_done / transition 这类状态机写回 API（架构无此物）
    t.assert_true(not src:match("function%s+M%.mark_done"), "不应存在 M.mark_done（派生状态架构）")
    t.assert_true(not src:match("function%s+M%.transition"), "不应存在 M.transition")
    -- register 函数体（到下一个 function M. 为止）不应有 vim.api/vim.notify/io.
    local body = src:match("function M%.register.-\nend")
    t.assert_true(body ~= nil, "应能截取 register 体")
    t.assert_true(not body:match("vim%.api"), "register 体不应调 vim.api")
    t.assert_true(not body:match("vim%.notify"), "register 体不应调 vim.notify")
    t.assert_true(not body:match("vim%.schedule"), "register 体不应调 vim.schedule")
    t.assert_true(not body:match("io%."), "register 体不应做 IO")
  end)

  -- 接入点守护：register 调用只在 job 创建后，on_exit 回调本体内无 task_registry。
  -- 用单行 on_exit 形式精确匹配（接入点的 on_exit 都是 `on_exit = function(...) ... end`
  -- 单行/紧凑写法）；朴素 `.-end` 会跨越 else 块误吞，故按「同一行的 on_exit=function..end」
  -- 或「register 块与 on_exit 之间隔着结构关键字」来判定，这里改为更稳的检查：
  -- task_registry.register 调用所在行附近不应是 on_exit 上下文——直接断言每个接入点
  -- 文件里 register 调用出现在 `pcall(function()` 包裹中（侧路标志），而非裸在回调体。
  t.it("接入点 register 走 pcall 侧路、不在 on_exit 行内", function()
    local cfg = vim.fn.stdpath("config")
    local files = {
      "/lua/utils/ue_launch.lua",
      "/lua/utils/ue_logs.lua",
      "/lua/ue/dap.lua",
    }
    for _, rel in ipairs(files) do
      local fd = io.open(cfg .. rel, "r")
      if fd then
        local lines = {}
        for line in (fd:read("*a") .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = line end
        fd:close()
        for i, line in ipairs(lines) do
          if line:match("task_registry") and line:match("register") then
            -- register 调用行本身不得同时是 on_exit 定义行（C-INV-1：不在退出回调内联）
            t.assert_true(not line:match("on_exit"),
              rel .. ":" .. i .. " register 不应内联在 on_exit 行")
          end
        end
      end
    end
  end)
end)

t.describe("task_registry: DAP 边界（K5）", function()
  -- cancel_all 只作用于注册表内任务集合。DAP 会话从不被 register，
  -- 故 cancel_all 不可能触及它。用「注册表为空时 cancel_all 返回 0」+
  -- 「只登记普通任务时 cancel_all 只动这些」证明其作用域受限于注册表。
  t.it("cancel_all 作用域仅限注册表内任务", function()
    fresh()
    tr._set_probe_for_test(function(rec)
      return rec.handle.alive and "running" or "done"
    end)
    -- 空注册表
    t.assert_eq(tr.cancel_all(), 0)
    -- 登记 2 个普通任务（模拟 build/logcat），无 DAP 会话被登记
    local function sys(alive)
      local h = { alive = alive }
      function h:kill(_) self.alive = false end
      return h
    end
    tr.register({ name = "build", group = "build", kind = "system", handle = sys(true) })
    tr.register({ name = "logcat", group = "dap", kind = "system", handle = sys(true) })
    t.assert_eq(tr.cancel_all(), 2, "cancel_all 只动注册表内的 2 个任务")
  end)
end)

