# editor-behavior-regression Specification

## Purpose

定义针对本 Neovim 配置中编辑器行为的回归测试覆盖范围：验证 `lua/config/options.lua` 设置的关键 option 取值、自定义 filetype 映射与 FileType autocmd 的可观察行为、workarounds 注册表完整性，以及关键模块重复加载/初始化的幂等与稳定性，确保「开发完跑一遍」即可发现编辑器行为层面的回归。

## Requirements

### Requirement: 编辑器 options 回归

回归套件 SHALL 验证 `lua/config/options.lua` 设置的关键 option 取值符合预期。

#### Scenario: 缩进与行号 option

- **WHEN** options 用例加载 `lua/config/options.lua` 后读取
- **THEN** `expandtab` 为 true、`shiftwidth`/`softtabstop`/`tabstop` 均为 4
- **AND** `number` 为 true、`relativenumber` 为 false

#### Scenario: session 与 list option

- **WHEN** options 用例读取
- **THEN** `sessionoptions` 含 `buffers`、`tabpages`、`winsize`、`skiprtp`
- **AND** `list` 为 false

### Requirement: filetype 与 autocmd 行为回归

回归套件 SHALL 验证自定义 filetype 映射与 FileType autocmd 的可观察行为。

#### Scenario: usf/ush 解析为 hlsl

- **WHEN** 用例加载 options 配置后，对 `foo.usf` / `bar.ush` 调用 `vim.filetype.match`
- **THEN** 返回的 filetype 为 `hlsl`

#### Scenario: C 家族缩进切换为 cindent

- **WHEN** 用例创建一个 `cpp` filetype 的 buffer 并触发 FileType autocmd
- **THEN** 该 buffer 的 `cindent` 为 true、`smartindent` 为 false
- **AND** `cinoptions` 为配置中的 `g0,:0,l1,(0,W4,t0,j1,J1`

#### Scenario: commentstring 回退

- **WHEN** 用例对 `hlsl` filetype 调用 commentstring 回退逻辑
- **THEN** 解析出的 commentstring 含 `%s` 且为 `// %s`

### Requirement: workarounds 注册表完整性回归

回归套件 SHALL 验证 workarounds 注册表能发现所有 workaround 文件、frontmatter 合法且无加载错误。

#### Scenario: 全部 workaround 被发现且无 error

- **WHEN** 用例调用 `require("workarounds").setup({ auto_apply = false })` 后读取 `list()`
- **THEN** 返回的条目数 ≥ 实际 `lua/workarounds/<scope>/*.lua` 文件数
- **AND** 没有任何条目带有非 nil 的 `error` 字段

#### Scenario: frontmatter 必填字段齐全

- **WHEN** 用例遍历注册表条目
- **THEN** 每个无 error 条目均含 `name`、`scope`、`symptom`、`introduced`、`removal_condition` 等必填字段
- **AND** `enabled` 字段为 boolean

#### Scenario: status 查询形状正确

- **WHEN** 用例对任一已注册 workaround 调用 `status(name)`
- **THEN** 返回 table，含 `name`、`scope`、`applied` 字段
- **AND** 对未知名称调用返回 nil

### Requirement: 稳定性与幂等回归

回归套件 SHALL 验证关键模块的重复加载与重复初始化是幂等且无状态泄漏的，守护 nvim 功能稳定性。

#### Scenario: 模块重复 require 幂等

- **WHEN** 用例对 `ue`、`ue.config`、`utils.platform`、`utils.ue_paths` 连续 require 两次
- **THEN** 两次返回同一 table 引用（`==`）

#### Scenario: ue.setup 可重复调用

- **WHEN** 用例连续调用 `require("ue").setup()` 两次
- **THEN** 两次均无异常
- **AND** 关键命令（如 `UEBuild`、`UEDAPAttach`）在两次后仍 `exists == 2`

#### Scenario: config 多轮 override/reset 无泄漏

- **WHEN** 用例执行三轮 `ue.config.setup({...})` → `reset_for_test()`
- **THEN** 每轮 reset 后 `index.idle_cold_ms` 均恢复为默认 120000
- **AND** 末轮结束后 `dap.lldb_dap_path` 为 nil

#### Scenario: DAP 平台注册可重复清空

- **WHEN** 用例连续两次 `ue.dap.platforms._reset_for_test()` 后注册并查询
- **THEN** 注册的 handler 可被 `attach_handler` 取回
- **AND** reset 后未注册项返回 nil

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

#### Scenario: 周期性回调禁止同步子进程往返（K40 一般化）

- **WHEN** 用例扫描 `lua/`（不含 vendored 副本）中 `timer:start(...)` 回调体
- **THEN** SHALL NOT 出现 `vim.fn.system` / `vim.fn.systemlist`——周期性探测 MUST 使用
  `vim.system` 异步回调或 `jobstart`

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

