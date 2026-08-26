# C++ Semantic Index Coverage Specification

## Purpose

定义 C++ 语义导航所消费的 clangd 索引覆盖合同，使快速增量索引能够提升新鲜度而不会缩窄已知定义集合，并让每次跳转都能证明其 active build、CDB、toolchain 与索引 generation 来源。

## Requirements

### Requirement: Active semantic index coverage SHALL be monotonic within one build generation

系统 SHALL 为每个 active build generation 记录可验证的 coverage 集合与等级。较窄的 current/hot 产物完成后 MUST NOT 替换、隐藏或降级同一 generation 中已经可用的较宽基线；只有覆盖集合为超集，或明确进入新的 build generation，才允许改变 active semantic coverage 的可见基线。full/current/hot 由 compiler-authored UBT unity wrapper / exact fallback CDB 提供，clangd 以 `--enable-config=false` 启动，并通过官方 `compilationDatabaseChanges` 接收当前文件的 exact commands。

#### Scenario: Current refresh completes after a full baseline
- **WHEN** 同一 build generation 已有 full controlled BackgroundIndex baseline，随后只覆盖当前模块的 current coverage 完成
- **THEN** full 基线中的其他模块 body SHALL 继续可被 `gd` 查询
- **AND** current 结果 SHALL 只作为更新层或新鲜度证据参与解析，不得把 active coverage 降为 current

#### Scenario: Hot and full phases finish out of scheduling order
- **WHEN** hot、current、full 产物因异步执行或重试以任意顺序完成
- **THEN** active coverage SHALL 按已证明的覆盖集合单调前进
- **AND** 最后完成但覆盖更窄的产物 MUST NOT 成为唯一 active index

#### Scenario: Only a partial baseline exists
- **WHEN** 新 generation 尚无 full synthetic TU baseline，而 current 或 hot partial coverage 已可用
- **THEN** 系统 MAY 使用该局部 coverage 与 exact commands 提供其范围内的语义结果
- **AND** 系统 SHALL 把 active coverage 标记为 partial，不能宣称全 build body 覆盖已完成

### Requirement: Index results SHALL be bound to an immutable build generation

每个供导航消费的 generation SHALL 至少绑定 active target/platform/configuration、CDB 内容 fingerprint、toolchain identity、manifest gate、exact-command map 摘要与覆盖集合。导航请求开始后发生的 generation 切换 MUST 使旧响应 stale；旧 generation 的定义位置不得在新 generation 中自动生效。

#### Scenario: Generation identity survives a Nvim restart
- **WHEN** active target、CDB 内容与 toolchain 均未变化，但 Lua table 的迭代顺序因新进程而改变
- **THEN** generation fingerprint SHALL 保持完全相同
- **AND** 系统 SHALL 使用 canonical key ordering 序列化 hash payload，不得把运行时 hash 顺序当作 build evidence

#### Scenario: Prepared tuple artifacts survive a Nvim restart
- **WHEN** 当前 project/target/platform/configuration 的 selection、manifest、controlled CDB、semantic CDB
  与源 CDB 签名仍可证明为 ready，随后 Neovim 重启
- **THEN** clangd SHALL 直接消费这些持久化工件并为 UE C/C++ buffer 启动
- **AND** 系统 MUST NOT 因新的 Lua 进程尚未执行 `UEPrepare` 而要求重复 prepare
- **AND** 工件缺失、stale 或 tuple/build evidence 变化时 SHALL 继续 defer；同一进程内也必须重新验证

#### Scenario: Compile database changes during navigation
- **WHEN** `gd` 发出后 active CDB fingerprint 发生变化，旧索引响应随后返回
- **THEN** 旧响应 SHALL 被标记为 stale 且 MUST NOT 跳转
- **AND** 下一次导航 SHALL 使用新 generation 的 context 与索引证据

