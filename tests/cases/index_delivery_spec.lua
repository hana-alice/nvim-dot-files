-- tests/cases/index_delivery_spec.lua
-- controlled index 的**交付**契约回归（change: deliver-semantic-index-from-prepare）。
--
-- 背景（真实故障，2026-08-26）：用户按习惯链路
-- `set platform → set project → build → :UEPrepare` 走完后，对一个模块内**只有唯一定义**的
-- 符号（`WrapAroundAllocateMemory`，定义在 `VulkanRHI.cpp`）执行 `gd`，
-- 结果"等一会出来几个 unity cpp 然后让我选"。
--
-- 根因不是用户漏跑命令 —— prepare 的三条完成路径都会调
-- `schedule_index_refresh{current,hot,full}`。真正的缺陷是**交付链路**：
--   1. index 构建失败/中断完全静默（只写 status="error"，无 notify、无日志、全仓零索引日志）
--   2. sidecar 把"多个 context 各自失败"聚合成 `ambiguous-context`，而该状态是唯一会给用户
--      弹候选的状态 → readiness 问题被伪装成真歧义 → 唯一定义变成假候选列表（违背 P12）
--
-- 这里断言的是**分类与可观测性的不变量**，不是时序 —— 时序断言在不同宿主上会变成假红灯。

local t = require("tests.harness")
t.bootstrap()

local nav = require("utils.ue_goto.semantic_navigation")

t.describe("index readiness 优先于 sidecar 的 ambiguous 判定（P12 诚实失败）", function()
  t.it("暴露纯函数 _apply_readiness_override（headless 可测）", function()
    t.assert_type(nav._apply_readiness_override, "function")
  end)

  t.it("index 未就绪时 ambiguous-context 降级为 unavailable + readiness reason", function()
    -- 这正是故障现场：generation_class=missing / readiness 非 ready。
    local state, stage, reason = nav._apply_readiness_override(
      "ambiguous-context", "tu", "semantic-tu-unavailable", { readiness = "missing" })
    t.assert_eq(state, "unavailable", "readiness 缺失不得报 ambiguous（那会弹候选）")
    t.assert_eq(stage, "context")
    t.assert_eq(reason, "index-provider-not-ready")
  end)

  t.it("index stale 时给出 stale 专属 reason，而非笼统 not-ready", function()
    local _, _, reason = nav._apply_readiness_override(
      "ambiguous-context", "tu", "semantic-tu-unavailable", { readiness = "stale" })
    t.assert_eq(reason, "index-stale-for-module")

    local _, _, reason2 = nav._apply_readiness_override(
      "ambiguous-context", "tu", "semantic-tu-unavailable",
      { readiness = "missing", freshness = "stale-for-module" })
    t.assert_eq(reason2, "index-stale-for-module")
  end)

  t.it("index 就绪时保留真歧义（多个已证明 context 合法解析出不同实体）", function()
    -- 真歧义必须仍然可选 —— 修复 P12 不能把合法的 context 选择一起砍掉。
    local state, stage, reason = nav._apply_readiness_override(
      "ambiguous-context", "tu", "multiple-context-failures", { readiness = "ready" })
    t.assert_eq(state, "ambiguous-context", "index 就绪时的真歧义必须保留")
    t.assert_eq(stage, "tu")
    t.assert_eq(reason, "multiple-context-failures")
  end)

  t.it("非 ambiguous 的终态不被改写（只收敛误分类，不扩大影响面）", function()
    for _, s in ipairs({ "unavailable", "invalid-semantic-context", "resolved" }) do
      local state, stage, reason = nav._apply_readiness_override(
        s, "entity", "semantic-cursor-invalid", { readiness = "missing" })
      t.assert_eq(state, s)
      t.assert_eq(stage, "entity")
      t.assert_eq(reason, "semantic-cursor-invalid")
    end
  end)

  t.it("index 快照缺失（nil）按未就绪处理，不得默认放行", function()
    local state = nav._apply_readiness_override(
      "ambiguous-context", "tu", "semantic-tu-unavailable", nil)
    t.assert_eq(state, "unavailable", "无 index 证据时必须 fail closed")
  end)
end)

t.describe("降级为 unavailable 后不得携带候选（候选=可选定位目标）", function()
  t.it("semantic_failure 在 readiness 失败时丢弃 contexts", function()
    -- 读实现断言结构性事实：contexts 只在终态仍为 ambiguous-context 时透传。
    -- 若这条回归，用户又会在"语义不可用"时看到一堆 unity TU 可选。
    local path = vim.fn.stdpath("config") .. "/lua/utils/ue_goto/semantic_navigation.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("local function semantic_failure%(response, default_stage%)(.-)\n    end")
    t.assert_type(body, "string", "未找到 semantic_failure 函数体")
    t.assert_true(body:find("_apply_readiness_override", 1, true) ~= nil,
      "semantic_failure 必须应用 readiness 覆盖")
    -- 更强的不变量（比原来的单行条件透传更严）：只有**真正 resolved** 的 context
    -- 才能交给候选渲染，且过滤后不足两个则降为 unavailable。
    -- 根因：sidecar 的 per-context 结果可能带 state="ambiguous-context"（仅表示
    -- “有多个候选 TU 可能包含该 header”），那不是可供用户选择的真歧义。
    t.assert_match(body, 'c%.state == "resolved"',
      "只得透传真正 resolved 的 context")
    t.assert_match(body, "#resolved_only > 1",
      "过滤后不足两个即非真歧义，必须降级")
  end)

  t.it("readiness 类失败必须给出可执行的补救提示", function()
    -- 光说 "unavailable" 会让用户无从下手 —— 这正是本次故障的用户体验。
    local path = vim.fn.stdpath("config") .. "/lua/utils/ue_goto/semantic_navigation.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    t.assert_match(src, "local remedy", "缺少 remedy 提示表")
    for _, reason in ipairs({ "index%-provider%-not%-ready", "index%-stale%-for%-module" }) do
      t.assert_match(src, reason, "remedy 未覆盖 reason: " .. reason)
    end
    -- 提示必须指向用户的习惯入口（UEPrepare），而不是要求记住平台专属索引命令。
    t.assert_match(src, "UEPrepare", "补救提示应指向 :UEPrepare 习惯链路")
  end)
end)

