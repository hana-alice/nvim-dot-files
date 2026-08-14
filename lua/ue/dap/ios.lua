-- ue.dap.ios — explicit unsupported boundary for native iOS DAP.
--
-- A macOS host does not make an iOS target a Mac process. Real device attach
-- needs a separate CoreDevice/debugserver lifecycle, so this module must never
-- fall through to the Mac target handler.

return {
  attach = function()
    vim.notify(
      "UEDAP ios: native iOS device attach is not implemented; Mac DAP is not a valid fallback.",
      vim.log.levels.WARN
    )
  end,
  launch = function()
    vim.notify(
      "UEDAP ios: debug launch is not implemented. :UELaunch supports app launch without DAP.",
      vim.log.levels.WARN
    )
  end,
}
