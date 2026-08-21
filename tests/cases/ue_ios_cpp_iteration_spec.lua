local t = require("tests.harness")
t.bootstrap()

local function write_executable(path, lines)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile(lines, path)
  assert(vim.uv.fs_chmod(path, 493))
end

local function run(args, env)
  return vim.system(args, {
    cwd = vim.fn.stdpath("config"),
    env = env,
    text = true,
  }):wait()
end

t.describe("iOS C++ iteration script", function()
  t.it("passes zsh syntax validation", function()
    if vim.uv.os_uname().sysname ~= "Darwin" then return end
    for _, name in ipairs({ "ue_ios_cpp_iteration.zsh", "ue_ios_legacy_launch.zsh" }) do
      local script = vim.fn.stdpath("config") .. "/scripts/" .. name
      local result = run({ "/bin/zsh", "-n", script })
      t.assert_eq(result.code, 0, name .. ": " .. tostring(result.stderr))
    end
  end)

  t.it("launches an installed legacy app and publishes verified process identity", function()
    if vim.uv.os_uname().sysname ~= "Darwin" then return end

    local root = vim.fn.tempname() .. " ios legacy launch"
    local app = root .. "/Prepared Client.app"
    local ios_deploy = root .. "/fake-ios-deploy.zsh"
    local args_log = root .. "/ios-deploy.args"
    local output = root .. "/launch.json"
    local script = vim.fn.stdpath("config") .. "/scripts/ue_ios_legacy_launch.zsh"
    vim.fn.mkdir(app, "p")
    vim.fn.writefile({
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
      '<plist version="1.0"><dict>',
      '<key>CFBundleIdentifier</key><string>com.example.legacy</string>',
      '</dict></plist>',
    }, app .. "/Info.plist")
    write_executable(ios_deploy, {
      "#!/bin/zsh",
      '[[ -n "${UE_TEST_ARGS_LOG-}" ]] && print -r -- "$*" >> "$UE_TEST_ARGS_LOG"',
      'if [[ " $* " == *" --justlaunch "* ]]; then',
      '  if [[ -n "${UE_TEST_FAIL_LAUNCH-}" ]]; then',
      '    print -r -- "Timed out waiting for device"',
      "    exit 253",
      "  fi",
      '  print -r -- "Application launched"',
      "  exit 0",
      "fi",
      'if [[ " $* " == *" --get_pid "* ]]; then',
      '  print -r -- "pid: 4242"',
      "  exit 0",
      "fi",
      "exit 9",
    })

    local argv = {
      "/bin/zsh", script,
      "--ios-deploy", ios_deploy,
      "--device", "00008101-000C699E2640001E",
      "--bundle-id", "com.example.legacy",
      "--app", app,
      "--json-output", output,
    }
    local result = run(argv)
    local decoded = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
    local network_argv = vim.deepcopy(argv)
    vim.list_extend(network_argv, { "--transport", "network" })
    local network = run(network_argv, { UE_TEST_ARGS_LOG = args_log })
    local network_args = table.concat(vim.fn.readfile(args_log), "\n")
    local failed = run(argv, { UE_TEST_FAIL_LAUNCH = "1" })
    vim.fn.delete(root, "rf")

    t.assert_eq(result.code, 0, result.stderr)
    t.assert_eq(decoded.deviceIdentifier, "00008101-000C699E2640001E")
    t.assert_eq(decoded.bundleIdentifier, "com.example.legacy")
    t.assert_eq(decoded.processIdentifier, 4242)
    t.assert_contains(result.stdout, "IOS app running")
    t.assert_eq(network.code, 0, network.stderr)
    t.assert_false(network_args:find("--no-wifi", 1, true) ~= nil)
    t.assert_eq(failed.code, 1)
    t.assert_contains(failed.stderr, "Timed out waiting for device")
  end)

  t.it("skips AOT only after a successful fingerprinted build and invalidates changed inputs or outputs", function()
    if vim.uv.os_uname().sysname ~= "Darwin" then return end

    local root = vim.fn.tempname() .. " ios cpp iteration"
    local project = root .. "/Project"
    local plugin = project .. "/Plugins/AotPlugin"
    local cache = root .. "/Cache"
    local output_dir = plugin .. "/ThirdParty/mono/lib/IOS/Release"
    local env_log = root .. "/aot-env.log"
    local script = vim.fn.stdpath("config") .. "/scripts/ue_ios_cpp_iteration.zsh"
    local build = root .. "/fake-build.zsh"
    local xcrun = root .. "/fake-xcrun.zsh"

    vim.fn.mkdir(plugin .. "/Source/AotPlugin", "p")
    vim.fn.mkdir(project .. "/Content/SampleGame/ScriptAssemblies", "p")
    vim.fn.mkdir(plugin .. "/ThirdParty/mono/runtime/IOS/Release", "p")
    vim.fn.mkdir(plugin .. "/Tools/AOTCompiler/IOS/arm64", "p")
    vim.fn.mkdir(plugin .. "/Tools/AssmblySourcePostprocess", "p")
    vim.fn.mkdir(output_dir, "p")
    vim.fn.writefile({ 'Environment.GetEnvironmentVariable("bSkipAOTProcess")' },
      plugin .. "/Source/AotPlugin/AotPlugin.build.cs")
    vim.fn.writefile({ "game-v1" }, project .. "/Content/SampleGame/ScriptAssemblies/Game.dll")
    vim.fn.writefile({ "runtime" }, plugin .. "/ThirdParty/mono/runtime/IOS/Release/System.Runtime.dll")
    vim.fn.writefile({ "compiler" }, plugin .. "/Tools/AOTCompiler/IOS/arm64/mono-aot-cross")
    vim.fn.writefile({ "postprocess" }, plugin .. "/Tools/AssmblySourcePostprocess/run.sh")

    write_executable(xcrun, {
      "#!/bin/zsh",
      "print -r -- /Fake/iPhoneOS.sdk",
    })
    write_executable(build, {
      "#!/bin/zsh",
      'print -r -- "${bSkipAOTProcess-unset}" >> "$UE_TEST_ENV_LOG"',
      'print -r -- framework > "$UE_TEST_OUTPUT_DIR/Game.embeddedframework.zip"',
    })

    local argv = {
      "/bin/zsh", script, "build",
      "--project-dir", project,
      "--cache-dir", cache,
      "--target", "SampleGame",
      "--configuration", "Development",
      "--xcrun", xcrun,
      "--", build,
    }
    local env = {
      UE_TEST_ENV_LOG = env_log,
      UE_TEST_OUTPUT_DIR = output_dir,
      bSkipAOTProcess = "true",
      bDisableAOT = "true",
    }

    local first = run(argv, env)
    local second = run(argv, env)
    vim.fn.writefile({ "tampered" }, output_dir .. "/Game.embeddedframework.zip")
    local third = run(argv, env)
    vim.fn.writefile({ "game-v2" }, project .. "/Content/SampleGame/ScriptAssemblies/Game.dll")
    local fourth = run(argv, env)
    local observed = vim.fn.readfile(env_log)
    vim.fn.delete(root, "rf")

    t.assert_eq(first.code, 0, first.stderr)
    t.assert_eq(second.code, 0, second.stderr)
    t.assert_eq(third.code, 0, third.stderr)
    t.assert_eq(fourth.code, 0, fourth.stderr)
    t.assert_eq(table.concat(observed, ","), "unset,true,unset,unset")
    t.assert_contains(first.stdout, "AOT cache miss")
    t.assert_contains(second.stdout, "AOT cache hit")
    t.assert_contains(second.stdout, "reused 5, hashed 0")
    t.assert_contains(third.stdout, "AOT cache miss")
    t.assert_contains(fourth.stdout, "AOT cache miss")
    t.assert_contains(fourth.stdout, "reused 4, hashed 1")
  end)

  t.it("generates a dSYM and prints both UUID probes", function()
    if vim.uv.os_uname().sysname ~= "Darwin" then return end

    local root = vim.fn.tempname() .. " ios symbols"
    local binary = root .. "/SampleGame"
    local script = vim.fn.stdpath("config") .. "/scripts/ue_ios_cpp_iteration.zsh"
    local xcrun = root .. "/fake-xcrun.zsh"
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "macho" }, binary)
    write_executable(xcrun, {
      "#!/bin/zsh",
      'if [[ "$1" == "dsymutil" ]]; then',
      '  [[ "$2 $3 $4" == "--linker parallel --verify-dwarf=output" ]] || exit 8',
      '  mkdir -p "$7"',
      '  print -r -- generated > "$7/marker"',
      "  exit 0",
      "fi",
      'if [[ "$1" == "dwarfdump" ]]; then',
      '  print -r -- "UUID: TEST $3"',
      "  exit 0",
      "fi",
      "exit 9",
    })

    local result = run({
      "/bin/zsh", script, "symbols",
      "--xcrun", xcrun,
      "--binary", binary,
    })
    local dsym_exists = vim.uv.fs_stat(binary .. ".dSYM") ~= nil
    vim.fn.delete(root, "rf")

    t.assert_eq(result.code, 0, result.stderr)
    t.assert_true(dsym_exists)
    t.assert_contains(result.stdout, "Binary UUID")
    t.assert_contains(result.stdout, "dSYM UUID")
    t.assert_contains(result.stdout, "UUID: TEST")
  end)
end)
