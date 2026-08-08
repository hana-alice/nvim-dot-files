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

系统 SHALL 暴露脱敏后的 active generation、coverage level、覆盖模块/TU 摘要、controlled BackgroundIndex baseline、exact-command source、warm cache freshness、64-context cap 命中与最后构建结果，并以自动化测试证明 coverage 不降级。状态输出 MUST NOT 包含用户项目绝对路径、设备标识或其他不必要的本机信息。

#### Scenario: User explains an index-backed miss
- **WHEN** 用户查看最近一次 C++ `gd` explain/diagnostic
- **THEN** 输出 SHALL 指明该请求使用的 generation、coverage level、index readiness 与 miss reason
- **AND** 路径 SHALL 以 workspace-relative 或脱敏形式展示

#### Scenario: Regression simulates full synthetic baseline, partial miss, and restart recovery
- **WHEN** 测试以 `--enable-config=false` 启动 clangd，磁盘 CDB full 只含 compiler-authored synthetic/full TU，并通过官方 `compilationDatabaseChanges` 注入打开文件 exact commands；随后切到 partial-only generation，再切回 full generation
- **THEN** full baseline 下 call/declaration SHALL 到达 `.cpp` body，partial generation 下 SHALL 停在 declaration，返回 full generation 后 SHALL 再次到达 `.cpp` body
- **AND** 测试 SHALL 在旧的 declaration-self-terminating 行为或陈旧 generation 复用下失败
