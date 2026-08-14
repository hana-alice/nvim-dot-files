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
    local script = vim.fn.stdpath("config") .. "/scripts/ue_ios_cpp_iteration.zsh"
    local result = run({ "/bin/zsh", "-n", script })
    t.assert_eq(result.code, 0, result.stderr)
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
    t.assert_contains(third.stdout, "AOT cache miss")
    t.assert_contains(fourth.stdout, "AOT cache miss")
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
      '  mkdir -p "$4"',
      '  print -r -- generated > "$4/marker"',
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
