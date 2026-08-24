-- tests/cases/ue_cdb_spec.lua
-- ue.cdb 子模块契约：json / paths / shaders。
-- 迁移自 scripts/headless_smoke.lua 的对应断言。

local t = require("tests.harness")
t.bootstrap()

t.describe("ue.cdb.json", function()
  local json = require("ue.cdb.json")

  t.it("template_entry happy path", function()
    local e = json.template_entry({ { file = "x.cpp", arguments = { "clang++" } } })
    t.assert_eq(e.file, "x.cpp")
  end)
  t.it("program 来自 arguments", function()
    t.assert_eq(json.program({ arguments = { "clang++" } }), "clang++")
  end)
  t.it("program 来自 command", function()
    t.assert_eq(json.program({ command = '"clang.exe" -c x' }), "clang.exe")
  end)
  t.it("template_entry empty 返回 table", function()
    t.assert_type(json.template_entry({}), "table")
  end)
end)

t.describe("ue.cdb.paths", function()
  local paths = require("ue.cdb.paths")

  t.it("targets 形状正确", function()
    local tg = paths.targets({ engine_root = "/x" })
    t.assert_eq(#tg, 2)
    t.assert_eq(tg[1], "/x/compile_commands.json")
  end)

  t.it("project context writes only to its isolated active CDB", function()
    local tg = paths.targets({
      engine_root = "/x",
      paths = { active_cdb = "/x/.cache/nvim-ue/projects/game/cdb/active/Android/compile_commands.json" },
    })
    t.assert_eq(#tg, 1)
    t.assert_eq(tg[1], "/x/.cache/nvim-ue/projects/game/cdb/active/Android/compile_commands.json")
  end)
  t.it("candidates 不存在 root 返回 table", function()
    local c = paths.candidates({ engine_root = "/nonexistent_xyz_12345" }, {})
    t.assert_type(c, "table")
  end)

  t.it("候选只来自受控位置，不递归拾取 ThirdParty 测试夹具", function()
    local root = vim.fn.tempname() .. "-cdb-candidates"
    local fixture = root .. "/Engine/Source/ThirdParty/Fixture/tests/INPUTS/compile_commands.json"
    vim.fn.mkdir(vim.fs.dirname(fixture), "p")
    vim.fn.writefile({ "[]" }, fixture)

    local scanned = false
    local candidates = paths.candidates({ engine_root = root }, {
      first_executable = function() return "fd" end,
      run_lines = function()
        scanned = true
        return 0, { fixture }
      end,
    })

    vim.fn.delete(root, "rf")
    t.assert_false(scanned, "CDB 候选不得递归扫描任意嵌套 compile_commands.json")
    t.assert_eq(#candidates, 0)
  end)

  t.it("semantic source 按完整 tuple 隔离", function()
    local path = paths.semantic_source({
      engine_root = "/UE",
      paths = { cache = "/UE/.cache/nvim-ue" },
    }, {
      platform = "IOS",
      target = "Sample Client",
      configuration = "Development",
    })
    t.assert_eq(
      path,
      "/UE/.cache/nvim-ue/cdb/sources/IOS-Sample_Client-Development/compile_commands.json"
    )
  end)

  t.it("当前 tuple semantic source 优先于 canonical 镜像", function()
    local root = vim.fn.tempname() .. "-cdb-priority"
    local tuple = { platform = "IOS", target = "Game", configuration = "Development" }
    local ctx = { engine_root = root, paths = { cache = root .. "/.cache/nvim-ue" } }
    local semantic = paths.semantic_source(ctx, tuple)
    local canonical = root .. "/compile_commands.json"
    vim.fn.mkdir(vim.fs.dirname(semantic), "p")
    vim.fn.writefile({ "[]" }, semantic)
    vim.fn.writefile({ "[]" }, canonical)

    local candidates = paths.candidates(ctx, { tuple = tuple })
    vim.fn.delete(root, "rf")
    t.assert_eq(candidates[1], semantic)
    t.assert_eq(candidates[2], require("ue.core.fs").norm(canonical))
  end)
end)

t.describe("ue.cdb.source provenance", function()
  local source = require("ue.cdb.source")

  local ctx = {
    engine_root = "/UE",
    project_root = "/Project",
    uproject = "/Project/Game.uproject",
  }
  local tuple = {
    platform = "IOS",
    target = "Game",
    configuration = "Development",
  }
  local driver = {
    validate_semantic_cdb = function(entries)
      for _, entry in ipairs(entries) do
        local command = tostring(entry.command or "")
        if command:find("iPhoneOS.platform", 1, true) then
          return { ok = true, matched = 1 }
        end
      end
      return { ok = false, reason = "missing IOS compiler evidence" }
    end,
  }

  t.it("accepts owned entries with target-driver tuple evidence", function()
    local ok, info = source.validate_content(vim.json.encode({
      {
        file = "/UE/Engine/Source/Runtime/Apple/MetalRHI/Private/MetalBuffer.cpp",
        directory = "/UE/Engine/Source",
        command = "clang++ -isysroot /Xcode/iPhoneOS.platform/SDK -c MetalBuffer.cpp",
      },
    }), ctx, tuple, driver)

    t.assert_true(ok)
    t.assert_eq(info.entry_count, 1)
  end)

  t.it("rejects foreign fixtures before they can replace the canonical CDB", function()
    local ok, info = source.validate_content(vim.json.encode({
      {
        file = "/home/example/Projects/SampleGame/project.cpp",
        directory = "/home/example/Projects/SampleGame",
        command = "clang++ -c project.cpp",
      },
    }), ctx, tuple, driver)

    t.assert_false(ok)
    t.assert_contains(info.reason, "outside current engine/project roots")
  end)

  t.it("rejects owned but foreign-platform databases", function()
    local ok, info = source.validate_content(vim.json.encode({
      {
        file = "/UE/Engine/Source/Runtime/Core/Private/Core.cpp",
        directory = "/UE/Engine/Source",
        command = "clang++ -isysroot /Xcode/MacOSX.platform/SDK -c Core.cpp",
      },
    }), ctx, tuple, driver)

    t.assert_false(ok)
    t.assert_contains(info.reason, "missing IOS compiler evidence")
  end)

  t.it("publishes a validated pending source and skips identical rewrites", function()
    local root = vim.fn.tempname() .. "-semantic-publish"
    local local_ctx = {
      engine_root = root .. "/UE",
      project_root = root .. "/Project",
      uproject = root .. "/Project/Game.uproject",
    }
    local stable = root .. "/cache/compile_commands.json"
    local pending1 = root .. "/cache/pending-1.json"
    local pending2 = root .. "/cache/pending-2.json"
    local content = vim.json.encode({
      {
        file = local_ctx.engine_root .. "/Engine/Source/Runtime/Apple/MetalRHI/Private/MetalBuffer.cpp",
        directory = local_ctx.engine_root .. "/Engine/Source",
        command = "clang++ -isysroot /Xcode/iPhoneOS.platform/SDK -c MetalBuffer.cpp",
      },
    })
    vim.fn.mkdir(vim.fs.dirname(stable), "p")
    vim.fn.writefile({ content }, pending1)

    local ok_first, first = source.promote(pending1, stable, local_ctx, tuple, driver)
    t.assert_true(ok_first)
    t.assert_false(first.no_op)
    t.assert_eq(vim.fn.filereadable(stable), 1)

    vim.fn.writefile({ content }, pending2)
    local ok_second, second = source.promote(pending2, stable, local_ctx, tuple, driver)
    t.assert_true(ok_second)
    t.assert_true(second.no_op)
    t.assert_eq(vim.fn.filereadable(pending2), 0)
    vim.fn.delete(root, "rf")
  end)
end)

t.describe("ue.cdb.shaders", function()
  local shaders = require("ue.cdb.shaders")

  t.it("augment 空列表返回 '[]'", function()
    t.assert_eq(shaders.augment("[]", {}, {}), "[]")
  end)
  t.it("make_entry 形状正确", function()
    local e = shaders.make_entry("/s/x.usf",
      { directory = "/d", arguments = { "clang++" } }, { "/inc" })
    t.assert_eq(e.file, "/s/x.usf")
    t.assert_eq(e.directory, "/d")
    t.assert_eq(e.arguments[1], "clang++")
    t.assert_eq(e.arguments[2], "-x")
  end)
end)

t.describe("ue.cdb.shards active selection", function()
  local shards = require("ue.cdb.shards")

  local function manifest(active)
    return {
      active = active,
      shards = {
        ["Android-Main-Development"] = {
          platform = "Android", target = "Main", config = "Development",
          mtime = 100, entry_count = 16000,
        },
        ["Android-Hot-Development"] = {
          platform = "Android", target = "Hot", config = "Development",
          mtime = 101, entry_count = 1,
        },
        ["Win64-Game-Development"] = {
          platform = "Win64", target = "Game", config = "Development",
          mtime = 300,
        },
        ["Win64-GameEditor-Development"] = {
          platform = "Win64", target = "GameEditor", config = "Development",
          mtime = 200,
        },
      },
    }
  end

  t.it("matching manifest.active beats a newer sibling target", function()
    local key = shards.active_key({
      state = { target_platform = "Android", target_configuration = "Development" },
    }, manifest("Android-Main-Development"))
    t.assert_eq(key, "Android-Main-Development")
  end)

  t.it("Editor suffix selects the editor build class when active platform differs", function()
    local key = shards.active_key({
      state = { target_platform = "Win64", target_configuration = "Development Editor" },
    }, manifest("Android-Main-Development"))
    t.assert_eq(key, "Win64-GameEditor-Development")
  end)

  t.it("explicit target_name selects that target instead of mtime", function()
    local key = shards.active_key({
      state = {
        target_platform = "Android",
        target_configuration = "Development",
        target = "",
        target_name = "Main",
      },
    }, manifest("Win64-Game-Development"))
    t.assert_eq(key, "Android-Main-Development")
  end)
end)

t.describe("ue.cdb.pipeline lifecycle", function()
  local pipeline = require("ue.cdb.pipeline")

  local function temp_cdb()
    local path = vim.fn.tempname():gsub("\\", "/") .. ".json"
    local f = assert(io.open(path, "wb"))
    f:write("[]")
    f:close()
    return path
  end

  t.it("失败也结束 running 状态并回调 false", function()
    local path = temp_cdb()
    local result
    pipeline.set_runtime({
      jobstart = function(_, _, opts)
        opts.on_fail(1, { "boom" }, path .. ".log")
        return 17
      end,
      notify = function() end,
      log_error = function() end,
    })

    pipeline.run(path, { path }, function(ok) result = ok end)
    t.assert_false(result, "pipeline 失败必须显式回调 false")
    t.assert_false(pipeline.is_running(), "失败后不得永久占用 pipeline 锁")
    pcall(os.remove, path)
  end)

  t.it("运行中拒绝第二个 writer，完成后释放", function()
    local path = temp_cdb()
    local captured = {}
    local starts = 0
    local second_result
    pipeline.set_runtime({
      jobstart = function(_, _, opts)
        starts = starts + 1
        captured[#captured + 1] = opts
        return 23
      end,
      notify = function() end,
      log_error = function() end,
    })

    pipeline.run(path, { path }, function() end)
    t.assert_true(pipeline.is_running(), "首个 pipeline 启动后应占用 writer 锁")
    local second_jobid, second_err = pipeline.run(path, { path }, function(ok) second_result = ok end)
    t.assert_eq(starts, 1, "运行中第二次调用不得启动新 writer")
    t.assert_false(second_result, "被拒调用应显式回调 false")
    t.assert_eq(second_jobid, nil, "被拒调用不得返回伪 jobid")
    t.assert_contains(tostring(second_err), "already running")

    local index = 1
    while pipeline.is_running() do
      local callback = captured[index]
      t.assert_true(callback ~= nil, "each pipeline step must expose an exit callback")
      callback.on_exit(23, 0, "exit")
      index = index + 1
    end
    t.assert_false(pipeline.is_running(), "成功完成后应释放 writer 锁")
    pcall(os.remove, path)
  end)

  t.it("source 已替换时即使 pipeline 无改写也强制重启 clangd", function()
    local path = temp_cdb()
    local callbacks = {}
    local restarts = 0
    pipeline.set_runtime({
      jobstart = function(_, _, opts)
        callbacks[#callbacks + 1] = opts
        return 29
      end,
      notify = function() end,
      log_error = function() end,
      restart_clangd = function() restarts = restarts + 1 end,
    })

    pipeline.run(path, { path }, function() end, { force_restart = true })
    local index = 1
    while pipeline.is_running() do
      callbacks[index].on_exit(29, 0, "exit")
      index = index + 1
    end

    t.assert_eq(restarts, 1)
    pcall(os.remove, path)
  end)


  t.it("每个 CDB phase 使用 argv 顺序执行，不拼接 host shell 字符串", function()
    local path = temp_cdb()
    local commands = {}
    local callbacks = {}
    pipeline.set_runtime({
      jobstart = function(command, _, opts)
        commands[#commands + 1] = command
        callbacks[#callbacks + 1] = opts
        return 31
      end,
      notify = function() end,
      log_error = function() end,
    })

    pipeline.run(path, { path }, function() end)
    local index = 1
    while pipeline.is_running() do
      local callback = callbacks[index]
      t.assert_true(callback ~= nil)
      callback.on_exit(31, 0, "exit")
      index = index + 1
    end

    t.assert_true(#commands > 0)
    for _, command in ipairs(commands) do
      t.assert_type(command, "table")
      t.assert_false(table.concat(command, " "):find(" && ", 1, true) ~= nil)
    end
    if require("utils.platform").is_mac then
      for _, command in ipairs(commands) do
        t.assert_false(table.concat(command, " "):find("prebuild_pch_v2.py", 1, true) ~= nil)
      end
    end
    pcall(os.remove, path)
  end)

  t.it("jobstart 启动失败返回错误且释放 writer", function()
    local path = temp_cdb()
    local result
    pipeline.set_runtime({
      jobstart = function() return -1 end,
      notify = function() end,
      log_error = function() end,
    })

    local jobid, err = pipeline.run(path, { path }, function(ok) result = ok end)
    t.assert_eq(jobid, nil)
    t.assert_contains(tostring(err), "failed to start")
    t.assert_false(result, "启动失败必须显式回调 false")
    t.assert_false(pipeline.is_running(), "启动失败后不得永久占用 writer 锁")
    pcall(os.remove, path)
  end)

  t.it("跨进程 writer lease 存在时不启动 pipeline", function()
    local path = temp_cdb()
    local lock = require("ue.file_lock")
    local lease = assert(lock.acquire(path .. ".writer.lock"))
    local starts, result = 0, nil
    pipeline.set_runtime({
      jobstart = function() starts = starts + 1; return 31 end,
      notify = function() end,
      log_error = function() end,
    })
    local jobid, err = pipeline.run(path, { path }, function(ok) result = ok end)
    t.assert_eq(jobid, nil)
    t.assert_eq(starts, 0, "live foreign lease must reject before spawn")
    t.assert_false(result)
    t.assert_contains(tostring(err), "another Neovim")
    t.assert_false(pipeline.is_running())
    lock.release(lease)
    pcall(os.remove, path)
  end)

  t.it("同步入口检查 writer slot 并传播 pipeline 启动结果", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    t.assert_contains(source, 'if pipeline.is_running() then\n    return false, "compile_commands pipeline is already running"')
    t.assert_contains(source, 'local jobid, pipeline_err = run_compile_commands_pipeline(path, targets, on_pipeline_done, {')
    t.assert_contains(source, 'force_restart = ctx._force_cdb_restart == true')
    t.assert_contains(source, 'local pipeline_jobid, pipeline_err = run_compile_commands_pipeline(targets[1], targets, function()')
    t.assert_contains(source, 'return false, nil, pipeline_err or "compile_commands pipeline failed to start"')
  end)

  t.it("每步 python 带 -u 无缓冲、独立 step tag（实时日志可归因）", function()
    local path = temp_cdb()
    local calls = {}
    pipeline.set_runtime({
      jobstart = function(cmd, tag, opts)
        table.insert(calls, { cmd = cmd, tag = tag, opts = opts })
        -- Complete each step immediately so the chain drains and the writer
        -- slot is released for later cases.
        vim.schedule(function() end)
        opts.on_exit(0, {}, tag .. ".log")
        return 40 + #calls
      end,
      notify = function() end,
      log_error = function() end,
    })
    pipeline.run(path, { path }, function() end)
    t.assert_true(#calls >= 1, "至少应启动一个 step job")
    for _, call in ipairs(calls) do
      t.assert_type(call.cmd, "table")
      -- Every python step must run unbuffered, otherwise a long step logs
      -- nothing until exit (looks like a hang).
      t.assert_eq(call.cmd[2], "-u", "python 必须带 -u 取消 stdout 缓冲: " .. call.tag)
      -- Per-step tag names the script → the log dir/failure message point at
      -- the actual culprit step.
      t.assert_true(call.tag:find("^ue%-pipeline%-") ~= nil, "step tag 必须带步骤名: " .. call.tag)
      if call.tag:find("prune_include_dirs", 1, true) then
        t.assert_eq(call.cmd[3], "-I", "prune 需同时保留 -I 隔离与 -u")
      end
    end
    t.assert_false(pipeline.is_running())
    pcall(os.remove, path)
  end)

  t.it("启动成功后注册进 task_registry（:Tasks 可停）", function()
    local path = temp_cdb()
    local tr = require("utils.task_registry")
    tr._reset_for_test()
    tr._set_probe_for_test(function() return "running" end)
    local pending = {}
    pipeline.set_runtime({
      jobstart = function(_, _, opts)
        table.insert(pending, opts)
        return 60 + #pending
      end,
      notify = function() end,
      log_error = function() end,
    })
    pipeline.run(path, { path }, function() end)
    t.assert_true(pipeline.is_running())
    local rows = tr.list()
    local found = false
    for _, row in ipairs(rows) do
      if tostring(row.name):find("cdb pipeline", 1, true) and row.group == "ue" then
        found = true
      end
    end
    t.assert_true(found, "pipeline 任务必须出现在 :Tasks 列表")
    -- Drain the sequential step chain: each on_exit starts the next step and
    -- appends its opts to `pending`.
    local i = 0
    while i < #pending do
      i = i + 1
      pending[i].on_exit(0, {}, "step.log")
    end
    t.assert_false(pipeline.is_running(), "全部 step 完成后应释放 writer 锁")
    tr._set_probe_for_test(nil)
    tr._reset_for_test()
    pcall(os.remove, path)
  end)

  t.it("cancel 停掉在飞 pipeline 并经 on_fail 释放 writer（build WAW 互斥）", function()
    local path = temp_cdb()
    local pending = {}
    local result
    pipeline.set_runtime({
      jobstart = function(_, _, opts)
        table.insert(pending, opts)
        return 80 + #pending
      end,
      notify = function() end,
      log_error = function() end,
    })
    pipeline.run(path, { path }, function(ok) result = ok end)
    t.assert_true(pipeline.is_running())
    t.assert_true(#pending >= 1, "pipeline 应已启动首个 step")
    t.assert_true(pipeline.cancel("test build started"), "在飞时 cancel 应返回 true")
    -- jobstop drives the real runner's on_exit; simulate the kill exit of the
    -- CURRENT (last-started) step here.
    pending[#pending].on_fail(143, { "killed" }, path .. ".log")
    t.assert_false(pipeline.is_running(), "cancel 后经 on_fail 必须释放 writer 锁")
    t.assert_false(result, "被 cancel 的 pipeline 必须回调 false")
    t.assert_false(pipeline.cancel("idle"), "无在飞任务时 cancel 应返回 false")
    pcall(os.remove, path)
  end)

  t.it("build ⇄ prepare 互斥入口存在（源断言）", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    -- UEBuild entry cancels the in-flight pipeline (build wins the WAW).
    t.assert_contains(source, 'require("ue.cdb.pipeline").cancel(title')
    -- prepare_async refuses to start while the build terminal job is alive.
    t.assert_contains(source, "if CORE_RT.ue_build_running() then")
    t.assert_contains(source, "function CORE_RT.ue_build_running()")
  end)

  t.it("_logged_jobstart 边跑边落盘（可 tail）并返回 log_path", function()
    local ue = require("ue")
    -- argv-list form bypasses vim.o.shell entirely (the harness may run under
    -- bash while shellcmdflag is still cmd-style). Child = nvim -l printing
    -- two lines: portable on every machine that can run this suite.
    local child = vim.fn.tempname() .. ".lua"
    do
      local f = assert(io.open(child, "w"))
      f:write('print("live-line-1")\nprint("live-line-2")\n')
      f:close()
    end
    local script = { vim.v.progpath, "--clean", "--headless", "-l", child }
    local finished = false
    local log_path_seen
    local jobid, log_path = ue._logged_jobstart(script, "ue-pipeline-test", {
      on_exit = function(_, _, lp)
        finished = true
        log_path_seen = lp
      end,
    })
    t.assert_true(type(jobid) == "number" and jobid > 0, "jobstart 应返回有效 jobid")
    t.assert_type(log_path, "string")
    vim.wait(5000, function() return finished end, 50)
    t.assert_true(finished, "测试 job 应在 5s 内退出")
    t.assert_eq(log_path_seen, log_path)
    local content = table.concat(vim.fn.readfile(log_path), "\n")
    t.assert_contains(content, "live-line-1")
    t.assert_contains(content, "live-line-2")
    t.assert_contains(content, "# exit: 0")
    pcall(os.remove, log_path)
    pcall(os.remove, child)
  end)
end)
