local t = require("tests.harness")
local config = t.bootstrap()

t.describe("iOS DAP protocol probe", function()
  t.it("passes its parser and redaction self-test", function()
    local python = vim.fn.exepath("python3")
    if python == "" then return end
    local result = vim.system({
      python,
      config .. "/tools/ios_dap_protocol_probe.py",
      "self-test",
    }, { text = true }):wait()

    t.assert_eq(result.code, 0, result.stderr)
    local payload = vim.json.decode(result.stdout)
    t.assert_eq(payload.schema, "ue-ios-dap-probe-v1")
    t.assert_eq(payload.status, "passed")
  end)

  t.it("keeps identities parameterized and detach non-terminating", function()
    local source = table.concat(vim.fn.readfile(config .. "/tools/ios_dap_protocol_probe.py"), "\n")
    t.assert_contains(source, 'add_argument("--device", required=True)')
    t.assert_contains(source, 'add_argument("--bundle-id", required=True)')
    t.assert_contains(source, '"terminateDebuggee": False')
    t.assert_false(source:find("/Users/", 1, true) ~= nil)
    t.assert_false(source:find("Mac PID attach", 1, true) ~= nil)
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
