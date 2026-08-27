## 1. 固定证据与范围（先量清，避免又"以为修好了"）

- [x] 1.1 记录 AppControl `app_sysmon.db`（binary_id=258 = LLVM clangd 22.1.5）今日时间线：
      14:34–14:54 / 16:45–16:55 / **17:56–18:46 持续 50 分钟满负荷**；
      而 CPU 相关改动落盘于 16:03–16:05 → **复发发生在修改之后**，用户判断正确。
- [x] 1.2 记录覆盖缺口：`rg -l "admit_background_phase"` 仅命中
      `_admission.lua` / `_schedule.lua`；而 spawn 点分散于 ue.lua(24)、dap/android(16)、
      cdb/pipeline(10)、index/_build(4)、task_registry(4) 等十余文件 → 结构性缺口。
- [x] 1.3 记录三类视野外负载：事发时 clangd 本体仅静态 -j=20（24 核的 83%；已先降为 12）、
      UE build、Neovide 渲染；以及必须排除的外部进程（rustc 等）。
- [x] 1.4 确认 `--background-index-priority` 按 clangd --help 为 OS-specific，
      **本平台未验证**，不得计入已有防线。

## 2. 把 P6 扩写为宿主级原则（文档先行，因为它是判据来源）

- [x] 2.1 `docs/CONSTRAINTS.md` P6：改为「不得阻塞主循环 **且** 不得占满宿主」，
      并写明「资源让路优先于功能尽快完成」。
- [x] 2.2 `docs/CONSTRAINTS.md` §三 C4 第 2 条同步（仓内不存在 README Conventions 节，原任务引用陈旧）。
- [x] 2.3 新增坑条目：记录本次"只覆盖 index、clangd 裸奔"的教训（避免再犯）。

## 3. 通用准入判据（从 index 子系统提升为全仓工具）

- [x] 3.1 把 `_admission.admit_background_phase` / `admission_opts` 提升为通用模块
      （候选 `lua/utils/host_admission.lua`），保持纯函数 + 可注入。
- [x] 3.2 `ue.index._admission` 改为薄委派，**不得**保留第二份阈值。
- [x] 3.3 阈值配置收口一处（现 `ue.config.index.cpu_*` 需评估是否上移为通用命名）。
- [x] 3.4 用例：两处调用得到完全一致的判定（防漂移）。

## 4. 按类型接入

- [x] 4.1 可推迟批任务：CDB pipeline、csearch/GTAGS、ccjson subprocess 接入推迟（index 已完成）；
      watcher shader GTAGS MUST 从 timer 内同步 wait 改为 async。
- [x] 4.2 长驻服务：clangd 进程 OS 级降级（见
      `constrain-clangd-under-cpu-pressure`，本 change 只保证纪律一致）。
- [x] 4.3 前台任务：UEBuild/install/deploy **不得**被自动推迟；但 SHALL 抑制后台批任务
      （复用 K51 已有的 build ⇄ prepare 互斥）。
- [x] 4.4 并发预算复审：`clangd_jobs` 当前 24 核给 20（83%）过高，SHALL 更保守。

## 5. 防遗漏（这是本 change 最容易失败的地方）

- [x] 5.1 回归用例：扫描 `lua/` 中 `vim.system`、`jobstart`、`termopen`、`vim.loop/uv.spawn`、
      `vim.lsp.rpc.start`；新增 spawn 若未分类为 admitted batch / foreground / long-lived，且不在
      显式白名单（短命令/交互查询/detached opener/DAP）则 FAIL。
- [x] 5.2 白名单按精确 path + anchor + 期望数量登记并带理由，不得用整个 API/整个文件默默豁免。

## 6. 回归与验收

- [x] 6.1 分范围 `cpu_admission` `ui_responsiveness` `index_delivery` `ue_api` `ue_cdb`
      `stability` `structure`；提交前全量。
- [x] 6.2 **agent MUST NOT 自行启动真实 clangd / 真实构建验证**（前次致用户机器卡死）。
- [x] 6.3 真实验收由用户在自身会话观察；agent SHALL 提供判断依据
      （看哪些进程、期望什么优先级/负载），不得要求用户执行额外命令。
- [x] 6.4 changelog + spec 一致性处置。
