# multi-instance-state-isolation Specification

## Purpose

保证多个 Neovim 进程同时使用同一 Unreal Engine checkout 时，live project、target、
Android device 不互相改写；需要跨进程共享的持久状态具有明确的 project scope、原子发布、
merge 或 single-writer 合同，不因 basename 碰撞或共享 JSON read-modify-write 丢数据。

## Requirements

### Requirement: live selections SHALL be process-local

当前 project、target platform/configuration 与 Android device serial SHALL 在 Neovim 进程内
捕获。一个进程修改选择 MUST NOT 重定向另一个已运行进程。`selection.json` 只 SHALL 作为未来
进程首次解析 engine context 时的启动默认值，MUST NOT 被 live process 反复读取为权威状态。

#### Scenario: 两个实例选择不同项目和设备

- **WHEN** 实例 A 与 B 共用 engine，A 选择 ProjectA/Android/DeviceA，B 选择 ProjectB/Win64/DeviceB
- **THEN** A 的 live context SHALL 保持 ProjectA/Android/DeviceA
- **AND** B 的选择 MUST NOT 改写 A 的后续 build、ADB 或 cache path

#### Scenario: 新进程读取最近默认项目

- **WHEN** 实例 B 更新 startup selector 后实例 C 首次解析该 engine
- **THEN** C SHALL 读取 B 写入的项目作为启动默认值
- **AND** 已运行的实例 A SHALL 保持其原选择

### Requirement: persisted project data SHALL use canonical project buckets

project state、CDB、clangd/index/PCH、csearch、gtags、watch dirty set、breakpoints 与 definition
cache SHALL 位于 `<engine>/.cache/nvim-ue/projects/<project-key>/`。`project-key` SHALL 绑定
canonical project/uproject path，不得只用 basename；platform-sensitive artifacts SHALL 在 project
bucket 内再按 platform/configuration 隔离。

#### Scenario: 同 engine 下两个项目

- **WHEN** 两个不同 canonical project path 共用同一 engine
- **THEN** 它们的 state/cache/breakpoint 路径 SHALL 不同
- **AND** 切换项目 SHALL 保留旧 bucket，而不是删除或复用它

#### Scenario: 两个同名 checkout

- **WHEN** 不同路径的两个项目 basename 相同
- **THEN** canonical path digest SHALL 使 project-key 不同
- **AND** breakpoint 与 definition cache MUST NOT 碰撞

### Requirement: shared persistence SHALL be atomic and merge-safe

独立 state field 与 definition-cache key SHALL 以独立原子文件发布；必须共享一个集合的 probe、
recent-project 与 dirty overlay SHALL 在 filesystem lease 内重新读取并 merge 后原子替换。
target platform/configuration SHALL 作为一个原子 pair 写入，MUST NOT 产生跨 writer 撕裂组合。

#### Scenario: 并发写不同字段和 key

- **WHEN** 多个 Neovim 进程同时写同一 project 的不同 state fields 或 definition keys
- **THEN** 所有不同字段/key SHALL 保留
- **AND** 读取方 MUST NOT 观察到截断或非法 JSON

#### Scenario: 并发写共享集合

- **WHEN** 多个进程同时记录不同 recent projects、dirty paths 或同一 probe counter
- **THEN** 最终集合 SHALL 包含所有不同项，counter SHALL 等于事件总数

#### Scenario: 并发更新 target pair

- **WHEN** 多个进程同时写入不同的 `(platform, configuration)` pair
- **THEN** 磁盘最终值 SHALL 完整来自某一个 writer
- **AND** MUST NOT 组合一个 writer 的 platform 与另一个 writer 的 configuration

### Requirement: engine-level target preference SHALL suggest, never inherit

engine 级 target preference（`.cache/nvim-ue/target-default.json`）SHALL 在每次显式
`update_target` 时镜像最新 `(platform, configuration)` pair（last-writer-wins，原子替换）。
它 SHALL 仅作为交互 picker 的排序建议；`read_state()` 与任何构建/缓存路径 MUST NOT 将其
作为 platform 来源。新 project bucket 在用户显式选择前 SHALL 视为未设置 target；
需要 platform 的操作（如 UEBuild）MUST NOT 在未设置时静默采用任何默认值构建，SHALL 先
要求一次显式选择。

同一 Neovim 进程内，显式 `:UESetPlatform` SHALL 额外捕获一个 one-shot target intent：若尚未
执行目标 `:UESetProject`，下一次显式 project selection SHALL 将该 pair 写入所选 project bucket 后消费。
该 intent MUST NOT 跨进程持久化为 build authority，也 MUST NOT 导致之后未关联的 project switch 继承。

#### Scenario: 新 bucket 不自动继承

- **WHEN** 项目 A 显式设置 `(Android, Test)` 后用户切换到从未设置过 target 的项目 B
- **THEN** B 的 `read_state().target_platform` SHALL 为空且 `target_is_set` SHALL 为 false
- **AND** engine preference SHALL 仍返回 `(Android, Test)` 供 picker 置顶建议

#### Scenario: 未设置时构建先提示

