-- tests/cases/host_resource_discipline_spec.lua
-- P6 host-level resource discipline: shared policy, batch gates, foreground ownership.

local t = require("tests.harness")
t.bootstrap()

local admission = require("utils.host_admission")

local function source(path)
  return table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. path), "\n")
end

local function write(path, content)
  local file = assert(io.open(path, "wb"))
  file:write(content or "x")
  file:close()
end

-- Exact source anchors: adding or changing any spawn API reference requires an
-- explicit resource classification and rationale here. Broad file/API
-- exemptions are deliberately impossible.
local SPAWN_AUDIT = {
  { p="lua/config/lazy.lua", api="fn-system", a="vim.fn.system({ \"git\", \"clone\"", class="bootstrap", reason="one-time lazy.nvim bootstrap before UI exists" },
  { p="lua/config/neovide.lua", api="vim.system", a="opts.run or vim.system", class="interactive", reason="native folder picker; user is waiting" },
  { p="lua/plugins/ue.lua", api="lsp-rpc", a="vim.lsp.rpc.start", class="long-lived", reason="owned clangd", guard="clangd_resource_controller" },
  { p="lua/ue/build_monitor.lua", api="vim.system", a="opts.run or vim.system", class="foreground-inherited", reason="bounded status probe while terminal build token is active" },
  { p="lua/ue/cdb/pipeline.lua", api="jobstart", a="_rt.jobstart(step.command", class="deferrable", reason="admitted CDB chain", guard="host_admission" },
  { p="lua/ue/cdb/pipeline.lua", api="fn-system", a="vim.fn.system(cmd)", class="subprocess-only", reason="slim runs inside admitted ccjson or explicit sync path" },
  { p="lua/ue/clangd_commands.lua", api="vim.system", a="vim.system(cmd, { text = true }", class="interactive", reason="bounded compile-command query for active LSP request" },
  { p="lua/ue/dap/android.lua", api="vim.system", a="local ok_spawn = pcall(vim.system", n=2, class="dap", reason="DAP protocol/process lifecycle exemption" },
  { p="lua/ue/dap/android.lua", api="jobstart", a="vim.fn.jobstart({ adb, \"-s\", serial, \"shell\", cmd }", class="dap", reason="DAP device process bridge" },
  { p="lua/ue/dap/android.lua", api="jobstart", a="vim.fn.jobstart(jdb_connect_argv", class="dap", reason="DAP JDWP bridge" },
  { p="lua/ue/dap/android.lua", api="vim.system", a="vim.system(", class="dap", reason="DAP bounded host operation" },
  { p="lua/ue/dap/android.lua", api="fn-system", a="vim.fn.system(cmd)", n=2, class="dap", reason="DAP preflight fallback" },
  { p="lua/ue/dap/ios.lua", api="vim.system", a="pcall(vim.system, argv", class="dap", reason="DAP adapter lifecycle" },
  { p="lua/ue/dap/ios.lua", api="jobstart", a="bridge.job_id = vim.fn.jobstart", class="dap", reason="DAP bridge lifecycle" },
  { p="lua/ue/dap.lua", api="jobstart", a="logcat_job = vim.fn.jobstart", class="dap", reason="DAP log stream" },
  { p="lua/ue/dap.lua", api="fn-system", a="vim.fn.system({ dap_exe", class="dap", reason="DAP version preflight" },
  { p="lua/ue/dap.lua", api="fn-system", a="vim.fn.systemlist(cmd)", class="dap", reason="DAP process snapshot fallback" },
  { p="lua/ue/gtags.lua", api="vim.system", a="vim.system(command", class="sync-debug", reason="explicit UEPrepareSync twin only" },
  { p="lua/ue/gtags.lua", api="vim.system", a="spec.system or vim.system", class="deferrable", reason="watcher GTAGS async rebuild", guard="admission.run_when_allowed" },
  { p="lua/ue/index/_build.lua", api="vim.system", a="partition_result(vim.system", class="sync-debug", reason="explicit synchronous twin; UI callers use async" },
  { p="lua/ue/index/_build.lua", api="vim.system", a="local handle = vim.system(plan.command", class="deferrable", reason="admitted async CDB partition", guard="admission.run_when_allowed" },
  { p="lua/ue/index/_build.lua", api="vim.system", a="vim.system(cmd, {", class="deferrable", reason="controlled index child admitted by scheduler", guard="admit_background_phase", gp="lua/ue/index/_schedule.lua" },
  { p="lua/ue/index/_generation.lua", api="vim.system", a="vim.system({ path,", class="short", reason="cached bounded toolchain identity probe" },
  { p="lua/ue/target_tasks.lua", api="vim.system", a="pcall(vim.system, command", class="foreground", reason="operation metadata classifies explicit task", guard="is_foreground_operation" },
  { p="lua/ue/workflows/android/install.lua", api="jobstart", a="pcall(d.jobstart, install_cmd", class="foreground", reason="explicit APK install", guard="foreground_begin" },
  { p="lua/ue/workflows/android/launch.lua", api="jobstart", a="pcall(deps.jobstart, prepared.command", class="interactive", reason="short explicit app launch" },
  { p="lua/ue.lua", api="vim.system", a="if vim.system then", n=2, class="helper", reason="capability branch for shared sync query helper" },
  { p="lua/ue.lua", api="vim.system", a="local result = vim.system(cmd, system_opts):wait()", class="sync-debug", reason="explicit sync helper used by UEPrepareSync/query fallbacks" },
  { p="lua/ue.lua", api="vim.system", a="if not vim.system then", class="helper", reason="async helper capability branch" },
  { p="lua/ue.lua", api="vim.system", a="local handle = vim.system(cmd, system_opts", class="interactive", reason="async short query helper" },
  { p="lua/ue.lua", api="vim.system", a="  vim.system(cmd, system_opts, function(result)", class="deferrable", reason="admitted workspace scan", guard="host_admission" },
  { p="lua/ue.lua", api="vim.system", a="if vim.fn.executable(\"fd\") == 1 and vim.system then", class="subprocess-only", reason="shader scan runs inside admitted ccjson subprocess" },
  { p="lua/ue.lua", api="vim.system", a="return vim.system(cmd, { text = true, cwd = root }):wait()", class="subprocess-only", reason="shader scan runs inside admitted ccjson subprocess" },
  { p="lua/ue.lua", api="jobstart", a="function M._logged_jobstart", class="helper", reason="CDB runner definition; concrete call is separately audited" },
  { p="lua/ue.lua", api="jobstart", a="vim.fn.jobstart(cmd, job_opts)", class="deferrable", reason="CDB job runner is called behind pipeline admission", guard="host_admission", gp="lua/ue/cdb/pipeline.lua" },
  { p="lua/ue.lua", api="termopen", a="vim.fn.termopen(cmd", class="foreground", reason="visible user terminal task", guard="foreground_begin" },
  { p="lua/ue.lua", api="jobstart", a="CORE_RT.prepare_jobid = vim.fn.jobstart", class="deferrable", reason="admitted cold GTAGS", guard="admission.run_when_allowed" },
  { p="lua/ue.lua", api="jobstart", a="local pch_jobid = vim.fn.jobstart", class="foreground", reason="explicit PCH rebuild", guard="foreground_begin" },
  { p="lua/ue.lua", api="vim.system", a="local handle = vim.system(cmd, {", class="deferrable", reason="admitted ccjson subprocess", guard="admission.run_when_allowed" },
  { p="lua/ue.lua", api="fn-system", a="vim.fn.systemlist(joined)", class="helper", reason="legacy fallback for shared sync helper" },
  { p="lua/utils/android_device.lua", api="vim.system", a="pcall(vim.system", class="interactive", reason="bounded device discovery requested by user" },
  { p="lua/utils/code_search/init.lua", api="spawn", a="vim.loop.spawn(cs", class="interactive", reason="cancellable indexed query" },
  { p="lua/utils/code_search/init.lua", api="spawn", a="vim.loop.spawn(rg", class="interactive", reason="cancellable grep fallback" },
  { p="lua/utils/code_search/init.lua", api="spawn", a="vim.loop.spawn(cindex", class="deferrable", reason="admitted csearch rebuild", guard="admission.run_when_allowed" },
  { p="lua/utils/core_health.lua", api="vim.system", a="pcall(vim.system, argv", class="foreground", reason="explicit isolated core audit", guard="foreground_begin" },
  { p="lua/utils/core_health_checks.lua", api="vim.system", a="pcall(vim.system, argv", class="subprocess-only", reason="bounded probe inside already-foreground headless audit" },
  { p="lua/utils/platform/linux.lua", api="jobstart", a="vim.fn.jobstart({ \"xdg-open\", path }", class="detached", reason="OS opener; no sustained child ownership" },
  { p="lua/utils/platform/linux.lua", api="jobstart", a="vim.fn.jobstart({ \"xdg-open\", dir }", class="detached", reason="OS revealer; no sustained child ownership" },
  { p="lua/utils/platform/macos.lua", api="jobstart", a="vim.fn.jobstart({ \"open\", path }", class="detached", reason="OS opener" },
  { p="lua/utils/platform/macos.lua", api="jobstart", a="vim.fn.jobstart({ \"open\", \"-R\", path }", class="detached", reason="OS revealer" },
  { p="lua/utils/platform/windows.lua", api="jobstart", a="vim.fn.jobstart(command, { detach = true }", class="detached", reason="Explorer opener/revealer" },
  { p="lua/utils/restart.lua", api="spawn", a="uv.spawn(exe", class="interactive", reason="explicit editor restart handoff" },
  { p="lua/utils/ue_goto/semantic_client_runtime.lua", api="jobstart", a="vim.fn.jobstart({", class="interactive", reason="compiler-semantic sidecar for active gd" },
  { p="lua/utils/ue_goto/semantic_sidecar_catalog.lua", api="vim.system", a="vim.system(args", class="subprocess-only", reason="bounded compiler probe inside headless sidecar" },
  { p="lua/utils/ue_goto/semantic_sidecar_libclang.lua", api="vim.system", a="vim.system(cmd", class="subprocess-only", reason="bounded compiler probe inside headless sidecar" },
  { p="lua/utils/ue_launch.lua", api="vim.system", a="vim.system(cmd", class="interactive", reason="explicit target launch waits only for PID handoff" },
  { p="lua/utils/ue_launch.lua", api="jobstart", a="pcall(vim.fn.jobstart, cmd", class="detached", reason="explicit detached target launch" },
  { p="lua/utils/ue_logs.lua", api="jobstart", a="active_jobid = vim.fn.jobstart", class="interactive", reason="explicit low-CPU log stream" },
  { p="lua/utils/yazi.lua", api="termopen", a="vim.fn.termopen(cmd", class="interactive", reason="explicit interactive terminal UI" },
  { p="lua/trouble/sources/ue_sidebar.lua", api="vim.system", a="if vim.system then", class="helper", reason="sidebar async capability branch" },
  { p="lua/trouble/sources/ue_sidebar.lua", api="vim.system", a="vim.system(cmd", class="interactive", reason="bounded sidebar query" },
  { p="lua/trouble/sources/ue_sidebar.lua", api="fn-system", a="vim.fn.systemlist(cmd)", class="interactive", reason="legacy sidebar fallback" },
}