### Requirement: Host load awareness SHALL be continuous, cheap, and attributable

宿主资源纪律（P6 第 2 层）的全部决策都依赖负载读数，因此该读数本身 SHALL 满足下列性质。
感知层 SHALL 只回答「现在多忙、趋势如何、谁在占用」，MUST NOT 内嵌阈值或推迟/降级策略 ——
后者属于准入判定，混入感知层会使阈值散落多处并互相漂移。

**常驻**：系统 SHALL 持续维护宿主忙碌度，使任意调用方在建立首个差分间隔后都能立即获得有效
缓存读数。MUST NOT 采用「仅在被调用时才开始采样」的被动模式：差分读数需要至少两次采样，
被动模式在首次询问时必然返回未知，而那恰是最需要判定的时刻。启动后的首个差分间隔 SHALL 明确
报告为 `warming`，MUST NOT 伪装成 `idle`。

**廉价**：常驻采样的稳态开销 SHALL 可忽略并有明确上限，且 SHALL 优先使用便宜的数据来源。
昂贵来源（如需为每个逻辑核分配对象的整机查询）SHALL 低频调用。感知层 MUST NOT 通过 spawn
子进程获取负载（周期性同步子进程往返会阻塞主循环，见 K40）。一个自身消耗可观 CPU 的 CPU
感知层是自相矛盾的。

**可归属**：系统 SHALL 同时暴露宿主整体忙碌度与 Neovim 本进程的占用，使调用方能观察主循环
自身是否繁忙。`uv.getrusage()` 不包含仍在运行的 clangd 等子进程，因此剩余占用 SHALL 标记为
`unattributed`，MUST NOT 伪装成「外部进程占用」；它既可能来自 rustc，也可能来自本配置启动的
clangd。完整进程树的所有权与控制属于后续资源控制器，不得由感知层编造。

**趋势**：系统 SHALL 暴露平滑值与变化方向，使调节不被单次尖峰误导。

**诚实的状态**：`warming`（首个差分间隔）、`unknown`（平台不支持或计数器未推进）SHALL 与
`idle` 明确区分。调用方 MUST NOT 把 `warming` / `unknown` 当作空闲；系统 MUST NOT 为掩盖未知
而编造读数，也 MUST NOT 因 `unknown` 永久阻塞工作。`uv.loadavg()` MUST NOT 用作判据
（在 Windows 恒为 0，会谎报空闲）。

#### Scenario: A caller asks for load after the priming interval
- **WHEN** 某工作在感知层完成首个差分间隔后查询宿主负载，且此前无人查询过
- **THEN** 系统 SHALL 返回一个基于已有常驻采样的有效缓存读数
- **AND** 查询 MUST NOT 触发新的整机采样

#### Scenario: A caller asks during the priming interval
- **WHEN** 某工作在感知层尚未完成首个差分间隔时查询宿主负载
- **THEN** 系统 SHALL 返回 `warming`
- **AND** MUST NOT 返回 0 或伪装成 `idle`

#### Scenario: Steady-state sampling cost stays negligible
- **WHEN** 感知层常驻运行
- **THEN** 其稳态每秒开销 SHALL 低于既定上限，并由回归用例守护
- **AND** MUST NOT 通过 spawn 子进程采样

#### Scenario: Host and editor-process signals differ
- **WHEN** 宿主整体忙碌度高，而 Neovim 本进程占用很低
- **THEN** 读数 SHALL 分别暴露两者，并把差值标记为 `unattributed`
- **AND** MUST NOT 将该差值宣称为「外部进程占用」

#### Scenario: Neovim itself burns CPU
- **WHEN** 宿主整体忙碌度高，且 Neovim 本进程占用同样可观
- **THEN** 读数 SHALL 使调用方可观察到两个独立信号
- **AND** 感知层 MUST NOT 自行执行降级动作

#### Scenario: A single spike must not flip decisions
- **WHEN** 宿主负载出现单次短时尖峰后立即回落
- **THEN** 平滑值 SHALL 抑制该尖峰的影响
- **AND** 趋势 SHALL 反映方向，使调节不在尖峰上反复启停

#### Scenario: Counters do not advance or the platform is unsupported
- **WHEN** 负载计数器未推进、发生回退（休眠/恢复），或平台不提供所需数据
- **THEN** 系统 SHALL 报告 `unknown`
- **AND** MUST NOT 返回 0 或任何编造的数值

#### Scenario: Awareness layer holds no policy
- **WHEN** 用例检查感知层实现
- **THEN** 其中 SHALL NOT 出现高/低水位阈值、推迟上限或降级动作
- **AND** 这些 SHALL 只存在于准入判定层

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

