## MODIFIED Requirements

### Requirement: C++ definition navigation SHALL accept only semantic targets

C++ `gd` SHALL 只接受当前 active build generation 下由 compiler-owned identity 关联的 declaration / definition destination。Tree-sitter、符号文本、receiver 文本、参数个数、workspace symbol、csearch、GTAGS、文件距离、返回顺序或候选排序 MUST NOT 选择、替换或否决 C++ 语义目标。`resolved` SHALL 表示目标身份与目标位置均已证明，而不能只表示“找到一个同身份 declaration”。

#### Scenario: Source TU returns one semantic definition
- **WHEN** 用户在 active compile database 覆盖的 `.cpp` reference/call 触发 `gd`，且语义系统返回唯一 canonical entity 与唯一 definition
- **THEN** 系统 SHALL 跳转到该 definition
- **AND** 跳转结果 SHALL NOT 被任何文本候选覆盖

#### Scenario: Source provider can prove only a declaration
- **WHEN** source 查询的函数、变量或前置类型 compiler identity 只有 declaration evidence，且 provider 的 definition 响应落在该声明
- **THEN** 系统 MUST NOT 把声明标为 `definition-resolved` 或 `destination_role=definition`
- **AND** SHALL 保留声明角色与缺少 definition 的证据

#### Scenario: One provider returns multiple canonical identities
- **WHEN** 同一 symbolInfo 响应包含多个不同 USR，例如模板 dependent call 或 overload using declaration
- **THEN** provider SHALL 聚合去重所有 USR，不能选择数组第一项作为唯一身份
- **AND** 不同身份尚未消歧时 MUST NOT 按首项继续 definition 查询

#### Scenario: Compiler macro identity has no symbolInfo ranges
- **WHEN** 同一 exact-command client 在原 snapshot 上证明唯一 macro USR，而 symbolInfo 不提供 declarationRange 或 definitionRange
- **THEN** source navigation SHALL 按 clangd 的 macro referent 语义接受该 client 唯一的 definition destination
- **AND** macro expansion 的 underlying type USR MUST NOT 被误当作该宏的歧义；不同 macro USR 或不同 client 的冲突仍 SHALL 拒绝
- **AND** 内建宏无可导航源位置时 SHALL 返回 `macro-no-source-definition`，不得误报 index coverage 缺失

#### Scenario: Alias and namespace destinations have declaration roles
- **WHEN** 同一 client 的 exact-position AST 证明 `Typedef/type` 或 `Namespace/specifier`，且 definition 唯一位置与唯一 canonical USR 的 declarationRange 一致
- **THEN** source navigation SHALL 跳转到该 alias/namespace 声明，报告 `declaration-resolved` 与 `destination_role=declaration`
- **AND** 多 identity 时 SHALL 通过 compiler destination 与 declarationRange 的唯一关联消歧，不按名称、USR 顺序或 underlying 类型猜选
- **AND** 普通函数声明、extern 变量、前置类、未消歧 overload 和未知 AST kind MUST NOT 复用该放行规则
- **AND** AST 请求 SHALL 使用原 snapshot 的编码位置、有界 deadline、相同 client、exact command 与 freshness/cancellation 门禁，不拉取全文件 AST

#### Scenario: Cursor is already on its proven definition
- **WHEN** source symbolInfo 的 definitionRange 包含当前 snapshot 位置，即使 clangd definition 请求会切换到该实体的声明
- **THEN** 系统 SHALL 保持光标与 jumplist 不变并报告 `already-at-definition`
- **AND** MUST NOT 将 self-filter 后的空列表误报为 index-incomplete 或缺少 definition

#### Scenario: Source TU uses the transported exact command
- **WHEN** 当前 source TU 已由 controlled active CDB 提供 exact compile command 并传给 clangd
- **THEN** `gd` SHALL 在不可变光标 snapshot 上向同一 clangd client 请求 canonical USR 与 definition
- **AND** MUST NOT 为每次 source `gd` 在 sidecar 中重新读取或解析全量 CDB
- **AND** 进入 header 时 SHALL 把该 exact command 记录为后续 header-in-context 的 origin TU evidence

