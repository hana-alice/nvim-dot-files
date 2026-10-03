local t = require("tests.harness")
local cfg = t.bootstrap()

-- Exercise the native confirmation with a real attached UI and RPC input.
-- The existing measurement helper supplies MessagePack and grid decoding only.
local driver = [=[
import json
import os
from pathlib import Path
import queue
import runpy
import subprocess
import sys
import threading
import time
import traceback

root, directory, executable, scenario = sys.argv[1:]
directory = Path(directory)
helper = runpy.run_path(str(Path(root) / "tools" / "measure_inlay_hints.py"))


class Session(helper["Nvim"]):
    def __init__(self, environment):
        super().__init__(executable, environment, directory / "nvim.stderr.log")
        self.events = []
        # Kill our embedded child before the parent's 20-second Python deadline.
        # Even an unexpected blocked RPC therefore cannot orphan Neovim.
        self.watchdog = threading.Timer(15, self.expire)
        self.watchdog.daemon = True
        self.watchdog.start()

    def expire(self):
        print("UNSAVED_CONFIRM_TIMEOUT " + scenario + "\nUI:\n" + self.screen(),
              file=sys.stderr, flush=True)
        self.process.kill()
        self.process.wait(timeout=3)
        os._exit(2)

    def consume(self, message):
        super().consume(message)
        if isinstance(message, list) and message[:2] == [2, "confirm_test_mutated"]:
            self.events.append(message[2])

    def call(self, method, *arguments):
        self.sequence += 1
        identifier = self.sequence
        self.process.stdin.write(helper["pack"]([0, identifier, method, arguments]))
        self.process.stdin.flush()
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            message = self.messages.get(timeout=max(0.01, deadline - time.monotonic()))
            self.consume(message)
            if isinstance(message, list) and message[:2] == [1, identifier]:
                if message[2]:
                    raise RuntimeError(message[2])
                return message[3]
        raise TimeoutError(method)

    def screen(self):
        return "\n".join("".join(row) for grid in self.grids.values() for row in grid)

    def wait_for(self, predicate, label, timeout=5):
        deadline = time.monotonic() + timeout
        while not predicate():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(label + "\nUI:\n" + self.screen())
            try:
                self.consume(self.messages.get(timeout=remaining))
            except queue.Empty:
                raise TimeoutError(label + "\nUI:\n" + self.screen()) from None

    def drain(self, seconds):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                self.consume(self.messages.get(timeout=deadline - time.monotonic()))
            except queue.Empty:
                return

    def close(self):
        # A broken confirmation must never make cleanup wait for another key.
        # Stop only the embedded Neovim owned by this test; Python is awaited.
        self.watchdog.cancel()
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=3)
        finally:
            for stream in (self.process.stdin, self.process.stdout):
                stream.close()
            self.log.close()


environment = os.environ.copy()
environment["PYTHONIOENCODING"] = "utf-8"
for variable in ("XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME"):
    environment[variable] = str(directory / variable.lower())
instance = Session(environment)
try:
    instance.call("nvim_ui_attach", 120, 24, {"rgb": True, "ext_linegrid": True})
    channel = instance.call("nvim_get_api_info")[0]
    instance.lua("""
        local root, directory, channel = ...
        vim.opt.rtp:prepend(root)
        vim.o.swapfile = false
        vim.o.shada = ''
        vim.o.hidden = true
        _G.test_channel = channel
        _G.test_done, _G.test_exits, _G.test_notices = false, {}, {}
        local native_command = vim.cmd
        vim.cmd = function(command)
          if command == 'qa' or command == 'qa!' then
            table.insert(_G.test_exits, command)
          else
            return native_command(command)
          end
        end
        vim.notify = function(message, level)
          table.insert(_G.test_notices, {message=message, level=level})
        end
        vim.ui.select = function(_, _, callback) _G.test_picker_callback = callback end
        _G.test_unsaved = require('utils.unsaved')
        _G.test_unsaved.setup()
        _G.test_buf = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_name(_G.test_buf, directory .. '/Unsaved.cpp')
        vim.api.nvim_buf_set_lines(_G.test_buf, 0, -1, false, {'before confirmation'})
        _G.test_mutate = function()
          assert(not _G.test_done, 'mutation must occur while confirmation is waiting')
          vim.api.nvim_buf_set_lines(_G.test_buf, 0, -1, false, {'changed during confirmation'})
          vim.rpcnotify(_G.test_channel, 'confirm_test_mutated', 'changed during confirmation')
        end
    """, root, str(directory), channel)
    instance.lua("""
        local scenario = ...
        vim.schedule(function()
          if scenario == 'timer' then vim.defer_fn(_G.test_mutate, 1000) end
          local ok, err = pcall(function()
            _G.test_unsaved.quit()
            _G.test_picker_callback('放弃修改并退出')
          end)
          _G.test_error = not ok and tostring(err) or nil
          _G.test_done = true
        end)
    """, scenario)
    instance.wait_for(lambda: "确定放弃" in instance.screen() and "取消" in instance.screen(),
                      "native confirmation never appeared")
    prompt = instance.screen()
    assert "Unsaved.cpp" in prompt, prompt
    if scenario == "timer":
        instance.wait_for(lambda: bool(instance.events), "timer did not run inside native confirm")
    elif scenario == "rpc":
        instance.lua("_G.test_mutate()")
        instance.wait_for(lambda: bool(instance.events), "RPC mutation notification missing")
    key = {"yes": "y", "no": "n", "default": "<CR>", "timer": "y", "rpc": "y"}[scenario]
    assert instance.call("nvim_input", key) > 0, "no input bytes accepted"
    state = instance.lua("""
        assert(_G.test_done, 'confirmation did not finish after input')
        assert(not _G.test_error, _G.test_error)
        return {exits=_G.test_exits, notices=_G.test_notices,
          modified=vim.bo[_G.test_buf].modified,
          lines=vim.api.nvim_buf_get_lines(_G.test_buf, 0, -1, false),
          dirty_count=#_G.test_unsaved.list(), info_level=vim.log.levels.INFO}
    """)
    expected_exits = ["qa!"] if scenario == "yes" else []
    assert state["exits"] == expected_exits, state
    assert state["modified"] and state["dirty_count"] == 1, state
    expected_line = "changed during confirmation" if scenario in ("timer", "rpc") else "before confirmation"
    assert state["lines"] == [expected_line], state
    if scenario in ("timer", "rpc"):
        assert any("确认期间" in notice["message"] and notice["level"] == state["info_level"]
                   for notice in state["notices"]), state
    else:
        assert state["notices"] == [], state
    print("UNSAVED_CONFIRM_OK " + json.dumps({"scenario": scenario, "key": key,
          "ui": "ext_linegrid 120x24", "state": state}, ensure_ascii=False), flush=True)
except BaseException:
    traceback.print_exc()
    print("UI at failure:\n" + instance.screen(), file=sys.stderr)
    raise
finally:
    instance.close()
]=]

