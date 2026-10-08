local t = require("tests.harness")
t.bootstrap()

-- Pure parsing/quickfix contract for :UEAndroidCrash. Frame text below follows
-- the `logcat -b crash` debuggerd line format (values are synthetic).
local crash = require("ue.dap._android_crash")

local SAMPLE = table.concat({
  "01-01 00:00:00.000  1000  1000 F DEBUG   :       #00 pc 00000000000cf3a4  /apex/com.android.runtime/lib64/bionic/libc.so (__fortify_fatal(char const*, ...)+228) (BuildId: 0123456789abcdef0123456789abcdef)",
  "01-01 00:00:00.000  1000  1000 F DEBUG   :       #01 pc 000000000010f718  /apex/com.android.runtime/lib64/bionic/libc.so (__memset_chk_fail+72) (BuildId: 0123456789abcdef0123456789abcdef)",
  "01-01 00:00:01.000  2000  2000 F DEBUG   :       #00 pc 0000000000c0ffee  /data/app/~~a/com.x.game-1/lib/arm64/libUE4.so (BuildId: 1122aabb)",
  "01-01 00:00:01.000  2000  2000 F DEBUG   :       #01 pc 00000000000abcde  /apex/com.android.runtime/lib64/bionic/libc.so (abort+168) (BuildId: b0bf)",
}, "\n")

