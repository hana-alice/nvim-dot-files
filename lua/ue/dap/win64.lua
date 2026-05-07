-- ue.dap.win64 — native Win64 DAP attach/launch via codelldb.
--
-- Phase H scope: prompt for PID (attach) or binary (launch), spawn
-- codelldb, hand off to nvim-dap. UE-specific bits like pdb path
-- discovery and module load filters are deferred to a future phase.

local C = require("ue.dap._common")

local M = {}

local function notify_no_adapter()
  vim.notify(
    "UEDAP win64: codelldb adapter not found.\n" ..
    "Install via Mason or set ue.config.dap.codelldb_path.",
    vim.log.levels.ERROR
  )
end

function M.attach()
  local adapter = C.find_codelldb()
  if not adapter then return notify_no_adapter() end
  local pid = C.prompt_pid()
  if not pid then return end
  local cfg = C.codelldb_config({
    name = "UE Win64 Attach",
    adapter = adapter,
    request = "attach",
    pid = pid,
  })
  C.run(cfg, "UEDAP win64 attach")
end

function M.launch()
  local adapter = C.find_codelldb()
  if not adapter then return notify_no_adapter() end
  local program = C.prompt_binary()
  if not program then return end
  local cfg = C.codelldb_config({
    name = "UE Win64 Launch",
    adapter = adapter,
    request = "launch",
    program = program,
  })
  C.run(cfg, "UEDAP win64 launch")
end

return M
