-- ue.dap.win64 — native Win64 DAP attach/launch via lldb-dap.
local C = require("ue.dap._common")

local M = {}

local function notify_no_adapter()
  vim.notify(
    "UEDAP win64: lldb-dap not found.\n" ..
    "Install LLVM 18+ (winget install LLVM.LLVM) or set ue.config.dap.lldb_dap_path.",
    vim.log.levels.ERROR
  )
end

-- LLDB init for UE binaries on Win64: skip stop-on-shared-library, use
-- inline breakpoint strategy, leave SIGSTOP/SIGSEGV unmoved (UE relies on
-- catching them itself).
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
    name = "UE Win64 Attach",
    request = "attach",
    _ue_session_owner = "win64",
    _ue_session_operation = "attach",
    pid = pid,
    initCommands = INIT,
  }), "UEDAP win64 attach")
end

function M.launch()
  local adapter = C.find_lldb_dap()
  if not adapter then return notify_no_adapter() end
  local program = C.prompt_binary()
  if not program then return end
  C.run(C.lldb_dap_config({
    name = "UE Win64 Launch",
    request = "launch",
    _ue_session_owner = "win64",
    _ue_session_operation = "launch",
    program = program,
    initCommands = INIT,
  }), "UEDAP win64 launch")
end

return M