local function exercise(scenario)
  local dir = vim.fn.tempname() .. "-unsaved-confirm"
  vim.fn.mkdir(dir, "p")
  local script = dir .. "/driver.py"
  local result
  local ok, err = pcall(function()
    vim.fn.writefile(vim.split(driver, "\n", { plain = true }), script)
    result = vim
      .system({ "python", "-I", "-B", script, cfg, dir, vim.v.progpath, scenario }, {
        text = true,
        env = { PYTHONIOENCODING = "utf-8" },
      })
      :wait(20000)
  end)
  local diagnostics = result and ((result.stdout or "") .. (result.stderr or "")) or tostring(err)
  local stderr_path = dir .. "/nvim.stderr.log"
  if vim.fn.filereadable(stderr_path) == 1 then
    diagnostics = diagnostics .. "\nChild stderr:\n" .. table.concat(vim.fn.readfile(stderr_path), "\n")
  end
  vim.fn.delete(dir, "rf")
  t.assert_true(ok, diagnostics)
  t.assert_eq(result.code, 0, diagnostics)
  t.assert_contains(result.stdout or "", "UNSAVED_CONFIRM_OK", diagnostics)
end

t.describe("unsaved_confirm: 原生外部 UI 确认", function()
  for _, case in ipairs({
    { "yes", "真实 y 热键确认放弃，捕获 qa! 并保留可检查状态" },
    { "no", "真实 n 热键取消，保留修改" },
    { "default", "Enter 默认取消，保留修改" },
    { "timer", "原生确认等待期间 timer 编辑后，y 取消退出并保留新内容" },
    { "rpc", "原生确认等待期间 RPC 编辑后，y 取消退出并保留新内容" },
  }) do
    if vim.fn.executable("python") == 1 then
      t.it(case[2], function()
        exercise(case[1])
      end)
    else
      t.skip(case[2], "native external UI test requires Python (standard library only)", { native = true })
    end
  end
end)