- **WHEN** 用户在 target 未设置的项目上触发 UEBuild
- **THEN** 系统 SHALL 先弹出 platform/configuration 选择（建议项置顶）
- **AND** 用户确认后 SHALL 持久化到该 project bucket 并继续原构建
- **AND** 用户取消时 MUST NOT 以猜测的 platform 继续构建

#### Scenario: 先设置平台再设置工程

- **WHEN** 用户先显式选择 `(IOS, Development)`，再执行 `:UESetProject` 选择项目 B
- **THEN** B 的 per-project target selection SHALL 原子写入 `(IOS, Development)`
- **AND** 后续再切换到项目 C 时 MUST NOT 重放已经消费的 one-shot intent
- **AND** 另一个 Neovim 进程 MUST NOT 观察到该 live intent

### Requirement: destructive cache writers SHALL hold cross-process leases

UEPrepare、CDB pipeline、csearch build 与 controlled semantic-index phase 的 writer ownership SHALL 同时覆盖进程内与跨进程。
lease owner record SHALL 包含 PID/token；live owner 存在时第二 writer SHALL 被拒绝；owner 进程
退出后的 stale lease SHALL 可回收。release SHALL 校验 token，MUST NOT 删除其他 writer 的 lease。

#### Scenario: 第二个实例同时 prepare

- **WHEN** 实例 A 已持有某 project 的 prepare/CDB/csearch lease，实例 B 请求相同输出
- **THEN** B SHALL 在修改任何目标前失败并显示 owner contention
- **AND** A 的临时文件与最终 artifact SHALL 不受影响

#### Scenario: owner 异常退出

- **WHEN** lease owner PID 已不存在
- **THEN** 后续 writer SHALL 回收 stale lease 并继续

### Requirement: diagnostic and preference globals SHALL declare ownership

纯诊断日志（包括插件自有 logger）SHALL 使用 PID-suffixed filename，避免不同实例
truncate/rotate 同一路径。主题等明确
属于用户级 preference 的状态 MAY 共享 last-writer-wins 文件，但 SHALL 原子替换。进程内 `vim.g`
不得被文档描述成跨 Neovim 全局。

#### Scenario: 两实例同时记录日志

- **WHEN** 两个 Neovim 进程同时写 debug/grep/DAP protocol trace 或 nvim-dap main/stdout/stderr log
- **THEN** 它们 SHALL 写不同 PID 路径
- **AND** 任一实例的 rotate/truncate MUST NOT 破坏另一实例日志

### Requirement: legacy state SHALL migrate without becoming writable authority

当新 project bucket 尚不存在且发现旧顶层 `state.json` 时，系统 SHALL 只读导入兼容字段到 canonical
bucket，并保留旧文件以便回滚。迁移后所有新写入 SHALL 进入新布局，MUST NOT 继续修改旧顶层 state。

#### Scenario: 升级旧 checkout

- **WHEN** engine 只有旧 `.cache/nvim-ue/state.json` 且包含 project_root/uproject
- **THEN** 首次解析 SHALL 建立对应 canonical bucket 并读到旧字段
- **AND** 后续 update SHALL 只写 project bucket

#### Scenario: 已有索引与 active CDB 升级时不重建

- **WHEN** 旧顶层 state 的 canonical project identity 等于当前 project bucket
- **AND** 旧布局存在 csearch/GTAGS 或 engine-root active CDB，而新 bucket 尚无对应工件
- **THEN** 首次解析 SHALL 以同文件系统原子发布方式导入对应工件
- **AND** 导入 MUST NOT 删除或改写旧路径，保证已运行的旧 Neovim 实例继续可用
- **AND** 大型索引/CDB 的迁移 MUST NOT 在 UI 主线程复制文件内容

#### Scenario: 旧缓存属于另一项目

- **WHEN** 旧顶层 state 的 canonical project identity 与当前 project bucket 不同
- **THEN** 系统 MUST NOT 把旧索引、GTAGS 或 CDB 导入当前 bucket

### Requirement: live workflow/session owners SHALL freeze across selection changes

当 build、prepare、deploy 或 launch workflow 开始时，系统 SHALL 冻结该 workflow 的 project、target、device serial 与 session owner；后续 live selection 变更 MUST NOT 改投、重绑或重新解释已经开始的 workflow、已持有的 lease，或正在发布的 artifact。新的 owner 只能由后续新 invocation 捕获。

#### Scenario: 运行中的 workflow 遭遇 live selection 变更

- **WHEN** 实例 A 正在执行一个已捕获 project/target/device/session owner 的 workflow，用户随后切换 live selection
- **THEN** 当前 workflow SHALL 继续使用最初捕获的 owner
- **AND** 当前 workflow MUST NOT 因新的 live selection 改投到其他 project、target 或 device

#### Scenario: 新 workflow 允许观察最新选择

- **WHEN** 前一个 workflow 已结束，且用户在此期间更新了 live selection
- **THEN** 下一次新的 workflow invocation SHALL 读取最新 live selection 作为新的 owner 捕获点
- **AND** 旧 workflow 的 owner 冻结状态 SHALL 不被重用到新任务
