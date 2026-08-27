## MODIFIED Requirements

### Requirement: Index results SHALL be bound to an immutable build generation

每个供导航消费的 generation SHALL 至少绑定 active target/platform/configuration、CDB 内容
fingerprint、toolchain identity、manifest gate、exact-command map 摘要与覆盖集合。导航请求开始后
发生的 generation 切换 MUST 使旧响应 stale；旧 generation 的定义位置不得在新 generation 中自动生效。

每个阶段产物 SHALL 在其 controlled CDB 与 index 产物确实生成后**立即**写出绑定
`generation_id` / `build_key` / `cdb_source_signature` 的持久化 manifest。manifest 是"该产物属于
哪一次 build"的自证，其写出 MUST NOT 依赖后续步骤（selection 提升、clangd 重启、其他阶段）是否
成功 —— 否则产物留在磁盘上却无法自证归属，readiness 只能依赖易失的进程内账本。

#### Scenario: Generation identity survives a Nvim restart
- **WHEN** active target、CDB 内容与 toolchain 均未变化，但 Lua table 的迭代顺序因新进程而改变
- **THEN** generation fingerprint SHALL 保持完全相同
- **AND** 系统 SHALL 使用 canonical key ordering 序列化 hash payload，不得把运行时 hash 顺序当作
  build evidence

#### Scenario: Prepared tuple artifacts survive a Nvim restart
- **WHEN** 当前 project/target/platform/configuration 的 selection、manifest、controlled CDB、semantic CDB
  与源 CDB 签名仍可证明为 ready，随后 Neovim 重启
- **THEN** clangd SHALL 直接消费这些持久化工件并为 UE C/C++ buffer 启动
- **AND** 系统 MUST NOT 因新的 Lua 进程尚未执行 `UEPrepare` 而要求重复 prepare
- **AND** 工件缺失、stale 或 tuple/build evidence 变化时 SHALL 继续 defer；同一进程内也必须重新验证

#### Scenario: A phase produces artifacts but later delivery steps fail
- **WHEN** 某阶段的 controlled CDB 与 index 产物已生成，但 selection 提升、clangd 重启或其他阶段
  随后失败
- **THEN** 该阶段的 manifest SHALL 已经落盘并可证明其 generation 归属
- **AND** 后续进程 SHALL 能据此判定该产物可用或 stale，而不是把它视为不存在

## ADDED Requirements

### Requirement: Readiness SHALL be provable from persisted artifacts, not only from in-process state

索引就绪判定 MUST NOT 只依赖进程内/单文件的 `state` 账本。该账本会因进程中途退出、并发写入或
状态文件损坏而丢失，而 controlled CDB、index 产物与 manifest 仍完好存在于磁盘。

当 `state` 的 selection 或 artifact 记录缺失、类型错误或与磁盘不一致时，系统 SHALL 扫描当前 tuple
的持久化 manifest，并在 `generation_id`、`build_key` 与 `cdb_source_signature` 均校验通过后重建
selection。系统 MUST NOT 因账本丢失而要求用户重跑 `UEPrepare`。

重建 MUST fail closed：manifest 缺失、无法解析、generation/build_key 不匹配，或其引用的产物文件
不存在时，SHALL 继续判为非就绪并 defer，MUST NOT 猜测或降级校验。

#### Scenario: State ledger is lost but artifacts remain on disk
- **WHEN** `state.index_artifacts` 为空或类型错误，但该 tuple 的 manifest、controlled CDB 与
  semantic CDB 仍存在且签名匹配当前 build
- **THEN** 系统 SHALL 依据磁盘 manifest 重建 selection 并判定为 ready
- **AND** 系统 MUST NOT 提示用户重跑 `UEPrepare`

#### Scenario: Disk manifest does not match the active build
- **WHEN** manifest 存在但其 `generation_id` / `build_key` / `cdb_source_signature` 与当前 tuple
  或源 CDB 不匹配
- **THEN** 系统 SHALL 判为 stale 并继续 defer
- **AND** MUST NOT 用不匹配的 manifest 重建 selection

#### Scenario: Manifest references a missing artifact
- **WHEN** manifest 校验通过，但其引用的 index 产物或 background CDB 文件不存在
- **THEN** 系统 SHALL 判为非就绪
- **AND** MUST NOT 仅因 manifest 存在就宣称 ready

### Requirement: A `ready` verdict SHALL be self-evidencing

`ready` MUST 是可证伪的。系统报告 readiness 为 `ready` 时，active selection MUST 同时携带非空
`index_path`、`artifact_fingerprint` 与 `coverage_level`，且 `index_path` 指向的文件 MUST 存在。

任何内部矛盾的就绪状态（例如报 `ready` 却没有指向产物的证据）SHALL 被降级为非就绪并以可观测方式
记录，MUST NOT 静默通过 —— 假 `ready` 会让"已交付"不可证伪，并使下游误判索引可用。

#### Scenario: Selection claims readiness without artifact evidence
- **WHEN** readiness 计算得到 `ready`，但 selection 的 `index_path`、`artifact_fingerprint` 或
  `coverage_level` 为空
- **THEN** 系统 SHALL 将其降级为非就绪并附带可解释的 reason
- **AND** SHALL 记录该矛盾以便诊断，MUST NOT 报告 `ready`

#### Scenario: Selection references an artifact that no longer exists
- **WHEN** selection 携带完整字段，但 `index_path` 指向的文件已被删除
- **THEN** 系统 SHALL 判为非就绪
- **AND** MUST NOT 依据陈旧 selection 宣称 ready
