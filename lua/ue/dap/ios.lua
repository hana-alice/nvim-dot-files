-- ue.dap.ios — iOS DAP attach via codelldb.
--
-- Phase H scope: thin wrapper over the macOS module since real iOS
-- debugging needs Xcode-side device attach plumbing that doesn't fit
-- in this commit. Registering it now means `:UEDAPAttach ios` doesn't
-- WARN, and the eventual real handler can swap in without touching
-- the dispatch table.

local mac = require("ue.dap.mac")

return {
  attach = function()
    vim.notify(
      "UEDAP ios: forwarding to mac handler. Real iOS attach (USB/Wi-Fi via Xcode toolchain) is a future phase.",
      vim.log.levels.INFO
    )
    mac.attach()
  end,
  launch = function()
    vim.notify(
      "UEDAP ios: launch unsupported. Use Xcode `xcrun devicectl` to install + launch, then UEDAPAttach ios.",
      vim.log.levels.WARN
    )
  end,
}
