## MODIFIED Requirements

### Requirement: Index coverage SHALL be observable and regression-tested

系统 SHALL 暴露脱敏后的 active generation、coverage level、覆盖模块/TU 摘要、controlled
BackgroundIndex baseline、exact-command source、warm cache freshness、64-context cap 命中与最后构建
结果，并以自动化测试证明 coverage 不降级。状态输出 MUST NOT 包含用户项目绝对路径、设备标识或
其他不必要的本机信息。

controlled index 的构建 SHALL 是**可观测的前台阶段**，而不是完成后静默的 fire-and-forget 后台
任务。构建期间 SHALL 提供进度指示（阶段名 + 进展），并遵守 P5：至多 start + 中段更新，成功后自然
消退，MUST NOT 周期性刷屏。

构建失败或中断 MUST NOT 静默。失败 SHALL 同时（a）以 notify 告知用户，（b）写入
`utils.log`（含 phase、exit code、stderr 尾部），使跨会话事后诊断不依赖控制台输出。

#### Scenario: User explains an index-backed miss
- **WHEN** 用户查看最近一次 C++ `gd` explain/diagnostic
- **THEN** 输出 SHALL 指明该请求使用的 generation、coverage level、index readiness 与 miss reason
- **AND** 路径 SHALL 以 workspace-relative 或脱敏形式展示

#### Scenario: Controlled index build reports progress
- **WHEN** `current` / `hot` / `full` 任一阶段开始构建
- **THEN** 系统 SHALL 显示该阶段的进度指示，含 phase 名称与可辨识的进展信息
- **AND** 成功后指示 SHALL 自然消退，MUST NOT 留下常驻或周期刷新的通知

#### Scenario: Controlled index build fails
- **WHEN** index 构建子进程非零退出、产物缺失，或交付步骤（manifest/selection/promotion）未完成
- **THEN** 系统 SHALL notify 用户并写入结构化日志（phase、exit code、stderr 尾部）
- **AND** `state.build.status` SHALL 记为 `error` 且 `finished_at` SHALL 写入真实时间
- **AND** 系统 MUST NOT 把该次构建计入成功统计

#### Scenario: Regression simulates full synthetic baseline, partial miss, and restart recovery
- **WHEN** 测试以 `--enable-config=false` 启动 clangd，磁盘 CDB full 只含 compiler-authored
  synthetic/full TU，并通过官方 `compilationDatabaseChanges` 注入打开文件 exact commands；随后切到
  partial-only generation，再切回 full generation
- **THEN** full baseline 下 call/declaration SHALL 到达 `.cpp` body，partial generation 下 SHALL 停在
  declaration，返回 full generation 后 SHALL 再次到达 `.cpp` body
- **AND** 测试 SHALL 在旧的 declaration-self-terminating 行为或陈旧 generation 复用下失败

## ADDED Requirements

### Requirement: Prepare SHALL deliver a usable semantic index without extra user commands

`UEPrepare` 的完成语义 SHALL 覆盖 controlled index 的就绪状态。用户完成
`set platform → set project → build → UEPrepare` 后，SHALL NOT 需要额外记忆或执行任何平台专属
索引命令（如 `UEIndexFull`）才能获得可用的 C++ 定义跳转。

`UEIndexNow` / `UEIndexHot` / `UEIndexFull` SHALL 仅作为显式重建入口保留，MUST NOT 成为日常
流程的必要步骤。

当 prepare 完成而 index 尚未就绪时，系统 SHALL 明确告知当前处于 index 构建中或构建失败，
MUST NOT 让用户以为语义能力已可用。

#### Scenario: Habitual prepare flow yields working definition navigation
- **WHEN** 用户依次执行设置 platform、设置 project、构建、`UEPrepare`，且各步成功
- **THEN** controlled index SHALL 被构建并交付（manifest + selection + 提升后的 semantic CDB）
- **AND** 随后对已证明唯一定义的 C++ 符号执行 `gd` SHALL 到达该定义
- **AND** 流程 MUST NOT 要求用户执行 `UEIndexFull` 或其他索引命令

#### Scenario: Prepare completes while index build is still running
- **WHEN** prepare 的 CDB 阶段完成但 controlled index 仍在构建
- **THEN** 系统 SHALL 通过进度指示表明 index 构建进行中
- **AND** 状态查询 SHALL 报告 index 尚未就绪，而不是报告 prepare 已整体完成

### Requirement: Interrupted index builds SHALL be self-healing

index 构建状态 MUST NOT 因进程退出而永久卡死。当持久化的 `state.build.status` 为 `running` 而其
owner 进程已不存在时，系统 SHALL 判定该状态为孤儿并复位，随后重新调度或明确告知用户，
MUST NOT 依赖用户手动删除状态文件或锁目录。

跨进程构建 lease 的孤儿目录 SHALL 可被回收（owner 进程已死时），且回收 MUST NOT 破坏另一个存活
Neovim 正在进行的构建。

#### Scenario: Neovim exits mid-build and is restarted
- **WHEN** controlled index 构建期间 Neovim 退出，持久化状态留下 `status="running"`、
  `finished_at=0`，其 owner PID 已不存在
- **THEN** 下一次索引操作 SHALL 将该孤儿状态复位，而不是判定"构建中"并拒绝新构建
- **AND** 系统 SHALL 重新调度构建或明确告知上次构建被中断

#### Scenario: A second live Neovim owns the build
- **WHEN** 孤儿检测发现 `running` 状态但 owner 进程仍存活
- **THEN** 系统 SHALL 保留该状态并拒绝抢占
- **AND** MUST NOT 回收属于存活进程的 lease

### Requirement: Prepare SHALL not accumulate stale or intermediate artifacts

prepare 家族 SHALL 在成功后清理自身产生的中间备份（如 `.pre-pch.bak`、`.pre-unify.bak`）。
不同 build generation 的陈旧 controlled CDB SHALL 被失效或清除，MUST NOT 以"存在即可用"的形式
留在磁盘上误导 readiness 判定。

清理 MUST NOT 删除当前 generation 仍需的产物，也 MUST NOT 删除属于其他 project bucket 或其他
platform 分片的有效产物（与 K27/C5b 的失效矩阵一致）。

#### Scenario: Prepare succeeds with intermediate backups present
- **WHEN** prepare 的 CDB 阶段成功完成，且过程中产生了 `.pre-*.bak` 中间备份
- **THEN** 这些中间备份 SHALL 被清理
- **AND** 当前 generation 的 active CDB 与 controlled CDB SHALL 保留

#### Scenario: Stale controlled CDB from an older generation exists
- **WHEN** controlled CDB 存在但其 generation 与当前源 CDB 签名不匹配，且无有效 manifest
- **THEN** 该产物 SHALL 被视为失效，MUST NOT 被计入 coverage 或 readiness
- **AND** 系统 SHALL 以可观测方式表明该产物已失效（而非静默忽略）