#### Scenario: Platform or configuration changes
- **WHEN** active platform、configuration 或 target 改变，即使文件路径和 symbol name 相同
- **THEN** 系统 SHALL 创建新的 build generation
- **AND** 旧 generation 的 coverage、USR/opaque identity 与 destination MUST NOT 被复用为新 generation 的证明

#### Scenario: Module baseline freshness cannot be proven
- **WHEN** controlled BackgroundIndex baseline、module AST 或 exact-command map 无法证明由当前 CDB/toolchain generation 产生
- **THEN** 系统 SHALL 拒绝把该 baseline 作为语义 destination authority
- **AND** 失败信息 SHALL 指明 generation/freshness 缺口，不得静默使用陈旧位置

### Requirement: Definition misses SHALL distinguish incomplete coverage from semantic absence

索引查询没有返回 definition 时，系统 SHALL 根据 generation coverage 输出结构化结论。partial coverage 下的 miss 必须表示为 `index-incomplete`；只有完成声明所覆盖 active build 范围的索引后，才可表示 `definition-absent-in-complete-index`。两者都 MUST NOT 被归类为 overload ambiguity 或 invalid AST。

#### Scenario: Definition TU is outside current coverage
- **WHEN** canonical entity 的 declaration 已被证明，但其 definition TU 不在 active partial coverage 中
- **THEN** 导航 SHALL 返回 `unavailable` / `index-incomplete`
- **AND** 结果 SHALL 包含 coverage level、generation 与缺失 destination stage，并触发或保持已配置的完整索引收敛流程

#### Scenario: Complete index contains no definition
- **WHEN** 当前 generation 的 complete coverage 已就绪，且同一 canonical entity 没有 definition location
- **THEN** 导航 SHALL 返回 `unavailable` / `definition-absent-in-complete-index`
- **AND** 系统 MUST NOT 用同名、同 arity、邻近文件或历史缓存制造 definition

#### Scenario: Provider or module baseline is not ready
- **WHEN** clangd 尚未完成 controlled BackgroundIndex baseline、exact-command transport 尚未生效、正在重启或无法回答查询
- **THEN** 导航 SHALL 返回 provider/index readiness reason
- **AND** MUST NOT 把暂时性 provider 状态包装成实体不存在

### Requirement: Published clangd CDB SHALL use the standard JSON compilation database schema

current/hot/full phase artifact MAY 携带 `nvim_ue_members`、`nvim_ue_module_root` 等内部 provenance，
但发布给 clangd 的 `compile_commands.json` SHALL 只包含标准的 `directory`、`file`、
`arguments`/`command` 与可选 `output` 字段。内部 provenance MUST 在发布边界剥离；否则 clangd
拒绝整份数据库时不得回退到 active per-file CDB。

#### Scenario: Controlled phase entries contain portable provenance
- **WHEN** SuperUnity phase artifact 包含 member/module-root metadata 并被合并到 clangd background CDB
- **THEN** phase artifact SHALL 保留这些字段供 semantic sidecar 使用
- **AND** clangd 发布视图 SHALL 剥离所有非标准字段，同时保持 exact argv、cwd、file 与 output 不变

### Requirement: Live file freshness SHALL overlay rather than replace broad coverage

已打开或有 unsaved overlay 的 C++ 文件 SHALL 使用与其 document version 一致的 live semantic data 覆盖较旧静态记录；该覆盖 MUST NOT 删除静态基线中不相关文件的定义。文件、CDB 或 generation 失效时，live overlay SHALL 被丢弃或重建。

#### Scenario: Unsaved source changes a definition
- **WHEN** 用户修改已打开 source buffer 中的 declaration/definition 且尚未保存
- **THEN** 该 buffer 的导航 SHALL 使用当前 document version 的 live semantic data
- **AND** 其他模块仍 SHALL 保留 broad baseline 的定义覆盖

#### Scenario: Live overlay becomes stale
- **WHEN** buffer changedtick、compile command 或 build generation 改变
- **THEN** 旧 live overlay MUST NOT 继续贡献 destination
- **AND** 后续请求 SHALL 等待或建立与新快照一致的 semantic data

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
