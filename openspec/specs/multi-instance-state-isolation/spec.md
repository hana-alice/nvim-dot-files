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
