-- ue/clangd_jobs.lua — how many parallel workers clangd may have.
--
-- WHY THIS IS A MODULE, NOT A FEW LINES IN ue.lua
-- ----------------------------------------------
-- This is a resource-budget POLICY with a correctness requirement attached:
-- the editor must always retain enough CPU to draw a frame (P6 — UI stutter is
-- a bug). Policy with an invariant deserves a named home and headless tests,
-- and `ue.lua` is under a monotonically decreasing line ratchet, so new policy
-- belongs outside it.
--
-- THE DEFECT THIS FIXES (measured 2026-08-25)
-- -------------------------------------------
-- The previous inline computation derived -j from RAM ALONE:
--     jobs = clamp(floor(total_gb / 4), 8, 24)
-- On this 94 GB / 24-logical-core host that yields -j=23: 96% of every core on
-- the machine, leaving ONE core to be shared by nvim's main loop, Neovide's
-- render thread, and the desktop compositor.
--
-- Observed during background indexing: host CPU 6% busy -> 60% busy, clangd
-- holding 38 threads and ~12-17 GB RSS. No single Lua callback was slow — which
-- is exactly why six separate headless experiments (input-path timing,
-- statuscolumn cost, lazy reloader cost, synthetic CPU load, synthetic disk
-- load, clangd-under-headless) all reported a perfectly smooth main loop while
-- the user's GUI session stuttered. A headless nvim has no render thread and no
-- UI pipe to service, so it needs almost no CPU and never feels the starvation.
--
-- THE RULE
-- --------
-- Two independent ceilings, take the smaller, then never spend the UI's share:
--   * memory ceiling: clangd holds ~2 GB per in-flight preamble with
--     --pch-storage=memory, so allow about one worker per 4 GB.
--   * cpu ceiling: total logical cores minus UI_RESERVED_CORES.
-- Both are real; whichever binds first wins. RAM-only sizing was the bug.

local M = {}

-- Logical cores withheld from clangd so the machine stays usable.
--
-- The original budget reserved 4 of 24 cores, i.e. clangd could take 83%. That
-- was still too much: measured on this host (AppControl app_sysmon telemetry,
-- binary_id=258 = LLVM clangd 22.1.5) clangd held the machine at full load for a
-- continuous 50 minutes (17:56-18:46 on 2026-08-26), and the user reported the
-- whole desktop becoming unusable. "4 cores for the UI" only holds when nothing
-- else runs; on this box rustc, several zellij sessions, Chrome and AppControl are
-- routinely busy, so those 4 reserved cores do not actually exist.
--
-- A share, not a fixed count, is the right model: reserving 4 of 8 cores is
-- drastic while reserving 4 of 64 is negligible. Keep a fixed floor for small
-- hosts and additionally cap clangd at MAX_CORE_SHARE of the machine.
M.UI_RESERVED_CORES = 4

-- Hard ceiling on the fraction of logical cores clangd may use.
--
-- Rationale for 0.5: background indexing is a batch job whose latency the user
-- does not observe directly, whereas losing the desktop is immediately painful.
-- Halving throughput to keep the machine responsive is the correct trade under
-- "resource yielding outranks finishing sooner". On this 24-core host it means
-- -j=12 instead of -j=20.
M.MAX_CORE_SHARE = 0.5

-- Never drop below this, or indexing a UE tree stops being viable.
M.MIN_JOBS = 4

-- clangd's own practical ceiling; more workers stop helping and cost memory.
M.MAX_JOBS = 24

-- Fallback when RAM cannot be probed: the historical default, which was safe on
-- every host we have run on.
local RAM_UNKNOWN_JOBS = 8

--- Compute the -j value from host resources.
---
--- Pure and fully injectable so the UI-headroom invariant is provable headless
--- instead of only observable by feel.
---
--- @param total_mb number|nil total physical RAM in MiB (0/nil when unknown)
--- @param cpus number|nil logical core count (0/nil when unknown)
--- @return integer jobs value to pass as clangd's -j
function M.compute(total_mb, cpus)
  total_mb = tonumber(total_mb) or 0
  cpus = tonumber(cpus) or 0

  -- Memory ceiling: ~1 worker per 4 GB of RAM.
  local ram_jobs
  if total_mb >= 1024 then
    ram_jobs = math.floor(math.floor(total_mb / 1024) / 4)
  else
    ram_jobs = RAM_UNKNOWN_JOBS
  end

  -- CPU ceiling: never claim the cores the UI needs to stay smooth, and never
  -- exceed MAX_CORE_SHARE of the machine regardless of how many cores exist.
  local cpu_jobs = math.huge
  if cpus > 0 then
    cpu_jobs = math.min(cpus - M.UI_RESERVED_CORES, math.floor(cpus * M.MAX_CORE_SHARE))
  end

  local jobs = math.min(ram_jobs, cpu_jobs)
  if jobs < M.MIN_JOBS then
    jobs = M.MIN_JOBS
  end
  if jobs > M.MAX_JOBS then
    jobs = M.MAX_JOBS
  end
  return math.floor(jobs)
end

--- Resolve -j for the current host, honouring an explicit user override.
--- UE_CLANGD_JOBS=N always wins: stated intent outranks our heuristic.
--- @return integer
function M.resolve()
  local env_jobs = tonumber(vim.env.UE_CLANGD_JOBS or "")
  if env_jobs and env_jobs > 0 then
    return math.floor(env_jobs)
  end

  local total_mb = 0
  local ok_mem, mem = pcall(function()
    return vim.uv.get_total_memory and vim.uv.get_total_memory() or 0
  end)
  if ok_mem and type(mem) == "number" and mem > 0 then
    total_mb = math.floor(mem / (1024 * 1024))
  end

  local cpus = 0
  local ok_cpu, cpu_info = pcall(function()
    return vim.uv.cpu_info and vim.uv.cpu_info() or nil
  end)
  if ok_cpu and type(cpu_info) == "table" then
    cpus = #cpu_info
  end

  return M.compute(total_mb, cpus)
end

return M
