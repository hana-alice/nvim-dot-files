-- E2E test: jumplist regression for jump_to_location.
-- Picks a target file that is NOT yet in the buffer list, drives a jump,
-- snapshots jumplist before/after.
local pipe = arg[1] or [[\\.\pipe\nvim.72696.0]]
local ok, ch = pcall(vim.fn.sockconnect, "pipe", pipe, { rpc = true })
if not ok or ch == 0 then
  io.stderr:write("SOCKCONNECT FAILED: " .. tostring(ch) .. "\n")
  vim.cmd("qa!")
  return
end

local function call(lua_src, args)
  return vim.rpcrequest(ch, "nvim_exec_lua", lua_src, args or {})
end

-- Step 0: reload module
io.stdout:write("[0] reload module\n")
local rev = call([[
  package.loaded['utils.lsp_fallback'] = nil
  require('utils.lsp_fallback')
  return require('utils.lsp_fallback').MODULE_REVISION or '<no-rev>'
]])
io.stdout:write("    rev = " .. rev .. "\n")

-- Step 1: pick a target file from the cpp's #includes that is not in buf list
io.stdout:write("[1] picking unloaded target\n")
local target_path = call([[
  local candidates = {
    '<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteSceneProxy.h',
    '<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteVertexFactory.h',
    '<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteVisualizationData.h',
    '<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteDefinitions.h',
  }
  for _, p in ipairs(candidates) do
    local b = vim.fn.bufnr(p)
    if b == -1 or not vim.api.nvim_buf_is_loaded(b) then return p end
  end
  return ''
]])
io.stdout:write("    target = " .. target_path .. "\n")
if target_path == "" then
  io.stderr:write("All candidates already loaded; pick fresh ones\n")
  vim.cmd("qa!")
  return
end

-- Step 2: ensure we are in NaniteCullRaster.cpp at a known position
io.stdout:write("[2] reset source position to NaniteCullRaster.cpp:500,10\n")
call([[
  vim.cmd("buffer " .. vim.fn.bufnr('NaniteCullRaster.cpp'))
  vim.api.nvim_win_set_cursor(0, { 500, 10 })
  -- Clear any user-side spurious changes by adding a sentinel jump
  vim.cmd("normal! m'")
]])

local pre = call([[
  return vim.json.encode({
    bufname = vim.api.nvim_buf_get_name(0),
    cursor = vim.api.nvim_win_get_cursor(0),
    src_bufnr = vim.api.nvim_get_current_buf(),
  })
]])
io.stdout:write("    pre  = " .. pre .. "\n")

-- Step 3: drive jump_to_location to target, line 50, col 4, then wait IN SERVER
io.stdout:write("[3] driving jump_to_location to target line 50, with server-side wait\n")
local jump_lua = string.format([[
  local lf = require('utils.lsp_fallback')
  local loc = {
    uri = vim.uri_from_fname(%q),
    range = { start = { line = 49, character = 4 } },
  }
  print("DBG loc.uri=" .. loc.uri .. " line=" .. loc.range.start.line)
  local r = lf._test_jump_to_location(loc)
  -- Wait 300ms IN THE SERVER for deferred drift-fix (30/150ms) to fire
  vim.wait(400, function() return false end, 20)
  return tostring(r) .. " line_after=" .. tostring(vim.api.nvim_win_get_cursor(0)[1])
]], target_path)
local jr = call(jump_lua)
io.stdout:write("    jump_to_location returned: " .. jr .. "\n")

-- Step 5: snapshot jumplist
local post = call([[
  local jl = vim.fn.getjumplist()
  return vim.json.encode({
    bufname = vim.api.nvim_buf_get_name(0),
    cursor = vim.api.nvim_win_get_cursor(0),
    cur_bufnr = vim.api.nvim_get_current_buf(),
    -- Last 6 jumplist entries are most relevant
    jl_tail = (function()
      local entries = jl[1]
      local n = #entries
      local out = {}
      for i = math.max(1, n - 5), n do table.insert(out, entries[i]) end
      return out
    end)(),
    jl_pos = jl[2],
    jl_len = #jl[1],
  })
]])
io.stdout:write("[4] post = " .. post .. "\n")
io.stdout:flush()

vim.cmd("qa!")
