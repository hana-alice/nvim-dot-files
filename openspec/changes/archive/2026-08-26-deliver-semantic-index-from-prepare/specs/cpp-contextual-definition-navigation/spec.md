## MODIFIED Requirements

### Requirement: Definition navigation SHALL expose explicit terminal states

每次 C++ `gd` SHALL 最终进入 `resolved`、`ambiguous-context`、`invalid-semantic-context` 或
`unavailable` 之一，并 SHALL 附带稳定的 `stage` 与 `reason`。只有拥有已证明 destination 且实际执行
跳转的请求 SHALL 标记 `resolved`；其他状态 SHALL 保持用户位置。`invalid-semantic-context` 仅用于
compiler AST/identity 本身无效，provider 不支持、compile command 缺失、index 未就绪或 definition
coverage 缺口 SHALL 使用 `unavailable` 的不同 reason。

`ambiguous-context` SHALL 仅表示**同一位置在多个已证明的真实 TU context 中合法地解析为不同实体**。
当语义上下文根本不可用时（index/generation 未就绪、无 proven TU、缺 manifest/selection，
`generation_class` 为 `missing`），终态 MUST 为 `unavailable` 并携带 readiness reason，
MUST NOT 归类为 `ambiguous-context`。

`ambiguous-context` 的候选 SHALL 仅由已证明的 TU context 构成，且 SHALL 展示 context 与目标的对应
关系。系统 MUST NOT 在语义不可用时以候选列表形式呈现 csearch/GTAGS/文本搜索结果
——把无法区分重载、同名与 namespace 的文本命中呈现为可选定位目标，比诚实失败更有害（P12）。

#### Scenario: Reference resolves directly to a definition
- **WHEN** canonical entity 与唯一 definition destination 均被当前 generation 证明
- **THEN** `gd` SHALL 跳转并返回 `resolved`，同时标注 destination role 为 `definition`

#### Scenario: Cursor is already on a declaration
- **WHEN** 当前精确位置等于 canonical declaration 且同一 entity 在 active complete index 中存在唯一
  definition
- **THEN** `gd` SHALL 跳转到该 definition
- **AND** MUST NOT 因 definition request 返回当前位置或 declaration 已知而原地终止

#### Scenario: Cursor is already on the definition
- **WHEN** 当前精确位置已经是该 canonical entity 的 definition
- **THEN** 系统 SHALL 保持当前位置并返回可解释的 `unavailable` / `already-at-definition`
- **AND** MUST NOT 伪造一次自跳转或改用 declaration/implementation 语义

#### Scenario: Multiple contexts produce different valid targets
- **WHEN** 同一头文件位置在多个真实 TU context 中合法地解析为不同实体
- **THEN** 系统 SHALL 返回 `ambiguous-context` 并展示 context 与目标的对应关系
- **AND** 用户选择后 SHALL 仅跳转到该 context 的真实目标

#### Scenario: Semantic context is unavailable rather than ambiguous
- **WHEN** controlled index 未就绪、无 proven TU context、manifest/selection 缺失，或
  `generation_class` 为 `missing`
- **THEN** 终态 SHALL 为 `unavailable` 并携带 index/context readiness reason
- **AND** 系统 MUST NOT 返回 `ambiguous-context`
- **AND** 系统 MUST NOT 呈现任何候选列表供用户选择

#### Scenario: Unique definition exists but index is not ready
- **WHEN** 目标符号在其模块内只有唯一定义，但当前 tuple 的 controlled index 尚未交付
- **THEN** 系统 SHALL 返回 `unavailable` 并说明 index 未就绪及补救动作
- **AND** MUST NOT 以 unity TU 文本命中构成候选列表让用户猜测

#### Scenario: Provider lacks symbol identity capability
- **WHEN** semantic provider 不支持 identity 请求、超时或返回协议错误
- **THEN** 系统 SHALL 返回 `unavailable` 及 provider/capability reason
- **AND** MUST NOT 把它归类为当前 C++ 位置语义无效

#### Scenario: Request becomes stale before completion
- **WHEN** 用户移动光标、切换 buffer、再次触发 `gd`、document version 或 generation 变化后旧请求才
  返回
- **THEN** 旧请求 SHALL 被标记 stale 且 MUST NOT 改变窗口、buffer、jumplist、光标或 context lineage
