-- Diagnostic: dump stack frame source paths after hitting a breakpoint
-- cd <PROJ_DRIVE>\uetemp
-- nvim --headless -u $LOCALAPPDATA\nvim\init.lua +"luafile $LOCALAPPDATA/nvim/tools/test_stack_paths.lua"

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

local stop_events = {}
dap.listeners.after.event_stopped["test"] = function(session, body)
  body = body or {}
  table.insert(stop_events, {
    reason = body.reason or "?",
    thread = body.threadId,
    bps = body.hitBreakpointIds,
  })
end

local ready_seen = false
local orig_notify = vim.notify
vim.notify = function(msg, level, opts)
  orig_notify(msg, level, opts)
  if not ready_seen and tostring(msg):find("READY") then
    ready_seen = true
    p("=== READY, waiting for breakpoint hit ===")
    local check_count = 0
    local function check_bp()
      check_count = check_count + 1
      -- Check for BP hit or any stopped thread
      local session = dap.session()
      if session and session.stopped_thread_id then
        p("=== Stopped on thread " .. tostring(session.stopped_thread_id) .. " ===")
        session:request("stackTrace", {
          threadId = session.stopped_thread_id,
          startFrame = 0,
          levels = 30,
        }, function(err, response)
          vim.schedule(function()
            if err then
              p("stackTrace error:", vim.inspect(err))
              vim.cmd("qall!")
              return
            end
            local frames = response and response.stackFrames or {}
            p(("=== %d frames ==="):format(#frames))
            for i, frame in ipairs(frames) do
              local source = frame.source or {}
              local path = source.path or ""
              local name = source.name or ""
              local ref = source.sourceReference or 0
              local exists = path ~= "" and vim.uv.fs_stat(path) and "EXISTS" or "MISSING"
              p(("[%d] %s:%d"):format(i, frame.name or "?", frame.line or 0))
              p(("     path=%s"):format(path))
              p(("     name=%s  ref=%s  %s"):format(name, tostring(ref), exists))
            end
            vim.cmd("qall!")
          end)
        end)
        return
      end
      if check_count < 40 then
        vim.defer_fn(check_bp, 500)
      else
        p("=== No stopped thread after 20s ===")
        vim.cmd("qall!")
      end
    end
    vim.defer_fn(check_bp, 500)
  end
end

vim.defer_fn(function() p("TIMEOUT"); vim.cmd("qall!") end, 90000)
vim.cmd("UEAndroidDAPAttach")
