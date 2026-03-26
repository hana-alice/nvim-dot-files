-- Temporary diagnostic: query DAP session state
local dap = require("dap")
local s = dap.session()
if not s then
  print("NO DAP SESSION")
  return
end

print("=== DAP Session State ===")
print("stopped_thread_id = " .. tostring(s.stopped_thread_id))
print("")

local thread_count = 0
for id, t in pairs(s.threads or {}) do
  thread_count = thread_count + 1
  local frame_count = t.frames and #t.frames or 0
  local frame_names = {}
  for i, f in ipairs(t.frames or {}) do
    if i <= 3 then
      table.insert(frame_names, "    " .. f.name .. (f.source and f.source.path and (" @ " .. f.source.path) or ""))
    end
  end
  print(string.format("tid:%d %q stopped=%s frames=%d", id, t.name, tostring(t.stopped), frame_count))
  for _, fn in ipairs(frame_names) do
    print(fn)
  end
end
print("\nTotal threads: " .. thread_count)

if s.current_frame then
  print("\ncurrent_frame: " .. s.current_frame.name
    .. (s.current_frame.source and s.current_frame.source.path and (" @ " .. s.current_frame.source.path) or ""))
end
