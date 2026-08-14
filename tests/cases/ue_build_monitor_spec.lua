local t = require("tests.harness")
t.bootstrap()

local monitor = require("ue.build_monitor")

local PS_FIXTURE = table.concat({
  "  101     1 S    00:12   0.0  0.1 /bin/zsh /Engine/Build.sh SampleGame IOS Development",
  "  102   101 S    00:11   0.4  0.2 /usr/bin/mono UnrealBuildTool.exe SampleGame IOS",
  "  103   102 R    00:08  99.7  1.5 /Toolchain/usr/bin/clang -cc1as /tmp/SampleGame.Generated.dll.s",
  "  104   999 R    00:03  88.0  0.4 /usr/bin/unrelated input.cpp",
}, "\n")

t.describe("ue.build_monitor: process snapshot", function()
  t.it("parses macOS ps rows without losing the command", function()
    local rows = monitor.parse_snapshot(PS_FIXTURE)
    t.assert_eq(#rows, 4)
    t.assert_eq(rows[3].pid, 103)
    t.assert_eq(rows[3].ppid, 102)
    t.assert_eq(rows[3].state, "R")
    t.assert_eq(rows[3].cpu, 99.7)
    t.assert_contains(rows[3].command, "SampleGame.Generated.dll.s")
  end)

  t.it("summarizes only descendants of the build root", function()
    local summary = monitor.summarize(monitor.parse_snapshot(PS_FIXTURE), 101)
    t.assert_eq(summary.process_count, 3)
    t.assert_eq(summary.active.pid, 103)
    t.assert_eq(summary.active.tool, "clang")
    t.assert_eq(summary.active.item, "SampleGame.Generated.dll.s")
    t.assert_true(summary.total_cpu > 100 and summary.total_cpu < 101)
  end)

  t.it("formats a compact heartbeat for the build terminal", function()
    local summary = monitor.summarize(monitor.parse_snapshot(PS_FIXTURE), 101)
    local lines = monitor.format_lines(summary, 78, {
      { time = "12:00:00", label = "mono-aot-cross · SampleGame.Generated.dll" },
    })
    t.assert_eq(#lines, 2)
    t.assert_contains(lines[1], "[UE stage]")
    t.assert_contains(lines[2], "[UE heartbeat]")
    t.assert_contains(lines[2], "clang")
    t.assert_contains(lines[2], "SampleGame.Generated.dll.s")
    t.assert_contains(lines[2], "01:18")
  end)
end)

t.describe("ue.build_monitor: terminal lifecycle", function()
  t.it("is owned by the existing UE terminal runner", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue.lua"
    local source = table.concat(vim.fn.readfile(path), "\n")
    t.assert_contains(source, 'require("ue.build_monitor").start({')
    t.assert_contains(source, "jobid = active_jobid")
    t.assert_contains(source, "bufnr = buf")
    t.assert_contains(source, "build_monitor:stop()")
  end)

  t.it("renders into the supplied terminal buffer and clears on stop", function()
    local buf = vim.api.nvim_create_buf(false, true)
    local rendered = {}
    local timer = { stopped = false, closed = false }
    function timer:start(_, _, callback)
      self.callback = callback
    end
    function timer:stop()
      self.stopped = true
    end
    function timer:close()
      self.closed = true
    end

    local handle = monitor.start({
      bufnr = buf,
      jobid = 7,
      root_pid = 101,
      driver = {
        build_process_snapshot_plan = function()
          return { executable = "/bin/ps", args = { "fixture" } }
        end,
      },
      new_timer = function()
        return timer
      end,
      schedule = function(fn)
        fn()
      end,
      is_job_running = function()
        return true
      end,
      run = function(_, _, callback)
        callback({ code = 0, stdout = PS_FIXTURE, stderr = "" })
        return {}
      end,
      render = function(target_buf, lines)
        rendered[#rendered + 1] = { bufnr = target_buf, lines = vim.deepcopy(lines) }
      end,
      now = function()
        return 100
      end,
    })

    t.assert_true(handle ~= nil)
    t.assert_eq(rendered[1].bufnr, buf)
    t.assert_contains(rendered[1].lines[1], "Inspecting")
    timer.callback()
    t.assert_eq(rendered[#rendered].bufnr, buf)
    t.assert_contains(rendered[#rendered].lines[1], "[UE heartbeat]")
    t.assert_contains(rendered[#rendered].lines[1], "clang")

    handle:stop()
    t.assert_true(timer.stopped)
    t.assert_true(timer.closed)
    t.assert_eq(#rendered[#rendered].lines, 0)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  t.it("uses virtual lines without changing terminal contents", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "real build output" })
    monitor._render_virtual_lines(buf, { "[UE heartbeat] clang" })

    t.assert_eq(vim.api.nvim_buf_get_lines(buf, 0, -1, false)[1], "real build output")
    local marks = vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })
    t.assert_eq(#marks, 1)
    t.assert_type(marks[1][4].virt_lines, "table")
    t.assert_contains(marks[1][4].virt_lines[1][1][1], "clang")

    monitor._render_virtual_lines(buf, {})
    t.assert_eq(#vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, {}), 0)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  t.it("stays disabled when the host driver lacks the capability", function()
    local handle = monitor.start({
      bufnr = vim.api.nvim_get_current_buf(),
      jobid = 7,
      root_pid = 101,
      driver = {},
    })
    t.assert_eq(handle, nil)
  end)
end)
