-- tools/stall_profile.lua — attach-and-sample main-loop profiler (diagnostic).
--
-- WHY: :StallReport proves the main loop was blocked and for how long, but it
-- cannot say BY WHOM. K42 was only pinned down by `jit.profile` sampling a
-- LIVE instance for 8s and reading which stacks dominated. This file makes
-- that procedure a repeatable tool instead of a one-off shell incantation.
--
-- USAGE (from a shell, against a running Neovim):
--   nvim --headless --server //./pipe/nvim.<PID>.0 \
--     --remote-expr "luaeval('loadfile(_A)()', 'C:/.../tools/stall_profile.lua')"
-- or inside the instance:
--   :lua dofile(vim.fn.stdpath('config') .. '/tools/stall_profile.lua')
--
-- Sampling runs for DURATION_MS on a uv timer so the caller returns
-- immediately (P6: never block the loop we are measuring). Results land in
-- <stdpath('state')>/stall_profile.<pid>.txt, newest run appended.
--
-- WHAT IT MEASURES: LuaJIT VM samples, 1ms interval, "fZ;" format
-- (function + Z-compressed stack). A stack that owns a large share of samples
-- while the user is idle IS the stall source — that is the whole point.
--
-- Sampling has cost, so this is a deliberate diagnostic entry point, never
-- something armed by default.

local DURATION_MS = tonumber(vim.env.UE_STALL_PROFILE_MS or "") or 8000
local INTERVAL = "li1" -- line-level, 1ms

-- jit.profile is a SUBMODULE: it only exists after an explicit require, which
-- is why a bare `jit.profile` reads nil in a stock Neovim Lua state.
local profile = jit.profile or require("jit.profile")

local counts = {}
local total = 0

local function on_sample(thread, samples, vmstate)
  total = total + samples
  local ok, stack = pcall(profile.dumpstack, thread, "pl;", 12)
  if not ok or not stack then
    stack = "<unknown>"
  end
  local key = vmstate .. " | " .. stack
  counts[key] = (counts[key] or 0) + samples
end

local function report()
  local rows = {}
  for stack, n in pairs(counts) do
    rows[#rows + 1] = { stack = stack, n = n }
  end
  table.sort(rows, function(a, b)
    return a.n > b.n
  end)

  local lines = {
    ("=== stall_profile %s pid=%d duration=%dms samples=%d ==="):format(
      os.date("%Y-%m-%dT%H:%M:%S"),
      vim.fn.getpid(),
      DURATION_MS,
      total
    ),
    "vmstate legend: N=compiled I=interpreted C=C code G=GC J=JIT-compiler",
    "",
  }
  local shown = 0
  for _, row in ipairs(rows) do
    shown = shown + 1
    if shown > 40 then
      break
    end
    lines[#lines + 1] = ("%6d  %5.1f%%  %s"):format(row.n, row.n / math.max(total, 1) * 100, row.stack)
  end

  local path = ("%s/stall_profile.%d.txt"):format(vim.fn.stdpath("state"), vim.fn.getpid())
  local f = io.open(path, "a")
  if f then
    f:write(table.concat(lines, "\n") .. "\n\n")
    f:close()
  end
  vim.schedule(function()
    vim.notify(("stall profile written (%d samples): %s"):format(total, path), vim.log.levels.INFO, {
      title = "stall_profile",
    })
  end)
  return path
end

profile.start(INTERVAL, on_sample)

local timer = (vim.uv or vim.loop).new_timer()
timer:start(DURATION_MS, 0, function()
  timer:stop()
  timer:close()
  profile.stop()
  vim.schedule(report)
end)

return ("sampling %dms; results -> %s/stall_profile.%d.txt"):format(
  DURATION_MS,
  vim.fn.stdpath("state"),
  vim.fn.getpid()
)
