-- ue.dap.ios — iOS DAP attach via lldb-dap.
--
-- Real iOS attach needs `xcrun devicectl` plus an Xcode debugserver
-- forwarded over USB; that orchestration is out of scope here. Forward
-- to the macOS handler so :UEDAPAttach ios doesn't WARN, with a clear
-- notify so the user knows it's a passthrough.

local mac = require("ue.dap.mac")

return {
  attach = function()
    vim.notify(
      "UEDAP ios: forwarding to mac handler. Native iOS device attach " ..
      "(USB/Wi-Fi via Xcode + lldb-dap remote-platform) is a future phase.",
      vim.log.levels.INFO
    )
    mac.attach()
  end,
  launch = function()
    vim.notify(
      "UEDAP ios: launch unsupported. Use Xcode `xcrun devicectl` to install + " ..
      "launch, then UEDAPAttach ios.",
      vim.log.levels.WARN
    )
  end,
}
