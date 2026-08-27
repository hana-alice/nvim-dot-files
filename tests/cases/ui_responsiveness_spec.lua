-- tests/cases/ui_responsiveness_spec.lua
-- 主循环余量（main-loop headroom）回归。守护 P6：任何时候都不得卡。
--
-- 这些用例锁住的是 2026-08-25 实测定位的三个「持续偷主循环」缺陷，每条都有
-- 可复现的测量背书（见 docs/changelog.md）：
--   1. clangd -j 只按 RAM 推导 → 24 核机器上 -j=23，只剩 1 核给 nvim 主循环 +
--      Neovide 渲染线程 + 合成器。必须同时受 CPU 预算约束并为 UI 留核。
--   2. vim.lsp 把 server 的 stderr 一律按 ERROR 落盘，且每条 write 后 flush()
--      —— 实测 lsp.json 16.6MB / 58803 条，全部是 clangd 的普通信息输出。
--   3. lazy.nvim change_detection 的 2000ms/2000ms 主循环 fs_stat 轮询
--      （33 个 spec 文件），命中变更时 21ms。
--
-- 这里断言的是**策略与配置的可观察结果**，不是「跑得快」的时序断言——时序在
-- CI/不同宿主上不稳定，会变成假红灯。真实耗时证据留在 changelog 与
-- tools/stall_*.lua 的诊断产出里。

local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")
local clangd_jobs = require("ue.clangd_jobs")

t.describe("clangd -j：必须为 UI 保留 CPU 余量", function()
  t.it("clangd_jobs.compute 是纯函数（可注入 ram/cpus，headless 可测）", function()
    t.assert_type(clangd_jobs.compute, "function")
    t.assert_type(clangd_jobs.resolve, "function")
    t.assert_type(clangd_jobs.UI_RESERVED_CORES, "number")
    t.assert_true(clangd_jobs.UI_RESERVED_CORES >= 1, "至少保留 1 核给 UI")
  end)

  t.it("大内存 + 多核：不得占满所有逻辑核（复现缺陷的那台机器）", function()
    -- 94GB / 24 核：最初公式 floor(94/4)=23 → 只剩 1 核给 UI。
    local jobs = clangd_jobs.compute(96 * 1024, 24)
    t.assert_true(jobs <= 24 - clangd_jobs.UI_RESERVED_CORES,
      ("24 核必须保留 %d 核给 UI，实际 -j=%d"):format(clangd_jobs.UI_RESERVED_CORES, jobs))
    t.assert_true(jobs >= 4, "仍需保留可用的索引并发度")
  end)

  t.it("并发度不得超过宿主核数的 MAX_CORE_SHARE（保留 4 核仍不够）", function()
    -- 实测：仅"保留 4 核"时 24 核机器给 clangd 20 核（83%），AppControl 遥测显示
    -- clangd 连续 50 分钟满负荷、整机不可用。份额上限才是承重约束：
    -- 保留 4/8 核很激进，保留 4/64 核形同没有。
    t.assert_type(clangd_jobs.MAX_CORE_SHARE, "number")
    t.assert_true(clangd_jobs.MAX_CORE_SHARE <= 0.5,
      "后台索引不得占用过半宿主 CPU")
    for _, cpus in ipairs({ 8, 12, 16, 24, 32, 64 }) do
      local jobs = clangd_jobs.compute(96 * 1024, cpus)
      t.assert_true(jobs <= math.floor(cpus * clangd_jobs.MAX_CORE_SHARE),
        ("%d 核时 -j=%d 超过份额上限"):format(cpus, jobs))
    end
  end)

  t.it("本机 24 核：-j 必须显著低于此前的 20", function()
    -- 回归守卫：防止有人"为了索引快"把份额调回去。
    local jobs = clangd_jobs.compute(96 * 1024, 24)
    t.assert_true(jobs <= 12,
      ("24 核 / 94GB 应 <=12（原 20 导致整机卡死），实际 %d"):format(jobs))
  end)

  t.it("核数是独立上限：大内存小核机器由 CPU 预算决定", function()
    -- 96GB 但只有 8 核：RAM 预算会给 24，CPU 预算必须压到 8-4=4。
    t.assert_eq(clangd_jobs.compute(96 * 1024, 8), 4)
  end)

  t.it("内存是独立上限：小内存大核机器由 RAM 预算决定", function()
    -- 8GB / 32 核：CPU 预算给 28，但 2GB/worker 的内存预算只允许 2 → 抬到下限 4。
    local jobs = clangd_jobs.compute(8 * 1024, 32)
    t.assert_true(jobs <= 4, ("小内存不得按核数放大并发，实际 -j=%d"):format(jobs))
  end)

  t.it("探测失败（ram=0/cpus=0）回落到历史默认值，不得为 0 或负数", function()
    local jobs = clangd_jobs.compute(0, 0)
    t.assert_true(jobs >= 4, "未知宿主不得产出不可用的并发度")
    t.assert_true(jobs <= 24)
  end)

  t.it("永不超过 24 的硬上限", function()
    t.assert_true(clangd_jobs.compute(1024 * 1024, 256) <= 24)
  end)

  t.it("实际 argv 里的 -j 与策略一致（策略没有被绕过）", function()
    local cmd = ue.clangd_cmd()
    local argv_jobs
    for _, arg in ipairs(cmd) do
      local j = arg:match("^%-j=(%d+)$")
      if j then argv_jobs = tonumber(j) end
    end
    t.assert_type(argv_jobs, "number", "clangd argv 必须携带 -j")

    local cpus = #((vim.uv or vim.loop).cpu_info() or {})
    if cpus > clangd_jobs.UI_RESERVED_CORES then
      -- 本宿主上 argv 必须满足同一条 UI 余量不变量。
      t.assert_true(argv_jobs <= cpus - clangd_jobs.UI_RESERVED_CORES,
        ("argv -j=%d 未给 UI 留核（cpus=%d）"):format(argv_jobs, cpus))
    end
  end)

  t.it("UE_CLANGD_JOBS 显式覆盖仍然生效（用户意图优先）", function()
    local old = vim.env.UE_CLANGD_JOBS
    vim.env.UE_CLANGD_JOBS = "3"
    local cmd = ue.clangd_cmd()
    vim.env.UE_CLANGD_JOBS = old
    t.assert_true(vim.tbl_contains(cmd, "-j=3"),
      "显式 UE_CLANGD_JOBS 必须覆盖自动策略")
  end)
end)

