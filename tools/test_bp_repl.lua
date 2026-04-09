-- Test what CodeLLDB REPL returns for breakpoint commands
-- cd <PROJ_DRIVE>\uetemp
-- nvim --headless -u $LOCALAPPDATA\nvim\init.lua +"luafile $LOCALAPPDATA/nvim/tools/test_bp_repl.lua"

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

-- Capture console output
local console_outputs = {}
dap.listeners.after.event_output["test"] = function(_, body)
  if body and body.output and body.category == "console" then
    table.insert(console_outputs, body.output:gsub("%s+$", ""))
  end
end

-- Wait for READY then test REPL breakpoint
local done = false
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  orig_notify(msg, level, opts)
  if not done and tostring(msg):find("READY") then
    done = true
    p("=== READY, testing REPL breakpoint command ===")
    -- Clear console_outputs
    console_outputs = {}
    vim.defer_fn(function()
      M._dap_eval_lldb(
        'breakpoint set --file "VulkanShaders.cpp" --line 100',
        function(ok, result)
          vim.schedule(function()
            p("=== REPL result ===")
            p("  ok:", tostring(ok))
            p("  result:", vim.inspect(result))
            p("  result type:", type(result))
            p("  result length:", #tostring(result or ""))
            -- Check what was in console output
            vim.defer_fn(function()
              p("=== Console outputs after breakpoint set ===")
              for i, out in ipairs(console_outputs) do
                p(("  [%d] %s"):format(i, out))
              end
              -- Also test breakpoint list
              M._dap_eval_lldb("breakpoint delete", function(ok2, r2)
                vim.schedule(function()
                  p("=== delete result:", tostring(ok2), vim.inspect(r2))
                  vim.cmd("qall!")
                end)
              end)
            end, 1000)
          end)
        end)
    end, 500)
  end
end

vim.defer_fn(function() p("TIMEOUT"); vim.cmd("qall!") end, 60000)
vim.cmd("UEAndroidDAPAttach")
