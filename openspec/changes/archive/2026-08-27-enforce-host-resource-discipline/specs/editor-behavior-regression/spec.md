## MODIFIED Requirements

### Requirement: 主循环余量（main-loop headroom）

编辑器 MUST NOT 在任何时刻卡顿（P6）。该要求有**两个层面**，缺一不可：

1. **进程内**：单个回调不得阻塞主循环；周期性回调、每事件同步 I/O 都属违规。
2. **宿主级**：本配置启动的工作 MUST NOT 把宿主资源占满到编辑器不可用。

第 2 条是首要原则：其余优化都以机器可用为前提。主循环空转得再顺，若 24 核被我们自己 spawn 的
子进程占满，编辑器一样卡。**当资源与功能冲突时，让路优先于功能尽快完成。**

回归套件 SHALL 验证下列不变量。这些不变量在 2026-08-25/26 由实测定位（证据与耗时记录在
`docs/changelog.md`；诊断工具在 `tools/stall_profile.lua`、`tools/stall_attribute.lua`、
`tools/stall_repro.lua`）。

#### Scenario: clangd 并发度必须为 UI 保留 CPU

- **WHEN** 用例以注入的 `(total_mb, cpus)` 调用 `require("ue").clangd_jobs`
- **THEN** 结果 SHALL 同时受内存预算与 CPU 预算约束
- **AND** 当核数已知时，结果 SHALL 至少为 UI 保留 `ue.clangd_jobs.UI_RESERVED_CORES` 个逻辑核
- **AND** 探测失败（`total_mb=0` / `cpus=0`）SHALL 回落到可用默认值，不得产出 0 或负数
- **AND** `ue.clangd_cmd()` 实际 argv 中的 `-j` SHALL 与该策略一致（策略不得被绕过）
- **AND** 显式 `UE_CLANGD_JOBS=N` SHALL 覆盖自动策略（用户意图优先）

#### Scenario: language server 的 stderr 不得每条同步落盘

- **WHEN** `config.ui_responsiveness` 完成 setup
- **THEN** `vim.lsp` 的日志级别 SHALL 为 OFF——server 的普通 stderr 输出不是 error，
  MUST NOT 为每个 chunk 在主循环上支付一次 `write()` + `flush()`
- **AND** SHALL 注册 `:LspLogLevel` 以便排查真实 server 故障时临时提级并恢复

#### Scenario: 禁止在主循环上周期性轮询文件系统

- **WHEN** 用例读取 `lua/config/lazy.lua`
- **THEN** `change_detection` SHALL 显式 `enabled = false`——其 2000ms 周期回调会在主循环上
  同步 `fs_stat` 全部 spec 模块，命中变更时进一步执行 `Plugin.load()` 与相关 autocmd
- **AND** `config.ui_responsiveness.assert_change_detection_disabled` SHALL 在运行时配置与该
  意图漂移时记录告警

#### Scenario: 卡顿记录必须携带归属判定

常驻卡顿探针仅记录「卡了多久」不足以定位；它 SHALL 同时记录该 gap 内本进程消耗的 CPU
与由此得出的归属结论，否则跨越会话的证据无法区分「我们阻塞了主循环」与「宿主超订」。

- **WHEN** `utils.stall_probe` 捕获一条卡顿
- **THEN** 记录 SHALL 含 `verdict`（`in-process` / `descheduled` / `mixed` / `unknown`）
- **AND** `verdict` SHALL 由 cpu/gap 比值得出，且保留 `mixed` 中间带，MUST NOT 强行二分
- **AND** rusage 不可用时 SHALL 诚实为 `unknown`，MUST NOT 默认猜一个归属
- **AND** 归属数据 SHALL 同时进入日志（不仅存于会话内 ring buffer）
- **AND** `:StallReport` SHALL 先展示聚合（verdict 分布 + 是否存在新鲜按键）再列明细
- **AND** 探针自身的周期开销 SHALL 保持可忽略（实测 10Hz 下 0.013ms/秒）

#### Scenario: 交互路径禁止同步阻塞主循环

按键与命令路径 MUST NOT 在主循环上等待子进程或 LSP 应答。实测依据（2026-08-25）：
`vim.system():wait()` 在本宿主的**空 spawn 底线就是 87ms p50**，`client:request_sync`
默认可堵至 5000ms。