t.describe("host discipline: spawn audit", function()
  t.it("每个 spawn API 引用都有精确类别、理由与数量守卫", function()
    local patterns = {
      ["vim.system"] = function(code) return code:match("vim%.system") end,
      ["fn-system"] = function(code)
        return code:match("vim%.fn%.system%s*%(") or code:match("vim%.fn%.systemlist%s*%(")
      end,
      jobstart = function(code)
        return code:match("[%w%._]+jobstart%s*%(")
          or code:match("pcall%s*%(%s*[%w%._]+jobstart")
      end,
      termopen = function(code) return code:match("termopen%s*%(") end,
      spawn = function(code) return code:match("[%w%._]+%.spawn%s*%(") end,
      ["lsp-rpc"] = function(code) return code:match("vim%.lsp%.rpc%.start%s*%(") end,
    }
    local valid = {
      deferrable=true, foreground=true, ["foreground-inherited"]=true,
      ["long-lived"]=true, interactive=true, detached=true, dap=true,
      short=true, helper=true, bootstrap=true, ["sync-debug"]=true, ["subprocess-only"]=true,
    }
    local hits = {}
    for _, entry in ipairs(SPAWN_AUDIT) do
      t.assert_true(valid[entry.class] == true, "未知 class: " .. tostring(entry.class))
      t.assert_true(type(entry.reason) == "string" and entry.reason ~= "", entry.p .. " 缺 reason")
      hits[entry] = 0
      if entry.guard then
        t.assert_contains(source(entry.gp or entry.p), entry.guard,
          entry.p .. " 缺资源接入 anchor: " .. entry.guard)
      end
    end

    local config_root = vim.fn.stdpath("config") .. "/"
    for _, path in ipairs(vim.fn.glob(config_root .. "lua/**/*.lua", false, true)) do
      local rel = path:gsub("\\", "/"):sub(#config_root + 1)
      if not rel:match("^lua/nio/") then
        for _, line in ipairs(vim.fn.readfile(path)) do
          local code = line:gsub("%-%-.*$", "")
          for api, detects in pairs(patterns) do
            if detects(code) then
              local matches = {}
              for _, entry in ipairs(SPAWN_AUDIT) do
                if entry.p == rel and entry.api == api and code:find(entry.a, 1, true) then
                  matches[#matches + 1] = entry
                end
              end
              t.assert_eq(#matches, 1, ("未分类/重复 spawn: %s [%s] %s"):format(rel, api, vim.trim(code)))
              hits[matches[1]] = hits[matches[1]] + 1
            end
          end
        end
      end
    end
    for entry, count in pairs(hits) do
      t.assert_eq(count, entry.n or 1,
        ("spawn anchor 数量漂移: %s [%s] %s"):format(entry.p, entry.api, entry.a))
    end
  end)
end)

t.describe("host discipline: deferrable batch integration", function()
  t.it("CDB pipeline queued 时不取 writer/spawn，build cancel 能取消 pending", function()
    admission._reset_for_test()
    local pipeline = require("ue.cdb.pipeline")
    local spawned, completed = 0, nil
    pipeline.set_runtime({
      jobstart = function() spawned = spawned + 1; return 99 end,
      notify = function() end,
      log_error = function() end,
    })
    local foreground = admission.foreground_begin("build")
    local jobid = pipeline.run("Z:/does/not/matter/compile_commands.json", {}, function(ok)
      completed = ok
    end)
    t.assert_eq(jobid, 0, "queued pipeline 用 0 表示尚无 child")
    t.assert_true(pipeline.is_running(), "queued 也必须占逻辑 slot")
    t.assert_eq(spawned, 0)
    t.assert_true(pipeline.cancel("foreground build"))
    t.assert_false(pipeline.is_running())
    t.assert_false(completed)
    admission.foreground_done(foreground)
  end)

  t.it("csearch build gate 位于 executable lookup/spawn 之前", function()
    admission._reset_for_test()
    local foreground = admission.foreground_begin("install")
    local completed = false
    local stop = require("utils.code_search").build_index({}, "missing-list", function()
      completed = true
    end)
    t.assert_type(stop, "function")
    t.assert_false(completed, "deferred 时不得探测/启动 cindex")
    stop()
    admission.foreground_done(foreground)
  end)

  t.it("ccjson subprocess 在 temp JSON 与 vim.system 之前 gate", function()
    admission._reset_for_test()
    local foreground = admission.foreground_begin("build")
    local progress, completed = nil, false
    local control = require("ue").async_generate_compile_commands({}, function(stage)
      progress = stage
    end, function()
      completed = true
    end)
    t.assert_type(control, "table")
    t.assert_true(control.pending)
    t.assert_eq(progress, "admission")
    t.assert_false(completed)
    control:cancel()
    admission.foreground_done(foreground)
  end)

  t.it("cold 与 fast UEPrepare 都走 admitted async ccjson，不在 UI 解析 17s+", function()
    local text = source("lua/ue.lua")
    local cold_at = assert(text:find("local function continue_after_scan", 1, true))
    local gtags_at = assert(text:find("Phase 3b: build GTAGS", cold_at, true))
    local cold = text:sub(cold_at, gtags_at - 1)
    t.assert_match(cold, "M%.async_generate_compile_commands%(ctx")
    t.assert_nil(cold:find("return generate_compile_commands(ctx", 1, true),
      "cold prepare 不得回到主进程 CDB generator")
  end)

  t.it("正常 prepare 与手动 CDB partition 不再调用同步 wait twin", function()
    local build = source("lua/ue/index/_build.lua")
    local async_at = assert(build:find("M.partition_base_cdb_async", 1, true))
    local async_body = build:sub(async_at)
    t.assert_match(async_body, "admission%.run_when_allowed")
    t.assert_match(async_body, "vim%.system")
    local ue_source = source("lua/ue.lua")
    t.assert_match(ue_source, "INDEX_FN%.partition_base_cdb_async%(ctx")
    local sync_calls = select(2, ue_source:gsub("INDEX_FN%.partition_base_cdb%(ctx", ""))
    t.assert_eq(sync_calls, 0, "UI 命令/正常 prepare 不得落回 blocking twin")
  end)

  t.it("cold UEPrepare GTAGS 在 jobstart 前使用通用 queue", function()
    local text = source("lua/ue.lua")
    local phase_at = assert(text:find("Phase 3b: build GTAGS", 1, true))
    local closure_at = assert(text:find("local function start_gtags_phase", phase_at, true))
    local spawn_at = assert(text:find("CORE_RT.prepare_jobid = vim.fn.jobstart", phase_at, true))
    local gate_at = assert(text:find("admission.run_when_allowed", phase_at, true))
    local start_ref = assert(text:find("start = start_gtags_phase", gate_at, true))
    t.assert_true(closure_at < spawn_at and spawn_at < gate_at and gate_at < start_ref,
      "jobstart 必须封装在只由 admission 调用的 continuation 中")
  end)
end)

t.describe("host discipline: watcher GTAGS is async", function()
  local gtags = require("ue.gtags")

  t.it("rebuild_async 函数体不得 wait 主循环", function()
    local text = source("lua/ue/gtags.lua")
    local start_at = assert(text:find("function M.rebuild_async", 1, true))
    local stop_at = assert(text:find("function M.is_running", start_at, true))
    local body = text:sub(start_at, stop_at - 1)
    t.assert_nil(body:find(":wait%(") , "watcher async path 不得同步 wait")
    t.assert_match(body, "admission%.run_when_allowed")
    t.assert_match(body, "pcall%(system")
  end)

  t.it("foreground 活动时 async rebuild 只排队，不探测/启动 GTAGS", function()
    admission._reset_for_test()
    gtags._reset_for_test()
    local foreground = admission.foreground_begin("build")
    local system_calls, result = 0, nil
    local ok, state, control = gtags.rebuild_async({
      label = "test gtags",
      first_executable = function() error("must not probe while deferred") end,
      system = function() system_calls = system_calls + 1 end,
    }, function(done, message) result = { done, message } end)
    t.assert_true(ok)
    t.assert_eq(state, "queued")
    t.assert_eq(system_calls, 0)
    control:cancel()
    t.assert_false(gtags.is_running(), "取消 pending 必须释放单写者")
    t.assert_true(result and result[1] == false)
    gtags._reset_for_test()
    admission.foreground_done(foreground)
  end)

  t.it("放行后通过 vim.system callback 完成，不阻塞", function()
    admission._reset_for_test()
    gtags._reset_for_test()
    local root = vim.fn.tempname() .. "-gtags"
    local filelist, db = root .. "/files", root .. "/db"
    vim.fn.mkdir(root, "p")
    write(filelist, "Source/Test.cpp\n")
    local calls, result = 0, nil
    local ok, state = gtags.rebuild_async({
      root = root,
      filelist = filelist,
      db_dir = db,
      label = "test async GTAGS",
      first_executable = function() return "gtags" end,
      system = function(_, _, on_exit)
        calls = calls + 1
        vim.fn.mkdir(db, "p")
        for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do write(db .. "/" .. name) end
        on_exit({ code = 0, stdout = "", stderr = "" })
        return { kill = function() end, is_closing = function() return false end }
      end,
    }, function(done, message)
      result = { done, message }
    end)
    t.assert_true(ok)
    t.assert_eq(state, "running")
    vim.wait(100, function() return result ~= nil end)
    t.assert_eq(calls, 1)
    t.assert_true(result and result[1], tostring(result and result[2]))
    t.assert_false(gtags.is_running())
    vim.fn.delete(root, "rf")
  end)
end)

t.describe("host discipline: user foreground is never deferred", function()
  t.it("terminal runner marks successful termopen through exit", function()
    local text = source("lua/ue.lua")
    local terminal_at = assert(text:find("local function open_terminal_command", 1, true))
    local next_section = assert(text:find("PICKER INTEGRATION", terminal_at, true))
    local body = text:sub(terminal_at, next_section)
    local spawn_at = assert(body:find("vim.fn.termopen", 1, true))
    local begin_at = assert(body:find("foreground_begin", 1, true))
    t.assert_true(spawn_at < begin_at, "spawn 成功后才登记，失败不得泄漏 token")
    t.assert_match(body, "foreground_done")
  end)

  t.it("generic target runner 接受 metadata 或 workflow 显式 foreground", function()
    t.assert_true(admission.is_foreground_operation("install"))
    t.assert_true(admission.is_foreground_operation("so_deploy"))
    t.assert_true(admission.is_foreground_operation("package"))
    t.assert_false(admission.is_foreground_operation("clangd-version-preflight"))
    local text = source("lua/ue/target_tasks.lua")
    t.assert_match(text, "is_foreground_operation%(operation%)")
    t.assert_match(text, "opts%.foreground")
    t.assert_match(text, "foreground_begin")
    t.assert_match(text, "foreground_done")
    t.assert_match(source("lua/ue/workflows/ios/install.lua"), "foreground = true")
  end)

  t.it("Android bespoke install 的 success/failure 都释放 foreground token", function()
    local text = source("lua/ue/workflows/android/install.lua")
    local begin_at = assert(text:find("foreground_begin", 1, true))
    local spawn_at = assert(text:find("pcall(d.jobstart", begin_at, true))
    t.assert_true(begin_at < spawn_at, "同步 fake/启动失败也必须有可释放 token")
    local done_count = select(2, text:gsub("foreground_done", ""))
    t.assert_true(done_count >= 2, "on_exit 与 spawn failure 均须释放")
  end)
end)
