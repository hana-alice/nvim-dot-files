-- ue.dap.linux — native Linux DAP attach/launch via lldb-dap.
local C = require("ue.dap._common")

local M = {}

local function notify_no_adapter()
  vim.notify(
    "UEDAP linux: lldb-dap not found.\n" ..
    "Install LLVM 18+ (e.g. apt install lldb-18) or set ue.config.dap.lldb_dap_path.",
    vim.log.levels.ERROR
  )
end

local INIT = {
  "settings set stop-disassembly-display never",
  "settings set target.inline-breakpoint-strategy always",
  "settings set target.move-to-nearest-code true",
  "settings set target.process.stop-on-sharedlibrary-events false",
}

function M.attach()
  local adapter = C.find_lldb_dap()
  if not adapter then return notify_no_adapter() end
  local pid = C.prompt_pid()
  if not pid then return end
  C.run(C.lldb_dap_config({
    name = "UE Linux Attach", request = "attach", pid = pid, initCommands = INIT,
  }), "UEDAP linux attach")
end

function M.launch()
  local adapter = C.find_lldb_dap()
  if not adapter then return notify_no_adapter() end
  local program = C.prompt_binary()
  if not program then return end
  C.run(C.lldb_dap_config({
    name = "UE Linux Launch", request = "launch", program = program, initCommands = INIT,
  }), "UEDAP linux launch")
end

return M
