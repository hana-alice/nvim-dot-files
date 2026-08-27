local t = require("tests.harness")
t.bootstrap()

local tasks = require("ue.target_tasks")

t.describe("ue.target_tasks", function()
  t.it("converts a structured plan to argv without shell joining", function()
    local command, err = tasks.command({
      executable = "/Engine Root/Build.sh",
      args = { "Sample Game", "IOS", "Development", "-Project=/Project Root/Sample.uproject" },
    })

    t.assert_eq(err, nil)
    t.assert_eq(command[1], "/Engine Root/Build.sh")
    t.assert_eq(command[2], "Sample Game")
    t.assert_eq(command[5], "-Project=/Project Root/Sample.uproject")
  end)

  t.it("rejects structured unavailable and malformed plans", function()
    local unavailable, unavailable_err = tasks.command({
      status = "unavailable",
      reason = "host capability missing",
    })
    local malformed, malformed_err = tasks.command({ args = {} })

    t.assert_eq(unavailable, nil)
    t.assert_eq(unavailable_err, "host capability missing")
    t.assert_eq(malformed, nil)
    t.assert_eq(malformed_err, "target plan executable is missing")
  end)

  t.it("formats process failures using stderr before stdout", function()
    t.assert_contains(tasks.error_message({ code = 7, stdout = "fallback", stderr = "primary" }), "primary")
    t.assert_false(
      tasks.error_message({ code = 7, stdout = "fallback", stderr = "primary" }):find("fallback", 1, true) ~= nil
    )
  end)

  t.it("returns a start error instead of throwing when the executable cannot spawn", function()
    local original = vim.system
    vim.system = function()
      error("spawn rejected")
    end
    local ok, handle, err = pcall(tasks.run, {
      executable = "/missing/tool",
      args = { "--version" },
    })
    vim.system = original

    t.assert_true(ok)
    t.assert_eq(handle, nil)
    t.assert_contains(err, "spawn rejected")
  end)

  t.it("streams process output without losing the captured exit result", function()
    local original = vim.system
    local streamed = {}
    local completed
    vim.system = function(_, opts, on_exit)
      opts.stdout(nil, "stdout-one\n")
      opts.stdout(nil, "stdout-two\n")
      opts.stderr(nil, "stderr-one\n")
      on_exit({ code = 0, signal = 0 })
      return { kill = function() end }
    end

    local handle, err = tasks.run({ executable = "/tool", args = {} }, {
      on_stdout = function(chunk) streamed[#streamed + 1] = "out:" .. chunk end,
      on_stderr = function(chunk) streamed[#streamed + 1] = "err:" .. chunk end,
      on_exit = function(result) completed = result end,
    })
    vim.wait(100, function() return completed ~= nil end)
    vim.system = original

    t.assert_nil(err)
    t.assert_true(handle ~= nil)
    t.assert_eq(table.concat(streamed), "out:stdout-one\nout:stdout-two\nerr:stderr-one\n")
    t.assert_eq(completed.stdout, "stdout-one\nstdout-two\n")
    t.assert_eq(completed.stderr, "stderr-one\n")
  end)

  t.it("foreground operation marks its whole child lifetime without delaying spawn", function()
    local admission = require("utils.host_admission")
    admission._reset_for_test()
    local original = vim.system
    local exit_callback
    vim.system = function(_, _, on_exit)
      exit_callback = on_exit
      return { kill = function() end }
    end
    local handle = tasks.run({ executable = "/installer", args = {} }, {
      name = "install",
      foreground = true, -- workflow-owned classification; plan metadata may omit operation
    })
    t.assert_true(handle ~= nil)
    t.assert_true(admission.foreground_active(), "前台任务不得先等 CPU")
    exit_callback({ code = 0, signal = 0, stdout = "", stderr = "" })
    vim.wait(100, function() return not admission.foreground_active() end)
    vim.system = original
    t.assert_false(admission.foreground_active())
  end)

  t.it("exposes one reusable fidget progress controller for multi-stage target workflows", function()
    local saved = package.loaded["fidget.progress"]
    local reports = {}
    local finished = 0
    package.loaded["fidget.progress"] = {
      handle = {
        create = function(spec)
          reports[#reports + 1] = { message = spec.message, percentage = spec.percentage }
          return {
            report = function(_, update) reports[#reports + 1] = update end,
            finish = function() finished = finished + 1 end,
          }
        end,
      },
    }

    local progress = tasks.progress({ title = "UEInstall", message = "starting", percentage = 0 })
    progress:report("signing", 20)
    progress:finish("installed", 100)
    package.loaded["fidget.progress"] = saved

    t.assert_eq(reports[1].message, "starting")
    t.assert_eq(reports[2].message, "signing")
    t.assert_eq(reports[2].percentage, 20)
    t.assert_eq(reports[3].message, "installed")
    t.assert_eq(finished, 1)
  end)

  t.it("records user-triggered progress start and terminal state without history spam", function()
    local saved = package.loaded["fidget.progress"]
    local history = require("utils.notification_history")
    history._reset_for_test()
    package.loaded["fidget.progress"] = {
      handle = {
        create = function()
          return {
            report = function() end,
            finish = function() end,
          }
        end,
      },
    }

    local progress = tasks.progress({
      title = "IOS install",
      scope = "ue.install",
      message = "Validating signing and install inputs",
      percentage = 0,
    })
    progress:report("Checking SDK, signing identity, and private key", 8)
    progress:report("Starting container-preserving install", 15)
    progress:finish("Installed com.example.Game on device-1", 100)
    package.loaded["fidget.progress"] = saved

    local records = history.list()
    t.assert_eq(#records, 2)
    t.assert_eq(records[1].scope, "ue.install")
    t.assert_eq(records[1].message, "Installed com.example.Game on device-1")
    t.assert_eq(records[2].scope, "ue.install")
    t.assert_eq(records[2].message, "Validating signing and install inputs")
  end)
end)