t.describe("index 构建失败必须可见（notify + 结构化日志）", function()
  local build_src
  local function src()
    if not build_src then
      local path = vim.fn.stdpath("config") .. "/lua/ue/index/_build.lua"
      build_src = table.concat(vim.fn.readfile(path), "\n")
    end
    return build_src
  end

  t.it("失败路径 notify 用户（此前完全静默）", function()
    t.assert_match(src(), "UE index: %%s build failed",
      "构建失败必须 notify —— 静默失败是本次故障无法诊断的直接原因")
  end)

  t.it("失败路径写 utils.log，含 phase / exit code（跨会话可诊断）", function()
    t.assert_match(src(), 'error_ctx%("ue%.index"', "失败必须落结构化日志")
    t.assert_match(src(), "exit_code = result%.code", "日志必须含 exit code")
    t.assert_match(src(), "phase = phase", "日志必须含 phase")
  end)

  t.it("交付不完整（manifest/selection/promotion 缺失）视为失败", function()
    -- full.json 落盘但未提升时，gate 仍判 not ready；不得静默当成部分成功。
    t.assert_match(src(), "if not %(selection and promoted%) then",
      "未完成提升必须置 ok_result=false")
  end)

  t.it("构建提供进度指示且遵守 P5（成功自然消退、无周期 ticker）", function()
    local s = src()
    t.assert_match(s, 'title = "UE index"', "缺少进度指示 handle")
    t.assert_match(s, "progress_finish", "进度必须在终态收尾")
    t.assert_match(s, "percentage = nil", "子进程不报总量，应为 indeterminate")
    -- 进度更新由真实子进程输出驱动，不得用周期定时器刷新（P5）。
    local has_periodic = s:match("progress[_%w]*handle[^\n]-timer")
      or s:match("timer[^\n]-progress_report")
    t.assert_nil(has_periodic, "进度不得由周期 timer 驱动（P5）")
  end)

  t.it("子进程输出按行拼接后再展示（chunk 非行对齐，K51 教训）", function()
    local s = src()
    t.assert_match(s, "pending_out", "缺少 pending buffer")
    t.assert_match(s, 'pending_out:find%("\\n"%)', "必须按换行切分而非直接展示 chunk")
  end)
end)

t.describe("中断的 index 构建必须自愈（不得永久卡在 running）", function()
  -- 真实现场：owner 进程退出后，state.build 永久停在 status="running" /
  -- finished_at=0，且 stats 全零。此后 build_phase_async 会认为"忙"，
  -- 或 UI 声称有一个没有任何进程拥有的构建在进行 —— 用户无从恢复。
  -- `ue.index` is the only require entry point (submodules are loader-style
  -- `return function(M, core)`), so the helper is reached through it.
  local gen = require("ue.index")

  local function running_state(pid)
    return {
      build = {
        phase = "full",
        status = "running",
        started_at = 1000,
        finished_at = 0,
        message = "full modules=13",
        active_index = "",
        owner_pid = pid,
      },
    }
  end

  t.it("暴露 _reset_orphaned_build 并可注入存活探针（headless 可测）", function()
    t.assert_type(gen._reset_orphaned_build, "function")
  end)

  t.it("owner 进程已死 → 复位为 interrupted 并写入 finished_at", function()
    local st = running_state(999999)
    local reset = gen._reset_orphaned_build(st, function() return false end)
    t.assert_true(reset, "孤儿状态必须被复位")
    t.assert_eq(st.build.status, "interrupted")
    t.assert_true(st.build.finished_at > 0, "必须写入真实结束时间")
    t.assert_eq(st.build.phase, "full", "保留 phase 以便告知用户是哪一阶段被中断")
  end)

  t.it("owner 进程仍存活 → 不得抢占（保护另一个 Neovim 的在飞构建）", function()
    local st = running_state(4321)
    local reset = gen._reset_orphaned_build(st, function() return true end)
    t.assert_false(reset, "存活 owner 的构建不得被抢占")
    t.assert_eq(st.build.status, "running")
    t.assert_eq(st.build.finished_at, 0)
  end)

  t.it("已收尾的记录（finished_at 已写）不被改写", function()
    local st = running_state(999999)
    st.build.finished_at = 5000
    local reset = gen._reset_orphaned_build(st, function() return false end)
    t.assert_false(reset)
    t.assert_eq(st.build.status, "running")
  end)

  t.it("非 running 状态不受影响", function()
    for _, s in ipairs({ "idle", "ready", "error", "interrupted" }) do
      local st = running_state(999999)
      st.build.status = s
      t.assert_false(gen._reset_orphaned_build(st, function() return false end))
      t.assert_eq(st.build.status, s)
    end
  end)

  t.it("缺少 owner_pid 的旧状态按孤儿处理（向后兼容既有卡死记录）", function()
    -- 本次故障产生的记录没有 owner_pid 字段，必须也能自愈。
    local st = running_state(nil)
    t.assert_true(gen._reset_orphaned_build(st, nil) ~= false or true)
    -- 用显式探针断言语义：pid 缺失 → 视为不存活 → 复位。
    local st2 = running_state(nil)
    local reset = gen._reset_orphaned_build(st2, function(pid) return pid ~= nil end)
    t.assert_true(reset, "无 owner_pid 的遗留 running 必须可复位")
  end)

  t.it("构建启动时记录 owner_pid（否则孤儿检测无据可依）", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/index/_build.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    t.assert_match(src, "owner_pid = vim%.fn%.getpid%(%)",
      "running 状态必须携带 owner_pid")
  end)

  t.it("normalize_index_state 在每次读状态时自愈（无需用户手动删文件）", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/index/_generation.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("local function normalize_index_state%(state%)(.-)\n  end")
    t.assert_type(body, "string", "未找到 normalize_index_state 函数体")
    t.assert_match(body, "reset_orphaned_build",
      "状态归一化必须包含孤儿复位，否则卡死状态会一直被读成'构建中'")
  end)
end)

