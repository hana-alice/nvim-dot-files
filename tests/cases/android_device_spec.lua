-- Shared Android device selection and adb serial routing.

local t = require("tests.harness")
t.bootstrap()

local devices = require("utils.android_device")

local SAMPLE = table.concat({
  "List of devices attached",
  "SERIAL-001 device product:husky model:Pixel_8 device:husky transport_id:1",
  "SERIAL-002 device product:eureka model:Quest_3 device:eureka transport_id:2",
  "SERIAL-OFF offline product:old model:Old_Phone transport_id:3",
  "SERIAL-AUTH unauthorized usb:1-2 transport_id:4",
}, "\n")

t.describe("utils.android_device: adb devices -l", function()
  t.it("解析 serial/status/model 且过滤 daemon/header", function()
    local rows = devices.parse_devices("* daemon started successfully *\n" .. SAMPLE)
    t.assert_eq(#rows, 4)
    t.assert_eq(rows[1].serial, "SERIAL-001")
    t.assert_eq(rows[1].status, "device")
    t.assert_eq(rows[1].model, "Pixel_8")
    t.assert_eq(rows[1].product, "husky")
  end)

  t.it("ready_devices 只保留 status=device", function()
    local ready = devices.ready_devices(devices.parse_devices(SAMPLE))
    t.assert_eq(#ready, 2)
    t.assert_eq(ready[1].serial, "SERIAL-001")
    t.assert_eq(ready[2].serial, "SERIAL-002")
  end)

  t.it("picker label 同时展示可读名称和 serial", function()
    local row = devices.parse_devices(SAMPLE)[1]
    t.assert_eq(devices.format_item(row), "Pixel 8  [SERIAL-001]")
    t.assert_eq(devices.format_item({ serial = "X", device = "generic_arm64" }),
      "generic arm64  [X]")
  end)
end)

t.describe("utils.android_device: session-global picker", function()
  t.it("即使只有一台 ready device 也打开 picker，选择后写 vim.g", function()
    devices.clear()
    local picker_calls, label, selected = 0, nil, nil
    devices.select({
      devices = { { serial = "ONLY-ONE", status = "device", model = "Pixel_9" } },
      ui_select = function(items, opts, cb)
        picker_calls = picker_calls + 1
        label = opts.format_item(items[1])
        cb(items[1])
      end,
    }, function(serial) selected = serial end)

    t.assert_eq(picker_calls, 1)
    t.assert_eq(label, "Pixel 9  [ONLY-ONE]")
    t.assert_eq(selected, "ONLY-ONE")
    t.assert_eq(vim.g.ue_android_device_serial, "ONLY-ONE")
    devices.clear()
  end)

  t.it("offline/unauthorized 不进入 picker", function()
    devices.clear()
    local picker_calls, message, callback_serial = 0, nil, "unset"
    devices.select({
      output = table.concat({
        "List of devices attached",
        "OFF offline model:Old",
        "AUTH unauthorized model:New",
      }, "\n"),
      ui_select = function() picker_calls = picker_calls + 1 end,
      notify = function(msg) message = msg end,
    }, function(serial) callback_serial = serial end)

    t.assert_eq(picker_calls, 0)
    t.assert_nil(callback_serial)
    t.assert_contains(message or "", "OFF")
    t.assert_contains(message or "", "unauthorized")
    t.assert_nil(devices.get())
  end)

  t.it("取消重新选择时保留原全局 serial", function()
    devices.set("SERIAL-OLD")
    local callback_serial, callback_err = "unset", nil
    devices.select({
      devices = { { serial = "SERIAL-NEW", status = "device", model = "New" } },
      ui_select = function(_, _, cb) cb(nil) end,
    }, function(serial, _, err)
      callback_serial, callback_err = serial, err
    end)

    t.assert_nil(callback_serial)
    t.assert_eq(callback_err, "cancelled")
    t.assert_eq(devices.get(), "SERIAL-OLD")
    devices.clear()
  end)

  t.it("ensure 有全局值时不枚举、不打开 picker", function()
    devices.set("SERIAL-SET")
    local picker_calls, got = 0, nil
    local immediate = devices.ensure({
      devices = { { serial = "OTHER", status = "device" } },
      ui_select = function() picker_calls = picker_calls + 1 end,
    }, function(serial) got = serial end)

    t.assert_eq(immediate, "SERIAL-SET")
    t.assert_eq(got, "SERIAL-SET")
    t.assert_eq(picker_calls, 0)
    devices.clear()
  end)
end)

t.describe("utils.android_device: adb argv", function()
  t.it("设备定向命令固定为 adb -s <serial> ...", function()
    local cmd = assert(devices.adb_args("adb", "SERIAL-002", { "install", "-r", "Game.apk" }))
    t.assert_eq(table.concat(cmd, " "), "adb -s SERIAL-002 install -r Game.apk")
  end)

  t.it("serial 缺失时拒绝生成危险的裸 adb 命令", function()
    local cmd, err = devices.adb_args("adb", nil, { "install", "-r", "Game.apk" })
    t.assert_nil(cmd)
    t.assert_contains(err or "", ":UESetAndroidDevice")
  end)

  t.it("UEInstallAndroid 与 UELaunch 都显式路由到所选 serial", function()
    local install = assert(require("ue")._android_install_argv_for_test(
      "adb", "SERIAL-002", "Game.apk"))
    t.assert_eq(table.concat(install, " "), "adb -s SERIAL-002 install -r Game.apk")

    local launch = assert(require("utils.ue_launch")._android_launch_argv_for_test(
      "adb", "SERIAL-002", "com.example.game"))
    t.assert_eq(table.concat(launch, " "), table.concat({
      "adb", "-s", "SERIAL-002", "shell", "monkey", "-p", "com.example.game",
      "-c", "android.intent.category.LAUNCHER", "1",
    }, " "))
  end)

  t.it("Android logcat spec 不取第一台设备，脚本固定使用全局 serial", function()
    devices.set("SERIAL-LOG")
    local env = {
      is_file = function() return true end,
      powershell_quote = function(value) return "'" .. tostring(value) .. "'" end,
      trim = function(value)
        return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
      end,
      update_state_field = function() error("unexpected state write") end,
    }
    local spec, err = require("utils.ue_logs")._android_logcat_spec_for_test(env, {
      engine_root = "D:/UE",
      state = { android_package = "com.example.game" },
    })
    t.assert_nil(err)
    t.assert_eq(spec.source_id, "SERIAL-LOG:com.example.game")
    t.assert_contains(spec.cmd[#spec.cmd], "$serial = 'SERIAL-LOG'")
    t.assert_contains(spec.cmd[#spec.cmd], "& $adb -s $serial logcat")
    devices.clear()
  end)
end)

t.describe("ue.dap.android: global serial precedence", function()
  local android = require("ue.dap.android")

  t.it("显式 context/opts > 全局选择；缺值时不猜 last session", function()
    devices.set("SERIAL-GLOBAL")
    t.assert_eq(android._resolve_session_serial_for_test(
      { android_serial = "SERIAL-CONTEXT" }, { serial = "SERIAL-OPTS" }),
      "SERIAL-CONTEXT")
    t.assert_eq(android._resolve_session_serial_for_test(
      {}, { serial = "SERIAL-OPTS" }), "SERIAL-OPTS")
    t.assert_eq(android._resolve_session_serial_for_test({}, {}), "SERIAL-GLOBAL")
    devices.set("SERIAL-SWITCHED")
    t.assert_eq(android._resolve_session_serial_for_test({}, {}), "SERIAL-SWITCHED",
      "再次全局选择后下一次 DAP 操作必须使用新 serial")
    devices.clear()
    t.assert_nil(android._resolve_session_serial_for_test({}, {}),
      "普通 attach/launch 缺全局 serial 时必须开 picker，不得猜历史 session")
  end)

  t.it("K30 connect URL 与全局选择解析出的 serial 一致", function()
    devices.set("SERIAL-K30")
    local serial = android._resolve_session_serial_for_test({}, {}, nil)
    local commands = android._attach_commands_for_test({
      symbol_lib = "D:/symbols/libUE4.so",
      serial = serial,
      port = 5039,
      pid = 1234,
    })
    t.assert_contains(commands, "platform connect connect://[SERIAL-K30]:5039")
    devices.clear()
  end)
end)
