local t = require("tests.harness")
t.bootstrap()

local runtime = require("ue.workflows._runtime")
local workflows = require("ue.workflows")

local function make_snapshot(live)
  return workflows.snapshot({
    operation = "install",
    owner = "ios.install",
    project = { canonical = live.project },
    target = { id = live.target },
    configuration = live.configuration,
    host = { id = live.host },
    device = { id = live.device },
    signing = { fingerprint = live.signing },
    runtime = { bundle_id = live.bundle_id },
    context = { serial = live.device },
  })
end

local function progress_probe(records)
  return function(opts)
    records[#records + 1] = { event = "start", message = opts.message, scope = opts.scope }
    return {
      report = function(_, message, percentage)
        records[#records + 1] = { event = "report", message = message, percentage = percentage }
      end,
      finish = function(_, message, percentage, level)
        records[#records + 1] = {
          event = "finish",
          message = message,
          percentage = percentage,
          level = level,
        }
      end,
    }
  end
end

t.describe("ue.workflows snapshot", function()
  t.it("captures immutable operation identity without rereading live selection", function()
    local live = {
      project = "/Project/Sample.uproject",
      target = "IOS",
      configuration = "Development",
      host = "macos",
      device = "device-1",
      signing = "SHA1-AAA",
      bundle_id = "com.example.initial",
    }

    local snapshot = make_snapshot(live)
    live.project = "/Project/Other.uproject"
    live.device = "device-2"
    live.signing = "SHA1-BBB"
    live.bundle_id = "com.example.changed"

    t.assert_eq(snapshot.project.canonical, "/Project/Sample.uproject")
    t.assert_eq(snapshot.target.id, "IOS")
    t.assert_eq(snapshot.device.id, "device-1")
    t.assert_eq(snapshot.signing.fingerprint, "SHA1-AAA")
    t.assert_eq(snapshot.runtime.bundle_id, "com.example.initial")
    t.assert_eq(snapshot.owner, "ios.install")
    t.assert_false(pcall(function()
      snapshot.device.id = "device-3"
    end))
  end)
end)

t.describe("ue.workflows android owners", function()
  t.it("discovers zero, one, and multiple APK artifacts deterministically", function()
    local install = require("ue.workflows.android.install")
    local ctx = { uproject = "/Project/Sample.uproject" }
    local matches = {}
    local mtimes = {}
    local function discover()
      return install._find_apks_for_test(ctx, {
        glob = function(pattern)
          return matches[pattern] or {}
        end,
        getftime = function(path)
          return mtimes[path] or 0
        end,
      })
    end

    t.assert_eq(#discover(), 0)

    local primary = "/Project/Binaries/Android/Sample.apk"
    matches["/Project/Binaries/Android/*.apk"] = { primary }
    mtimes[primary] = 10
    t.assert_eq(table.concat(discover(), ","), primary)

    local newer = "/Project/Intermediate/Android/arm64/gradle/app/build/outputs/apk/New.apk"
    matches["/Project/Intermediate/Android/*/gradle/app/build/outputs/apk/*.apk"] = { primary, newer }
    mtimes[newer] = 20
    t.assert_eq(table.concat(discover(), ","), newer .. "," .. primary)
  end)

  t.it("fails Android build preflight before starting a build when Gradle cleanup fails", function()
    local build = require("ue.workflows.android.build")
    local stopped = 0
    local result, err, snapshot = build.run({
      target_id = "Android",
      operation = "build",
      host_driver = { id = "windows" },
      payload = {
        context = {
          engine_root = "/UE",
          project_root = "/Project",
          uproject = "/Project/Sample.uproject",
        },
        configuration = "Development",
      },
      deps = {
        stop_debugger = function()
          stopped = stopped + 1
          return {}
        end,
        join = function(...)
          return table.concat({ ... }, "/")
        end,
        glob = function()
          return { "/Project/stale.apk" }
        end,
        delete = function()
          return false
        end,
      },
    })

    t.assert_nil(result)
    t.assert_contains(err, "Failed to clean stale Gradle artifacts")
    t.assert_eq(stopped, 1)
    t.assert_eq(snapshot.project.canonical, "/Project")
    t.assert_eq(snapshot.configuration, "Development")
  end)

  t.it("skips Gradle cleanup for SO-only builds while retaining debugger cleanup", function()
    local build = require("ue.workflows.android.build")
    local glob_calls = 0
    local result, err = build.run({
      target_id = "Android",
      operation = "so_build",
      host_driver = { id = "windows" },
      payload = { context = { engine_root = "/UE", project_root = "/Project" } },
      deps = {
        stop_debugger = function()
          return { disconnected = true }
        end,
        glob = function()
          glob_calls = glob_calls + 1
          return {}
        end,
        notify = function() end,
      },
    })

    t.assert_eq(err, nil)
    t.assert_true(result.ok)
    t.assert_eq(glob_calls, 0)
  end)

  t.it("android install owner captures the selected serial before building the plan", function()
    local install = require("ue.workflows.android.install")
    local seen = {}
    local history = {}
    local finish_calls = 0
    local handle = {
      finish = function()
        finish_calls = finish_calls + 1
      end,
    }
    local timer = {
      start = function() end,
      stop = function() end,
      close = function() end,
    }

    local jobid, err, snapshot = install.run({
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          return {
            engine_root = "/UE",
            project_root = "/Project",
            uproject = "/Project/Sample.uproject",
          }
        end,
        android_device = {
          get = function()
            return "SERIAL-1"
          end,
        },
        find_apk = function()
          return "/Project/Binaries/Android/Sample.apk"
        end,
        resolve_tool = function()
          return { ok = true, path = "adb" }
        end,
        targets = {
          resolve = function()
            return { id = "Android" }
          end,
          plan = function(_, _, payload)
            seen.device_id = payload.device_id
            seen.apk = payload.apk
            return { metadata = { artifact = payload.apk } }
          end,
        },
        target_tasks = {
          command = function()
            return { "adb", "install" }
          end,
        },
        progress = {
          handle = {
            create = function(payload)
              handle.title = payload.title
              handle.message = payload.message
              return handle
            end,
          },
        },
        notification_history = {
          record = function(payload)
            history[#history + 1] = payload
          end,
        },
        task_registry = {
          register = function(payload)
            seen.task = payload.name
          end,
        },
        jobstart = function(cmd, opts)
          seen.cmd = table.concat(cmd, " ")
          opts.on_stdout(nil, {})
          opts.on_stderr(nil, {})
          opts.on_exit(nil, 0)
          return 41
        end,
        schedule = function(fn)
          fn()
        end,
        schedule_wrap = function(fn)
          return fn
        end,
        defer_fn = function(fn)
          fn()
        end,
        new_timer = function()
          return timer
        end,
        now = function()
          return 120
        end,
      },
    })

    t.assert_eq(err, nil)
    t.assert_eq(jobid, 41)
    t.assert_eq(snapshot.device.serial, "SERIAL-1")
    t.assert_eq(snapshot.runtime.artifact, "/Project/Binaries/Android/Sample.apk")
    t.assert_eq(snapshot.runtime.adb, "adb")
    t.assert_eq(seen.device_id, "SERIAL-1")
    t.assert_eq(seen.apk, "/Project/Binaries/Android/Sample.apk")
    t.assert_eq(seen.task, "UEInstallAndroid")
    t.assert_true(seen.cmd:find("adb install", 1, true) ~= nil)
    t.assert_eq(finish_calls, 1)
    t.assert_contains(history[1].message, "Installing APK:")
    t.assert_contains(history[#history].message, "Installed successfully:")
    t.assert_eq(history[#history].scope, "ue.install")
  end)

  t.it("android install owner reports missing artifacts before device or job side effects", function()
    local install = require("ue.workflows.android.install")
    local side_effects = 0
    local result, err = install.run({
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          return { engine_root = "/UE", project_root = "/Project", uproject = "/Project/Sample.uproject" }
        end,
        find_apk = function()
          return nil
        end,
        android_device = {
          get = function()
            side_effects = side_effects + 1
            return "SERIAL-A"
          end,
        },
        targets = {
          resolve = function()
            return { id = "Android" }
          end,
        },
        progress = { handle = {} },
        logger = { error = function() end },
        notify_error = function() end,
        jobstart = function()
          side_effects = side_effects + 1
        end,
      },
    })

    t.assert_nil(result)
    t.assert_contains(err, "No APK found")
    t.assert_eq(side_effects, 0)
  end)

  t.it("android install owner reports task-start and async failures without rereading serial", function()
    local install = require("ue.workflows.android.install")
    local live_serial = "SERIAL-A"
    local function request(jobstart, errors, history)
      local handle = { finish = function() end }
      local timer = { start = function() end, stop = function() end, close = function() end }
      return {
        host_driver = { id = "windows" },
        context = {
          resolve_context = function()
            return { engine_root = "/UE", project_root = "/Project", uproject = "/Project/Sample.uproject" }
          end,
          android_device = {
            get = function()
              return live_serial
            end,
          },
          find_apk = function()
            return "/Project/Binaries/Android/Sample.apk"
          end,
          resolve_tool = function()
            return { ok = true, path = "adb" }
          end,
          targets = {
            resolve = function()
              return { id = "Android" }
            end,
            plan = function(_, _, payload)
              return { metadata = { artifact = payload.apk, serial = payload.device_id } }
            end,
          },
          target_tasks = {
            command = function()
              return { "adb", "install" }
            end,
          },
          progress = {
            handle = {
              create = function()
                return handle
              end,
            },
          },
          notification_history = {
            record = function(payload)
              history[#history + 1] = payload
            end,
          },
          logger = { error = function() end },
          notify_error = function(_, message)
            errors[#errors + 1] = message
          end,
          jobstart = jobstart,
          schedule = function(fn)
            fn()
          end,
          schedule_wrap = function(fn)
            return fn
          end,
          defer_fn = function(fn)
            fn()
          end,
          new_timer = function()
            return timer
          end,
          now = function()
            return 120
          end,
        },
      }
    end

    local start_errors, start_history = {}, {}
    local started, start_err, start_snapshot = install.run(request(function()
      return 0
    end, start_errors, start_history))
    t.assert_nil(started)
    t.assert_contains(start_err, "Failed to start adb install job")
    t.assert_eq(start_snapshot.device.serial, "SERIAL-A")
    t.assert_contains(start_errors[1], "Failed to start adb install job")

    local async_errors, async_history = {}, {}
    local jobid, async_err, snapshot = install.run(request(function(_, opts)
      live_serial = "SERIAL-B"
      opts.on_stderr(nil, { "Failure [INSTALL_FAILED_VERSION_DOWNGRADE]" })
      opts.on_exit(nil, 7)
      return 61
    end, async_errors, async_history))
    t.assert_eq(async_err, nil)
    t.assert_eq(jobid, 61)
    t.assert_eq(snapshot.device.serial, "SERIAL-A")
    t.assert_eq(#async_errors, 0)
    t.assert_eq(async_history[#async_history].level, vim.log.levels.ERROR)
    t.assert_contains(async_history[#async_history].message, "exit 7")
    t.assert_contains(async_history[#async_history].message, "SERIAL-A")
    t.assert_contains(async_history[#async_history].message, "See :NvimLog")
  end)

  t.it("android deploy owner keeps device selection outside the command plan until a serial exists", function()
    local deploy = require("ue.workflows.android.deploy")
    local reinvoked = 0
    local ensured = 0

    local result, err = deploy.run({
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          return { engine_root = "/UE", project_root = "/Project", uproject = "/Project/Sample.uproject" }
        end,
        android_device = {
          get = function()
            return nil
          end,
          ensure = function(_, cb)
            ensured = ensured + 1
            cb(true)
          end,
        },
        read_state = function()
          return { android_package = "com.example.game" }
        end,
        target_context = function()
          return { project_dir = "/Project" }
        end,
        open_terminal_command = function()
          error("should not open terminal before serial is chosen")
        end,
        workspace_root = function()
          return "/Project"
        end,
        reinvoke = function()
          reinvoked = reinvoked + 1
        end,
      },
    })

    t.assert_nil(result)
    t.assert_eq(err, "device-selection-pending")
    t.assert_eq(ensured, 1)
    t.assert_eq(reinvoked, 1)
  end)

  t.it("android deploy owner consumes one structured plan with a frozen serial and package", function()
    local deploy = require("ue.workflows.android.deploy")
    local live = { serial = "SERIAL-A", package_name = "com.example.initial" }
    local planned = {}
    local opened
    local command, err, snapshot = deploy.run({
      target_id = "Android",
      operation = "so_deploy",
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          return { engine_root = "/UE", project_root = "/Project", uproject = "/Project/Sample.uproject" }
        end,
        android_device = {
          get = function()
            return live.serial
          end,
        },
        read_state = function()
          return { android_package = live.package_name }
        end,
        target_context = function()
          return { project_dir = "/Project", target = "Sample", configuration = "Test" }
        end,
        targets = {
          plan = function(_, operation, payload)
            planned.operation = operation
            planned.serial = payload.device_id
            planned.package_name = payload.package_name
            return { executable = "powershell", args = { "deploy" }, cwd = "/UE" }
          end,
        },
        target_tasks = {
          command = function(plan)
            return { plan.executable, plan.args[1] }
          end,
        },
        stop_android_debugger = function()
          planned.stopped = true
        end,
        open_terminal_command = function(cmd)
          live.serial = "SERIAL-B"
          live.package_name = "com.example.changed"
          opened = table.concat(cmd, " ")
        end,
        workspace_root = function()
          return "/Project"
        end,
      },
    })

    t.assert_eq(err, nil)
    t.assert_eq(table.concat(command, " "), "powershell deploy")
    t.assert_eq(opened, "powershell deploy")
    t.assert_eq(planned.operation, "so_deploy")
    t.assert_eq(planned.serial, "SERIAL-A")
    t.assert_eq(planned.package_name, "com.example.initial")
    t.assert_true(planned.stopped)
    t.assert_eq(snapshot.device.serial, "SERIAL-A")
    t.assert_eq(snapshot.runtime.package_name, "com.example.initial")
    t.assert_eq(snapshot.configuration, "Test")
  end)

  t.it("android deploy owner fails before debugger cleanup or device mutation when planning fails", function()
    local deploy = require("ue.workflows.android.deploy")
    local side_effects = 0
    local result, err = deploy.run({
      target_id = "Android",
      operation = "so_deploy",
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          return { engine_root = "/UE", project_root = "/Project" }
        end,
        android_device = {
          get = function()
            return "SERIAL-A"
          end,
        },
        read_state = function()
          return { android_package = "com.example.game" }
        end,
        target_context = function()
          return { project_dir = "/Project" }
        end,
        targets = {
          plan = function()
            return { status = "unavailable", reason = "source SO missing" }
          end,
        },
        target_tasks = {
          command = function()
            return nil, "source SO missing"
          end,
        },
        stop_android_debugger = function()
          side_effects = side_effects + 1
        end,
        open_terminal_command = function()
          side_effects = side_effects + 1
        end,
        notify_error = function() end,
      },
    })

    t.assert_nil(result)
    t.assert_contains(err, "source SO missing")
    t.assert_eq(side_effects, 0)
  end)

  t.it("android launch owner keeps callbacks pinned to the captured serial and package", function()
    local launch = require("ue.workflows.android.launch")
    local live = { serial = "SERIAL-A", package_name = "com.example.initial" }
    local planned = {}
    local notifications = {}
    local jobid, err, snapshot = launch.run({
      target_id = "Android",
      operation = "launch",
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          return { engine_root = "/UE", project_root = "/Project" }
        end,
        read_state = function()
          return { android_package = live.package_name }
        end,
        android_device = {
          get = function()
            return live.serial
          end,
        },
        resolve_tool = function()
          return { ok = true, path = "adb" }
        end,
        targets = {
          plan = function(_, operation, payload)
            planned.operation = operation
            planned.serial = payload.device_id
            planned.package_name = payload.package_name
            return { executable = "powershell", args = { "launch" } }
          end,
        },
        target_tasks = {
          command = function(plan)
            return { plan.executable, plan.args[1] }
          end,
        },
        jobstart = function(_, opts)
          live.serial = "SERIAL-B"
          live.package_name = "com.example.changed"
          opts.on_stdout(nil, { "started", "" })
          opts.on_exit(nil, 0)
          return 51
        end,
        schedule = function(fn)
          fn()
        end,
        task_registry = {
          register = function(payload)
            planned.task = payload.name
          end,
        },
        notify = function(_, message)
          notifications[#notifications + 1] = message
        end,
        notify_error = function(_, message)
          notifications[#notifications + 1] = message
        end,
      },
    })

    t.assert_eq(err, nil)
    t.assert_eq(jobid, 51)
    t.assert_eq(planned.operation, "launch")
    t.assert_eq(planned.serial, "SERIAL-A")
    t.assert_eq(planned.package_name, "com.example.initial")
    t.assert_eq(snapshot.device.serial, "SERIAL-A")
    t.assert_eq(snapshot.runtime.package_name, "com.example.initial")
    t.assert_contains(notifications[1], "com.example.initial on SERIAL-A")
    t.assert_contains(planned.task, "com.example.initial")
  end)

  t.it("android launch owner reports task-start and async failures", function()
    local launch = require("ue.workflows.android.launch")
    local function request(jobstart, errors)
      return {
        target_id = "Android",
        operation = "launch",
        host_driver = { id = "windows" },
        context = {
          resolve_context = function()
            return { engine_root = "/UE", project_root = "/Project" }
          end,
          read_state = function()
            return { android_package = "com.example.game" }
          end,
          android_device = {
            get = function()
              return "SERIAL-A"
            end,
          },
          resolve_tool = function()
            return { ok = true, path = "adb" }
          end,
          targets = {
            plan = function()
              return { executable = "powershell", args = { "launch" } }
            end,
          },
          target_tasks = {
            command = function()
              return { "powershell", "launch" }
            end,
          },
          jobstart = jobstart,
          schedule = function(fn)
            fn()
          end,
          notify = function() end,
          notify_error = function(_, message)
            errors[#errors + 1] = message
          end,
        },
      }
    end

    local start_errors = {}
    local started, start_err = launch.run(request(function()
      return 0
    end, start_errors))
    t.assert_nil(started)
    t.assert_contains(start_err, "Failed to start Android launch job")
    t.assert_contains(start_errors[1], "Failed to start Android launch job")

    local async_errors = {}
    local jobid, async_err = launch.run(request(function(_, opts)
      opts.on_stderr(nil, { "staging corrupt" })
      opts.on_exit(nil, 9)
      return 52
    end, async_errors))
    t.assert_eq(async_err, nil)
    t.assert_eq(jobid, 52)
    t.assert_contains(async_errors[1], "exit 9")
    t.assert_contains(async_errors[1], "staging corrupt")
  end)

  t.it("android log owner owns device selection and reinvokes with the captured request", function()
    local ensured = 0
    local reinvoked = 0
    local spec, err = require("ue.workflows.android.log").run({
      payload = {
        env = {
          trim = function(value)
            return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
          end,
          is_file = function()
            return true
          end,
        },
        context = { state = { android_package = "com.example.game" } },
        android_device = {
          adb_executable = function()
            return "/fake/adb"
          end,
          get = function()
            return nil
          end,
          ensure = function(opts, callback)
            ensured = ensured + 1
            t.assert_contains(opts.prompt, "UE logcat")
            callback("SERIAL-A")
          end,
        },
        reinvoke = function()
          reinvoked = reinvoked + 1
        end,
      },
    })

    t.assert_nil(spec)
    t.assert_nil(err)
    t.assert_eq(ensured, 1)
    t.assert_eq(reinvoked, 1)
  end)
end)

t.describe("ue.workflows runtime", function()
  t.it("keeps callback, poller, cleanup, and persistence pinned to the frozen snapshot", function()
    local live = {
      project = "/Project/Sample.uproject",
      target = "IOS",
      configuration = "Development",
      host = "macos",
      device = "device-1",
      signing = "SHA1-AAA",
      bundle_id = "com.example.initial",
    }
    local active_project = live.project
    local observed = {
      persisted = {},
      cleanup = {},
      callbacks = {},
      polls = {},
    }
    local progress = {}
    local exit_callback
    local session = runtime.start({
      title = "UE Install",
      scope = "ue.workflow.test",
      snapshot = make_snapshot(live),
      progress_factory = progress_probe(progress),
      state = {
        current_project = function()
          return active_project
        end,
        persist = function(event, snapshot)
          observed.persisted[#observed.persisted + 1] = {
            event = event,
            project = snapshot.project.canonical,
            device = snapshot.device.id,
            bundle_id = snapshot.runtime.bundle_id,
          }
        end,
      },
      poller = function(snapshot, payload)
        observed.polls[#observed.polls + 1] = {
          payload = payload,
          project = snapshot.project.canonical,
          device = snapshot.device.id,
        }
      end,
      cleanup = function(snapshot, reason)
        observed.cleanup[#observed.cleanup + 1] = {
          reason = reason,
          device = snapshot.device.id,
          bundle_id = snapshot.runtime.bundle_id,
        }
      end,
      on_failure = function(snapshot)
        observed.callbacks[#observed.callbacks + 1] = {
          project = snapshot.project.canonical,
          device = snapshot.device.id,
        }
      end,
      runner = {
        progress = progress_probe(progress),
        error_message = function(result)
          return ("exit=%d: %s"):format(result.code, result.stderr)
        end,
        run = function(_, opts)
          exit_callback = opts.on_exit
          return { kill = function() end }
        end,
      },
      tasks = {
        {
          id = "install",
          message = "Installing",
          plan = { executable = "/tool", args = { "install" } },
        },
      },
    })

    live.project = "/Project/Other.uproject"
    live.device = "device-2"
    live.bundle_id = "com.example.changed"
    session:poll("heartbeat")
    live.project = "/Project/Sample.uproject"
    exit_callback({ code = 9, stderr = "install failed" })

    t.assert_eq(observed.polls[1].payload, "heartbeat")
    t.assert_eq(observed.polls[1].project, "/Project/Sample.uproject")
    t.assert_eq(observed.polls[1].device, "device-1")
    t.assert_eq(observed.callbacks[1].project, "/Project/Sample.uproject")
    t.assert_eq(observed.callbacks[1].device, "device-1")
    t.assert_eq(observed.cleanup[1].reason, "task-failed")
    t.assert_eq(observed.cleanup[1].device, "device-1")
    t.assert_eq(observed.cleanup[1].bundle_id, "com.example.initial")
    t.assert_eq(observed.persisted[1].event, "started")
    t.assert_eq(observed.persisted[#observed.persisted].device, "device-1")
    t.assert_eq(progress[#progress].event, "finish")
  end)

  local cases = {
    {
      name = "completes successful tasks and finalizes progress",
      mode = "success",
      expected_status = "success",
      expected_events = { "started", "task_started", "task_succeeded", "completed" },
      expected_cleanup = 0,
      expect_kill = false,
      flip_project = false,
    },
    {
      name = "fails closed when the task cannot start",
      mode = "start_failure",
      expected_status = "failed",
      expected_events = { "started", "task_started", "task_start_failed", "failed" },
      expected_cleanup = 1,
      expect_kill = false,
      flip_project = false,
    },
    {
      name = "fails on async task errors",
      mode = "async_failure",
      expected_status = "failed",
      expected_events = { "started", "task_started", "task_failed", "failed" },
      expected_cleanup = 1,
      expect_kill = false,
      flip_project = false,
    },
    {
      name = "cancels the running handle and runs cleanup once",
      mode = "cancel",
      expected_status = "cancelled",
      expected_events = { "started", "task_started", "cancel_requested", "cancelled" },
      expected_cleanup = 1,
      expect_kill = true,
      flip_project = false,
    },
    {
      name = "aborts completion when the active project changes",
      mode = "project_change",
      expected_status = "failed",
      expected_events = { "started", "task_started", "project_changed", "failed" },
      expected_cleanup = 1,
      expect_kill = false,
      flip_project = true,
    },
  }

  for _, case in ipairs(cases) do
    t.it(case.name, function()
      local live_project = "/Project/Sample.uproject"
      local persisted = {}
      local cleanup = 0
      local progress = {}
      local kill_calls = 0
      local exit_callback
      local session = runtime.start({
        title = "UE Workflow",
        scope = "ue.workflow.runtime",
        snapshot = workflows.snapshot({
          operation = "build",
          owner = "ios.build",
          project = { canonical = live_project },
          target = { id = "IOS" },
          configuration = "Development",
          host = { id = "macos" },
        }),
        state = {
          current_project = function()
            return live_project
          end,
          persist = function(event)
            persisted[#persisted + 1] = event
          end,
        },
        cleanup = function()
          cleanup = cleanup + 1
        end,
        progress_factory = progress_probe(progress),
        runner = {
          progress = progress_probe(progress),
          error_message = function(result)
            return ("exit=%d: %s"):format(result.code, result.stderr or "")
          end,
          run = function(_, opts)
            if case.mode == "start_failure" then
              return nil, "spawn rejected"
            end
            exit_callback = opts.on_exit
            return {
              kill = function()
                kill_calls = kill_calls + 1
              end,
            }
          end,
        },
        tasks = {
          {
            id = "build",
            message = "Building",
            plan = { executable = "/tool", args = { "build" } },
          },
        },
      })

      if case.mode == "cancel" then
        session:cancel("user-requested")
      elseif case.mode == "async_failure" then
        exit_callback({ code = 7, stderr = "boom" })
      elseif case.mode == "success" then
        exit_callback({ code = 0, stderr = "" })
      elseif case.flip_project then
        live_project = "/Project/Other.uproject"
        exit_callback({ code = 0, stderr = "" })
      end

      t.assert_eq(session.status, case.expected_status)
      t.assert_eq(cleanup, case.expected_cleanup)
      t.assert_eq(table.concat(persisted, ","), table.concat(case.expected_events, ","))
      t.assert_eq(kill_calls > 0, case.expect_kill)
      t.assert_eq(progress[#progress].event, "finish")
    end)
  end
end)

t.describe("ue.workflows registry", function()
  t.it("dispatches only exact target-operation owners after target compatibility resolves", function()
    workflows._reset_for_test()
    local seen
    workflows.register("IOS", "build", {
      owner = "ios.build",
      run = function(request)
        seen = request
        return "ok"
      end,
    })

    local result, err = workflows.dispatch("IOS", "build", {
      host_driver = { id = "macos" },
      snapshot = workflows.snapshot({
        operation = "build",
        owner = "ios.build",
        project = { canonical = "/Project/Sample.uproject" },
        target = { id = "IOS" },
        configuration = "Development",
        host = { id = "macos" },
      }),
    })

    t.assert_eq(err, nil)
    t.assert_eq(result, "ok")
    t.assert_eq(seen.driver.id, "IOS")
    t.assert_eq(seen.operation, "build")
    t.assert_eq(seen.owner, "ios.build")
  end)

  t.it("fails closed for unsupported host-target combinations before owner lookup", function()
    workflows._reset_for_test()
    local called = 0
    workflows.register("Android", "build", {
      owner = "android.build",
      run = function()
        called = called + 1
      end,
    })

    local result, err = workflows.dispatch("Android", "build", {
      host_driver = { id = "macos" },
    })

    t.assert_nil(result)
    t.assert_eq(called, 0)
    t.assert_eq(err.status, "unavailable")
    t.assert_eq(err.reason, "unsupported host-target operation")
  end)

  t.it("does not fall back across targets when an exact owner is missing", function()
    workflows._reset_for_test()
    workflows.register("Mac", "build", {
      owner = "mac.build",
      run = function()
        return "wrong"
      end,
    })

    local result, err = workflows.dispatch("IOS", "build", {
      host_driver = { id = "macos" },
    })

    t.assert_nil(result)
    t.assert_eq(err.status, "unavailable")
    t.assert_eq(err.reason, "workflow owner missing")
  end)

  t.it("invokes compatibility seams through the matrix-filtered owner registry", function()
    workflows._reset_for_test()
    workflows.register("IOS", "build", {
      owner = "ios.build",
      run = function() end,
      api = {
        echo = function(value)
          return "owner:" .. value
        end,
      },
    })

    local result, err = workflows.invoke("IOS", "build", "echo", { "captured" }, { id = "macos" })
    t.assert_eq(err, nil)
    t.assert_eq(result, "owner:captured")

    local unavailable, unavailable_err = workflows.invoke("IOS", "build", "echo", { "wrong-host" }, { id = "windows" })
    t.assert_nil(unavailable)
    t.assert_eq(unavailable_err.status, "unavailable")
    t.assert_eq(unavailable_err.reason, "unsupported host-target operation")
  end)

  t.it("keeps target literals out of the generic registry implementation", function()
    local source = table.concat(vim.fn.readfile("lua/ue/workflows/init.lua"), "\n")
    for _, literal in ipairs({ "Android", "IOS", "Mac", "Win64", "Linux" }) do
      t.assert_false(source:find(literal, 1, true) ~= nil, literal .. " should not appear in generic registry")
    end
  end)
end)