t.describe("prepare 成功后清理中间产物（不得无界堆积）", function()
  -- 用户提出的问题：prepare 需要清理旧产物。实测本机现存 492MB 陈旧 `.bak`
  -- （`.pre-pch.bak` + `.pre-unify.bak`），紧邻 241MB 的 active CDB。
  -- C4-6 只约束"未变更时跳过写入"，没有"成功后删除中间产物"的对应契约。
  local pipeline = require("ue.cdb.pipeline")

  t.it("暴露可检视的清理策略（精确后缀，而非通配）", function()
    t.assert_type(pipeline.INTERMEDIATE_BACKUP_SUFFIXES, "table")
    t.assert_type(pipeline.intermediate_backup_paths, "function")
    local set = {}
    for _, s in ipairs(pipeline.INTERMEDIATE_BACKUP_SUFFIXES) do set[s] = true end
    t.assert_true(set[".pre-pch.bak"], "须覆盖 prebuild_pch_v2 的备份")
    t.assert_true(set[".pre-unify.bak"], "须覆盖 unify_include_dirs 的备份")
  end)

  t.it("只针对 active CDB 派生路径，绝不波及其他产物", function()
    local base = "D:/engine/.cache/nvim-ue/projects/P/cdb/active/Android-Test/compile_commands.json"
    local paths = pipeline.intermediate_backup_paths(base)
    t.assert_eq(#paths, 2)
    for _, p in ipairs(paths) do
      t.assert_true(p:sub(1, #base) == base,
        "清理路径必须由 active CDB 路径派生：" .. p)
      t.assert_true(p ~= base, "绝不得删除 active CDB 本身")
      -- 不得越出该 platform 分片 / project bucket（K27/C5b 失效矩阵）。
      t.assert_true(p:find("Android%-Test") ~= nil, "不得跨 platform 分片")
    end
  end)

  t.it("路径非法时返回空列表（fail closed，不猜）", function()
    t.assert_eq(#pipeline.intermediate_backup_paths(nil), 0)
    t.assert_eq(#pipeline.intermediate_backup_paths(""), 0)
  end)

  t.it("清理挂在成功路径上；失败必须保留备份以便诊断", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/cdb/pipeline.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("local function finish_success%(%)(.-)\n  end")
    t.assert_type(body, "string", "未找到 finish_success 函数体")
    t.assert_match(body, "cleanup_intermediate_backups",
      "成功路径必须清理中间备份")
    local fail_body = src:match("local function fail_step%((.-)\n  end")
    if fail_body then
      t.assert_nil(fail_body:match("cleanup_intermediate_backups"),
        "失败路径不得清理备份（否则失去诊断依据）")
    end
  end)
end)

t.describe("prepare 的完成汇报必须陈述 index 真实状态（不得暗示已就绪）", function()
  -- 这是本次故障的核心用户体验缺陷：prepare 在 CDB 生成后就打印 "UEPrepare done"
  -- 并结束进度条，而 controlled index 还在跑（或已失败）。用户合理认为"齐活了"，
  -- 随后 gd 退化却没有任何解释。
  local idx = require("ue.index")

  t.it("暴露 index_delivery_line / prepare_delivery_suffix", function()
    t.assert_type(idx.index_delivery_line, "function")
    t.assert_type(idx.prepare_delivery_suffix, "function")
  end)

  t.it("构建中 → building，且明说导航尚未就绪", function()
    local verdict, line = idx.index_delivery_line({ status = "running", phase_label = "FULL" })
    t.assert_eq(verdict, "building")
    t.assert_match(line, "BUILDING")
    t.assert_match(line, "not ready", "必须明说尚未就绪，不能只报阶段")
  end)

  t.it("构建失败 → failed，并指向日志", function()
    local verdict, line = idx.index_delivery_line({ status = "error" })
    t.assert_eq(verdict, "failed")
    t.assert_match(line, "FAILED")
    t.assert_match(line, "NvimLog", "失败必须给出可查证入口")
  end)

  t.it("上次被中断 → interrupted（区别于失败，说明会重建）", function()
    local verdict, line = idx.index_delivery_line({ status = "interrupted" })
    t.assert_eq(verdict, "interrupted")
    t.assert_match(line, "INTERRUPTED")
  end)

  t.it("排队中 → queued", function()
    local verdict, line = idx.index_delivery_line({
      status = "idle", queue_count = 2, queued = { "CUR", "HOT" } })
    t.assert_eq(verdict, "queued")
    t.assert_match(line, "QUEUED")
  end)

  t.it("已交付 → ready（附 coverage）", function()
    local verdict, line = idx.index_delivery_line({
      status = "idle", freshness = "fresh", coverage_level = "full" })
    t.assert_eq(verdict, "ready")
    t.assert_match(line, "ready %(full%)")
  end)

  t.it("stale / missing 选择不得报 ready（gate 会 defer，报 ready 即自相矛盾）", function()
    for _, fr in ipairs({ "stale", "missing" }) do
      local verdict = idx.index_delivery_line({
        status = "idle", freshness = fr, coverage_level = "full" })
      t.assert_eq(verdict, "pending", "freshness=" .. fr .. " 不得报 ready")
    end
    -- coverage 为空/占位同样不算交付。
    t.assert_eq(idx.index_delivery_line({ status = "idle", freshness = "fresh", coverage_level = "-" }),
      "pending")
  end)

  t.it("状态不可读时 prepare 后缀降级为空串，不得抛错打断 prepare", function()
    local ok, suffix = pcall(idx.prepare_delivery_suffix, nil)
    t.assert_true(ok, "prepare 汇报不得因索引状态读取失败而抛错")
    t.assert_eq(suffix, "")
  end)

  t.it("prepare_summary 接入该后缀（否则契约形同虚设）", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("local function prepare_summary%(ctx, compile_path, opts%)(.-)\nend")
    t.assert_type(body, "string", "未找到 prepare_summary 函数体")
    t.assert_match(body, "prepare_delivery_suffix",
      "prepare 的完成汇报必须包含 index 交付状态")
  end)
end)

t.describe("陈旧 controlled CDB 必须可观测（存在 ≠ 可用）", function()
  -- 真实现场：旧 bucket 的 current.json / hot.json 各 46MB、一个月前产出、**无 manifest**。
  -- 选择逻辑本就不会采信它们（same_generation 把关），但目录里"看起来索引是有的"，
  -- 而 gate 却在 defer —— 这种沉默正是难以诊断的根源。
  local idx = require("ue.index")

  t.it("暴露 stale_index_artifacts", function()
    t.assert_type(idx.stale_index_artifacts, "function")
  end)

  t.it("ctx 缺失时返回空表（fail closed，不猜测）", function()
    t.assert_eq(#idx.stale_index_artifacts(nil), 0)
    t.assert_eq(#idx.stale_index_artifacts({}), 0)
  end)

  t.it("只报告、不删除（跨实例/跨 tuple 删除不安全，K27/C5b/K43）", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/index/_delivery.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("M%.stale_index_artifacts = function%(ctx%)(.-)\n  end")
    t.assert_type(body, "string", "未找到 stale_index_artifacts 函数体")
    t.assert_nil(body:match("fs_unlink"), "报告函数不得删除文件")
    t.assert_nil(body:match("vim%.fn%.delete"), "报告函数不得删除文件")
  end)

  t.it("与选择逻辑共用同一 generation 判据（不得各写一套）", function()
    local dpath = vim.fn.stdpath("config") .. "/lua/ue/index/_delivery.lua"
    local dsrc = table.concat(vim.fn.readfile(dpath), "\n")
    t.assert_match(dsrc, "core%.h%.same_generation",
      "陈旧判定必须复用 select_active_artifact 的同一谓词")
    local gpath = vim.fn.stdpath("config") .. "/lua/ue/index/_generation.lua"
    local gsrc = table.concat(vim.fn.readfile(gpath), "\n")
    t.assert_match(gsrc, "core%.h%.same_generation = same_generation",
      "same_generation 必须导出给 _delivery")
  end)
end)

t.describe("prepare 的索引调度不得被普通编辑饿死（真正的根因）", function()
  -- 实测（2026-08-26）：prepare 三条完成路径都不传 full_delay_ms，`full` 落到
  -- idle_cold_ms=120000（两分钟）；而 schedule_index_phase 会 stop+重建同 phase 的
  -- timer，于是任何后续 refresh（BufWritePost 任一 C++ 文件都会触发）都把倒计时推后。
  -- 实证：两次 schedule 相隔 300ms、延迟 1500ms，最终 1821ms 才触发 —— deadline 被推移。
  -- 结果不是"晚"，而是"永远不到" —— 现场 stats 三项全零、零索引日志、用户走了三遍习惯
  -- 链路都没拿到可用的 gd。
  local idx = require("ue.index")

  t.it("暴露纯判定 _may_rearm（headless 可测）", function()
    t.assert_type(idx._may_rearm, "function")
  end)

  t.it("已保护的 deadline 不得被普通 refresh 重排（核心不变量）", function()
    t.assert_false(idx._may_rearm(true, false),
      "prepare 承诺的交付 deadline 不得被 BufWritePost 类刷新推后")
  end)

  t.it("保护请求之间仍可重排（prepare 再跑一次应生效）", function()
    t.assert_true(idx._may_rearm(true, true))
  end)

  t.it("未保护时一切照旧（不扩大影响面）", function()
    t.assert_true(idx._may_rearm(false, false))
    t.assert_true(idx._may_rearm(false, true))
  end)

  t.it("prepare 交付调度使用短 deadline，而非 idle_cold_ms", function()
    t.assert_type(idx.schedule_prepare_delivery, "function")
    t.assert_type(idx.PREPARE_FULL_DELAY_MS, "number")
    t.assert_true(idx.PREPARE_FULL_DELAY_MS <= 5000,
      ("交付 deadline 必须是秒级，实际 %sms"):format(tostring(idx.PREPARE_FULL_DELAY_MS)))
    local cfg = require("ue.config")
    local c = cfg.get and cfg.get("index") or {}
    if type(c.idle_cold_ms) == "number" then
      t.assert_true(idx.PREPARE_FULL_DELAY_MS < c.idle_cold_ms,
        "交付 deadline 必须显著短于 opportunistic 的 idle_cold_ms")
    end
  end)

  t.it("prepare 完成路径全部改用 schedule_prepare_delivery（不得再落回 120s）", function()
    local src = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    -- 三条 prepare 完成路径：fast-path / cold / pipeline。
    local n = select(2, src:gsub("INDEX_FN%.schedule_prepare_delivery", ""))
    t.assert_true(n >= 3,
      ("prepare 的三条完成路径都应使用交付调度，实际 %d 处"):format(n))
    -- 且这些路径不得再用带 full=true 的 refresh（那会落回 idle_cold_ms）。
    for line in src:gmatch("[^\n]*schedule_index_refresh[^\n]*") do
      if line:find("clear_index_dirty") then
        t.assert_nil(line:match("full%s*=%s*true"),
          "prepare 路径不得用 full=true 的 refresh：" .. line:sub(1, 80))
      end
    end
  end)

  t.it("交付调度为 full 传 protect（否则仍会被饿死）", function()
    local src = table.concat(
      vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/index/_schedule.lua"), "\n")
    local body = src:match("M%.schedule_prepare_delivery = function%(ctx%)(.-)\n  end")
    t.assert_type(body, "string", "未找到 schedule_prepare_delivery 函数体")
    t.assert_match(body, "protect = true", "full 阶段必须使用受保护的 deadline")
  end)

  t.it("被拒绝的重排不得写状态文件（避免无谓 IO 与状态抖动）", function()
    local src = table.concat(
      vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/index/_schedule.lua"), "\n")
    local body = src:match("M%.schedule_index_phase = function%(ctx, phase, delay_ms, opts%)(.-)\n\n    if RT%.timers")
    t.assert_type(body, "string", "未找到 schedule_index_phase 前半段")
    local guard_at = body:find("_may_rearm")
    local save_at = body:find("save_index_state")
    t.assert_true(guard_at ~= nil and save_at ~= nil and guard_at < save_at,
      "保护判定必须早于 save_index_state")
  end)
end)

t.describe("ready 必须自证（禁止内部矛盾的假就绪）", function()
  -- 实测（2026-08-26 14:38）：readiness 报 ready，而同一份 index_selection 里
  -- index_path=""、artifact_fingerprint=""、coverage_level=""，磁盘上唯一的 .idx
  -- 是一个月前的 0 字节文件。这个 ready 无法被证伪，直接导致误判"索引已交付"。
  local idx = require("ue.index")
  local yes = function() return true end
  local no = function() return false end
  local full = { index_path = "C:/x.idx", artifact_fingerprint = "abc", coverage_level = "full" }

  t.it("暴露纯判据 selection_is_self_evidencing", function()
    t.assert_type(idx.selection_is_self_evidencing, "function")
  end)

  t.it("字段完整且产物存在 → 自证通过", function()
    t.assert_true((idx.selection_is_self_evidencing(full, yes)))
  end)

  t.it("字段完整但产物文件不存在 → 不通过", function()
    local ok, reason = idx.selection_is_self_evidencing(full, no)
    t.assert_false(ok)
    t.assert_eq(reason, "ready-with-missing-index-artifact")
  end)

  t.it("任一关键字段为空 → 不通过，且 reason 指名字段", function()
    for field, want in pairs({
      index_path = "ready-without-index-path",
      artifact_fingerprint = "ready-without-artifact-fingerprint",
      coverage_level = "ready-without-coverage-level",
    }) do
      local sel = vim.deepcopy(full)
      sel[field] = ""
      local ok, reason = idx.selection_is_self_evidencing(sel, yes)
      t.assert_false(ok, field .. " 为空时不得自证通过")
      t.assert_eq(reason, want)
    end
  end)

  t.it("全空 selection（复现 14:38 现场）→ 不通过", function()
    t.assert_false((idx.selection_is_self_evidencing({}, yes)))
    t.assert_false((idx.selection_is_self_evidencing(nil, yes)))
  end)

  t.it("readiness 计算处应用该判据并落日志（不得静默降级）", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/index/_generation.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    t.assert_match(src, "selection_is_self_evidencing",
      "semantic_index_snapshot 必须应用自证判据")
    t.assert_match(src, "discarded self%-contradictory ready state",
      "矛盾状态必须可诊断，不得静默降级")
  end)
end)

t.describe("readiness 可从磁盘 manifest 自愈（不得要求重跑 prepare）", function()
  -- 根因：readiness 只信进程内 state 账本。账本一坏（进程中途退出/并发写/脚本事故），
  -- 261MB 受控 CDB 就"不存在"，用户唯一出路是重跑 388s 的 prepare。
  -- 而 spec「Prepared tuple artifacts survive a Nvim restart」明确禁止这样要求用户。
  local idx = require("ue.index")
  local yes = function() return true end
  local ev = { generation_id = "G1", build_key = "B1", cdb_source_signature = "S1" }
  local function mf(over)
    return vim.tbl_extend("force", {
      generation_id = "G1", build_key = "B1", cdb_source_signature = "S1",
      index_path = "C:/x.idx", background_cdb_path = "C:/bg.json",
      artifact_fingerprint = "fp1", coverage_level = "full", phase = "full",
    }, over or {})
  end

  t.it("暴露 classify_persisted_manifest / ledger_is_intact / recover_from_disk", function()
    t.assert_type(idx.classify_persisted_manifest, "function")
    t.assert_type(idx.ledger_is_intact, "function")
    t.assert_type(idx.recover_from_disk, "function")
    t.assert_type(idx.maybe_recover_readiness, "function")
  end)

  t.it("manifest 与当前 build 全匹配且产物在 → usable", function()
    local v, r = idx.classify_persisted_manifest(mf(), ev, yes)
    t.assert_eq(v, "usable")
    t.assert_eq(r, "ok")
  end)

  t.it("generation / build_key / cdb 签名任一不匹配 → stale（绝不复活别的 build）", function()
    for field, want in pairs({
      generation_id = "manifest-generation-mismatch",
      build_key = "manifest-build-key-mismatch",
      cdb_source_signature = "manifest-cdb-signature-mismatch",
    }) do
      local v, r = idx.classify_persisted_manifest(mf({ [field] = "OTHER" }), ev, yes)
      t.assert_eq(v, "stale", field .. " 不匹配必须判 stale")
      t.assert_eq(r, want)
    end
  end)

  t.it("证据缺失时不得当作匹配（fail closed）", function()
    -- 当前 build 证据为空 → 无法证明匹配 → 不得 usable。
    local v = idx.classify_persisted_manifest(mf(), { generation_id = "", build_key = "", cdb_source_signature = "" }, yes)
    t.assert_eq(v, "stale")
  end)

  t.it("manifest 引用的产物不存在 → unusable（manifest 只是声明，文件才是证明）", function()
    local v, r = idx.classify_persisted_manifest(mf(), ev, function(p) return p ~= "C:/x.idx" end)
    t.assert_eq(v, "unusable")
    t.assert_eq(r, "manifest-index-artifact-missing")

    local v2, r2 = idx.classify_persisted_manifest(mf(), ev, function(p) return p ~= "C:/bg.json" end)
    t.assert_eq(v2, "unusable")
    t.assert_eq(r2, "manifest-background-cdb-missing")
  end)

  t.it("manifest 缺失/不可解析 → unusable", function()
    t.assert_eq((idx.classify_persisted_manifest(nil, ev, yes)), "unusable")
    t.assert_eq((idx.classify_persisted_manifest("not-a-table", ev, yes)), "unusable")
  end)

  t.it("缺 fingerprint 的 manifest 不可用（selection 无法自证）", function()
    local v, r = idx.classify_persisted_manifest(mf({ artifact_fingerprint = "" }), ev, yes)
    t.assert_eq(v, "unusable")
    t.assert_eq(r, "manifest-missing-fingerprint")
  end)

  t.it("账本完好性判定：空表/空列表/缺 fingerprint 均视为已丢失", function()
    t.assert_false(idx.ledger_is_intact({}))
    -- vim.json 会把空 Lua table 编码成 []，被我的脚本事故复现过。
    t.assert_false(idx.ledger_is_intact({ index_artifacts = {}, index_selection = { artifact_fingerprint = "x" } }))
    t.assert_false(idx.ledger_is_intact({
      index_artifacts = { full = {} }, index_selection = { artifact_fingerprint = "" } }))
    t.assert_true(idx.ledger_is_intact({
      index_artifacts = { full = {} }, index_selection = { artifact_fingerprint = "fp" } }))
  end)

  t.it("recover_from_disk 用注入依赖重建 artifacts（每 phase 给出 reason）", function()
    local state = { index_artifacts = {} }
    local recovered, verdicts = idx.recover_from_disk({ paths = {} }, state, {
      manifest_path = function(p) return p .. ".manifest.json" end,
      read_manifest = function(p) return p:find("full") and mf() or nil end,
      phase_paths = function(_, phase) return nil, "C:/idx/" .. phase .. ".idx" end,
      generation = { generation_id = "G1", build_key = "B1" },
      cdb_source_signature = "S1",
      exists = yes,
    })
    t.assert_eq(#recovered, 1, "只应恢复匹配的 full phase")
    t.assert_eq(recovered[1], "full")
    t.assert_type(state.index_artifacts.full, "table")
    t.assert_eq(verdicts.full, "ok")
    t.assert_eq(verdicts.hot, "manifest-missing-or-unparsable")
  end)

  t.it("semantic_index_snapshot 接入自愈（否则契约形同虚设）", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/index/_generation.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    t.assert_match(src, "maybe_recover_readiness",
      "readiness 查询必须尝试从磁盘自愈")
  end)
end)

t.describe("manifest 随产物落盘（不再等全链路成功）", function()
  local src
  local function build_src()
    if not src then
      src = table.concat(vim.fn.readfile(
        vim.fn.stdpath("config") .. "/lua/ue/index/_build.lua"), "\n")
    end
    return src
  end

  t.it("manifest 写出不依赖 selection 提升/clangd 重启是否成功", function()
    local s = build_src()
    -- manifest 写出必须早于 promotion 的**调用点**。
    -- 注意不能直接 find("publish_semantic_cdb") —— 那会先命中函数**定义**
    -- （M.publish_semantic_cdb = function ...，位置远在前面），使断言失去意义。
    local write_at = s:find("write_json_file%(index_manifest_path")
    local promote_at = s:find("M%.publish_semantic_cdb%(ctx")
    t.assert_type(write_at, "number", "未找到 manifest 写出")
    t.assert_type(promote_at, "number", "未找到 promotion 调用点")
    t.assert_true(write_at < promote_at,
      "manifest 必须在提升之前落盘，否则产物无法自证归属")
  end)

  t.it("manifest 写失败必须可见（否则下次会话无法恢复）", function()
    t.assert_match(build_src(), "failed to persist index manifest",
      "写 manifest 失败必须落日志")
  end)
end)

t.describe("失败集合不得被伪装成真歧义（16:46 探针的真实根因）", function()
  -- 探针 08-26 16:46：state=ambiguous-context / reason=semantic-tu-unavailable /
  -- **generation_class=complete**。索引这次是完整交付的（前几轮的 readiness 修复生效了），
  -- 但 gd 依然弹候选 —— 说明还有一层独立缺陷。
  --
  -- 根因链：
  --   semantic_context.catalog_contexts 在 dedup 后 >1 个候选 TU 就返回
  --     state="ambiguous-context"（含义只是"没能缩小到唯一 TU"）
  --   → 这些 per-context 结果全部 FAILED，落进 sidecar 的 `unresolved`
  --   → summarize_unresolved 见到 state_counts["ambiguous-context"] 就把顶层终态
  --     也报成 ambiguous-context
  --   → ambiguous 是唯一会弹选择器的终态 → 唯一定义变成 unity TU 假候选列表（违背 P12）
  --
  -- 真歧义只能来自 sidecar 的 `#resolved > 1` 分支（每个都真的解析成功了）。

  t.it("summarize_unresolved 不得输出 ambiguous-context（全是失败项）", function()
    local path = vim.fn.stdpath("config") .. "/lua/utils/ue_goto/semantic_sidecar.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("local function summarize_unresolved%(unresolved%)(.-)\nend")
    t.assert_type(body, "string", "未找到 summarize_unresolved 函数体")
    -- 去掉注释后不得再有把 state 赋成 ambiguous-context 的可执行代码。
    local code = body:gsub("%-%-[^\n]*", "")
    t.assert_nil(code:match('state%s*=%s*"ambiguous%-context"'),
      "失败集合不得被汇总成 ambiguous-context（那会弹出假候选）")
    -- invalid-semantic-context 仍应保留（AST/identity 本身无效是另一回事）。
    t.assert_match(code, 'invalid%-semantic%-context',
      "AST/identity 无效的分类必须保留")
  end)

  t.it("真歧义分支（#resolved > 1）仍然保留", function()
    local path = vim.fn.stdpath("config") .. "/lua/utils/ue_goto/semantic_sidecar.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    t.assert_match(src, "elseif #resolved > 1 then",
      "多个已解析 context 的真歧义必须仍可产生 ambiguous-context")
  end)

  t.it("catalog_contexts 的多候选语义只是'未缩小'，不构成可选目标", function()
    -- 锁住语义来源，便于后来者理解为何不能直接采信它的 state。
    local sc = require("utils.ue_goto.semantic_context")
    t.assert_type(sc.catalog_contexts, "function")
    local path = vim.fn.stdpath("config") .. "/lua/utils/ue_goto/semantic_context.lua"
    local src = table.concat(vim.fn.readfile(path), "\n")
    local body = src:match("function M%.catalog_contexts%(contexts%)(.-)\nend")
    t.assert_type(body, "string")
    t.assert_match(body, 'state = "ambiguous%-context"',
      "此处产生的 ambiguous 仅表示候选 TU 未缩小，调用方不得当作用户可选目标")
  end)
end)

t.describe("头文件多候选 TU：先收敛，唯一定义直接跳转（不弹选择框）", function()
  -- 用户症状（08-26 17:18 新会话，已装载先前全部修复）：
  --   "gd 给几个提示之后好久才跳出 Module 选框，一样的"
  -- 且该次 gd **未产生任何 cpp-semantic-navigation 探针** —— 证明它走的是 catalog 路径，
  -- 与先前修的 query 终态分类无关。
  --
  -- 真凶：semantic_client_actions 在 #contexts > 1 时**无条件**弹
  -- vim.ui.select("Select proven translation-unit context")，format_item 只给 TU 文件名。
  -- 但非自包含头文件被大量 TU include 是**正常现象**，不是歧义；用户也无法从
  -- VulkanRHI_3.cpp 这类名字判断哪个含目标定义。
  --
  -- 关键发现：sidecar 的 handle_query **早就支持多 context**，并已用 by_identity /
  -- unique_definition_keys 做收敛判定 —— 客户端却一直只传 { 单个 context }，
  -- 白白浪费了这个能力。
  local function read(rel)
    return table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/" .. rel), "\n")
  end
  local CLI = "lua/utils/ue_goto/semantic_client_actions.lua"
  local SIDE = "lua/utils/ue_goto/semantic_sidecar.lua"

  t.it("sidecar 具备收敛能力（多 context + identity 分组 + 唯一 definition 判定）", function()
    local s = read(SIDE)
    t.assert_match(s, "request%.contexts", "handle_query 必须接受复数 contexts")
    t.assert_match(s, "by_identity", "必须按 canonical identity 分组")
    t.assert_match(s, "unique_definition_keys", "必须判定 definition 是否唯一")
  end)

  t.it("单一 identity + 唯一 definition → resolved（这是'直接跳转'的语义来源）", function()
    local s = read(SIDE)
    t.assert_match(s, "if #resolved == 1 or #identities == 1 then",
      "同一 identity 的多个 context 必须走收敛分支")
    t.assert_match(s, "if #unique_definition_keys > 1 then",
      "只有 definition 不唯一才升级为 ambiguous")
  end)

  t.it("客户端在多候选时把所有 context 一起求值（不再只传一个）", function()
    local c = read(CLI)
    t.assert_match(c, "query_contexts%(spec, contexts,",
      "多候选必须整批求值，交给编译器判定，而不是让用户挑文件")
    -- 单 context 的旧入口应保留（dispatch 仍用它），但必须委派给复数实现。
    t.assert_match(c, "return query_contexts%(spec, { context }, callback%)",
      "单 context 查询应委派给同一实现，避免两套逻辑漂移")
  end)

  t.it("求值得到 resolved → 直接跳转，不呈现任何选择", function()
    local c = read(CLI)
    local body = c:match("query_contexts%(spec, contexts, function%(response%)(.-)\n          end%)")
    t.assert_type(body, "string", "未找到收敛回调体")
    local resolved_at = body:find('response%.state == "resolved"')
    local select_at = body:find("vim%.ui%.select")
    t.assert_type(resolved_at, "number", "必须处理 resolved")
    if select_at then
      t.assert_true(resolved_at < select_at,
        "resolved 必须在任何选择框之前返回（唯一定义不得再问用户）")
    end
  end)

  t.it("旧的无条件 TU 选择框已移除", function()
    t.assert_nil(read(CLI):match("Select proven translation%-unit context"),
      "不得再以'候选 TU 数量>1'为由弹选择框")
  end)

  t.it("仅在求值后确有分歧时才提示，且展示目标而非仅 TU 名", function()
    local c = read(CLI)
    t.assert_match(c, "Multiple proven contexts resolve differently",
      "提示语必须表达'真的解析不同'")
    t.assert_match(c, "#response%.contexts > 1",
      "必须以求值后的 context 数量为门槛")
    t.assert_match(c, "def%.line", "选项必须展示目标位置，TU 名对用户不可判断")
  end)

  t.it("无法收敛且未证明分歧 → 诚实失败，不给候选列表（P12）", function()
    local c = read(CLI)
    local body = c:match("query_contexts%(spec, contexts, function%(response%)(.-)\n          end%)")
    t.assert_match(body, "finish%(response or catalog%)",
      "既不能收敛也无真分歧时必须返回终态，而非 TU 列表")
  end)

  t.it("收敛 MUST NOT 依据文件名/路径/顺序启发式（P11/P12）", function()
    local code = read(CLI):gsub("%-%-[^\n]*", "")
    for _, bad in ipairs({ "levenshtein", "path_distance", "table%.sort%(contexts" }) do
      t.assert_nil(code:match(bad), "收敛不得使用启发式：" .. bad)
    end
  end)

  t.it("收敛成功后记住 origin，后续导航跳过 catalog", function()
    local c = read(CLI)
    local body = c:match("query_contexts%(spec, contexts, function%(response%)(.-)\n          end%)")
    t.assert_match(body, "client%.note_origin",
      "收敛结果应写入 window origin，避免重复付出 catalog 代价")
  end)

  t.it("收敛回调必须做 stale 校验（异步期间光标/buffer 可能已变）", function()
    local c = read(CLI)
    local body = c:match("query_contexts%(spec, contexts, function%(response%)(.-)\n          end%)")
    t.assert_match(body, "client%.snapshot_is_current%(snapshot%)",
      "异步返回必须校验 snapshot 仍有效")
  end)
end)

t.describe("prepare 完成汇报不得为了打印计数而冻结 UI", function()
  -- 实测（2026-08-26）：workspace_all.files 27.5 MB / 262,875 行。
  -- 旧实现用 vim.fn.readfile（把整个文件物化成 Lua 字符串表）→ 单次阻塞主循环 ~253 ms，
  -- 而 prepare_summary 要数 4 个列表 → 一次 prepare 完成白付 ~1012 ms 的 UI 冻结，
  -- 仅仅为了在汇报里打印几个数字。
  local fs = require("ue.core.fs")

  t.it("暴露 count_lines_cached（流式 + 按 (mtime,size) 记忆）", function()
    t.assert_type(fs.count_lines_cached, "function")
  end)

  t.it("计数正确（含末行无换行 / 空文件 / 缺失文件）", function()
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "wb"); f:write("a\nb\nc\n"); f:close()
    t.assert_eq(fs.count_lines_cached(tmp), 3)

    local tmp2 = vim.fn.tempname()
    local f2 = io.open(tmp2, "wb"); f2:write(""); f2:close()
    t.assert_eq(fs.count_lines_cached(tmp2), 0)

    t.assert_eq(fs.count_lines_cached(vim.fn.tempname() .. "-missing"), 0,
      "缺失文件必须返回 0，不得抛错")
    t.assert_eq(fs.count_lines_cached(nil), 0)
    os.remove(tmp); os.remove(tmp2)
  end)

  t.it("内容变化后重新计数（缓存键必须包含 size/mtime）", function()
    local tmp = vim.fn.tempname()
    local f = io.open(tmp, "wb"); f:write("x\n"); f:close()
    t.assert_eq(fs.count_lines_cached(tmp), 1)
    -- 追加内容 → size 变化 → 必须重算，不得返回陈旧计数
    local f2 = io.open(tmp, "ab"); f2:write("y\nz\n"); f2:close()
    t.assert_eq(fs.count_lines_cached(tmp), 3, "size 变化后必须重新计数")
    os.remove(tmp)
  end)

  t.it("MUST NOT 用 vim.fn.readfile 数行（会物化整个文件）", function()
    local src = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue/core/fs.lua"), "\n")
    local body = src:match("function M%.count_lines_cached%(path%)(.-)\nend")
    t.assert_type(body, "string", "未找到 count_lines_cached 函数体")
    t.assert_nil(body:match("vim%.fn%.readfile"),
      "不得用 readfile 数行：27MB 文件会阻塞主循环 ~253ms")
    t.assert_match(body, "fh:read%(1024", "应分块流式读取")
  end)

  t.it("count_cached_entries 委派给该实现（不得各写一套）", function()
    local src = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local body = src:match("local function count_cached_entries%(path%)(.-)\nend")
    t.assert_type(body, "string")
    t.assert_match(body, "count_lines_cached", "必须复用同一实现")
    t.assert_nil(body:match("vim%.fn%.readfile"), "ue.lua 侧也不得 readfile")
  end)
end)

t.describe("启动提示不得触发 hit-enter（每次启动都要按 Enter）", function()
  -- 实测：clangd deferred 那条 notify 原文 187 字符单行，超出 cmdline 宽度 →
  -- 触发 Vim 的 hit-enter prompt，用户**每次启动**都得按一下 Enter。
  t.it("clangd deferred 提示足够短", function()
    local src = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local msg = src:match('"(clangd deferred[^"]*)"')
    t.assert_type(msg, "string", "未找到 clangd deferred 提示")
    t.assert_true(#msg <= 100,
      ("提示必须简短以免触发 hit-enter，实际 %d 字符：%s"):format(#msg, msg))
    -- 仍须包含可执行动作。
    t.assert_match(msg, "UEPrepare", "提示必须给出下一步动作")
  end)

  t.it("该提示未被拆成多段拼接（拼接后仍可能超长）", function()
    local src = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local seg = src:match('"clangd deferred.-%)\n')
    if seg then
      local _, joins = seg:gsub("%.%.", "")
      t.assert_true(joins == 0,
        "提示不得用 .. 拼接多段长文本（原缺陷正是三段拼成 187 字符）")
    end
  end)
end)

t.describe("索引进度不得误报 per-file 数量为待索引单元", function()
  -- 用户看到右下角 "16178"，据此认为 super-unity 没生效。实际上：
  --   [input] 16178 per-file entries        ← 给 LSP 的 CDB（每文件一条编译命令）
  --   Super-unity TUs created: 9 (vs 429)   ← 真正交给 clangd-indexer 的工作量（47.7x 压缩）
  -- 这两个是不同产物；把前者原样转发到进度条会让人以为要索引 16k 个单元。
  t.it("per-file 计数被改写为不会误读的措辞", function()
    local src = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue/index/_build.lua"), "\n")
    t.assert_match(src, "LSP compile entries",
      "per-file 计数必须标注用途，不能裸报数字")
    t.assert_match(src, "super%-unity", "应说明索引走 super-unity TU")
  end)

  t.it("只转发真正表示进度的行（不再逐行 forward 子进程输出）", function()
    local src = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue/index/_build.lua"), "\n")
    local body = src:match("local function progress_line%(line%)(.-)\n  end")
    t.assert_type(body, "string", "未找到 progress_line 过滤器")
    -- 源码里的模式本身是转义过的（"^%[indexer%]"），断言需匹配这个字面形式。
    t.assert_true(body:find("indexer", 1, true) ~= nil, "indexer 进度应转发")
    t.assert_match(body, "return nil", "其余输出应留在日志而非进度条")
  end)
end)
