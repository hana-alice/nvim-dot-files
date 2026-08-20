local t = require("tests.harness")
local config = t.bootstrap()

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
end)
