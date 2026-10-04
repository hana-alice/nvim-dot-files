local t = require("tests.harness")
local cfg = t.bootstrap()
local iterate = require("ue.workflows.android.iterate")
local runtime = require("ue.workflows._runtime")

local function loop_steps()
  local callbacks, seen, states = {}, {}, {}
  local steps = {
    set_status = function(value)
      states[#states + 1] = value
    end,
  }
  for _, stage in ipairs({ "build_so", "deploy_so", "launch" }) do
    steps[stage] = function(done, snapshot)
      callbacks[stage], seen[stage] = done, snapshot
      return {
        cancel = function()
          callbacks.cancelled = stage
        end,
      }
    end
  end
  steps.debug_launch = function(done, snapshot, on_stage)
    callbacks.debug, callbacks.on_stage, seen.debug = done, on_stage, snapshot
    return {
      cancel = function()
        callbacks.cancelled = "debug"
      end,
    }
  end
  return steps, callbacks, seen, states
end

local function frozen()
  return runtime.snapshot({
    operation = "iterate",
    owner = "android.iterate",
    project = "/Project/A",
    target = "Android",
    configuration = "Test",
    host = { id = "windows" },
    device = { serial = "SERIAL-A" },
    runtime = { package_name = "com.example.a" },
    context = { engine_root = "/Engine/A", project_root = "/Project/A", target = "SampleGame" },
  })
end

t.describe("ide_workflow: truthful Android loop", function()
  t.it(
    "ready context is captured once and later live project, target and device changes stay outside the run",
    function()
      local live = {
        engine_root = "/Engine/A",
        project_root = "/Project/A",
        uproject = "/Project/A/Sample.uproject",
        state = { android_package = "com.example.a" },
      }
      local target = { target = "SampleGame", configuration = "Test", project_root = live.project_root }
      local reads, device_reads, target_reads, snapshot = 0, 0, 0, nil
      iterate.capture({
        resolve_context = function()
          reads = reads + 1
          return live
        end,
        target_context = function(ctx, platform)
          target_reads = target_reads + 1
          t.assert_eq(platform, "Android")
          t.assert_eq(ctx.project_root, "/Project/A")
          return target
        end,
        host_driver = { id = "windows" },
        android_device = {
          get = function()
            device_reads = device_reads + 1
            return "SERIAL-A"
          end,
        },
      }, function(value, err)
        t.assert_nil(err)
        snapshot = value
      end)
      live.project_root, live.state.android_package, target.configuration = "/Project/B", "com.example.b", "Shipping"
      t.assert_eq(reads, 1)
      t.assert_eq(device_reads, 1)
      t.assert_eq(target_reads, 1)
      t.assert_eq(snapshot.context.project_root, "/Project/A")
      t.assert_eq(snapshot.target_context.configuration, "Test")
      t.assert_eq(snapshot.runtime.package_name, "com.example.a")
      t.assert_eq(snapshot.device.serial, "SERIAL-A")
    end
  )

  t.it("cancelling pending selection never starts build after the picker returns", function()
    local steps, callbacks = loop_steps()
    local selected
    steps.resolve_context = function()
      return { engine_root = "/Engine", project_root = "/Project" }
    end
    steps.target_context = function()
      error("must not reach target planning")
    end
    steps.android_device = {
      get = function()
        return nil
      end,
      ensure = function(_, done)
        selected = done
      end,
    }
    local run = iterate.run(steps, { notify = function() end })
    t.assert_eq(run.status, "preparing")
    run:cancel()
    selected("SERIAL-A")
    t.assert_eq(run.status, "cancelled")
    t.assert_nil(callbacks.build_so)
  end)

  t.it("package selection uses the configured adb and rejects a lying state write", function()
    local ctx = { engine_root = "/Engine", project_root = "/Project", state = {} }
    local snapshot, reason
    iterate.capture({
      resolve_context = function()
        return ctx
      end,
      target_context = function()
        error("must not plan after failed package readback")
      end,
      read_state = function()
        return {}
      end,
      update_state_field = function()
        return true
      end,
      android_device = {
        get = function()
          return "SERIAL-A"
        end,
        adb_executable = function()
          return "configured-adb"
        end,
      },
      pick_package = function(opts, done)
        t.assert_eq(opts.adb, "configured-adb")
        done("com.example.chosen")
      end,
    }, function(value, err)
      snapshot, reason = value, err
    end)
    t.assert_nil(snapshot)
    t.assert_contains(reason, "read-back mismatch")
  end)

  t.it("success waits for launch and attach response, and stages share one immutable snapshot", function()
    local steps, callbacks, seen, states = loop_steps()
    local snapshot = frozen()
    local run = iterate.run(steps, { snapshot = snapshot, notify = function() end })
    callbacks.build_so(0, { "build output" })
    callbacks.deploy_so(0, { "deploy output" })
    t.assert_false(table.concat(states):find("LOOP✓", 1, true) ~= nil, "request alone is not success")
    t.assert_eq(run.status, "running")
    t.assert_eq(seen.build_so, snapshot)
    t.assert_eq(seen.deploy_so, snapshot)
    t.assert_eq(seen.debug, snapshot)
    callbacks.on_stage("attach")
    t.assert_eq(run.stage, "attach")
    callbacks.debug(0, { response_succeeded = true })
    t.assert_eq(run.status, "success")
    t.assert_contains(states[#states], "LOOP✓")
    t.assert_eq(run.results.build_so.code, 0)
    t.assert_eq(run.results.deploy_so.output[1], "deploy output")
    t.assert_eq(run.results.attach.code, 0)
    t.assert_true(run.results.attach.output.response_succeeded)
    t.assert_error(function()
      run.snapshot.device.serial = "SERIAL-B"
    end)
  end)

  t.it("a failing or rejected stage ends the run and never starts the next stage", function()
    for _, stage in ipairs({ "build_so", "deploy_so", "debug" }) do
      for _, code in ipairs({ 6, -1 }) do
        local steps, callbacks = loop_steps()
        local run = iterate.run(steps, { snapshot = frozen(), notify = function() end })
        if stage ~= "build_so" then
          callbacks.build_so(0)
        end
        if stage == "debug" then
          callbacks.deploy_so(0)
        end
        if stage == "debug" then
          callbacks.on_stage("attach")
        end
        callbacks[stage](code, "stage rejected")
        t.assert_eq(run.status, "failed", stage .. " exit " .. code)
        if stage == "build_so" then
          t.assert_nil(callbacks.deploy_so)
        end
        if stage == "deploy_so" then
          t.assert_nil(callbacks.debug)
        end
      end
    end
  end)

  t.it("plain launch also waits for the actual job exit", function()
    local steps, callbacks, _, states = loop_steps()
    local run = iterate.run(steps, { snapshot = frozen(), nodebug = true, notify = function() end })
    callbacks.build_so(0)
    callbacks.deploy_so(0)
    t.assert_eq(run.status, "running")
    t.assert_false(table.concat(states):find("LOOP✓", 1, true) ~= nil)
    callbacks.launch(6, { "launch failed" })
    t.assert_eq(run.status, "failed")
    t.assert_eq(run.results.launch.code, 6)
  end)

  t.it("cancel at every stage closes running and late callbacks cannot start more work", function()
    for _, stage in ipairs({ "build_so", "deploy_so", "debug" }) do
      local steps, callbacks, _, states = loop_steps()
      local run = iterate.run(steps, { snapshot = frozen(), notify = function() end })
      if stage ~= "build_so" then
        callbacks.build_so(0)
      end
      if stage == "debug" then
        callbacks.deploy_so(0)
      end
      run:cancel()
      t.assert_eq(run.status, "cancelled")
      t.assert_eq(callbacks.cancelled, stage)
      local count = #states
      callbacks[stage](0)
      t.assert_eq(#states, count)
      if stage == "build_so" then
        t.assert_nil(callbacks.deploy_so)
      end
      if stage == "deploy_so" then
        t.assert_nil(callbacks.debug)
      end
    end
  end)

  t.it("new run ownership prevents stale callbacks from rewriting current results", function()
    local steps, old, _, states = loop_steps()
    local first = iterate.run(steps, { snapshot = frozen(), notify = function() end })
    local late = old.build_so
    first:cancel()
    local second = iterate.run(steps, { snapshot = frozen(), notify = function() end })
    local count = #states
    late(0)
    t.assert_true(first.id ~= second.id)
    t.assert_eq(second.stage, "build_so")
    t.assert_eq(#states, count)
    second:cancel()
  end)

  t.it("stage exceptions and never-started returns are explicit failures", function()
    for _, action in ipairs({
      function()
        error("owner failed")
      end,
      function()
        return nil, "rejected"
      end,
    }) do
      local steps = loop_steps()
      steps.build_so = action
      local run = iterate.run(steps, { snapshot = frozen(), notify = function() end })
      t.assert_eq(run.status, "failed")
      t.assert_eq(run.results.build_so.code, -1)
    end
  end)

  t.it("deployment reuse is shown only for an actual successful owner hash marker", function()
    local marker = "[UE SO deploy] unchanged (sha256=" .. string.rep("a", 64) .. ") — skipped"
    t.assert_true(iterate.deploy_skipped({ marker }))
    t.assert_false(iterate.deploy_skipped({ "unchanged — skipped", marker:gsub("a+", "a") }))
    for _, code in ipairs({ 0, 6 }) do
      local steps, callbacks = loop_steps()
      local run = iterate.run(steps, { snapshot = frozen(), notify = function() end, nodebug = true })
      callbacks.build_so(0)
      callbacks.deploy_so(code, { marker })
      t.assert_eq(run.results.deploy_so.skipped, code == 0)
      if code == 0 then
        callbacks.launch(0)
      end
      t.assert_eq(iterate.last(), run)
    end
  end)
end)

-- Native external UI input verifies insert mode, asynchronous exit ordering
-- and the actual production terminal/diagnostic wiring without a live UE build.
local ui_driver = [=[
import json
import os
from pathlib import Path
import queue
import runpy
import subprocess
import sys
import threading
import time

root, directory, executable = sys.argv[1:]
directory = Path(directory)
helper = runpy.run_path(str(Path(root) / 'tools' / 'measure_inlay_hints.py'))

class Session(helper['Nvim']):
    def call(self, method, *arguments):
        self.sequence += 1
        identifier = self.sequence
        self.process.stdin.write(helper['pack']([0, identifier, method, arguments]))
        self.process.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            self.consume(message)
            if isinstance(message, list) and message[:2] == [1, identifier]:
                if message[2]: raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)

environment = os.environ.copy()
for key in ('XDG_CONFIG_HOME', 'XDG_DATA_HOME', 'XDG_STATE_HOME', 'XDG_CACHE_HOME'):
    environment[key] = str(directory / key.lower())
instance = Session(executable, environment, directory / 'nvim.stderr.log')
def expire():
    instance.process.kill()
    instance.process.wait(timeout=3)
watchdog = threading.Timer(15, expire)
watchdog.daemon = True
watchdog.start()
try:
    instance.call('nvim_ui_attach', 120, 30, {'rgb': True, 'ext_linegrid': True})
    instance.lua(r'''
        local root, directory = ...
        vim.opt.rtp:prepend(root)
        vim.o.swapfile, vim.o.shada, vim.o.hidden = false, '', true
        vim.env.NVIM_UE_PROBE_PATH = directory .. '/ue_probes.json'
        vim.env.NVIM_UE_LOG_DIR = directory .. '/logs'
        vim.notify = function() end
        local function upvalue(fn, wanted)
          for i = 1, 255 do
            local name, value = debug.getupvalue(fn, i)
            if not name then break end
            if name == wanted then return value end
          end
          error('missing production upvalue ' .. wanted)
        end
        local ue = require('ue')
        _G.test_open = upvalue(upvalue(ue.setup, 'build_target'), 'open_terminal_command')
        _G.test_buf, _G.test_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
        _G.test_file = directory .. '/Source.cpp'
        vim.api.nvim_buf_set_name(_G.test_buf, _G.test_file)
        local lines = {}
        for i = 1, 40 do lines[i] = 'source line ' .. i end
        vim.api.nvim_buf_set_lines(_G.test_buf, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(_G.test_win, {12, 3})
        _G.test_completed = false
    ''', root, str(directory))
    instance.call('nvim_input', 'i')
    before = instance.lua('return {mode=vim.fn.mode(1), cursor=vim.api.nvim_win_get_cursor(0)}')
    assert before['mode'].startswith('i'), before
    instance.lua(r'''
        local command = { vim.v.progpath, '--headless', '-u', 'NONE', '-i', 'NONE',
          '-c', ('lua vim.wait(120); io.stdout:write(%q)'):format(
            _G.test_file .. ':2:1: error: controlled source failure\n'
            .. _G.test_file .. ':5:1: warning: retained warning\n'), '-c', 'cquit 6' }
        _G.test_job = _G.test_open(command, { quickfix_title = 'Native UI build failure',
          quickfix_root = ..., on_exit = function(code) _G.test_exit = code; _G.test_completed = true end })
        assert(_G.test_job and _G.test_job > 0)
        assert(vim.api.nvim_get_current_win() == _G.test_win, 'build took focus')
        assert(vim.fn.mode(1):sub(1,1) == 'i', 'build changed insert mode')
    ''', str(directory))
    deadline = time.monotonic() + 5
    while not instance.lua('return _G.test_completed'):
        if time.monotonic() >= deadline: raise TimeoutError('native build completion')
        time.sleep(0.02)
    state = instance.lua(r'''
        assert(vim.api.nvim_get_current_win() == _G.test_win, 'failure took focus')
        assert(vim.api.nvim_get_current_buf() == _G.test_buf, 'failure replaced source')
        assert(vim.fn.mode(1):sub(1,1) == 'i', 'failure changed insert mode')
        assert(vim.bo[_G.test_buf].modified, 'dirty source was lost')
        local cursor = vim.api.nvim_win_get_cursor(_G.test_win)
        assert(cursor[1] == 12 and cursor[2] == 3, vim.inspect(cursor))
        local items = vim.fn.getqflist()
        assert(#items == 2 and items[1].type == 'E' and items[2].type == 'W', vim.inspect(items))
        return {mode=vim.fn.mode(1), cursor=cursor, exit=_G.test_exit, problems=#items}
    ''')
    assert state['exit'] == 6, state
    instance.call('nvim_input', '<Esc>')
    normal_origin = instance.lua('return vim.api.nvim_win_get_cursor(0)')
    instance.lua("assert(require('ue.build_diagnostics').jump_first()); assert(vim.api.nvim_win_get_cursor(0)[1] == 2)")
    instance.call('nvim_input', '<C-o>')
    returned = instance.lua('return vim.api.nvim_win_get_cursor(0)')
    assert returned == normal_origin, {'returned': returned, 'normal_origin': normal_origin}
    instance.lua("local panel=require('utils.bottom_panel'); local win=panel.show('build'); assert(vim.api.nvim_get_current_win()==win)")
    print('IDE_WORKFLOW_UI_OK ' + json.dumps(state), flush=True)
finally:
    watchdog.cancel()
    if instance.process.poll() is None: instance.process.terminate()
    try: instance.process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        instance.process.kill()
        instance.process.wait(timeout=3)
    for stream in (instance.process.stdin, instance.process.stdout): stream.close()
    instance.log.close()
]=]

t.describe("ide_workflow: native external UI", function()
  t.it("insert-mode build failure keeps focus/cursor/dirty state and one Ctrl-O returns from first error", function()
    local directory = vim.fn.tempname() .. "-ide-workflow-ui"
    vim.fn.mkdir(directory, "p")
    local result
    local ok, err = pcall(function()
      local script = directory .. "/driver.py"
      vim.fn.writefile(vim.split(ui_driver, "\n", { plain = true }), script)
      result = vim
        .system(
          { "python", "-I", "-B", script, cfg, directory, vim.v.progpath },
          { text = true, env = { PYTHONIOENCODING = "utf-8" } }
        )
        :wait(20000)
    end)
    local output = result and ((result.stdout or "") .. (result.stderr or "")) or tostring(err)
    if vim.fn.filereadable(directory .. "/nvim.stderr.log") == 1 then
      output = output .. table.concat(vim.fn.readfile(directory .. "/nvim.stderr.log"), "\n")
    end
    vim.fn.delete(directory, "rf")
    t.assert_true(ok, output)
    t.assert_eq(result.code, 0, output)
    t.assert_contains(result.stdout, "IDE_WORKFLOW_UI_OK", output)
  end)
end)

t.describe("ide_workflow: frozen step owners", function()
  local function owner_snapshot()
    local raw = runtime.unwrap(frozen())
    raw.target_context = {
      target = "SampleGame",
      configuration = "Test",
      project_root = "/Project/A",
      project_dir = "/Project/A",
      uproject = "/Project/A/SampleGame.uproject",
      engine_root = "/Engine/A",
    }
    return runtime.snapshot(raw)
  end

  t.it("deploy never resolves a later live project, target or device after the loop froze", function()
    local done, plan_ctx
    local job, err, snapshot = require("ue.workflows.android.deploy").run({
      snapshot = owner_snapshot(),
      host_driver = { id = "windows" },
      context = {
        return_handle = true,
        resolve_context = function()
          error("live context must not be consulted")
        end,
        read_state = function()
          error("live state must not be consulted")
        end,
        target_context = function()
          error("live target must not be consulted")
        end,
        android_device = {
          get = function()
            error("live device must not be consulted")
          end,
        },
        targets = {
          plan = function(_, _, ctx)
            plan_ctx = ctx
            return { cwd = "/Engine/A" }
          end,
        },
        target_tasks = {
          command = function()
            return { "owner deploy" }
          end,
        },
        stop_android_debugger = function() end,
        workspace_root = function(ctx)
          t.assert_eq(ctx.project_root, "/Project/A")
          return "/Project/A"
        end,
        open_terminal_command = function(_, opts)
          done = opts.on_exit
          return 9
        end,
        on_exit = function(code)
          t.assert_eq(code, 0)
        end,
      },
    })
    t.assert_nil(err)
    t.assert_eq(job, 9)
    t.assert_eq(plan_ctx.configuration, "Test")
    t.assert_eq(plan_ctx.device_id, "SERIAL-A")
    t.assert_eq(plan_ctx.package_name, "com.example.a")
    t.assert_eq(snapshot.context.project_root, "/Project/A")
    done(0, { "deployment complete" })
  end)

  t.it("plain launch uses frozen package/device and completes only from its exit callback", function()
    local on_exit, completed, planned
    local job, err = require("ue.workflows.android.launch").run({
      target_id = "Android",
      snapshot = owner_snapshot(),
      host_driver = { id = "windows" },
      context = {
        resolve_context = function()
          error("must not resolve live context")
        end,
        android_device = {
          get = function()
            error("must not read live device")
          end,
        },
        resolve_tool = function()
          return { ok = true, path = "adb" }
        end,
        targets = {
          plan = function(_, _, ctx)
            planned = ctx
            return { args = {} }
          end,
        },
        target_tasks = {
          command = function()
            return { "launch owner" }
          end,
        },
        jobstart = function(_, opts)
          on_exit = opts.on_exit
          return 8
        end,
        schedule = function(fn)
          fn()
        end,
        task_registry = {},
        notify = function() end,
        on_exit = function(code)
          completed = code
        end,
      },
    })
    t.assert_nil(err)
    t.assert_eq(job, 8)
    t.assert_eq(planned.device_id, "SERIAL-A")
    t.assert_eq(planned.package_name, "com.example.a")
    t.assert_nil(completed)
    on_exit(8, 0)
    t.assert_eq(completed, 0)
  end)
end)

local function isolated(fn)
  local old_tab = vim.api.nvim_get_current_tabpage()
  local old_qf = vim.fn.getqflist({ items = 0, title = 0, idx = 0 })
  local old_buffers, jobs = {}, {}
  local modules = { "utils.bottom_panel", "utils.task_registry" }
  local old_modules = {}
  for _, name in ipairs(modules) do
    old_modules[name], package.loaded[name] = package.loaded[name], nil
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    old_buffers[buf] = true
  end
  vim.cmd("tabnew")
  local tab = vim.api.nvim_get_current_tabpage()
  local ok, err = pcall(fn, require("utils.bottom_panel"), jobs)
  for _, job in ipairs(jobs) do
    pcall(vim.fn.jobstop, job)
    pcall(vim.fn.jobwait, { job }, 2000)
  end
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose!")
  end
  if vim.api.nvim_tabpage_is_valid(old_tab) then
    vim.api.nvim_set_current_tabpage(old_tab)
  end
  vim.fn.setqflist({}, "r", old_qf)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not old_buffers[buf] then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  for _, name in ipairs(modules) do
    package.loaded[name] = old_modules[name]
  end
  if not ok then
    error(err, 0)
  end
end

-- Run the production private closure, not a copied terminal implementation.
local function terminal_fixture()
  local source = table.concat(vim.fn.readfile(cfg .. "/lua/ue.lua"), "\n")
  local first = assert(source:find("local function append_job_output", 1, true))
  local last = assert(source:find("-- PICKER INTEGRATION", first, true))
  local factory = assert(
    loadstring(
      "return function(CORE_RT, set_build_status, trim, strip_ansi, "
        .. "startinsert_in_window, diagnostic_entries_from_output)\n"
        .. source:sub(first, last - 1)
        .. "\nreturn open_terminal_command\nend",
      "@production-terminal-fixture"
    )
  )()
  return factory({}, function() end, vim.trim, function(value)
    return value
  end, function(win)
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
  end, function()
    return {}
  end)
end

t.describe("ide_workflow: background presentation and history", function()
  t.it("loop cancellation uses the registry's cancellation intent for a real owned job", function()
    isolated(function(_, jobs)
      local registry = require("utils.task_registry")
      local callback, record
      local run = iterate.run({
        set_status = function() end,
        build_so = function(done)
          callback = done
          local job = vim.fn.jobstart(
            { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua vim.wait(5000)", "-c", "qa!" },
            {
              on_exit = function(_, code)
                done(code)
              end,
            }
          )
          t.assert_true(job > 0)
          jobs[#jobs + 1] = job
          record = registry.register({ name = "native loop cancellation", kind = "job", handle = job })
          return job
        end,
      }, { snapshot = frozen(), notify = function() end })
      t.assert_true(run:cancel())
      t.assert_eq(run.status, "cancelled")
      t.assert_true(vim.wait(3000, function()
        return registry.status(record) ~= "running"
      end, 10))
      t.assert_eq(registry.status(record), "cancelled")
      callback(0)
      t.assert_eq(run.status, "cancelled")
    end)
  end)

  t.it("starting a real build terminal preserves the dirty source window and cursor", function()
    isolated(function(panel, jobs)
      local source = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "first", "dirty source" })
      vim.api.nvim_win_set_cursor(0, { 2, 3 })
      local code_win, cursor = vim.api.nvim_get_current_win(), vim.api.nvim_win_get_cursor(0)
      local job = terminal_fixture()(
        { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "lua vim.wait(150)", "-c", "qa!" },
        { finish_label = "fixture build" }
      )
      jobs[#jobs + 1] = job
      t.assert_true(job > 0)
      t.assert_eq(vim.api.nvim_get_current_win(), code_win)
      t.assert_eq(vim.api.nvim_get_current_buf(), source)
      t.assert_eq(vim.api.nvim_win_get_cursor(0)[1], cursor[1])
      t.assert_eq(vim.api.nvim_win_get_cursor(0)[2], cursor[2])
      t.assert_true(vim.bo[source].modified)
      local host = panel.show("build")
      t.assert_eq(vim.api.nvim_get_current_win(), host, "explicit panel open still focuses")
      t.assert_eq(vim.bo[vim.api.nvim_win_get_buf(host)].buftype, "terminal")
      t.assert_true(vim.wait(3000, function()
        return vim.fn.jobwait({ job }, 0)[1] ~= -1
      end, 10))
    end)
  end)

  t.it("failed build diagnostics preserve editor focus and warnings remain available", function()
    isolated(function(panel)
      local source, code_win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
      vim.api.nvim_buf_set_name(source, vim.fn.tempname() .. ".cpp")
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "line 1", "error line", "warning line" })
      vim.api.nvim_win_set_cursor(code_win, { 1, 2 })
      require("ue.build_diagnostics").publish("fixture exit 6", {
        { bufnr = source, lnum = 3, text = "warning: something", type = "W" },
        { bufnr = source, lnum = 2, text = "error: broken", type = "E" },
      })
      t.assert_eq(vim.api.nvim_get_current_win(), code_win)
      t.assert_eq(vim.api.nvim_win_get_cursor(code_win)[1], 1)
      t.assert_true(vim.bo[source].modified)
      t.assert_eq(#vim.fn.getqflist(), 2)
      t.assert_eq(vim.fn.getqflist()[2].type, "W")
      require("ue.build_diagnostics").jump_first()
      t.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 2)
      t.assert_true(panel.window() ~= code_win)
    end)
  end)

  t.it("subsequent stage logs remain accessible and completed history is bounded", function()
    isolated(function(panel)
      local buffers = {}
      for index = 1, 20 do
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "stage output " .. index })
        vim.b[buf].ue_build_title = "stage " .. index
        panel.register("build", buf)
        buffers[index] = buf
      end
      local history = panel.build_history()
      t.assert_eq(#history, 16)
      t.assert_true(vim.api.nvim_buf_is_valid(buffers[19]))
      t.assert_contains(table.concat(vim.api.nvim_buf_get_lines(buffers[19], 0, -1, false)), "stage output 19")
      t.assert_eq(history[1].buf, buffers[20])
      t.assert_eq(history[1].title, "stage 20")
      t.assert_false(vim.api.nvim_buf_is_valid(buffers[1]))
    end)
  end)

  t.it("closing a tab releases its completed history but never wipes ordinary dirty source", function()
    isolated(function(panel)
      local home = vim.api.nvim_get_current_tabpage()
      vim.cmd("tabnew")
      local log = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(log, 0, -1, false, { "completed output" })
      panel.register("build", log)
      local source = vim.api.nvim_create_buf(true, false)
      vim.api.nvim_buf_set_lines(source, 0, -1, false, { "dirty source must survive" })
      panel.register("build", source)
      vim.cmd("tabclose!")
      vim.api.nvim_set_current_tabpage(home)
      panel.build_history()
      t.assert_false(vim.api.nvim_buf_is_valid(log))
      t.assert_true(vim.api.nvim_buf_is_valid(source))
      t.assert_true(vim.bo[source].modified)
    end)
  end)

  t.it("task list shows group, nonzero exit and derived failure without state writes", function()
    isolated(function(panel)
      local registry = require("utils.task_registry")
      registry._set_probe_for_test(function()
        return "done", 6
      end)
      local id = registry.register({ name = "SO compile", group = "build", kind = "job", handle = 42 })
      local row = registry.list()[1]
      t.assert_eq(row.result, "failed")
      t.assert_nil(registry.get(id).state)
      t.assert_nil(registry.get(id).code)
      local host = panel.show("tasks")
      local text = table.concat(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(host), 0, -1, false), "\n")
      t.assert_contains(text, "failed")
      t.assert_contains(text, "exit=6")
      t.assert_contains(text, "build")
    end)
  end)

  t.it("real vim.system completion exposes exit 6 without wait or callback status writes", function()
    isolated(function()
      local registry = require("utils.task_registry")
      local handle = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-c", "cquit 6" })
      local id = registry.register({ name = "native failed task", kind = "system", handle = handle })
      local ok, err = pcall(function()
        t.assert_true(vim.wait(3000, function()
          return handle:is_closing()
        end, 10))
        local status, code = registry.status(id)
        t.assert_eq(status, "done")
        t.assert_eq(code, 6)
        t.assert_eq(registry.list()[1].result, "failed")
      end)
      if not handle:is_closing() then
        handle:kill(15)
      end
      if not ok then
        error(err, 0)
      end
    end)
  end)
end)
