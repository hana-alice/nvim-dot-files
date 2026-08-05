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
  t.it("candidates 不存在 root 返回 table", function()
    local c = paths.candidates({ engine_root = "/nonexistent_xyz_12345" }, {})
    t.assert_type(c, "table")
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
    local captured
    local starts = 0
    local second_result
    pipeline.set_runtime({
      jobstart = function(_, _, opts)
        starts = starts + 1
        captured = opts
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

    captured.on_exit(23, 0, "exit")
    t.assert_false(pipeline.is_running(), "成功完成后应释放 writer 锁")
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

  t.it("同步入口检查 writer slot 并传播 pipeline 启动结果", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    t.assert_contains(source, 'if pipeline.is_running() then\n    return false, "compile_commands pipeline is already running"')
    t.assert_contains(source, 'local jobid, pipeline_err = run_compile_commands_pipeline(path, targets)')
    t.assert_contains(source, 'local pipeline_jobid, pipeline_err = run_compile_commands_pipeline(targets[1], targets)')
    t.assert_contains(source, 'return false, nil, pipeline_err or "compile_commands pipeline failed to start"')
  end)
end)
