-- tests/run_parallel.lua
-- ----------------------------------------------------------------------------
-- 并行全量回归：每个 tests/cases/*_spec.lua 在独立 `nvim --headless -l tests/run.lua <file>`
-- 子进程中运行（run.lua 已为每个进程隔离 state/log/probe 根），最多 JOBS 个并发。
--
-- 用法：
--   nvim --headless -l tests/run_parallel.lua            # JOBS 默认 = min(8, CPU/2)
--   JOBS=12 nvim --headless -l tests/run_parallel.lua
--   nvim --headless -l tests/run_parallel.lua <filter>   # 只跑文件名含 <filter> 的
--
-- 进度实时打到 stdout：`[done/total] OK|FAIL <file> (<秒>s, <passed>/<total>)`。
-- 结束时汇总失败文件及其 FAIL 行，退出码 0 = 全绿，1 = 有失败。
-- 串行入口 tests/run.lua 保持不变，仍是 CI 与提交门禁的权威入口；本脚本只是本地加速。
-- ----------------------------------------------------------------------------

local cfg = vim.fn.stdpath("config")
local filter = (_G.arg and _G.arg[1] ~= "" and _G.arg[1]) or vim.env.FILTER
local cpus = #(vim.uv.cpu_info() or {})
local jobs = tonumber(vim.env.JOBS) or math.max(1, math.min(8, math.floor(cpus / 2)))

local files = vim.fn.glob(cfg .. "/tests/cases/*_spec.lua", true, true)
table.sort(files)
if filter then
  files = vim.tbl_filter(function(f) return f:find(filter, 1, true) ~= nil end, files)
end
if #files == 0 then
  io.stderr:write("no spec files matched\n")
  vim.cmd("cquit 1")
  return
end

-- 最慢的原生文件先启动，缩短尾部等待（按上次耗时；无记录则按文件名）。
local timing_path = vim.fn.stdpath("cache") .. "/nvim_test_timings.json"
local timings = {}
do
  local ok, data = pcall(vim.fn.readfile, timing_path)
  if ok and data[1] then
    local okj, decoded = pcall(vim.json.decode, table.concat(data, "\n"))
    if okj and type(decoded) == "table" then timings = decoded end
  end
end
table.sort(files, function(a, b)
  local ta = timings[vim.fn.fnamemodify(a, ":t")] or 0
  local tb = timings[vim.fn.fnamemodify(b, ":t")] or 0
  if ta ~= tb then return ta > tb end
  return a < b
end)

io.write(string.format("Running %d spec file(s) with %d parallel job(s)\n", #files, jobs))
io.stdout:flush()

local total, done, running, next_idx = #files, 0, 0, 1
local results = {}
local started_at = vim.uv.hrtime()

local function launch(file)
  local name = vim.fn.fnamemodify(file, ":t")
  local t0 = vim.uv.hrtime()
  running = running + 1
  vim.system({ vim.v.progpath, "--headless", "-l", cfg .. "/tests/run.lua", file },
    { text = true, cwd = cfg, env = { CI = "false" } },
    function(res)
      local secs = (vim.uv.hrtime() - t0) / 1e9
      local out = (res.stdout or "") .. "\n" .. (res.stderr or "")
      local summary = out:match("=== (%d+/%d+) passed") or "?"
      vim.schedule(function()
        running = running - 1
        done = done + 1
        local ok = res.code == 0
        results[#results + 1] = { name = name, ok = ok, out = out, secs = secs }
        timings[name] = secs
        io.write(string.format("[%d/%d] %-4s %s (%.1fs, %s)\n", done, total,
          ok and "OK" or "FAIL", name, secs, summary))
        io.stdout:flush()
      end)
    end)
end

local function pump()
  while running < jobs and next_idx <= total do
    launch(files[next_idx])
    next_idx = next_idx + 1
  end
end

pump()
while done < total do
  vim.wait(200, function() return false end)
  pump()
end

pcall(vim.fn.mkdir, vim.fn.fnamemodify(timing_path, ":h"), "p")
pcall(vim.fn.writefile, { vim.json.encode(timings) }, timing_path)

local failed = vim.tbl_filter(function(r) return not r.ok end, results)
io.write(string.format("\n=== %d/%d spec files passed in %.1fs (jobs=%d) ===\n",
  total - #failed, total, (vim.uv.hrtime() - started_at) / 1e9, jobs))
for _, r in ipairs(failed) do
  io.write("\n--- FAIL " .. r.name .. "\n")
  local lines = {}
  for line in r.out:gmatch("[^\n]+") do
    if line:find("^FAIL") or line:find("^%s+└─") or line:find("^===") then lines[#lines + 1] = line end
  end
  if #lines == 0 then lines = { r.out:sub(-2000) } end
  io.write(table.concat(lines, "\n") .. "\n")
end
io.stdout:flush()
vim.cmd(#failed == 0 and "quit" or "cquit 1")
