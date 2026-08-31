-- tests/cases/clangd_resource_spec.lua
-- Dynamic, reversible OS priority for clangd owned by this Neovim.

local t = require("tests.harness")
t.bootstrap()

local controller = require("utils.clangd_resource_controller")
local cpu_load = require("utils.cpu_load")

local function code_only(path)
  local lines = vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. path)
  local out = {}
  for _, line in ipairs(lines) do out[#out + 1] = line:gsub("%-%-.*$", "") end
  return table.concat(out, "\n")
end

local base = {
  enabled = true,
  high_pct = 85,
  low_pct = 70,
  max_deferrals = 20,
  foreground_active = false,
}

t.describe("clangd controller: shared hysteresis -> reversible priority", function()
  t.it("high→low；low→normal；滞回带保持；unknown→normal", function()
    t.assert_eq(controller.desired_priority({ status = "ready", host_pct = 95 }, "normal", base), "low")
    t.assert_eq(controller.desired_priority({ status = "ready", host_pct = 60 }, "low", base), "normal")
    t.assert_eq(controller.desired_priority({ status = "ready", host_pct = 78 }, "low", base), "low")
    t.assert_eq(controller.desired_priority({ status = "ready", host_pct = 78 }, "normal", base), "normal")
    t.assert_eq(controller.desired_priority({ status = "unknown" }, "low", base), "normal")
    t.assert_eq(controller.desired_priority(nil, "low", base), "normal")
  end)

  t.it("前台任务活动时 clangd 让路，但不停止", function()
    local opts = vim.tbl_extend("force", base, { foreground_active = true })
    t.assert_eq(controller.desired_priority({ status = "ready", host_pct = 10 }, "normal", opts), "low")
  end)

  t.it("发现多个 owned child、降级、恢复并淘汰死亡 PID", function()
    controller._reset_for_test()
    local alive = { [101] = true, [102] = true }
    local changes, child_scans, closed = {}, 0, 0
    local driver = {
      id = "fake-windows",
      child_processes = function(parent, name)
        child_scans = child_scans + 1
        t.assert_eq(parent, 77)
        t.assert_eq(name, "clangd.exe")
        local children = {}
        for _, pid in ipairs({ 101, 102 }) do
          if alive[pid] then children[#children + 1] = { pid = pid, native = { pid = pid } } end
        end
        return children
      end,
      process_exists = function(process)
        local pid = type(process) == "table" and process.pid or process
        return alive[pid] == true
      end,
      set_process_priority = function(process, priority)
        local pid = type(process) == "table" and process.pid or process
        changes[#changes + 1] = { pid, priority }
        return true
      end,
      close_process = function() closed = closed + 1; return true end,
    }
    local added = controller.discover("C:/LLVM/bin/clangd.exe", {
      driver = driver,
      parent_pid = 77,
      reading = { status = "ready", host_pct = 95 },
      options = base,
      foreground_active = false,
    })
    t.assert_eq(added, 2)
    t.assert_eq(#changes, 2)
    t.assert_eq(changes[1][2], "low")
    t.assert_eq(controller.status().count, 2)

    controller.reconcile({ status = "ready", host_pct = 60 }, {
      driver = driver,
      options = base,
      foreground_active = false,
    })
    t.assert_eq(#changes, 4)
    t.assert_eq(changes[3][2], "normal")
    alive[101] = false
    controller.reconcile({ status = "ready", host_pct = 60 }, {
      driver = driver,
      options = base,
      foreground_active = false,
    })
    t.assert_eq(controller.status().count, 1)
    t.assert_eq(child_scans, 1, "Toolhelp 只允许启动发现，不得进入 1Hz reconcile")
    t.assert_eq(closed, 1, "死亡进程 handle 必须释放")
    controller._reset_for_test()
  end)

  t.it("bounded discovery 重试 transient zero-match，不创建常驻 poller", function()
    controller._reset_for_test()
    local probes = 0
    local driver = {
      id = "fake-windows",
      child_processes = function()
        probes = probes + 1
        return probes < 3 and {} or { { pid = 303 } }
      end,
      process_exists = function() return true end,
      set_process_priority = function() return true end,
    }
    local control = controller.discover_with_retry("clangd.exe", {
      driver = driver,
      parent_pid = 77,
      reading = { status = "ready", host_pct = 10 },
      options = base,
      foreground_active = false,
      delays = { 0, 1, 1 },
      schedule = function(fn) fn() end,
      defer_fn = function(fn, _) fn() end,
    })
    t.assert_true(control.done)
    t.assert_eq(control.attempts, 3)
    t.assert_eq(control.registered, 1)
    controller._reset_for_test()
  end)

  t.it("无 PID / 平台无 capability → fail-open，不抛错", function()
    controller._reset_for_test()
    local ok_missing, registered = pcall(controller.register, nil, { driver = {} })
    t.assert_true(ok_missing)
    t.assert_false(registered)
    local ok_discover, count, reason = pcall(controller.discover, "clangd", { driver = { id = "stub" } })
    t.assert_true(ok_discover)
    t.assert_eq(count, 0)
    t.assert_eq(reason, "unsupported")
  end)

  t.it("实现不得 kill/suspend/affinity clangd", function()
    local source = code_only("lua/utils/clangd_resource_controller.lua")
    for _, forbidden in ipairs({ "jobstop", "terminate", "suspend", "ProcessorAffinity", "taskkill" }) do
      t.assert_nil(source:find(forbidden, 1, true), "controller 出现破坏性动作：" .. forbidden)
    end
    t.assert_match(source, "set_process_priority")
  end)
end)

t.describe("clangd controller: awareness subscription + Windows capability", function()
  t.it("subscriber 复用既有 host tick，不创建第二个 timer", function()
    cpu_load.reset()
    cpu_load._clear_subscribers_for_test()
    local now_ns, host_calls, observed = 0, 0, nil
    cpu_load.subscribe(function(reading) observed = reading end)
    cpu_load.setup({
      force = true,
      manual = true,
      now = function() return now_ns end,
      host_reader = function()
        host_calls = host_calls + 1
        return host_calls == 1
          and { idle = 100, total = 1000, cpus = 4 }
          or { idle = 110, total = 1100, cpus = 4 }
      end,
      editor_reader = function() return 0 end,
    })
    now_ns = 1e9
    cpu_load._tick(true)
    vim.wait(100, function() return observed ~= nil end)
    t.assert_true(observed ~= nil)
    t.assert_eq(observed.status, "ready")
    t.assert_eq(observed.host_pct, 90)
    cpu_load._clear_subscribers_for_test()
    cpu_load.reset()
  end)

  t.it("真实 awareness subscriber 驱动 low→normal，不创建 controller timer", function()
    controller._reset_for_test()
    cpu_load.reset()
    cpu_load._clear_subscribers_for_test()
    local now_ns, host_i = 0, 0
    local hosts = {
      { idle = 100, total = 1000, cpus = 4 },
      { idle = 110, total = 1100, cpus = 4 }, -- raw 90
      { idle = 200, total = 1200, cpus = 4 }, -- raw 10; EMA -> 70
    }
    cpu_load.setup({
      force = true, manual = true,
      now = function() return now_ns end,
      host_reader = function() host_i = host_i + 1; return hosts[host_i] end,
      editor_reader = function() return 0 end,
    })
    local changes = {}
    local driver = {
      id = "fake-windows",
      process_exists = function() return true end,
      set_process_priority = function(_, priority)
        changes[#changes + 1] = priority
        return true
      end,
    }
    controller.register(404, {
      driver = driver,
      reading = { status = "ready", host_pct = 10 },
      options = base,
      foreground_active = false,
    })
    now_ns = 1e9; cpu_load._tick(true)
    vim.wait(100, function() return changes[1] == "low" end)
    now_ns = 2e9; cpu_load._tick(true)
    vim.wait(100, function() return changes[2] == "normal" end)
    t.assert_eq(table.concat(changes, ","), "low,normal")
    t.assert_eq(cpu_load.status().stats.host_samples, 3)
    controller._reset_for_test()
    cpu_load._clear_subscribers_for_test()
    cpu_load.reset()
  end)

  t.it("cmd factory 原样返回 RPC，并在 spawn 后有界 discover", function()
    local source = code_only("lua/plugins/ue.lua")
    local spawn_at = assert(source:find("vim.lsp.rpc.start", 1, true))
    local discover_at = assert(source:find("discover_with_retry", spawn_at, true))
    local return_at = assert(source:find("return rpc", discover_at, true))
    t.assert_true(spawn_at < discover_at and discover_at < return_at)
  end)

  t.it("Windows 原生 process capability 可枚举，不 spawn PowerShell", function()
    local platform = require("utils.platform")
    local driver = platform.driver()
    if driver.id ~= "windows" then return end
    t.assert_type(driver.child_processes, "function")
    t.assert_type(driver.process_exists, "function")
    t.assert_type(driver.set_process_priority, "function")
    local children, err = driver.child_processes(vim.fn.getpid(), "definitely-not-a-real-child.exe")
    t.assert_type(children, "table", tostring(err))
    t.assert_eq(#children, 0)
    local exists = driver.process_exists(vim.fn.getpid())
    t.assert_true(exists == true, "当前 nvim PID 应可查询")
    local source = code_only("lua/utils/platform/windows.lua")
    local capability_at = assert(source:find("function M.child_processes", 1, true))
    local capability_end = assert(source:find("function M.default_clangd_candidates", capability_at, true))
    local capability = source:sub(capability_at, capability_end - 1)
    t.assert_nil(capability:find("powershell", 1, true), "进程控制不得 spawn PowerShell")
  end)
end)
