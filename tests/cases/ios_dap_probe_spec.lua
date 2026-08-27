local t = require("tests.harness")
local config = t.bootstrap()

local function write_file(path, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
end

local function smoke_fixture()
  local root = vim.fn.tempname() .. "-ios-dap-smoke"
  local project_dir = root .. "/SecretProject"
  local uproject = project_dir .. "/SecretProject.uproject"
  local source = project_dir .. "/Source/Secret/Hidden.cpp"
  local binary = project_dir .. "/Binaries/IOS/SecretProject"
  local dsym = project_dir .. "/Binaries/IOS/SecretProject.dSYM"
  local cwd = project_dir .. "/Intermediate/Headless"
  vim.fn.mkdir(project_dir, "p")
  vim.fn.mkdir(dsym, "p")
  vim.fn.mkdir(cwd, "p")
  write_file(uproject, { '{"FileVersion":3}' })
  write_file(source, { "int HiddenValue() {", "  return 42;", "}" })
  write_file(binary, { "binary" })
  write_file(dsym .. "/Info.plist", { "plist" })
  return {
    root = root,
    project_dir = project_dir,
    uproject = uproject,
    source = source,
    binary = binary,
    dsym = dsym,
    cwd = cwd,
  }
end

local function run_smoke(env)
  local output = vim.fn.tempname() .. ".json"
  local merged_env = vim.tbl_extend("force", {
    NVIM_IOS_DAP_SMOKE_RESULT = output,
    NVIM_IOS_DAP_SMOKE_TIMEOUT_MS = "500",
  }, env or {})
  local result = vim
    .system({
      vim.v.progpath,
      "--headless",
      "-u",
      "NONE",
      "-l",
      config .. "/tools/nvim_ios_dap_smoketest.lua",
    }, {
      env = merged_env,
      text = true,
    })
    :wait()
  local encoded = table.concat(vim.fn.readfile(output), "\n")
  return result, vim.json.decode(encoded), encoded
end

t.describe("iOS DAP protocol probe", function()
  t.it("passes its parser and redaction self-test", function()
    local python = vim.fn.exepath("python3")
    if python == "" then return end
    local output = vim.fn.tempname()
    local result = vim.system({
      python,
      config .. "/tools/ios_dap_protocol_probe.py",
      "self-test",
      "--output",
      output,
    }, { text = true }):wait()

    t.assert_eq(result.code, 0, result.stderr)
    local payload = vim.json.decode(result.stdout)
    local persisted = vim.json.decode(table.concat(vim.fn.readfile(output), "\n"))
    local encoded = vim.json.encode(persisted.attach_identity_example)
    t.assert_eq(payload.schema, "ue-ios-dap-probe-v1")
    t.assert_eq(payload.status, "passed")
    t.assert_eq(persisted.schema, "ue-ios-dap-probe-v1")
    t.assert_eq(persisted.status, "passed")
    t.assert_contains(encoded, '"pid_digest"')
    t.assert_false(encoded:find('"pid"', 1, true) ~= nil)
    t.assert_false(encoded:find("4242", 1, true) ~= nil)
  end)

  t.it("keeps identities parameterized and detach non-terminating", function()
    local source = table.concat(vim.fn.readfile(config .. "/tools/ios_dap_protocol_probe.py"), "\n")
    t.assert_contains(source, 'add_argument("--device", required=True)')
    t.assert_contains(source, 'add_argument("--bundle-id", required=True)')
    t.assert_contains(source, '"pid_digest": pid_digest(args.pid)')
    t.assert_contains(source, '"terminateDebuggee": False')
    t.assert_contains(source, 'settings set target.memory-module-load-level minimal')
    t.assert_contains(source, 'settings set symbols.enable-external-lookup false')
    t.assert_contains(source, 'target symbols add " + lldb_quote(args.dsym)')
    t.assert_contains(source, '"loaded iOS executable UUID does not match the local debug artifact"')
    t.assert_contains(source, "max_bootstrap_stops = 8")
    t.assert_false(source:find("/Users/", 1, true) ~= nil)
    t.assert_false(source:find("Mac PID attach", 1, true) ~= nil)
    t.assert_false(source:find('"pid": args.pid', 1, true) ~= nil)
  end)

  t.it("keeps the legacy backend explicit and redacts both Apple UDID forms", function()
    local source = table.concat(vim.fn.readfile(config .. "/tools/ios_dap_protocol_probe.py"), "\n")
    t.assert_contains(source, '"legacy-preflight"')
    t.assert_contains(source, 'legacy.add_argument("--device", required=True)')
    t.assert_contains(source, 'legacy.add_argument("--symbols", required=True)')
    t.assert_contains(source, "legacy-backend-requires-pre-ios17")
    t.assert_contains(source, "APPLE_DEVICE_ID_RE")
    t.assert_contains(source, "<redacted-device-id>")
  end)

  t.it("requires an explicit smoke device instead of auto-selecting one", function()
    local fixture = smoke_fixture()
    local device = "00008030-001C195E0A42002E"
    local bundle = "com.secret.game"
    local result, payload, encoded = run_smoke({
      NVIM_IOS_DAP_SMOKE_MODE = "attach",
      NVIM_IOS_DAP_SMOKE_BACKEND = "coredevice",
      NVIM_IOS_DAP_SMOKE_BUNDLE = bundle,
      NVIM_IOS_DAP_SMOKE_BINARY = fixture.binary,
      NVIM_IOS_DAP_SMOKE_DSYM = fixture.dsym,
      NVIM_IOS_DAP_SMOKE_SOURCE = fixture.source,
      NVIM_IOS_DAP_SMOKE_LINE = "2",
      NVIM_IOS_DAP_SMOKE_PID = "4242",
      NVIM_IOS_DAP_SMOKE_PROJECT = fixture.project_dir,
      NVIM_IOS_DAP_SMOKE_CWD = fixture.cwd,
      NVIM_IOS_DAP_SMOKE_EXPR = 'FString(TEXT("secret"))',
    })

    t.assert_eq(result.code, 0, result.stderr)
    t.assert_eq(payload.status, "error")
    t.assert_contains(payload.error.message, "NVIM_IOS_DAP_SMOKE_DEVICE")
    t.assert_contains(payload.error.message, "never auto-selects the first device")
    t.assert_true(payload.identity.device_digest == nil)
    t.assert_true(payload.identity.bundle_digest ~= nil)
    t.assert_true(payload.identity.pid_digest ~= nil)
    t.assert_false(encoded:find(device, 1, true) ~= nil)
    t.assert_false(encoded:find(bundle, 1, true) ~= nil)
    t.assert_false(encoded:find("4242", 1, true) ~= nil)
    t.assert_false(encoded:find(fixture.project_dir, 1, true) ~= nil)
    t.assert_false(encoded:find(fixture.source, 1, true) ~= nil)
  end)

  t.it("passes explicit coredevice opts and persists only redacted smoke evidence", function()
    local source = table.concat(vim.fn.readfile(config .. "/tools/nvim_ios_dap_smoketest.lua"), "\n")
    t.assert_contains(source, "NVIM_IOS_DAP_SMOKE_DEVICE")
    t.assert_contains(source, "NVIM_IOS_DAP_SMOKE_BACKEND")
    t.assert_contains(source, "NVIM_IOS_DAP_SMOKE_BINARY")
    t.assert_contains(source, "NVIM_IOS_DAP_SMOKE_DSYM")
    t.assert_contains(source, "NVIM_IOS_DAP_SMOKE_SOURCE")
    t.assert_contains(source, 'require("ue.dap.ios")[mode]({')
    t.assert_contains(source, "device_id = device_id")
    t.assert_contains(source, "device_backend = backend")
    t.assert_contains(source, "bundle_id = bundle_id")
    t.assert_contains(source, "binary = binary_path")
    t.assert_contains(source, "dsym = dsym_path")
    t.assert_contains(source, "source = target_source")
    t.assert_contains(source, "line = target_line")
    t.assert_contains(source, "continue_in_flight")
    t.assert_contains(source, "non_breakpoint_stops")
    t.assert_contains(source, "max_bootstrap_stops")
    t.assert_false(source:find("local continued = false", 1, true) ~= nil)

    local fixture = smoke_fixture()
    local device = "00008101-0011223344556677"
    local bundle = "com.secret.attach"
    local expression = "SecretNamespace::Reveal(4242)"
    local result, payload, encoded = run_smoke({
      NVIM_IOS_DAP_SMOKE_MODE = "bogus",
      NVIM_IOS_DAP_SMOKE_DEVICE = device,
      NVIM_IOS_DAP_SMOKE_BACKEND = "coredevice",
      NVIM_IOS_DAP_SMOKE_BUNDLE = bundle,
      NVIM_IOS_DAP_SMOKE_BINARY = fixture.binary,
      NVIM_IOS_DAP_SMOKE_DSYM = fixture.dsym,
      NVIM_IOS_DAP_SMOKE_SOURCE = fixture.source,
      NVIM_IOS_DAP_SMOKE_LINE = "2",
      NVIM_IOS_DAP_SMOKE_PID = "4242",
      NVIM_IOS_DAP_SMOKE_PROJECT = fixture.uproject,
      NVIM_IOS_DAP_SMOKE_CWD = fixture.cwd,
      NVIM_IOS_DAP_SMOKE_EXPR = expression,
    })

    t.assert_eq(result.code, 0, result.stderr)
    t.assert_eq(payload.status, "error")
    t.assert_eq(payload.target.source.name, "Hidden.cpp")
    t.assert_eq(payload.target.line, 2)
    t.assert_true(payload.identity.device_digest ~= nil)
    t.assert_true(payload.identity.bundle_digest ~= nil)
    t.assert_true(payload.identity.pid_digest ~= nil)
    t.assert_eq(payload.identity.binary.name, "SecretProject")
    t.assert_eq(payload.identity.dsym.name, "SecretProject.dSYM")
    t.assert_eq(payload.identity.project.name, "SecretProject.uproject")
    t.assert_eq(payload.identity.cwd.name, "Headless")
    t.assert_true(payload.identity.expression_digest ~= nil)
    t.assert_false(encoded:find(device, 1, true) ~= nil)
    t.assert_false(encoded:find(bundle, 1, true) ~= nil)
    t.assert_false(encoded:find("4242", 1, true) ~= nil)
    t.assert_false(encoded:find(expression, 1, true) ~= nil)
    t.assert_false(encoded:find(fixture.binary, 1, true) ~= nil)
    t.assert_false(encoded:find(fixture.dsym, 1, true) ~= nil)
    t.assert_false(encoded:find(fixture.uproject, 1, true) ~= nil)
    t.assert_false(encoded:find(fixture.cwd, 1, true) ~= nil)
  end)

  t.it("keeps persisted CoreDevice evidence free of raw identities and personal paths", function()
    local evidence_dir = config .. "/tools/evidence/ios-dap"
    for _, name in ipairs({
      "coredevice-raw-attach.current.result.json",
      "coredevice-production-attach.current.result.json",
      "coredevice-production-launch.current.result.json",
    }) do
      local encoded = table.concat(vim.fn.readfile(evidence_dir .. "/" .. name), "\n")
      t.assert_false(encoded:find('"device_id"', 1, true) ~= nil, name)
      t.assert_false(encoded:find('"bundle_id"', 1, true) ~= nil, name)
      t.assert_false(encoded:find('"pid"', 1, true) ~= nil, name)
      t.assert_false(encoded:find("/Users/", 1, true) ~= nil, name)
      t.assert_false(encoded:find('"com.', 1, true) ~= nil, name)
    end
  end)
end)