t.describe("交互路径禁止同步阻塞（`gr` references）", function()
  t.it("ue 提供 async references twin", function()
    t.assert_type(ue.gtags_references_async, "function",
      "`gr` 的 GTAGS 回退必须有异步版")
  end)

  t.it("lsp_fallback.references 不再使用 request_sync / 同步 GTAGS", function()
    -- 读源文件断言：这条锁的是「不得在主循环上等子进程/LSP」的结构性事实。
    -- 实测（2026-08-25）：request_sync 最多堵 5000ms；vim.system():wait() 在本
    -- 宿主光 spawn 就 87ms p50。两者都在 `gr` 这条日常按键上。
    local path = vim.fn.stdpath("config") .. "/lua/utils/lsp_fallback.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("function M%.references%(%)(.-)\nend")
    t.assert_type(body, "string", "未找到 M.references 函数体")
    t.assert_false(body:find("sync_locations", 1, true) ~= nil,
      "references 不得使用 sync_locations（request_sync 阻塞主循环最多 5s）")
    t.assert_false(body:match("ue%.gtags_references%s*%(") ~= nil,
      "references 不得调同步 ue.gtags_references（内部 vim.system():wait()）")
    t.assert_true(body:find("async_lsp_request", 1, true) ~= nil,
      "references 应走异步 LSP 请求")
    t.assert_true(body:find("gtags_references_async", 1, true) ~= nil,
      "references 的 GTAGS 回退应走异步版")
  end)

  t.it("异步 references 请求仍携带 includeDeclaration（行为不变）", function()
    -- 旧的 sync_locations 总是设 includeDeclaration=true；换到异步通道不得静默
    -- 改变返回集。
    local path = vim.fn.stdpath("config") .. "/lua/utils/ue_goto/provider.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    t.assert_match(src, "textDocument/references",
      "async_lsp_request 必须为 references 补 ReferenceContext")
    t.assert_match(src, "includeDeclaration")
  end)
end)

