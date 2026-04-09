-- Test that _reapply_breakpoints uses single set_command, not _dap_try_set_breakpoint
-- cd <PROJ_DRIVE>\uetemp
-- nvim --headless -u $LOCALAPPDATA\nvim\init.lua +"luafile $LOCALAPPDATA/nvim/tools/test_bp_fix.lua"

local function p(...)
  local args = { ... }
  for i, v in ipairs(args) do args[i] = tostring(v) end
  io.write(table.concat(args, "\t") .. "\n")
  io.flush()
end

vim.notify = function(msg, level) p(("[L%s] %s"):format(level or "?", msg)) end
vim.fn.input = function(_, default) return default or "" end

require("lazy").load({ plugins = { "nvim-dap", "nvim-dap-ui", "nvim-nio" } })
local dap = require("dap")
local M = require("ue")
local dapui_ok, dapui = pcall(require, "dapui")
if dapui_ok then dapui.open = function() end; dapui.close = function() end end

-- Track breakpoint commands sent via REPL evaluate
local bp_commands_sent = {}
local orig_eval = M._dap_eval_lldb

-- After READY, count how many breakpoint set commands are issued during _reapply_breakpoints
local ready_seen = false
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  orig_notify(msg, level, opts)
  if not ready_seen and tostring(msg):find("READY") then
    ready_seen = true
    p("=== READY detected ===")
    -- Wait a bit for reapply to complete, then check
    vim.defer_fn(function()
      p("=== Breakpoint commands sent during attach ===")
      local set_count = 0
      for i, cmd in ipairs(bp_commands_sent) do
        p(("  [%d] %s"):format(i, cmd))
        if cmd:find("^breakpoint set") then
          set_count = set_count + 1
        end
      end
      p(("Total breakpoint set commands: %d"):format(set_count))

      -- Check total LLDB breakpoints
      M._dap_eval_lldb("breakpoint list", function(_, bp_list)
        vim.schedule(function()
          p("=== breakpoint list ===")
          -- Count breakpoint entries
          local bp_count = 0
          for _ in tostring(bp_list or ""):gmatch("Breakpoint%s+%d+:") do
            bp_count = bp_count + 1
          end
          p(("LLDB breakpoints: %d (from console output, may be 0 if empty REPL)"):format(bp_count))
          -- Also count from console events
          vim.defer_fn(function()
            p("=== RESULT ===")
            local specs = M._breakpoint_specs or {}
            local spec_count = vim.tbl_count(specs)
            p(("  specs: %d"):format(spec_count))
            p(("  set commands sent: %d"):format(set_count))
            if set_count <= spec_count + 1 then
              p("  PASS: no breakpoint explosion (set_count <= spec_count + 1)")
            else
              p(("  FAIL: breakpoint explosion! %d set commands for %d specs"):format(set_count, spec_count))
            end
            vim.cmd("qall!")
          end, 2000)
        end)
      end)
    end, 3000)
  end
end

-- Intercept _dap_eval_lldb to track commands
M._dap_eval_lldb = function(command, cb)
  if command:find("^breakpoint") then
    bp_commands_sent[#bp_commands_sent + 1] = command
  end
  return orig_eval(command, cb)
end

vim.defer_fn(function() p("TIMEOUT"); vim.cmd("qall!") end, 90000)
p("=== BP Fix Test ===")
vim.cmd("UEAndroidDAPAttach")
