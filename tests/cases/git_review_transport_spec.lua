local t = require("tests.harness")
t.bootstrap()
local transport = require("workarounds.codediff.threaded_git")
local fixture = require("tests.helpers.git_review_fixture")
if not vim.uv.new_work or vim.fn.executable("git") ~= 1 then
  t.skip("threaded Git transport", "libuv worker or Git unavailable", { native = true })
  return
end

local function run(args, opts)
  local result
  local task = transport.system(args, opts or {}, function(value) result = value end)
  t.assert_true(vim.wait(10000, function() return result ~= nil end, 5), "worker completed")
  t.assert_true(task:is_closing())
  return result
end

t.describe("CodeDiff threaded Git", function()
  t.it("a pipe read failure after process exit never reports successful truncated output", function()
    local real_uv = vim.uv
    local pipes, on_exit, kills = {}, nil, 0
    local function handle()
      return {
        is_closing = function(self) return self.closed == true end,
        close = function(self) self.closed = true end,
        read_start = function(self, callback) self.reader = callback end,
        start = function() end,
        kill = function() kills = kills + 1 end,
      }
    end
    local fake_uv = {
      new_pipe = function() local pipe = handle(); pipes[#pipes + 1] = pipe; return pipe end,
      new_timer = handle,
      hrtime = function() return 1000000 end,
      fs_stat = function() return nil end,
      spawn = function(_, opts, callback)
        t.assert_true(opts.hide, "owned Git children must not flash console windows")
        on_exit = callback
        return handle(), 123
      end,
      run = function()
        on_exit(0, 0)
        -- libuv may deliver the exit callback before draining both pipes.
        pipes[1].reader("EIO while draining exited process", nil)
        pipes[2].reader(nil, nil)
      end,
    }
    local encoded = vim.mpack.encode({ executable = "git", args = {}, timeout = 500, cancel_path = "unused-test-marker" })
    vim.uv = fake_uv
    local ok, code, _, _, stderr = pcall(transport._worker_for_test, encoded, { send = function() end })
    vim.uv = real_uv
    t.assert_true(ok, tostring(code))
    t.assert_true(code ~= 0, "drain failure must remain a failure after exit code zero")
    t.assert_contains(stderr, "EIO while draining")
    t.assert_eq(kills, 0, "never signal an already exited process")
  end)
  t.it("process creation never calls the main-loop spawn function", function()
    local spawn = vim.uv.spawn
    vim.uv.spawn = function() error("spawn ran on the main loop") end
    local ok, result = pcall(run, { "--version" }, {})
    vim.uv.spawn = spawn
    t.assert_true(ok, tostring(result))
    t.assert_eq(result.code, 0)
    t.assert_contains(result.stdout, "git version")
    t.assert_true(transport.status().spawned >= 1)
    local jobs = transport.jobs()
    t.assert_true(jobs[#jobs].spawn_ms >= 0)
    t.assert_true(jobs[#jobs].elapsed_ms >= jobs[#jobs].spawn_ms)
  end)
  t.it("runs real Git with raw stdin/stdout and text normalization", function()
    fixture.with_repo(function(f)
      local bytes = "one\r\ntwo\r\n"
      local hash = run({ "hash-object", "-w", "--stdin" }, { cwd = f.root, stdin = bytes, text = false })
      t.assert_eq(hash.code, 0)
      local oid = vim.trim(hash.stdout)
      local raw = run({ "cat-file", "blob", oid }, { cwd = f.root, text = false })
      t.assert_eq(raw.stdout, bytes)
      local text = run({ "cat-file", "blob", oid }, { cwd = f.root, text = true })
      t.assert_eq(text.stdout, "one\ntwo\n")
    end)
  end)
  t.it("reports spawn and Git errors exactly once on the main loop", function()
    local callbacks, observed, fast = 0
    transport.system({ "--version" }, { executable = "/missing-codex-git-transport" }, function(result)
      callbacks, observed, fast = callbacks + 1, result, vim.in_fast_event()
    end)
    t.assert_true(vim.wait(10000, function() return observed ~= nil end, 5))
    t.assert_eq(callbacks, 1)
    t.assert_false(fast)
    t.assert_eq(observed.code, -1)
    t.assert_contains(observed.stderr, "Failed to spawn Git")
    local invalid = run({ "not-a-real-git-subcommand" }, {})
    t.assert_true(invalid.code ~= 0)
    t.assert_true(#invalid.stderr > 0)
  end)
  t.it("limits workers to two and cancels queued/running owned processes", function()
    fixture.with_repo(function(f)
      local results, handles = {}, {}
      for i = 1, 3 do
        handles[i] = transport.system({ "cat-file", "--batch" }, { cwd = f.root, stdin = true, timeout = 7000 }, function(value) results[i] = value end)
      end
      t.assert_eq(transport.status().active, 2)
      t.assert_eq(transport.status().queued, 1)
      t.assert_true(handles[3]:kill())
      t.assert_true(handles[3]:is_closing())
      t.assert_eq(results[3].code, 130)
      t.assert_true(vim.wait(7000, function() return handles[1].pid and handles[2].pid end, 5))
      for i = 1, 2 do t.assert_true(handles[i]:kill()) end
      t.assert_true(vim.wait(7000, function() return results[1] and results[2] end, 5))
      for i = 1, 2 do
        t.assert_eq(results[i].code, 130)
        t.assert_true(results[i].cancelled)
        t.assert_true(handles[i]:is_closing())
        t.assert_false(vim.uv.kill(handles[i].pid, 0) == 0, "owned Git process exited")
      end
      t.assert_eq(transport.status().active, 0)
    end)
  end)
  t.it("timeout kills its own Git process and completes", function()
    fixture.with_repo(function(f)
      local result = run({ "cat-file", "--batch" }, { cwd = f.root, stdin = true, timeout = 200 })
      t.assert_eq(result.code, 124)
      t.assert_contains(result.stderr, "timed out")
      t.assert_eq(transport.status().active, 0)
    end)
  end)
  t.it("hunk apply uses raw stdin without changing working files", function()
    fixture.with_repo(function(f)
      f.baseline("old\r\n")
      f.write("new\r\n")
      local done, err
      transport.apply_patch(f.root, "--- a/review.txt\n+++ b/review.txt\n@@ -1 +1 @@\n-old\r\n+new\r\n", false, function(value) done, err = true, value end)
      t.assert_true(vim.wait(10000, function() return done end, 5))
      t.assert_nil(err)
      t.assert_eq(f.git({ "show", ":0:review.txt" }), "new\r\n")
      t.assert_eq(f.read(), "new\r\n")
    end)
  end)
  t.it("closing the last root cancels work but reopening the same tab protects it", function()
    fixture.with_repo(function(f)
      local saved_git, saved_lifecycle = package.loaded["codediff.core.git"], package.loaded["codediff.ui.lifecycle"]
      local tab = vim.api.nvim_get_current_tabpage()
      local sessions = { [tab] = { git_root = f.root } }
      package.loaded["codediff.core.git"] = { apply_patch = function() end }
      package.loaded["codediff.ui.lifecycle"] = { get_session = function(id) return sessions[id] end }
      transport.attach()
      local completed
      local handle = transport.system({ "cat-file", "--batch" }, { cwd = f.root, stdin = true, timeout = 7000 }, function(value) completed = value end)
      local ok, err = xpcall(function()
        t.assert_true(vim.wait(5000, function() return handle.pid ~= nil end, 5))
        vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", modeline = false, data = { tabpage = tab } })
        -- A new session in the same tab appears before the scheduled check.
        sessions[tab] = { git_root = f.root }
        local flushed
        vim.schedule(function() flushed = true end)
        t.assert_true(vim.wait(1000, function() return flushed end, 5))
        t.assert_false(handle:is_closing())
        t.assert_nil(vim.uv.fs_stat(handle.cancel_path))
        vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", modeline = false, data = { tabpage = tab } })
        sessions[tab] = nil
        t.assert_true(vim.wait(5000, function() return completed ~= nil end, 5))
        t.assert_eq(completed.code, 130)
        t.assert_eq(transport.status().active, 0)
      end, debug.traceback)
      transport.cancel_all()
      vim.wait(5000, function() return handle:is_closing() end, 5)
      transport.disable()
      package.loaded["codediff.core.git"], package.loaded["codediff.ui.lifecycle"] = saved_git, saved_lifecycle
      if not ok then error(err) end
    end)
  end)
  t.it("close snapshots old work without cancelling a newly opening review", function()
    fixture.with_repo(function(f)
      local saved_git, saved_lifecycle = package.loaded["codediff.core.git"], package.loaded["codediff.ui.lifecycle"]
      local tab = vim.api.nvim_get_current_tabpage()
      local sessions = { [tab] = { git_root = f.root } }
      package.loaded["codediff.core.git"] = { apply_patch = function() end }
      package.loaded["codediff.ui.lifecycle"] = { get_session = function(id) return sessions[id] end }
      transport.attach()
      local completed, replacement
      local old = transport.system({ "cat-file", "--batch" }, { cwd = f.root, stdin = true, timeout = 7000 }, function(value) completed = value end)
      local ok, err = xpcall(function()
        t.assert_true(vim.wait(5000, function() return old.pid ~= nil end, 5))
        vim.api.nvim_exec_autocmds("User", { pattern = "CodeDiffClose", modeline = false, data = { tabpage = tab } })
        sessions[tab] = nil
        -- This new request has no session yet when the deferred close runs.
        replacement = transport.system({ "cat-file", "--batch" }, { cwd = f.root, stdin = true, timeout = 7000 }, function() end)
        t.assert_true(vim.wait(5000, function() return completed ~= nil end, 5))
        t.assert_eq(completed.code, 130)
        t.assert_nil(vim.uv.fs_stat(replacement.cancel_path), "new request must not receive an old close's cancellation")
        t.assert_false(replacement:is_closing())
      end, debug.traceback)
      transport.cancel_all()
      vim.wait(5000, function() return transport.status().active == 0 end, 5)
      transport.disable()
      package.loaded["codediff.core.git"], package.loaded["codediff.ui.lifecycle"] = saved_git, saved_lifecycle
      if not ok then error(err) end
    end)
  end)
end)