- **WHEN** 用例检查 `utils.lsp_fallback.references`（`gr` 的实现）
- **THEN** 其函数体 SHALL NOT 使用 `provider.sync_locations` 或同步 `ue.gtags_references`
- **AND** SHALL 经 `provider.async_lsp_request` 与 `ue.gtags_references_async` 完成
- **AND** 异步 references 请求 SHALL 仍携带 `includeDeclaration`，使返回集与同步版一致
  （性能修复 MUST NOT 静默改变可观察行为）

#### Scenario: 周期性回调禁止同步子进程往返（K40 一般化）

- **WHEN** 用例扫描 `lua/`（不含 vendored 副本）中 `timer:start(...)` 回调体
- **THEN** SHALL NOT 出现 `vim.fn.system` / `vim.fn.systemlist`——周期性探测 MUST 使用
  `vim.system` 异步回调或 `jobstart`

## ADDED Requirements

### Requirement: Host resource discipline SHALL apply to every workload this config starts

本配置启动的任何重活（后台索引、CDB pipeline、csearch/gtags 重建、语言服务器、构建与部署）
SHALL 受统一的宿主资源纪律约束。判定 SHALL 复用同一份宿主负载采样与双水位滞回阈值，
MUST NOT 由各子系统各写一套可能漂移的判据。

负载策略 SHALL 按工作类型区分，MUST NOT 一刀切：

- **可推迟的批任务** SHALL 在宿主高于高水位时推迟启动，并在回落后恢复；推迟 SHALL 有上限，
  MUST NOT 因宿主长期繁忙而无限饿死交付。
- **长驻交互服务**（如 clangd）MUST NOT 被 kill 或 suspend——终止会丢弃已建 preamble 并使
  下一次导航重付分钟级代价；SHALL 改用可逆的 OS 级降级与更保守的启动并发度。
- **用户显式发起的前台任务** SHALL NOT 被自动推迟或降级（用户正在等待），但 SHALL 抑制新的
  后台批任务启动。抑制 MUST NOT 为节省 CPU 而终止已经运行的批任务；既有因数据正确性建立的
  build⇄CDB WAW cancel 契约不受影响。

并发预算参数（`-j` 等）SHALL 同时受 RAM 与 CPU 约束，并为 UI 保留余量。

系统 MUST NOT 声称能保证宿主 CPU 低于任何阈值，MUST NOT 操作非自身启动的进程。契约仅为：
不在宿主已饱和时继续加压，且在饱和时主动让路。

#### Scenario: A deferrable batch task becomes due while the host is saturated
- **WHEN** 某可推迟批任务到达其 deadline，而宿主 CPU 高于高水位
- **THEN** 系统 SHALL 推迟其启动，MUST NOT 启动新的重活子进程
- **AND** 推迟原因 SHALL 可观测，MUST NOT 静默无响应

#### Scenario: A long-lived language server is running while the host saturates
- **WHEN** 宿主 CPU 高于高水位且 clangd 正在运行
- **THEN** 系统 SHALL 施加可逆的 OS 级降级（优先级/亲和性）
- **AND** MUST NOT kill 或 suspend 该进程

#### Scenario: The user explicitly starts a foreground build
- **WHEN** 用户显式发起构建/安装/部署，而宿主 CPU 已高于高水位
- **THEN** 系统 SHALL 照常执行该任务（用户在等待）
- **AND** 在其生命周期内 SHALL 抑制新的后台批任务启动
- **AND** MUST NOT 仅为节省 CPU 而终止已经运行的批任务

#### Scenario: External processes dominate the host
- **WHEN** 宿主饱和主要由非本配置启动的进程造成（例如外部编译器）
- **THEN** 系统 SHALL 仍然抑制自身的可推迟工作并降级自身长驻服务
- **AND** MUST NOT 尝试挂起、降级或终止那些外部进程
- **AND** MUST NOT 声称宿主总体 CPU 会因此低于任何阈值

#### Scenario: Load sampling is unavailable
- **WHEN** 宿主负载无法测量（平台不支持或采样失败）
- **THEN** 系统 SHALL 视为无压力并按既有行为执行
- **AND** MUST NOT 因无法测量而永久阻塞任何工作