t.describe("vim.lsp stderr 日志：不得每条都同步 write+flush 主循环", function()
  local resp = require("config.ui_responsiveness")

  t.it("模块暴露 setup / setup_lsp_logging", function()
    t.assert_type(resp.setup, "function")
    t.assert_type(resp.setup_lsp_logging, "function")
  end)

  t.it("setup_lsp_logging 后 LSP 日志级别为 OFF", function()
    resp.setup_lsp_logging()
    -- OFF 语义：ERROR 不再通过。直接断级别值，避免依赖内部实现细节。
    t.assert_false(vim.lsp.log.should_log(vim.log.levels.ERROR),
      "server 的 stderr 不是 error，不得每条落盘 + flush")
  end)

  t.it("注册 :LspLogLevel 供排查时临时提级（证据一条命令可得）", function()
    resp.setup_lsp_logging()
    t.assert_eq(vim.fn.exists(":LspLogLevel"), 2, ":LspLogLevel 未注册")
  end)

  t.it("提级后可恢复：debug 生效、off 关闭（不留全局副作用）", function()
    vim.cmd("LspLogLevel debug")
    t.assert_true(vim.lsp.log.should_log(vim.log.levels.ERROR),
      "提级到 debug 后应当记录")
    vim.cmd("LspLogLevel off")
    t.assert_false(vim.lsp.log.should_log(vim.log.levels.ERROR),
      "恢复 off 后不得继续记录")
  end)
end)

t.describe("lazy change_detection：不得在主循环上 2s 轮询 fs_stat", function()
  local resp = require("config.ui_responsiveness")

  t.it("config/lazy.lua 里显式禁用 change_detection", function()
    -- 读配置源文件断言意图：headless 下 lazy 未必已 setup，不能只查运行时。
    local path = vim.fn.stdpath("config") .. "/lua/config/lazy.lua"
    local content = table.concat(vim.fn.readfile(path), "\n")
    local block = content:match("change_detection%s*=%s*{(.-)}")
    t.assert_type(block, "string", "未找到 change_detection 配置块")
    t.assert_match(block, "enabled%s*=%s*false",
      "change_detection 必须显式 false（2s 主循环 fs_stat 轮询）")
  end)

  t.it("提供漂移守卫 assert_change_detection_disabled", function()
    t.assert_type(resp.assert_change_detection_disabled, "function")
    local verdict = resp.assert_change_detection_disabled()
    -- lazy 未加载时返回 nil（不适用）；加载了就必须是 true。
    if verdict ~= nil then
      t.assert_true(verdict, "运行时 change_detection 仍开启，与配置漂移")
    end
  end)
end)

t.describe("周期性回调契约（K40/K42 家族的一般化）", function()
  t.it("timer 回调里禁止同步 vim.fn.system（K40）", function()
    -- 扫描运行时代码：timer 回调内的同步子进程往返会按周期钉住主循环。
    -- 这条锁住的是 K40 的一般形态，不只是当初那一个 Android poller。
    local root = vim.fn.stdpath("config") .. "/lua/"
    local offenders = {}
    local files = vim.fn.globpath(root, "**/*.lua", false, true)
    for _, file in ipairs(files) do
      local rel = file:sub(#root + 1):gsub("\\", "/")
      -- vendored 第三方副本不在本仓约束范围内。
      if not rel:match("^nio/") and not rel:match("^trouble/") then
        local lines = vim.fn.readfile(file)
        local in_timer = false
        local depth_marker = nil
        for i, line in ipairs(lines) do
          if line:match(":start%(%s*%d") then
            in_timer = true
            depth_marker = i
          end
          -- 只看 timer:start( 之后紧邻的窗口内（回调体的头部），避免全文件误报。
          if in_timer and depth_marker and i > depth_marker and i - depth_marker < 25 then
            if line:match("vim%.fn%.system") or line:match("vim%.fn%.systemlist") then
              offenders[#offenders + 1] = ("%s:%d"):format(rel, i)
            end
          elseif depth_marker and i - depth_marker >= 25 then
            in_timer = false
            depth_marker = nil
          end
        end
      end
    end
    t.assert_eq(#offenders, 0,
      "timer 回调附近出现同步 system()（K40）：" .. table.concat(offenders, ", "))
  end)
end)
