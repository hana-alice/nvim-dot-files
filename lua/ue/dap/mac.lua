-- ue.dap.mac — native macOS DAP attach/launch via codelldb.
local C = require("ue.dap._common")

local M = {}

local function notify_no_adapter()
  vim.notify(
    "UEDAP mac: codelldb adapter not found.\n" ..
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
    name = "UE Mac Attach", adapter = adapter, request = "attach", pid = pid,
  }), "UEDAP mac attach")
end

function M.launch()
  local adapter = C.find_codelldb()
  if not adapter then return notify_no_adapter() end
  local program = C.prompt_binary()
  if not program then return end
  C.run(C.codelldb_config({
    name = "UE Mac Launch", adapter = adapter, request = "launch", program = program,
  }), "UEDAP mac launch")
end

return M
