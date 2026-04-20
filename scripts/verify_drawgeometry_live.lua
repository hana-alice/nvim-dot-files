local pipe = arg[1] or [[\.\pipe\nvim.21324.0]]
print("Connecting to: " .. pipe)
local ch = vim.fn.sockconnect("pipe", pipe, { rpc = true })
if ch == 0 then print("ERR sockconnect"); os.exit(1) end

-- Reload + clear messages
vim.rpcrequest(ch, "nvim_exec_lua", [[
  for k in pairs(package.loaded) do
    if k:match("^utils%.ue_goto") or k == "utils.lsp_fallback" then
      package.loaded[k] = nil
    end
  end
  require("utils.lsp_fallback")
  vim.cmd("messages clear")
]], {})

-- Diagnose state at cursor BEFORE calling definition()
local diag = vim.rpcrequest(ch, "nvim_exec_lua", [[
  vim.cmd("edit <PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteCullRaster.cpp")
  vim.api.nvim_win_set_cursor(0, { 6290, 4 })
  local symbol_mod = require("utils.ue_goto.symbol")
  local sym = symbol_mod.current_symbol()
  local recv = symbol_mod.current_receiver()
  local at_def, dk, dn = symbol_mod.is_at_definition_at_cursor()
  local dep, droot, dchain = symbol_mod.is_dependent_at_cursor()
  local arity, callee = nil, nil
  if symbol_mod.call_arity_at_cursor then
    arity, callee = symbol_mod.call_arity_at_cursor()
  end
  return vim.json.encode({
    sym = sym, receiver = recv,
    at_def = at_def, def_kind = dk, def_name = dn,
    dependent = dep, dep_root = droot, dep_chain = dchain,
    call_arity = arity, callee = callee,
    cur = vim.api.nvim_win_get_cursor(0),
    line = vim.api.nvim_get_current_line(),
  })
]], {})
print("=== PRE-CALL DIAG ===")
print(diag)

-- Now actually call definition() and watch for errors
vim.rpcrequest(ch, "nvim_exec_lua", [[
  local ok, err = pcall(function()
    require("utils.lsp_fallback").definition()
  end)
  if not ok then
    vim.notify("DEFINITION_CRASH: " .. tostring(err), vim.log.levels.ERROR)
    print("DEFINITION_CRASH: " .. tostring(err))
  end
]], {})
print("definition() call done, waiting 12s...")
vim.wait(12000)

-- Read messages + trace
local out = vim.rpcrequest(ch, "nvim_exec_lua", [[
  local msgs = vim.api.nvim_exec2("messages", { output = true }).output
  local p = vim.fn.stdpath("cache") .. "/ue_def_trace.log"
  local f = io.open(p, "r")
  local trace = ""
  if f then
    local content = f:read("*a"); f:close()
    local lines = vim.split(content, "\n")
    local tail = {}
    for i = math.max(1, #lines - 80), #lines do tail[#tail+1] = lines[i] end
    trace = table.concat(tail, "\n")
  end
  return vim.json.encode({
    messages = msgs,
    trace = trace,
    cursor = vim.api.nvim_win_get_cursor(0),
    bufname = vim.api.nvim_buf_get_name(0),
    line_at_cursor = vim.api.nvim_get_current_line():sub(1, 80),
  })
]], {})
print("=== POST ===")
print(out)