t.describe("android crash: tombstone frames", function()
  t.it("parses pc, module, symbol and build-id from debuggerd lines", function()
    local frames = crash.parse_frames(SAMPLE)
    t.assert_eq(#frames, 4)
    t.assert_eq(frames[1].pc, "00000000000cf3a4")
    t.assert_eq(frames[1].basename, "libc.so")
    t.assert_eq(frames[1].symbol, "__fortify_fatal(char const*, ...)+228")
    t.assert_eq(frames[1].build_id, "0123456789abcdef0123456789abcdef")
    t.assert_eq(frames[3].basename, "libUE4.so")
    t.assert_nil(frames[3].symbol)
  end)

  t.it("keeps only the most recent crash", function()
    local last = crash.last_crash(crash.parse_frames(SAMPLE))
    t.assert_eq(#last, 2)
    t.assert_eq(last[1].basename, "libUE4.so")
  end)

  t.it("parses llvm-symbolizer GNU output and rejects unknown locations", function()
    local hit = crash.parse_symbolizer("FEngineLoop::Tick()\nD:/UE/Engine/Source/Launch/Private/LaunchEngineLoop.cpp:5210\n")
    t.assert_eq(hit.func, "FEngineLoop::Tick()")
    t.assert_eq(hit.file, "D:/UE/Engine/Source/Launch/Private/LaunchEngineLoop.cpp")
    t.assert_eq(hit.lnum, 5210)
    local miss = crash.parse_symbolizer("??\n??:0\n")
    t.assert_nil(miss.file)
  end)

  t.it("symbolizes only the UE module in one process and keeps other frames verbatim", function()
    local frames = crash.last_crash(crash.parse_frames(SAMPLE))
    local seen_cmd, seen_stdin, resolved
    crash.symbolize(frames, "/host/libUE4.so", "libUE4.so", function(r) resolved = r end, {
      symbolizer = "llvm-symbolizer",
      system = function(cmd, opts, on_exit)
        seen_cmd, seen_stdin = cmd, opts.stdin
        on_exit({ code = 0, stdout = "UObject::Crash()\nD:/Game/Source/Crash.cpp:42\n" })
        return {}
      end,
    })
    t.assert_true(vim.wait(1000, function() return resolved ~= nil end, 10))
    t.assert_eq(seen_cmd[2], "--obj=/host/libUE4.so")
    t.assert_eq(seen_stdin, "0x0000000000c0ffee\n")
    local items = crash.quickfix_items(frames, resolved)
    t.assert_eq(items[1].filename, "D:/Game/Source/Crash.cpp")
    t.assert_eq(items[1].lnum, 42)
    t.assert_contains(items[2].text, "abort+168")
    t.assert_contains(items[2].text, "[unresolved]")
  end)
end)

t.describe("android package picker", function()
  local pkg = require("utils.android_package")

  t.it("parses pm list output and orders project packages before device ones", function()
    local device = pkg.parse_pm_list("package:com.b.other\r\npackage:com.x.game\n\nnoise\n")
    t.assert_eq(table.concat(device, ","), "com.b.other,com.x.game")
    local rows = pkg.candidates({ "com.x.game" }, device)
    t.assert_eq(rows[1].name, "com.x.game")
    t.assert_eq(rows[1].source, "project")
    t.assert_eq(#rows, 2, "a project package already on the device is not duplicated")
  end)

  t.it("lists device packages asynchronously and returns the chosen name", function()
    local chosen, offered
    pkg.pick({
      adb = "adb", serial = "S1",
      system = function(cmd, _, on_exit)
        t.assert_eq(table.concat(cmd, " "), "adb -s S1 shell pm list packages -3")
        on_exit({ code = 0, stdout = "package:com.x.game\n" })
        return {}
      end,
      ui_select = function(rows, _, cb) offered = rows; cb(rows[1]) end,
    }, function(name) chosen = name end)
    t.assert_true(vim.wait(1000, function() return chosen ~= nil end, 10))
    t.assert_eq(chosen, "com.x.game")
    t.assert_eq(offered[#offered].source, "manual", "manual entry stays available")
  end)
end)

t.describe("android device statusline label", function()
  local device = require("utils.android_device")

  t.it("labels the selection with the device model and clears with it", function()
    local saved = vim.g[device.global_key]
    device.set("SERIAL1", { serial = "SERIAL1", model = "Pixel_8" })
    t.assert_eq(device.status_label(), "Pixel 8")
    device.set("SERIAL2")
    t.assert_eq(device.status_label(), "SERIAL2")
    device.clear()
    t.assert_nil(device.status_label())
    if saved then device.set(saved) end
  end)
end)

t.describe("android target status token", function()
  local android = require("ue.targets.android")
  local device = require("utils.android_device")

  t.it("shows device model and package short name without a UE-level target literal", function()
    local saved = vim.g[device.global_key]
    device.set("SERIAL1", { serial = "SERIAL1", model = "Pixel_8" })
    t.assert_eq(android.status_token({ android_package = "com.x.game" }), "A:Pixel 8/game")
    device.clear()
    t.assert_eq(android.status_token({}), "A:no-device")
    if saved then device.set(saved) end
  end)
end)

t.describe("ue hub: keyboard-first command surface", function()
  local hub = require("utils.ue_hub")

  t.it("generic actions are runnable and target-owned actions join for that target only", function()
    for _, action in ipairs(hub.actions) do
      t.assert_type(action.run, "function")
      t.assert_true(action.group ~= nil and action.label ~= nil)
    end
    local android = hub.visible_actions({ platform = "Android", state = {} })
    local win = hub.visible_actions({ platform = "Win64", state = {} })
    t.assert_eq(#win, #hub.actions, "a target without hub data adds nothing")
    t.assert_true(#android > #win, "the Android target contributes its own actions")
    local groups, last = {}, nil
    for _, action in ipairs(android) do
      if action.group ~= last then
        t.assert_nil(groups[action.group], "groups stay contiguous: " .. action.group)
        groups[action.group], last = true, action.group
      end
    end
    t.assert_contains(hub.format_action(android[1]), "<leader>uH")
    local f5 = vim.tbl_filter(function(action) return action.key == "<F5>" end, android)
    t.assert_eq(#f5, 1, "the original F5 route remains available")
  end)

  t.it("hub commands reference registered user commands", function()
    require("ue").setup()
    local registered = vim.api.nvim_get_commands({})
    local checked = 0
    local function check(name)
      name = name:match("^(%S+)")
      -- ue.setup() owns UE*/Task* commands; others (NotificationHistory,
      -- NvimCoreHealth) are registered by their own modules at real startup.
      if name:match("^UE") or name:match("^Task") then
        checked = checked + 1
        t.assert_true(registered[name] ~= nil, "hub references unregistered command: " .. name)
      end
    end
    local src = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/utils/ue_hub.lua"), "\n")
    for name in src:gmatch('cmd%("(%u[%w ]+)"') do check(name) end
    local contribution = require("ue.targets.android").hub({})
    check(contribution.loop_command)
    for _, action in ipairs(contribution.actions) do check(action.command) end
    for _, field in ipairs(contribution.fields) do if field.command then check(field.command) end end
    t.assert_true(checked >= 20, "expected the hub to reference the UE command set")
  end)

  t.it("target rows and summary come from the target owner's fields", function()
    local device = require("utils.android_device")
    local saved = vim.g[device.global_key]
    device.set("SERIAL1", { serial = "SERIAL1", model = "Pixel_8" })
    local target = { project = "Game", platform = "Android", configuration = "Development",
      state = { android_package = "com.x.game" } }
    t.assert_eq(hub.target_summary(target), "Game · Android Development · Pixel 8 · com.x.game")
    t.assert_eq(#hub.target_rows(target), 4)
    device.clear()
    t.assert_contains(hub.target_summary(target), "no device")
    t.assert_eq(#hub.target_rows({ project = "Game", platform = "Win64", configuration = "", state = {} }), 2)
    if saved then device.set(saved) end
  end)

  t.it("a failure's fix runs once from one key and is then consumed", function()
    local ran = {}
    vim.api.nvim_create_user_command("UEHubFixProbe", function() ran[#ran + 1] = true end, {})
    hub.offer_fix("UEHubFixProbe", "probe")
    t.assert_eq(hub.run_fix(), "UEHubFixProbe")
    t.assert_eq(#ran, 1)
    t.assert_nil(hub.run_fix())
    vim.api.nvim_del_user_command("UEHubFixProbe")
  end)

  t.it("doctor marks missing target parts with the command that fixes them", function()
    local device = require("utils.android_device")
    local saved = vim.g[device.global_key]
    device.clear()
    local rows = hub.doctor_rows({ project = nil, platform = "Android", state = {} })
    if saved then device.set(saved) end
    local by = {}
    for _, row in ipairs(rows) do by[row.name] = row end
    t.assert_eq(by.project.ok, false)
    t.assert_eq(by.device.fix, "UESetAndroidDevice")
    t.assert_eq(by.package.fix, "UESetAndroidPackage")
    t.assert_eq(hub.debug_indicator(), "", "no indicator without a debug session")
  end)
end)

t.describe("android logcat helpers", function()
  local logcat = require("utils.android_logcat")

  t.it("cycles levels and builds the adb filterspec", function()
    t.assert_eq(logcat.next_level("V"), "D")
    t.assert_eq(logcat.next_level("E"), "V")
    t.assert_eq(#logcat.filter_args("V"), 0)
    t.assert_eq(logcat.filter_args("W")[1], "*:W")
  end)

  t.it("reads severity and source locations from log lines", function()
    t.assert_eq(logcat.line_level("01-01 00:00:00.000  1000  1001 E UE4     : boom"), "E")
    local file, lnum = logcat.parse_location("E UE4 : Assertion failed [File:D:/Game/Source/A.cpp] [Line: 42]")
    t.assert_eq(file, "D:/Game/Source/A.cpp")
    t.assert_eq(lnum, 42)
    file, lnum = logcat.parse_location("W UE4 : Runtime/Core/Private/Foo.cpp:17 something")
    t.assert_eq(file, "Runtime/Core/Private/Foo.cpp")
    t.assert_eq(lnum, 17)
    t.assert_nil(logcat.parse_location("I UE4 : nothing to see"))
  end)

  t.it("attaches buffer-local keys without touching other buffers", function()
    local buf, other = vim.api.nvim_create_buf(false, true), vim.api.nvim_create_buf(false, true)
    local cycled
    logcat.attach(buf, { level = "I", on_cycle = function(level) cycled = level end })
    local keys = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do keys[m.lhs] = m end
    t.assert_true(keys["gl"] ~= nil and keys["<CR>"] ~= nil and keys["gx"] ~= nil)
    t.assert_eq(#vim.api.nvim_buf_get_keymap(other, "n"), 0)
    keys["gl"].callback()
    t.assert_eq(cycled, "W")
  end)
end)

t.describe("history hub: searches worth finding again", function()
  local history = require("utils.history_hub")

  t.it("drops typing-pause prefixes and case duplicates, keeps order", function()
    local cleaned = history.clean_queries({ "rasterbin", "shadebin", "shadeb", "RasterBin", "persistentthread", "shade" })
    t.assert_eq(table.concat(cleaned, ","), "rasterbin,shadebin,persistentthread")
  end)

  t.it("records used queries newest-first with counts, bounded and case-insensitive", function()
    local entries = history.record_into({}, "FooBar", "grep", 100)
    entries = history.record_into(entries, "baz", "grep", 200)
    entries = history.record_into(entries, "foobar", "grep", 300)
    t.assert_eq(entries[1].query, "foobar")
    t.assert_eq(entries[1].count, 2)
    t.assert_eq(entries[2].query, "baz")
    t.assert_eq(#entries, 2)
    t.assert_eq(#history.record_into(entries, "  ", "grep", 400), 2, "blank queries are not recorded")
  end)

  t.it("puts used searches first, then cleaned older history without duplicates", function()
    local merged = history.merge({ { query = "shadebin", kind = "grep", count = 3, last = 0 } },
      { "SHADEBIN", "shadeb", "raster" })
    t.assert_eq(#merged, 2)
    t.assert_eq(merged[1].query, "shadebin")
    t.assert_eq(merged[2].query, "raster")
    t.assert_eq(merged[2].count, 0)
    t.assert_contains(history.format_entry(merged[1], 3 * 3600), "3h ×3")
    t.assert_contains(history.format_entry(merged[2], 0), "older")
  end)

  t.it("persists per project in a state file", function()
    local key = "test-" .. tostring(vim.uv.hrtime())
    history.record("VulkanRHI", "grep", key)
    history.record("vulkanrhi", "grep", key)
    local loaded = history.load(key)
    t.assert_eq(#loaded, 1)
    t.assert_eq(loaded[1].count, 2)
    os.remove(vim.fs.joinpath(vim.fn.stdpath("state"), "ue_search_history", key .. ".json"))
  end)

  t.it("every history surface has a runnable entry and a key", function()
    for _, surface in ipairs(history.surfaces) do
      t.assert_type(surface.run, "function")
      t.assert_true(type(surface.key) == "string" and surface.key ~= "")
    end
  end)
end)

t.describe("android iterate loop", function()
  local iterate = require("ue.workflows.android.iterate")
  local function steps(build_code, deploy_code, log)
    return {
      capture = function(_, done)
        done(require("ue.workflows._runtime").snapshot({ operation = "iterate", owner = "test",
          project = "/Test", target = "Android", configuration = "Test" }))
      end,
      build_so = function(done) log[#log + 1] = "build"; done(build_code) end,
      deploy_so = function(done) log[#log + 1] = "deploy"; done(deploy_code) end,
      launch = function(done) log[#log + 1] = "launch"; done(0) end,
      set_status = function(value) log.status = value end,
    }
  end
  local quiet = function() end

  t.it("runs build → deploy → debug-launch and records success with duration", function()
    local log, clock = {}, 0
    iterate.run(steps(0, 0, log), { notify = quiet, now = function() clock = clock + 21; return clock end,
      debug_launch = function(done) log[#log + 1] = "debug"; done(0) end })
    t.assert_eq(table.concat(log, ","), "build,deploy,debug")
    t.assert_contains(log.status, "LOOP✓")
  end)

  t.it("stops at the first failing step and marks the statusline", function()
    local log = {}
    iterate.run(steps(2, 0, log), { notify = quiet })
    t.assert_eq(table.concat(log, ","), "build")
    t.assert_eq(log.status, "LOOP✗")
    log = {}
    iterate.run(steps(0, 5, log), { notify = quiet })
    t.assert_eq(table.concat(log, ","), "build,deploy")
    t.assert_eq(log.status, "LOOP✗")
  end)

  t.it("a step that could not start (exit -1) still ends the loop visibly", function()
    local log, notes = {}, {}
    iterate.run(steps(-1, 0, log), { notify = function(m) notes[#notes + 1] = m end })
    t.assert_eq(table.concat(log, ","), "build")
    t.assert_eq(log.status, "LOOP✗")
    t.assert_contains(notes[#notes], "did not start")
  end)

  t.it("nodebug launches without the debugger", function()
    local log = {}
    iterate.run(steps(0, 0, log), { notify = quiet, nodebug = true, debug_launch = function() log[#log + 1] = "debug" end })
    t.assert_eq(table.concat(log, ","), "build,deploy,launch")
  end)
end)

t.describe("doctor async row checks", function()
  t.it("a selected-but-unplugged device row is rewritten to ✗ with the fix", function()
    local hub = require("utils.ue_hub")
    local row = { name = "device", ok = true, detail = "Pixel", fix = "UESetAndroidDevice" }
    t.assert_contains(hub.format_doctor_row(row), "✓ device")
    local failed = vim.tbl_extend("force", row, { ok = false, detail = "Pixel — not found" })
    local line = hub.format_doctor_row(failed)
    t.assert_contains(line, "✗ device")
    t.assert_contains(line, "→ :UESetAndroidDevice")
  end)

  t.it("android hub exposes a liveness check only when a device is selected", function()
    local devices = require("utils.android_device")
    local android = require("ue.targets.android")
    devices.clear()
    local function field() for _, f in ipairs(android.hub({}).fields) do if f.name == "device" then return f end end end
    t.assert_nil(field().check)
    devices.set("SERIAL-X")
    t.assert_eq(type(field().check), "function")
    devices.clear()
  end)
end)
