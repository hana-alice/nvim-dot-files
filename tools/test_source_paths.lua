-- Diagnostic: query LLDB for source paths via image lookup
-- cd <PROJ_DRIVE>\uetemp
-- nvim --headless -u $LOCALAPPDATA\nvim\init.lua +"luafile $LOCALAPPDATA/nvim/tools/test_source_paths.lua"

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

-- Capture ALL console output
local console_lines = {}
dap.listeners.after.event_output["test"] = function(_, body)
  if body and body.output and body.category == "console" then
    console_lines[#console_lines + 1] = body.output:gsub("%s+$", "")
  end
end

local ready_seen = false
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  orig_notify(msg, level, opts)
  if not ready_seen and tostring(msg):find("READY") then
    ready_seen = true
    p("=== READY ===")
    console_lines = {}
    vim.defer_fn(function()
      -- Query LLDB for source file info
      M._dap_eval_lldb('image lookup --file "VulkanShaders.cpp" --line 54', function(ok, r)
        vim.defer_fn(function()
          p("=== image lookup VulkanShaders.cpp:54 ===")
          p("repl result:", tostring(r))
          for _, line in ipairs(console_lines) do
            p("  console:", line)
          end
          -- Also check source-map setting
          console_lines = {}
          M._dap_eval_lldb('settings show target.source-map', function(ok2, r2)
            vim.defer_fn(function()
              p("=== source-map ===")
              p("repl:", tostring(r2))
              for _, line in ipairs(console_lines) do
                p("  console:", line)
              end
              -- Check what LLDB thinks the compilation directory is
              console_lines = {}
              M._dap_eval_lldb('target variable', function(ok3, r3)
                vim.defer_fn(function()
                  -- One more: get frame info on current stopped frame to see path format
                  local session = dap.session()
                  if session and session.stopped_thread_id then
                    session:request("stackTrace", {
                      threadId = session.stopped_thread_id,
                      startFrame = 0,
                      levels = 5,
                    }, function(err, response)
                      vim.schedule(function()
                        local frames = response and response.stackFrames or {}
                        p("=== DAP stackTrace frames (first 5) ===")
                        for i, frame in ipairs(frames) do
                          local source = frame.source or {}
                          p(("[%d] %s:%d"):format(i, frame.name or "?", frame.line or 0))
                          p(("     path=%s"):format(source.path or "<none>"))
                          p(("     name=%s  ref=%s"):format(source.name or "<none>", tostring(source.sourceReference or 0)))
                          if source.path and source.path ~= "" then
                            local exists = vim.uv.fs_stat(source.path) and "EXISTS" or "MISSING"
                            p(("     %s"):format(exists))
                          end
                        end
                        vim.cmd("qall!")
                      end)
                    end)
                  else
                    p("No stopped thread, can't get stackTrace")
                    vim.cmd("qall!")
                  end
                end, 500)
              end)
            end, 500)
          end)
        end, 500)
      end)
    end, 1000)
  end
end

vim.defer_fn(function() p("TIMEOUT"); vim.cmd("qall!") end, 90000)
vim.cmd("UEAndroidDAPAttach")
