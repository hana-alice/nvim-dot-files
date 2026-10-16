local t = require("tests.harness")
local cfg = t.bootstrap()
local diagnostics = require("ue.build_diagnostics")
local fs = require("ue.core.fs")

-- Execute the production parser and terminal runner together. Only channel
-- creation is injected: these tests do not claim UBT or host-tool capability.
local function section(source, first, following)
  local start = assert(source:find(first, 1, true), first)
  local finish = assert(source:find(following, start + #first, true), following)
  return source:sub(start, finish - 1)
end

local function fixture(run)
  local root = fs.norm(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  local source_file = root .. "/Callback.cpp"
  vim.fn.writefile({ "one", "two", "three", "four", "five", "six" }, source_file)
  local original_win = vim.api.nvim_get_current_win()
  local original_buf = vim.api.nvim_get_current_buf()
  local original_qf = vim.fn.getqflist({ items = 0, title = 0, idx = 0 })
  local original_wins, original_bufs = {}, {}
  for _, win in ipairs(vim.api.nvim_list_wins()) do original_wins[win] = true end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do original_bufs[buf] = true end
  local capture = { notifications = {}, statuses = {}, exits = {}, stops = 0 }
  local deps = {
    ["utils.host_admission"] = {
      foreground_begin = function() return "callback-test" end,
      foreground_done = function() capture.foreground_done = true end,
    },
    ["utils.task_registry"] = { register = function() end },
    ["ue.build_monitor"] = {
      start = function() return { stop = function() capture.stops = capture.stops + 1 end } end,
    },
    ["utils.log"] = { error = function() end, notify_error = function() end },
  }
  local test_vim = setmetatable({
    fn = setmetatable({
      termopen = function(_, opts)
        capture.channel = opts
        return 42
      end,
      jobwait = function() return { 0 } end,
    }, { __index = vim.fn }),
    notify = function(message, level)
      capture.notifications[#capture.notifications + 1] = { message = message, level = level }
    end,
  }, { __index = vim })
  local env = setmetatable({
    vim = test_vim,
    CORE_RT = {},
    _ufs = fs,
    trim = fs.trim,
    norm = fs.norm,
    join = fs.join,
    focus_window = function(win)
      if not vim.api.nvim_win_is_valid(win) then return false end
      vim.api.nvim_set_current_win(win)
      return true
    end,
    startinsert_in_window = function() end,
    set_build_status = function(value) capture.statuses[#capture.statuses + 1] = value end,
    require = function(name) return deps[name] or require(name) end,
  }, { __index = _G })
  local source = table.concat(vim.fn.readfile(cfg .. "/lua/ue.lua"), "\n")
  local chunk = assert(loadstring(
    section(source, "local function strip_ansi(", "local function populate_quickfix_from_entries(")
      .. section(source, "local function append_job_output(", "-- PICKER INTEGRATION")
      .. "\nreturn open_terminal_command", "@ue-build-callback-fixture"))
  setfenv(chunk, env)
  local open = chunk()
  function capture.start(build)
    local opts = {
      finish_label = build == false and "Background task" or "Fixture build",
      quickfix_title = build ~= false and "Fixture build errors" or nil,
      quickfix_root = root,
      on_exit = function(code, output)
        capture.exits[#capture.exits + 1] = { code = code, output = output }
      end,
    }
    t.assert_eq(open({ "fixture-channel" }, opts), 42)
  end
  function capture.finish(code)
    local count = #capture.exits
    capture.channel.on_exit(42, code)
    -- After real colorscheme loads the first native quickfix open is cold.
    -- The fixture tests delivery/data, not a 200 ms UI performance guarantee.
    t.assert_true(vim.wait(2000, function() return #capture.exits == count + 1 end), "scheduled exit callback")
  end
  function capture.seed_error()
    diagnostics.publish("Previous build", { { filename = source_file, lnum = 5, text = "error: previous" } })
  end
  diagnostics.clear()
  local ok, err = xpcall(function() run(capture, source_file) end, debug.traceback)
  diagnostics.clear()
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if not original_wins[win] then pcall(vim.api.nvim_win_close, win, true) end
  end
  if vim.api.nvim_win_is_valid(original_win) then
    vim.api.nvim_set_current_win(original_win)
    if vim.api.nvim_buf_is_valid(original_buf) then vim.api.nvim_win_set_buf(original_win, original_buf) end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if not original_bufs[buf] then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
  end
  vim.fn.setqflist({}, "r", original_qf)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("build terminal completion callback", function()
  t.it("parses fragmented channel stdout and stderr, puts errors first, retains warnings", function()
    fixture(function(f, file)
      f.start()
      -- Neovim channel arrays contain newline-separated lines; first and last
      -- elements may be fragments shared with adjacent callbacks.
      f.channel.on_stdout(42, { "Callback.cpp:2:1: war" })
      f.channel.on_stdout(42, { "ning: retained", "Callback.cpp:5:2: er" })
      f.channel.on_stdout(42, { "ror: broken", "" })
      f.channel.on_stderr(42, { "\27[31mCallback.cpp(3,1): error: second\27[0m", "" })
      f.finish(6)
      local items = vim.fn.getqflist()
      t.assert_eq(#items, 3)
      t.assert_eq(items[1].type, "E")
      t.assert_eq(items[1].lnum, 5)
      t.assert_eq(items[2].type, "E")
      t.assert_eq(items[2].lnum, 3)
      t.assert_eq(items[3].type, "W")
      t.assert_eq(items[3].lnum, 2)
      t.assert_contains(items[3].text, "warning: retained")
      local notification = f.notifications[#f.notifications]
      t.assert_eq(notification.level, vim.log.levels.ERROR)
      t.assert_contains(notification.message, "Callback.cpp:5")
      t.assert_contains(notification.message, "<leader>uE")
      t.assert_eq(f.statuses[#f.statuses], "B6")
      t.assert_true(f.foreground_done)
      t.assert_eq(f.stops, 1)
      t.assert_eq(#f.exits[1].output, 3)
      t.assert_true(diagnostics.jump_first())
      t.assert_eq(fs.norm(vim.api.nvim_buf_get_name(0)), file)
      t.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5)
    end)
  end)

  t.it("flushes an unterminated final error at exit before notifying", function()
    fixture(function(f)
      f.start()
      f.channel.on_stdout(42, { "Callback.cpp:4:1: error: no trailing newline" })
      f.finish(1)
      t.assert_eq(vim.fn.getqflist()[1].lnum, 4)
      t.assert_contains(f.notifications[1].message, "Callback.cpp:4")
      t.assert_eq(f.exits[1].output[1], "Callback.cpp:4:1: error: no trailing newline")
    end)
  end)

  t.it("clears stale error at the start of a successful build", function()
    fixture(function(f)
      f.seed_error()
      f.start()
      t.assert_eq(diagnostics.summary(), "未解析到错误源码位置")
      f.channel.on_stdout(42, { "Build succeeded", "" })
      f.finish(0)
      t.assert_false(diagnostics.jump_first())
      t.assert_false(f.notifications[1].message:find("首个错误", 1, true))
      t.assert_eq(f.statuses[#f.statuses], "BOK")
    end)
  end)

  t.it("reports missing source location without reusing a previous build error", function()
    fixture(function(f)
      f.seed_error()
      f.start()
      f.channel.on_stderr(42, { "BUILD FAILED: tool stopped", "" })
      f.finish(3)
      t.assert_eq(diagnostics.summary(), "未解析到错误源码位置")
      t.assert_contains(f.notifications[1].message, "未解析到错误源码位置")
      t.assert_false(f.notifications[1].message:find("Callback.cpp", 1, true))
      t.assert_false(diagnostics.jump_first())
    end)
  end)

  t.it("keeps quoted artifact context without letting it take the first source error", function()
    fixture(function(f, file)
      local artifact = fs.dirname(file) .. "/Output.so"
      f.start()
      f.channel.on_stderr(42, {
        'ERROR: Cannot open "' .. artifact .. '"',
        "Callback.cpp:5:2: error: actual source failure",
        "",
      })
      f.finish(1)
      local items = vim.fn.getqflist()
      t.assert_eq(#items, 2)
      t.assert_contains(items[1].text, artifact)
      t.assert_eq(items[2].lnum, 5)
      t.assert_contains(f.notifications[1].message, "Callback.cpp:5")
      t.assert_false(f.notifications[1].message:find("Output.so:1", 1, true))
      t.assert_true(diagnostics.jump_first())
      t.assert_eq(fs.norm(vim.api.nvim_buf_get_name(0)), file)
      t.assert_eq(vim.api.nvim_win_get_cursor(0)[1], 5)
    end)
  end)

  t.it("retains a quoted path failure but does not invent a source location", function()
    fixture(function(f, file)
      local artifact = fs.dirname(file) .. "/Output.so"
      f.seed_error()
      f.start()
      f.channel.on_stderr(42, { 'ERROR: Cannot open "' .. artifact .. '"', "" })
      f.finish(1)
      local items = vim.fn.getqflist()
      t.assert_eq(#items, 1)
      t.assert_contains(items[1].text, artifact)
      t.assert_eq(diagnostics.summary(), "未解析到错误源码位置")
      t.assert_contains(f.notifications[1].message, "未解析到错误源码位置")
      t.assert_false(f.notifications[1].message:find("<leader>uE", 1, true))
      t.assert_false(diagnostics.jump_first())
    end)
  end)

  t.it("does not append build-error summary or replace quickfix for a background task", function()
    fixture(function(f)
      f.seed_error()
      local title = vim.fn.getqflist({ title = 0 }).title
      f.start(false)
      f.channel.on_stdout(42, { "Background task failed", "" })
      f.finish(9)
      t.assert_contains(f.notifications[1].message, "Background task finished with exit code 9")
      t.assert_false(f.notifications[1].message:find("首个错误", 1, true))
      t.assert_false(f.notifications[1].message:find("<leader>uE", 1, true))
      t.assert_eq(vim.fn.getqflist({ title = 0 }).title, title)
      t.assert_eq(#f.statuses, 0)
    end)
  end)
end)
