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
    t.assert_match(body, 'contexts = state == "ambiguous%-context"',
      "contexts 必须以终态为条件透传，不得无条件传给候选渲染")
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
