-- ue.dap.linux — native Linux DAP attach/launch via codelldb.
local C = require("ue.dap._common")

local M = {}

local function notify_no_adapter()
  vim.notify(
    "UEDAP linux: codelldb adapter not found.\n" ..
    "Install via Mason or set ue.config.dap.codelldb_path.",
    vim.log.levels.ERROR
  )
end

function M.attach()
  local adapter = C.find_codelldb()
  if not adapter then return notify_no_adapter() end
  local pid = C.prompt_pid()
  if not pid then return end
  C.run(C.codelldb_config({
    name = "UE Linux Attach", adapter = adapter, request = "attach", pid = pid,
  }), "UEDAP linux attach")
end

function M.launch()
  local adapter = C.find_codelldb()
  if not adapter then return notify_no_adapter() end
  local program = C.prompt_binary()
  if not program then return end
  C.run(C.codelldb_config({
    name = "UE Linux Launch", adapter = adapter, request = "launch", program = program,
  }), "UEDAP linux launch")
end

return M
