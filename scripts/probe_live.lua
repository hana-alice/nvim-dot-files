-- Probe a live nvim via RPC pipe.
-- Usage: nvim --headless -u NONE --cmd "let g:pipe='\\.\pipe\nvim.NNN.0'" -S probe_live.lua
local pipe = "\\\\.\\pipe\\nvim.19212.0"
local ch = vim.fn.sockconnect("pipe", pipe, { rpc = true })
if ch == 0 then
  io.stdout:write("FAIL: could not connect to " .. pipe .. "\n")
  os.exit(1)
end

local function call(method, ...) return vim.rpcrequest(ch, method, ...) end
local function evalr(expr) return call("nvim_exec_lua", "return " .. expr, {}) end
local function exec(code)  return call("nvim_exec_lua", code, {}) end

io.stdout:write("=== probing " .. pipe .. " ===\n")

-- 1. Where is this nvim, what's its cwd?
local cwd = call("nvim_eval", "getcwd()")
io.stdout:write("cwd: " .. tostring(cwd) .. "\n")

-- 2. List loaded buffers with names + line counts (use exec, not eval-wrap)
local bufs_lua = [[
local out = {}
for _, b in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_is_loaded(b) then
    local n = vim.api.nvim_buf_get_name(b)
    if n ~= "" then
      out[#out+1] = string.format("  buf=%d lines=%d  %s", b, vim.api.nvim_buf_line_count(b), n)
    end
  end
end
return table.concat(out, "\n")
]]
local bufs = call("nvim_exec_lua", bufs_lua, {})
io.stdout:write("loaded buffers:\n" .. tostring(bufs) .. "\n")

-- 3. Check current MODULE_REVISION
local rev_lua = [[
local m = package.loaded['utils.lsp_fallback']
return (m and m.MODULE_REVISION) or 'NOT-LOADED'
]]
local rev = call("nvim_exec_lua", rev_lua, {})
io.stdout:write("module_revision (in-memory): " .. tostring(rev) .. "\n")

-- 4. Check if jumper is on disk-loadable
local can_load_lua = [[
local ok, mod = pcall(require, 'utils.ue_goto.jumper')
return tostring(ok) .. "  type(jump)=" .. (ok and type(mod.jump) or "n/a")
]]
local can_load = call("nvim_exec_lua", can_load_lua, {})
io.stdout:write("jumper module load test: " .. tostring(can_load) .. "\n")

-- 5. runtimepath
local rtp = call("nvim_eval", "&runtimepath")
io.stdout:write("rtp head:\n  " .. (rtp:sub(1, 300)) .. "...\n")

vim.fn.chanclose(ch)
io.stdout:write("=== done ===\n")
os.exit(0)
