-- Read the trace ring buffer from the live nvim
local pipe = arg[1] or [[\\.\pipe\nvim.72696.0]]
local ok, ch = pcall(vim.fn.sockconnect, "pipe", pipe, { rpc = true })
if not ok or ch == 0 then io.stderr:write("FAILED\n"); vim.cmd("qa!"); return end

local r = vim.rpcrequest(ch, "nvim_exec_lua", [[
  local lf = require('utils.lsp_fallback')
  -- Use the public dump_trace if exists, but it opens a window. We want raw.
  -- Inspect upvalues via debug? Simpler: call dump_trace then read the buffer.
  -- But that opens a vsplit. Use trace ring directly via a local exposure.
  -- Workaround: dump_trace creates a buffer; capture its lines, then wipe.
  local pre_bufs = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do pre_bufs[b] = true end
  pcall(lf.dump_trace)
  local trace_buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if not pre_bufs[b] then trace_buf = b; break end
  end
  if not trace_buf then return "{}" end
  local lines = vim.api.nvim_buf_get_lines(trace_buf, 0, -1, false)
  vim.api.nvim_buf_delete(trace_buf, { force = true })
  return vim.json.encode(lines)
]], {})

local lines = vim.json.decode(r)
for _, l in ipairs(lines) do io.stdout:write(l .. "\n") end
io.stdout:flush()
vim.cmd("qa!")
