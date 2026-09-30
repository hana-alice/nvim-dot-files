# multi-instance-state-isolation Specification

## Purpose

保证多个 Neovim 进程同时使用同一 Unreal Engine checkout 时，live project、
target、Android device 不互相改写；需要跨进程共享的持久状态具有明确的
project scope、原子发布、merge 或 single-writer 合同，不因 basename 碰撞
或共享 JSON read-modify-write 丢数据。边界：本 spec 管跨进程/跨项目的状态
隔离与持久化合同，不管单个 workflow 内部的业务逻辑正确性。

## Requirements

### Requirement: live selection SHALL be process-local

当前 project、target platform/configuration 与 Android device serial SHALL
在 Neovim 进程内捕获；一个进程修改选择 MUST NOT 重定向另一个已运行进程。
`selection.json` 只 SHALL 作为未来进程首次解析 engine context 时的启动
默认值，MUST NOT 被 live process 反复读取为权威状态。

#### Scenario: 两个实例选择不同项目和设备
- **WHEN** 实例 A 与 B 共用 engine，A 选择 ProjectA/Android/DeviceA，B 选择
  ProjectB/Win64/DeviceB
- **THEN** A 的 live context SHALL 保持不变，B 的选择 MUST NOT 改写 A 的
  后续 build、ADB 或 cache path

### Requirement: 持久状态位于 canonical project bucket，且原子/merge-safe

project state、CDB、clangd/index/PCH、csearch、gtags、watch dirty set、
breakpoints 与 definition cache SHALL 位于
`<engine>/.cache/nvim-ue/projects/<project-key>/`；`project-key` SHALL 绑定
canonical project/uproject path digest，不得只用 basename。独立 state
field 与 definition-cache key SHALL 以独立原子文件发布；必须共享一个集合
的 probe、recent-project、dirty overlay SHALL 在 filesystem lease 内重新
读取并 merge 后原子替换；`(platform, configuration)` SHALL 作为一个原子
pair 写入，MUST NOT 产生跨 writer 撕裂组合。上下文缓存失效签名 SHALL 从
实际读取用于生成状态的权威字节派生，而非依赖额外的共享 revision 文件；
相同大小或 mtime MUST NOT 掩盖内容变化。原子替换失败 SHALL 报告失败并
保留原字段。

#### Scenario: 两个同名 checkout
- **WHEN** 不同路径的两个项目 basename 相同
- **THEN** canonical path digest SHALL 使 project-key 不同，breakpoint 与
  definition cache MUST NOT 碰撞

#### Scenario: 并发更新 target pair
- **WHEN** 多个进程同时写入不同的 `(platform, configuration)` pair
- **THEN** 磁盘最终值 SHALL 完整来自某一个 writer，MUST NOT 组合两个
  writer 的字段

### Requirement: state-setting 命令必须以回读为凭报告成败

改写持久 project state 的用户命令 SHALL 先校验写入结果，并从读取方使用
的同一 project bucket 回读该字段后才能宣布成功。写入失败或回读不一致时
反馈 SHALL 是错误并包含原因，MUST NOT 打印成功文案。

事实基础（K61，2026-09-03 实测）：`project_state.update` 在本进程未选中
项目时返回 `false, ...`；`:UESetAndroidPackage` 曾丢弃该返回值，于是什么
都没落盘却仍打印成功文案，DAP attach 继续以旧包名失败——单纯检查返回值
不够，它无法表达 writer 与 reader 落在不同 bucket 的情形，故必须回读。

#### Scenario: 本进程未选中项目
- **WHEN** 本进程未选中任何 project 时执行一个 state-setting 命令
- **THEN** 命令 SHALL 报错并告知未选中项目，MUST NOT 报告成功或写入任何字段

### Requirement: engine-level target preference 只建议，不隐式继承

engine 级 target preference SHALL 在每次显式 `update_target` 时镜像最新
pair（last-writer-wins），且仅作为交互 picker 的排序建议；`read_state()`
与任何构建/缓存路径 MUST NOT 将其作为 platform 来源。新 project bucket 在
用户显式选择前 SHALL 视为未设置 target；需要 platform 的操作 MUST NOT
在未设置时静默采用默认值构建，SHALL 先要求一次显式选择。同一进程内显式
`:UESetPlatform` SHALL 捕获一个 one-shot target intent，供下一次
`:UESetProject` 消费一次；该 intent MUST NOT 跨进程持久化，也 MUST NOT
导致之后未关联的 project switch 继承。

