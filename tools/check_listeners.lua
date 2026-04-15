local dap = require("dap")
local results = {}

-- Check if setup_dap ran
local ue = require("ue")
table.insert(results, "ue._dap_blocked = " .. tostring(ue._dap_blocked))

-- Check listeners.after.event_stopped
local stopped = dap.listeners.after.event_stopped
table.insert(results, "\nlisteners.after.event_stopped:")
if stopped then
  for key, _ in pairs(stopped) do
    table.insert(results, "  " .. tostring(key))
  end
else
  table.insert(results, "  (nil)")
end

-- Check listeners.after.stackTrace
local st = dap.listeners.after.stackTrace
table.insert(results, "\nlisteners.after.stackTrace:")
if st then
  for key, _ in pairs(st) do
    table.insert(results, "  " .. tostring(key))
  end
else
  table.insert(results, "  (nil)")
end

-- Check session
local s = dap.session()
if s then
  table.insert(results, "\nSession: active, patched=" .. tostring(s._ue_patched))
  table.insert(results, "stopped_thread_id=" .. tostring(s.stopped_thread_id))
  local tc = 0
  for id, t in pairs(s.threads or {}) do
    tc = tc + 1
    if tc <= 3 then
      table.insert(results, string.format("  tid:%d %s frames=%s", id, t.name, tostring(t.frames and #t.frames or "nil")))
    end
  end
  if tc > 3 then table.insert(results, "  ... +" .. (tc-3) .. " more") end
else
  table.insert(results, "\nSession: none")
end

print(table.concat(results, "\n"))
