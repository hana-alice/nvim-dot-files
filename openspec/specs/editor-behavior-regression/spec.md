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

编辑器 MUST NOT 在任何时刻卡顿（P6）。除了「单个回调不得阻塞」之外，配置 SHALL
同时守护**持续性**主循环开销：周期性回调、每事件同步 I/O，以及把宿主资源分配到
没有余量给 UI 绘制的后台进程，都属于违规——即使其中任何单次操作看起来都很便宜。

回归套件 SHALL 验证下列不变量。这些不变量在 2026-08-25 由实测定位（证据与耗时记录在
`docs/changelog.md`；诊断工具在 `tools/stall_profile.lua`、`tools/stall_attribute.lua`、
`tools/stall_repro.lua`）。

#### Scenario: clangd 并发度必须为 UI 保留 CPU

- **WHEN** 用例以注入的 `(total_mb, cpus)` 调用 `require("ue").clangd_jobs`
- **THEN** 结果 SHALL 同时受内存预算（约每 4 GB 一个 worker）与 CPU 预算约束
- **AND** 当核数已知时，结果 SHALL 至少为 UI（主循环 + GUI 渲染线程 + 合成器 + 余量）
  保留 `ue.clangd_jobs.UI_RESERVED_CORES` 个逻辑核
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
与由此得出的归属结论，否则跳越会话的证据无法区分「我们阻塞了主循环」与「宿主超订」。

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

