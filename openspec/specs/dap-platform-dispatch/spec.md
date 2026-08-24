# dap-platform-dispatch Specification

## Purpose
这个 capability 把 DAP 的平台注册与会话分发收束成单一契约：adapter 的注册必须由可验证的 matrix 过滤，真正执行 attach、launch、stop、status、reattach 的 handler 必须按“会话创建时冻结的 owner”路由，而不是读取后来切换的 current platform 来猜。这样可以避免一个会话在生命周期中途被错误地切到另一个平台实现，也避免 attach 成功后、stop/status 却被当前平台带偏。DAP 的 dispatch seam 因此必须兼顾注册时的兼容性过滤和运行时的会话归属冻结，两者缺一不可。

## Requirements

### Requirement: DAP adapter 注册必须按 matrix 过滤

系统 SHALL 仅为在 matrix 中声明为兼容的 host/target pair 注册 DAP adapter；未声明的组合 MUST NOT 出现在可选注册表中。注册阶段不得依赖当前 UI 选择或运行时猜测，而必须依据已定义的兼容矩阵决定是否暴露该 adapter。

#### Scenario: 兼容组合进入注册表

- **WHEN** 某个 DAP adapter 的 matrix 声明当前 host/target pair 兼容
- **THEN** 系统 SHALL 将该 adapter 注册为可用
- **AND** 该注册结果 SHALL 可被后续 attach/launch 查询到

#### Scenario: 不兼容组合不得注册

- **WHEN** 某个 host/target pair 未被 matrix 声明为兼容
- **THEN** 系统 SHALL NOT 注册该 adapter
- **AND** MUST NOT 因 current platform 处于别的 target 就把它放进候选列表

### Requirement: 会话必须冻结 session owner 并据此分发

系统 SHALL 在 DAP session 创建时冻结 session owner；后续 attach、launch、stop、status 与 reattach 必须只按该 owner 分发。当前平台、当前 target 或 live selection 在会话建立后发生变化时 MUST NOT 改写 session owner，也 MUST NOT 重新选择另一个 adapter 来处理已经存在的会话。

#### Scenario: 平台切换后旧会话仍用原 owner

- **WHEN** 一个 DAP session 已经创建，随后用户切换到另一个平台或 target
- **THEN** 该 session 的 stop/status/reattach SHALL 继续路由到最初冻结的 owner
- **AND** MUST NOT 读取新的 current platform 来改投别的 adapter

#### Scenario: launch 记录会话归属

- **WHEN** 系统为某个 target 创建新的 launch session
- **THEN** 该 session SHALL 记录其 owner、adapter 与 matrix 来源
- **AND** 后续 lifecycle 操作 SHALL 复用同一归属信息

### Requirement: attach/launch/stop/status/reattach 不得猜 current platform

系统 SHALL 禁止 DAP dispatch 根据“现在看起来像哪个平台”来决定处理器；任何 attach、launch、stop、status、reattach 都必须使用已冻结的会话归属、已注册的 matrix 以及显式的 session metadata。若当前平台与会话 owner 不一致，系统 MUST 报告不一致而不是静默切换。

#### Scenario: 当前平台变化不能改写 stop 行为

- **WHEN** 一个会话已经 attach，而用户在别处切换了 current platform
- **THEN** stop/status SHALL 仍然由原 session owner 处理
- **AND** MUST NOT 重新解析当前平台后选择新的 stop handler

#### Scenario: reattach 必须沿用冻结的归属

- **WHEN** 用户对已存在会话执行 reattach
- **THEN** 系统 SHALL 使用该会话记录的 owner 和 adapter 信息
- **AND** MUST NOT 因当前平台不同就替换成另一个 target 的 reattach 逻辑

### Requirement: 会话归属缺失时必须显式失败

系统 SHALL 在 session metadata 缺失、owner 已失效或 matrix 归属不可验证时，明确失败并给出可诊断原因；MUST NOT 用当前平台、最近一次选择或别的活跃会话来补齐归属。这样可以保证 attach 成功后不会因为隐式补默认值而把 stop/status/reattach 送错处理器。

#### Scenario: 归属缺失不能靠当前平台补救

- **WHEN** 一个 session 缺少 owner 记录或该记录无法被验证
- **THEN** 系统 SHALL 失败并报告缺失的归属信息
- **AND** MUST NOT 使用当前平台或当前 target 作为补齐依据

#### Scenario: 归属存在但与 matrix 不一致

- **WHEN** session owner 与当前注册的 matrix 结果不一致
- **THEN** 系统 SHALL 报告一致性错误
- **AND** MUST NOT 静默切换到一个新的 adapter 继续执行