#### Scenario: Source symbolInfo cannot see a definition in another TU
- **WHEN** source exact-cursor USR 已证明，且同一 client 返回唯一 source-TU definition，但 source AST 的 symbolInfo.definitionRange 为空
- **THEN** 系统 SHALL 在目标 TU 的 exact compile command 下异步核验目标位置，要求同一 client、同一 USR 且 definitionRange 覆盖目标
- **AND** 目标只为 declaration、不同 USR、目标编辑或原请求过期时 MUST NOT 跳转；MUST NOT 仅凭 definition 请求的位置当作已验证 body
- **AND** 校验 SHALL 保持当前窗口不变，清理未使用的临时目标 buffer，保留任何用户编辑；不得按独立 header 猜 compile context

#### Scenario: First gd follows a cold clangd restart
- **WHEN** source 不属于 synthetic background CDB，clangd 已先用邻近 TU 推断命令打开该 buffer
- **THEN** exact-command transport SHALL 对同一 client/command 有界执行一次 `didClose → command update → didOpen`
- **AND** canonical USR 请求 SHALL 等待冷 UE preamble 的统一 provider hard ceiling，第一次 `gd` 即可得到语义结果

#### Scenario: A C++-extension source is compiled as Objective-C++
- **WHEN** exact compile command 以 `-x objective-c++` 或 `-x objective-c++-header` 证明 `.cpp` / `.h` 的真实语言
- **THEN** buffer SHALL 保留 `cpp` filetype 与 C++ Tree-sitter parser，并叠加 mixed `objcpp` syntax
- **AND** 普通 C/C++ compile command 与其他平台 SHALL NOT 启用该 Objective-C syntax overlay

#### Scenario: Only a declaration is currently reachable
- **WHEN** canonical entity 已证明，但当前 index coverage 只能提供 declaration
- **THEN** 系统 MAY 跳转到同一 identity 的 declaration，并 SHALL 标注 definition destination 尚未闭环的结构化原因
- **AND** declaration 上再次触发 `gd` SHALL 继续解析同一 entity 的 definition，不能把当前位置当作成功终点

#### Scenario: Semantic resolution is empty or invalid
- **WHEN** 编译器无法为 C++ 位置建立有效 canonical entity 或有效 destination
- **THEN** 系统 SHALL 保持当前位置并显示带 stage/reason 的语义失败状态
- **AND** 系统 MUST NOT 自动调用 csearch、GTAGS、workspace symbol 或基于文本的 fallback 执行跳转

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

#### Scenario: No eligible clangd client is attached
- **WHEN** 当前 buffer 没有符合 identity/provider 约束的 attached clangd client
- **THEN** transport SHALL 返回 `provider-unavailable`，MUST NOT 把空 client 集合当作 method unsupported 的证据
- **AND** 当前 index 为 missing/stale 时，导航终态 SHALL 说明 index readiness 与 `UEPrepare` 补救动作；index ready 时 SHALL 保留 provider absence 并指向 `LspInfo` / `UEDefExplain`
- **AND** 原始 provider absence SHALL 保留在结构化 explain record 中

#### Scenario: An attached provider explicitly lacks the requested capability
- **WHEN** 符合 identity/provider 约束的 attached client 明确不支持请求 method
- **THEN** transport SHALL 返回 `provider-method-unsupported` 并保留 client 与 capability 证据
- **AND** index 缺失 SHALL NOT 将已证明的 capability failure 改写为 provider absence

#### Scenario: Request becomes stale before completion
- **WHEN** 用户移动光标、切换 buffer、再次触发 `gd`、document version 或 generation 变化后旧请求才
  返回
- **THEN** 旧请求 SHALL 被标记 stale 且 MUST NOT 改变窗口、buffer、jumplist、光标或 context lineage
