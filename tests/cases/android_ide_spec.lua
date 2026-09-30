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
