local t = require("tests.harness")
t.bootstrap()

t.describe("distributed build context", function()
  t.it("resolves persistent machine config after module reload without inherited variables", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ '{"script":"/tools/build_android.py","worker_config":"/tools/config.json","python":"python3"}' }, path)
    package.loaded["ue.workflows.android.distributed"] = nil
    local module = require("ue.workflows.android.distributed")
    local result, err = module.resolve_config({ path = path, globals = {}, env = {} })
    vim.fn.writefile({ '{"script":"/new/build_android.py"}' }, path)
    local changed = module.resolve_config({ path = path, globals = {}, env = {} })
    vim.fn.delete(path)
    t.assert_nil(err)
    t.assert_eq(result.script, "/tools/build_android.py")
    t.assert_eq(result.worker_config, "/tools/config.json")
    t.assert_eq(result.python, "python3")
    t.assert_eq(changed.script, "/new/build_android.py")
    t.assert_eq(changed.python, "python")
  end)

  t.it("nonempty globals override environment which overrides local JSON", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ '{"script":"/local.py","worker_config":"/local.json","python":"local-python"}' }, path)
    local result = require("ue.workflows.android.distributed").resolve_config({
      path = path,
      globals = { ue_builddispatch_script = "/global.py", ue_builddispatch_worker_config = "", ue_builddispatch_python = " " },
      env = { NVIM_UE_BUILDDISPATCH = "/env.py", NVIM_UE_BUILDDISPATCH_CONFIG = "/env.json", NVIM_UE_BUILDDISPATCH_PYTHON = "" },
    })
    vim.fn.delete(path)
    t.assert_eq(result.script, "/global.py")
    t.assert_eq(result.worker_config, "/env.json")
    t.assert_eq(result.python, "local-python")
  end)

  t.it("rejects malformed and nonobject config while allowing a missing file", function()
    local path = vim.fn.tempname()
    local module = require("ue.workflows.android.distributed")
    for _, content in ipairs({ "{broken", "[]", "null", '{"script":3}' }) do
      vim.fn.writefile({ content }, path)
      local result, err = module.resolve_config({ path = path, globals = {}, env = {} })
      t.assert_nil(result)
      t.assert_contains(err, "Invalid BuildDispatch config")
    end
    -- No fallback is needed when every field is explicit.
    local explicit = module.resolve_config({ path = path, env = {}, globals = {
      ue_builddispatch_script = "/explicit.py", ue_builddispatch_worker_config = "/explicit.json", ue_builddispatch_python = "python",
    } })
    vim.fn.delete(path)
    local missing, err = module.resolve_config({ path = path, globals = {}, env = {} })
    t.assert_eq(explicit.script, "/explicit.py")
    t.assert_nil(err)
    t.assert_nil(missing.script)
    t.assert_eq(missing.python, "python")
  end)

  t.it("dry-run freezes stdin, follows the log tail and respects scroll-up with bounded history", function()
    local ue, tasks = require("ue"), require("ue.target_tasks")
    local saved_snapshot, saved_run, saved_progress = ue.build_snapshot, tasks.run, tasks.progress
    local saved_script = vim.g.ue_builddispatch_script
    local original_window = vim.api.nvim_get_current_win()
    local captured_plan, captured_opts
    local snapshot = { engine_root = "/engine", project_root = "/workspace", platform = "Android", configuration = "Development" }
    ue.build_snapshot = function() return snapshot end
    vim.g.ue_builddispatch_script = vim.fn.stdpath("config") .. "/tests/run.lua"
    tasks.progress = function() return { finish = function() end } end
    tasks.run = function(plan, opts)
      captured_plan, captured_opts = plan, opts
      return { kill = function() end }
    end
    local module = require("ue.workflows.android.distributed")
    local ok, handle = pcall(module.start, { dry_run = true })
    ue.build_snapshot, tasks.run, tasks.progress = saved_snapshot, saved_run, saved_progress
    vim.g.ue_builddispatch_script = saved_script
    if not ok then error(handle) end
    local log_window, buffer = vim.api.nvim_get_current_win(), module.last_buffer
    snapshot.configuration = "Shipping"
    captured_opts.on_stdout("one\ntwo\nthree\n")
    local followed = vim.api.nvim_win_get_cursor(log_window)[1] == vim.api.nvim_buf_line_count(buffer)
    vim.api.nvim_win_set_cursor(log_window, { 2, 0 })
    captured_opts.on_stdout("four\n")
    local respected_scroll = vim.api.nvim_win_get_cursor(log_window)[1] == 2
    vim.api.nvim_win_set_cursor(log_window, { vim.api.nvim_buf_line_count(buffer), 0 })
    local lines = {}
    for _ = 1, 5010 do lines[#lines + 1] = "compile progress" end
    captured_opts.on_stdout(table.concat(lines, "\n") .. "\n")
    local line_count = vim.api.nvim_buf_line_count(buffer)
    local followed_after_trim = vim.api.nvim_win_get_cursor(log_window)[1] == line_count
    captured_opts.on_exit({ code = 0, signal = 0 })
    vim.api.nvim_win_close(log_window, true)
    vim.api.nvim_set_current_win(original_window)
    vim.api.nvim_buf_delete(buffer, { force = true })
    t.assert_true(handle ~= nil)
    t.assert_contains(captured_plan.args, "--dry-run")
    t.assert_false(captured_opts.capture_output)
    t.assert_eq(vim.json.decode(captured_opts.stdin).configuration, "Development")
    t.assert_true(line_count <= 5000)
    t.assert_true(followed, "tail cursor should follow newly streamed lines")
    t.assert_true(respected_scroll, "reading older output must not jump to the tail")
    t.assert_true(followed_after_trim, "tail following should survive history trimming")
    t.assert_false(module.is_running())
  end)

  t.it("captures exact planner arguments, selected workspace and export flag without secrets", function()
    local ctx = { engine_root = "E:/Engine", project_root = "P:/Workspace", uproject = "P:/Workspace/Game/Game.uproject" }
    local command = { "cmd.exe", "/c", 'call "E:/Engine/Build.bat"', "Game", "Android", "Development", "-disable-sdk" }
    local function planner(operation, selected, platform)
      t.assert_eq(operation, "build")
      t.assert_eq(selected, ctx)
      t.assert_eq(platform, "Android")
      return command, nil, { executable = command[1], args = vim.list_slice(command, 2), cwd = "E:/Engine" }, {}, {
        target = "Game", platform = "Android", configuration = "Development", uproject = ctx.uproject,
      }
    end
    local result = require("ue.build_snapshot").capture({ platform = "Android" }, function() return ctx end, planner)
    t.assert_eq(result.project_root, "P:/Workspace")
    t.assert_eq(result.target, "Game")
    t.assert_true(vim.deep_equal(result.build_command, command))
    t.assert_eq(result.export_command[#result.export_command], "-WriteOutdatedActions=__BUILDDISPATCH_ACTIONS__")
    t.assert_eq(result.export_command[#result.export_command - 1], "-disable-sdk")
    t.assert_nil(result.environment.P4PASSWD)
    t.assert_nil(result.environment.P4TICKETS)
    command[4] = "Changed"
    t.assert_eq(result.build_command[4], "Game")
  end)

  t.it("configuration override replans without modifying current editor state", function()
    local selected = { configuration = "Development" }
    local result = require("ue.build_snapshot").capture({ configuration = "Shipping", host_driver = {} },
      function() return { engine_root = "/engine", project_root = "/workspace", state = selected } end,
      function()
        return { "/build", "Development" }, nil, {}, {
          build_plan = function(context)
            return { executable = "/build", args = { context.configuration } }
          end,
        }, { target = "Game", platform = "Android", configuration = selected.configuration, uproject = "/workspace/Game.uproject" }
      end)
    t.assert_eq(result.configuration, "Shipping")
    t.assert_eq(result.build_command[2], "Shipping")
    t.assert_eq(selected.configuration, "Development")
  end)

  t.it("propagates missing project and unavailable planner failures", function()
    local result, err = require("ue.build_snapshot").capture({}, function() return nil, "missing project" end)
    t.assert_nil(result)
    t.assert_eq(err, "missing project")
    result, err = require("ue.build_snapshot").capture({}, function() return {} end,
      function() return nil, "unsupported host" end)
    t.assert_nil(result)
    t.assert_eq(err, "unsupported host")
  end)

  t.it("passes stdin directly to the shared asynchronous task runner", function()
    local original = vim.system
    local input
    vim.system = function(_, opts)
      input = opts.stdin
      return { kill = function() end }
    end
    local ok, handle = pcall(require("ue.target_tasks").run, { executable = "python", args = {} }, {
      stdin = '{"project_root":"P:/Workspace"}', foreground = false,
    })
    vim.system = original
    t.assert_true(ok)
    t.assert_true(handle ~= nil)
    t.assert_eq(input, '{"project_root":"P:/Workspace"}')
  end)

  t.it("can stream executor logs without retaining a second unbounded copy", function()
    local original = vim.system
    local streamed, completed
    vim.system = function(_, opts, on_exit)
      opts.stdout(nil, "large output\n")
      on_exit({ code = 0, signal = 0 })
      return { kill = function() end }
    end
    local ok, err = pcall(require("ue.target_tasks").run, { executable = "python", args = {} }, {
      foreground = false, capture_output = false,
      on_stdout = function(data) streamed = data end,
      on_exit = function(result) completed = result end,
    })
    vim.system = original
    if not ok then error(err) end
    vim.wait(100, function() return completed ~= nil end)
    t.assert_eq(streamed, "large output\n")
    t.assert_eq(completed.stdout, "")
  end)
end)