#### Scenario: 新 bucket 不自动继承
- **WHEN** 项目 A 显式设置 target 后用户切换到从未设置过 target 的项目 B
- **THEN** B 的 target 状态 SHALL 为空；用户在 B 上触发构建时 SHALL 先弹
  platform/configuration 选择，取消时 MUST NOT 以猜测值继续构建

### Requirement: 破坏性缓存 writer 必须持有跨进程 lease

UEPrepare、CDB pipeline、csearch build 与 controlled semantic-index phase
的 writer ownership SHALL 同时覆盖进程内与跨进程；lease owner record
SHALL 包含 PID/token，live owner 存在时第二 writer SHALL 被拒绝，owner
进程退出后的 stale lease SHALL 可回收，release SHALL 校验 token 且不得
删除其他 writer 的 lease。过期回收者 SHALL 只删除它观察到的具体 owner
文件，MUST NOT 递归删除可能已被新 owner 替换的目录；探测权限不足或损坏
的 owner 记录 SHALL fail closed，不能当作进程已死亡。

#### Scenario: 第二个实例同时 prepare
- **WHEN** 实例 A 已持有某 project 的 lease，实例 B 请求相同输出
- **THEN** B SHALL 在修改任何目标前失败并显示 owner contention，A 的产物
  不受影响

### Requirement: 诊断日志按 PID 隔离，legacy 顶层 state 只读迁移一次

纯诊断日志（含插件自有 logger）SHALL 使用 PID-suffixed filename；用户级
preference（如主题）MAY 共享 last-writer-wins 文件但 SHALL 原子替换。
当新 project bucket 尚不存在且发现旧顶层 `state.json` 时，系统 SHALL 只读
导入兼容字段到 canonical bucket 并保留旧文件；迁移后所有新写入 SHALL 只
进入新布局；旧顶层 state 的 canonical project identity 与当前 bucket 不同
时，MUST NOT 把旧索引/GTAGS/CDB 导入当前 bucket。

#### Scenario: 两实例同时记录日志
- **WHEN** 两个 Neovim 进程同时写 debug/grep/DAP 日志
- **THEN** 它们 SHALL 写不同 PID 路径，互不破坏

### Requirement: 运行中的 workflow 必须冻结 owner，不随 live selection 改投

build、prepare、deploy 或 launch workflow 开始时，系统 SHALL 冻结该
workflow 的 project、target、device serial 与 session owner；后续 live
selection 变更 MUST NOT 改投、重绑或重新解释已经开始的 workflow、已持有
的 lease，或正在发布的 artifact。新 owner 只能由后续新 invocation 捕获。

#### Scenario: 运行中的 workflow 遭遇 live selection 变更
- **WHEN** 实例 A 正在执行一个已冻结 owner 的 workflow，用户随后切换 live
  selection
- **THEN** 当前 workflow SHALL 继续使用最初捕获的 owner

## 选型与踩坑

- **选型**：project-key 绑定 canonical path digest 而非 basename——同一
  机器常并存多个同构 checkout（相同目录层级、相同项目名），只用 basename
  会让不同路径的项目共享同一份 cache/breakpoint，产生跨项目数据污染。
- **选型**：engine-level target preference 只做 picker 排序建议，绝不做
  隐式继承——需要 platform 的构建操作宁可先弹选择也不猜默认值，避免用错
  平台的编译产物污染缓存。
- **选型**：state-setting 命令必须回读校验而非只信任返回值——见下方 K61
  踩坑，返回值检查无法表达「writer 与 reader 落在不同 bucket」的情形。
- **踩坑（K61，2026-09-03 实测）**：`:UESetAndroidPackage` 丢弃了
  `project_state.update` 在未选中项目时返回的失败结果，导致什么都没落盘
  却打印成功文案（lying success），随后 DAP attach 继续用旧包名失败，
  用户体感是「命令不刷新缓存」。处置：state-setting 命令统一改为回读为凭。
- **踩坑**：过期 lease 回收如果递归删除整个 owner 目录，会在与新 owner
  的发布时序竞态时误删新 owner 刚发布的内容；回收者只能删除自己观察到的
  具体 owner 文件。
- **重要事项**：诊断日志的 PID 隔离与「进程内 `vim.g` 不是跨 Neovim 全局」
  是同一类问题的两个面——本 capability 反复强调不要把进程内状态误当成
  跨进程权威状态。
