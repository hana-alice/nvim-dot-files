# C++ Contextual Definition Navigation Specification

## Purpose

定义 C++ `gd` 在 UE 大型代码库中的上下文感知语义导航合同：只有真实编译 TU 中由 Clang 证明的实体身份可以驱动跳转，并对头文件上下文、重载、缓存、失败状态和异步性能给出可验证约束。

## Requirements

### Requirement: C++ definition navigation SHALL accept only semantic targets

C++ `gd` SHALL 只接受当前 active build generation 下由 compiler-owned identity 关联的 declaration / definition destination。Tree-sitter、符号文本、receiver 文本、参数个数、workspace symbol、csearch、GTAGS、文件距离、返回顺序或候选排序 MUST NOT 选择、替换或否决 C++ 语义目标。`resolved` SHALL 表示目标身份与目标位置均已证明，而不能只表示“找到一个同身份 declaration”。

#### Scenario: Source TU returns one semantic definition
- **WHEN** 用户在 active compile database 覆盖的 `.cpp` reference/call 触发 `gd`，且语义系统返回唯一 canonical entity 与唯一 definition
- **THEN** 系统 SHALL 跳转到该 definition
- **AND** 跳转结果 SHALL NOT 被任何文本候选覆盖

#### Scenario: Source TU uses the transported exact command
- **WHEN** 当前 source TU 已由 controlled active CDB 提供 exact compile command 并传给 clangd
- **THEN** `gd` SHALL 在不可变光标 snapshot 上向同一 clangd client 请求 canonical USR 与 definition
- **AND** MUST NOT 为每次 source `gd` 在 sidecar 中重新读取或解析全量 CDB
- **AND** 进入 header 时 SHALL 把该 exact command 记录为后续 header-in-context 的 origin TU evidence

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

### Requirement: Header navigation SHALL use a proven translation-unit context

普通 C/C++ 头文件中的 `gd` SHALL 在一个已证明包含该头文件、拥有真实编译命令、且适用于当前导航 lineage 与 build generation 的 source TU context 中求值。窗口曾经使用过某个 TU 或其 build fingerprint 相同，不足以证明该 TU 适用于当前头文件；把非自包含头文件作为独立主文件解析所得候选 MUST NOT 被视为真实 build context 的语义证明。

#### Scenario: Header was reached from a source TU
- **WHEN** 用户从 source TU 导航进入其 dependency evidence 覆盖的头文件并继续触发 `gd`
- **THEN** 系统 SHALL 继承该 source TU、navigation lineage 与 subject-header membership
- **AND** Clang SHALL 在该 TU 的真实 include / macro / platform context 中解析精确位置

#### Scenario: Inherited context does not contain the current header
- **WHEN** 同一窗口随后打开另一个不属于 inherited TU dependency evidence 的头文件
- **THEN** 系统 SHALL 使 inherited context 对该 subject 失效并重新 catalog proven contexts
- **AND** MUST NOT 仅因 build fingerprint 相同而直接查询旧 context 或终止为 `invalid-query-file-not-in-tu`

#### Scenario: Header was opened directly with one proven context
- **WHEN** 用户直接打开头文件，且 active build dependency evidence 只证明一个可解析 source TU context
- **THEN** 系统 SHALL 使用该 context 求解 canonical entity 与 destination

#### Scenario: Proven origin TU contains only the declaration
- **WHEN** proven origin TU 解析出唯一 canonical identity 与 declaration，但该 TU AST 中没有 body
- **THEN** 系统 SHALL 先在 subject 所属 module 的 proven UBT TU / exact fallback AST 中按同一 canonical USR 查找唯一 body
- **AND** 只有 module contexts 暂不可用时，系统 MAY 使用与当前 generation 一致的 secondary clangd destination 协助补齐
- **AND** provider capability 缺失、module context 不完整、identity 冲突、body 为零个或多个时 SHALL 返回各自的结构化 reason，MUST NOT 按名称或返回顺序猜选

#### Scenario: Header has multiple proven contexts and none was inherited
- **WHEN** 用户直接打开头文件，且多个 source TU context 均由 active build evidence 证明
- **THEN** 系统 SHALL 在有界候选中异步求值，并在 canonical entity 与 definition 一致时自动收敛
- **AND** 只有候选求值产生不同实体或不同 definition 时，系统才 SHALL 要求用户选择具体 context
- **AND** 系统 MUST NOT 按同名、同目录、同 basename、最短路径或最近使用时间自动猜选 context

#### Scenario: No context can be proven
- **WHEN** 系统找不到同时具有 include evidence 与真实编译命令的 TU context
- **THEN** 系统 SHALL 返回 `unavailable` / `context-unproven` 并说明缺少的证据
- **AND** 系统 SHALL NOT 合成一个未经构建证据证明的 donor TU

### Requirement: Header navigation SHALL converge on a TU before asking the user

非自包含头文件被**大量** TU include 是正常现象，不是歧义。因此“存在多个候选 origin TU”
MUST NOT 单独作为向用户提示选择的理由：它表示系统尚未决定用哪个 TU 求值，而不是该位置在不同
TU 中合法地指向不同实体。

多个候选 TU 时，系统 SHALL 先尝试基于 compiler-emitted evidence 自动收敛（继承的 window origin
lineage、subject 的 unity membership、以及在候选中求值后比较 canonical USR）。收敛 MUST NOT 依据
文件名相似度、路径距离、候选顺序或其他文本启发式选择 TU（P11/P12）。

若多个候选 TU 求值后得到**同一** canonical entity 与同一 definition destination，系统 SHALL 直接
跳转，MUST NOT 提示用户选择。

只有当候选 TU 求值后**确实产生不同实体**时，系统才 SHALL 呈现选择，且展示 SHALL 说明分歧内容
（不同实体或不同目标位置），MUST NOT 仅列出 TU 文件名——用户无法据 TU 名称判断哪个是所需目标。

既无法自动收敛、也无法证明存在真实分歧时，系统 SHALL 返回 `unavailable` 并给出可执行原因，
MUST NOT 以候选 TU 列表代替答案。

收敛过程 SHALL 保持异步且不阻塞 UI，其尝试范围 SHALL 有上界。

#### Scenario: Header is included by many TUs that agree
- **WHEN** 某头文件位置有多个候选 origin TU，且在其中求值得到同一 canonical USR 与同一 definition
- **THEN** 系统 SHALL 直接跳转到该 definition
- **AND** 系统 MUST NOT 提示用户选择 translation-unit context

#### Scenario: Candidate TUs genuinely disagree
- **WHEN** 候选 origin TU 求值后得到不同的 canonical entity 或不同的 definition 位置
- **THEN** 系统 SHALL 返回 `ambiguous-context` 并呈现分歧对应关系
- **AND** 展示 SHALL 包含实体/目标信息，MUST NOT 仅呈现 TU 文件名

#### Scenario: Convergence is impossible and disagreement is unproven
- **WHEN** 系统既不能自动确定 origin TU，也无法证明候选之间存在真实分歧
- **THEN** 系统 SHALL 返回 `unavailable` 及可执行原因
- **AND** MUST NOT 用候选 TU 列表代替定位结果

#### Scenario: Convergence must not guess from names or paths
- **WHEN** 系统在多个候选 TU 之间收敛
- **THEN** 判据 SHALL 限于 compiler-emitted dependency evidence、unity membership 与 canonical USR 一致性
- **AND** MUST NOT 使用文件名相似度、路径距离或候选返回顺序

#### Scenario: Inherited origin already proves the TU
- **WHEN** 当前窗口的 origin lineage 在同一 build generation 下已证明适用于该 subject
- **THEN** 系统 SHALL 直接使用该 TU，MUST NOT 重新提示选择

### Requirement: Overloads SHALL be identified by compiler semantic identity

系统 SHALL 使用 Clang 实体身份（例如 USR 或等价的 compiler-owned identity）区分 C++ 重载，不得以函数名、参数数量或渲染后的签名字符串作为身份主键。

#### Scenario: Same name and same arity have different parameter types
- **WHEN** 两个重载同名且参数数量相同，但参数类型、转换序列、cv/ref 或模板约束不同
- **THEN** `gd` SHALL 跳转到 Clang overload resolution 选中的实体
- **AND** 参数数量相同 MUST NOT 导致 picker、随机首项或错误缓存命中

#### Scenario: Nested overload call in an inline overload body
- **WHEN** 无参 inline 重载的函数体调用同名 `TArrayView` 重载，且调用参数由一个含两个实参的嵌套 `MakeArrayView` 表达式产生
- **THEN** 外层调用 SHALL 解析为 `TArrayView` 参数重载的语义身份
- **AND** 系统 MUST NOT 跳回包围它的无参重载或同 arity 的指针重载

#### Scenario: Dependent or genuinely ambiguous call
- **WHEN** active TU 中的调用在 C++ 规则下仍是 dependent、ambiguous 或处于 recovery AST
- **THEN** 系统 SHALL 返回对应的非 resolved 状态并保留 Clang 诊断 / 候选身份
- **AND** 系统 MUST NOT 用语法或文本规则制造唯一答案

### Requirement: Semantic result reuse SHALL be scoped to the complete live context

系统 MUST NOT 持久化或复用按裸 `symbol`、`receiver::symbol`、arity 或格式化签名索引的 C++ definition location。每次导航 SHALL 建立不可变 request snapshot，至少绑定 action token、window/buffer、subject URI、精确位置、document version、active build/CDB/index generation、origin TU、compile-command fingerprint 与 provider client identity。异步阶段 MUST 使用该 snapshot 构造请求，而不得重新读取当前窗口位置作为原请求参数。

#### Scenario: A no-argument overload was resolved first
- **WHEN** 用户先对某个无参重载调用执行 `gd`，随后对另一个同名重载调用执行 `gd`
- **THEN** 第一次结果 MUST NOT 以裸符号或 receiver 键短路第二次语义请求
- **AND** 第二次结果 SHALL 独立来自其自身位置和 TU context

#### Scenario: Buffer or cursor changes while a request is dispatched
- **WHEN** request snapshot 建立后用户切换窗口/buffer 或移动光标，而 provider 请求尚未发出或返回
- **THEN** provider params SHALL 仍对应原 snapshot 的 URI、position 与 document version
- **AND** 因 snapshot 已 stale，响应 MUST NOT 产生跳转、通知覆盖、jumplist 或 context side effect

#### Scenario: Build or index generation changes
- **WHEN** active platform、configuration、target、project、compile command、donor TU 或 index generation 发生变化
- **THEN** 旧 context/result MUST NOT 在新 generation 中命中
- **AND** 系统 SHALL 重新建立或重新解析对应 semantic evidence

#### Scenario: Unsaved buffer changes overload resolution
- **WHEN** 未保存的 C++ buffer 内容改变实参类型、可见声明或重载集合
- **THEN** 下一次 `gd` SHALL 基于该 document version 的 unsaved contents 求值
- **AND** 较早 document version 的异步结果 MUST NOT 导致跳转

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

### Requirement: Semantic resolution SHALL remain asynchronous and reuse warm TUs

Clang 解析、TU 创建、reparse 与索引构建 SHALL 在 Neovim UI 主循环之外运行。导航入口 SHALL 在 50ms 内归还 UI 控制权；超过 150ms 的活动请求 SHALL 显示可取消进度。系统 SHALL 复用仍有效的 warm TU 与已加载索引，同一 snapshot/context 的暖查询 MUST NOT 重启完整编译器进程或重复支付 cold parse；资源占用 SHALL 受明确的 TU/index cache 上限约束并进入性能探针。

#### Scenario: Cold context parse
- **WHEN** 所需 TU 尚未加载且用户触发 `gd`
- **THEN** 命令 SHALL 在 50ms 内返回 UI 控制权并异步开始解析
- **AND** 超过 150ms 时 SHALL 显示可取消进度并记录 cold parse、RSS、generation 与最终状态

#### Scenario: Warm context query
- **WHEN** 相同 fingerprint/generation 的 TU 已加载且 document overlays 未使其失效
- **THEN** 系统 SHALL 直接复用该 TU 处理查询
- **AND** SHALL NOT 重复创建 TU、重启 sidecar/clangd 或读取全量 CDB

#### Scenario: Warm TU is invalidated
- **WHEN** compile-command fingerprint、active context、document overlay 或 build/index generation 使已加载 TU 失效
- **THEN** 系统 SHALL 丢弃该 TU 的权威资格并异步重建
- **AND** 重建期间 MUST NOT 复用旧 destination 执行跳转

#### Scenario: Repeated cold queries reach cache bounds
- **WHEN** 用户依次查询超过配置上限的不同 TU/context
- **THEN** 系统 SHALL 按可观察的 LRU/idle 策略释放旧 TU
- **AND** 进程 RSS、TU count 与 eviction reason SHALL 被探针记录且不得无界增长

### Requirement: Contextual semantic navigation SHALL NOT modify engine or project sources

为头文件建立真实 TU 语义上下文的实现 SHALL 位于 Neovim 配置、其状态目录或独立本地进程中，并只读消费 build artifacts / compile database。系统 MUST NOT 修改 UE 引擎源码、项目源码或为单个头文件注入持久化 source workaround。

#### Scenario: Non-self-contained UE header requires predecessor includes
- **WHEN** 头文件只有在真实 source TU 的 include 顺序与宏环境中才能完整解析
- **THEN** 系统 SHALL 在该真实 TU 中查询头文件位置
- **AND** MUST NOT 编辑头文件、`.cpp`、项目配置或提交 per-file forced-include 补丁

#### Scenario: Local semantic tooling is unavailable
- **WHEN** 本机缺少兼容的 Clang semantic tooling
- **THEN** 系统 SHALL 返回 `unavailable` 并报告工具探测结果
- **AND** MUST NOT 因工具缺失改走猜测式导航

### Requirement: Definition navigation SHALL follow one canonical entity route

对 compiler-addressable C++ entity，系统 SHALL 先建立 exact expression 选中的 canonical identity，再解析该 identity 的角色与 destination 集合；reference/call 与 declaration 的 `gd` 目标均为同一 selected entity 的 definition。virtual call 的静态类型、成员查找与 override 关系若明确选中派生 override，该派生 override SHALL 保持独立 identity 并导航到其定义，MUST NOT 被折叠成 base virtual identity。跨 provider 证据 SHALL 以 identity、build generation、exact compile command 与精确位置关联，不能以名称关联。

#### Scenario: Reference lands on declaration before index becomes complete
- **WHEN** reference 的 identity 已证明但当时只有 declaration 可达，用户随后在该 declaration 再次触发 `gd`
- **THEN** 第二次请求 SHALL 延续同一 canonical entity 并查询 definition destination
- **AND** 一旦 compatible complete index 提供唯一 definition，系统 SHALL 跳转到它

#### Scenario: Same name entities exist in different scopes
- **WHEN** 不同 namespace/class 中存在同名同 arity entity
- **THEN** route SHALL 只消费当前位置 canonical identity 的 destinations
- **AND** scope 文本或路径邻近度 MUST NOT 合并这些 entity

#### Scenario: Derived receiver statically selects an override
- **WHEN** exact call expression 的 receiver 静态类型、C++ member lookup 与 override resolution 证明 selected callable 是派生类 override
- **THEN** `gd` SHALL 跳转到该派生 override 的 definition
- **AND** base virtual declaration/definition 与 sibling overrides MUST NOT 替换该目标

#### Scenario: Base receiver dynamic type is not statically proven
- **WHEN** exact call expression 只证明 base virtual callable，而运行时 dynamic type 可能对应多个派生 override
- **THEN** `gd` SHALL 解析被静态选中的 base callable definition，或返回其真实 destination failure
- **AND** 系统 MUST NOT 根据构造点、最近类型、名称或 implementation 返回顺序猜选某个派生 override

### Requirement: Every semantic action SHALL be explainable from structured evidence

系统 SHALL 为最近一次 C++ `gd` 保存有界、脱敏、可查看的结构化 explain record，至少包含 subject snapshot、context provenance、canonical identity 摘要、cursor/entity role、provider capability/results、index coverage、destination filtering、terminal state、stage/reason、elapsed 与 stale 信息。用户通知 SHALL 简短，但 MUST 提供进入完整 explain 的稳定入口；失败类 reason SHALL 进入可迭代 probe feedback loop。

#### Scenario: Cross-TU definition is unavailable
- **WHEN** declaration identity 已知但跨 TU definition 未解析成功
- **THEN** explain record SHALL 区分 identity failure、provider failure、partial index miss、complete index miss 与 multiple destinations
- **AND** 用户无需重新开启 debug logging 即可查看最近一次证据链

#### Scenario: Repeated identical failure occurs
- **WHEN** 同一 stage/reason/generation 的失败重复发生
- **THEN** 探针 SHALL 以稳定 key 聚合 count/first/last 而非逐次追加
- **AND** 探针故障 MUST NOT 影响 `gd` 行为

#### Scenario: Explain output is shared
- **WHEN** explain record 被复制到 issue/spec 或日志
- **THEN** 绝对项目路径、用户名与本机特有标识 SHALL 被 workspace-relative 表示或脱敏
- **AND** identity 可使用稳定 hash，不能泄露不必要的完整源码签名

### Requirement: Semantic completeness SHALL be proven by a conformance matrix

完成验收 SHALL 同时包含纯 Lua 协议测试、真实 libclang fixture、真实 clangd controlled BackgroundIndex + module AST 端到端测试，以及可选真实 UE smoke。矩阵 SHALL 覆盖位置角色、entity kind、TU/context、索引 coverage、document freshness、exact-command transport 与 provider lifecycle；单一函数或纯 mock happy path MUST NOT 作为系统完成证据。

#### Scenario: Core entity and role matrix
- **WHEN** 运行语义导航回归
- **THEN** fixture SHALL 至少覆盖 function/method overload、derived/base virtual call、constructor/destructor、type/alias、field/variable、enum member、namespace/namespace alias、macro、template specialization 与 operator
- **AND** 每类 SHALL 覆盖适用的 reference/call、declaration、inline definition、out-of-line definition 角色

#### Scenario: Context and freshness matrix
- **WHEN** 运行跨 TU/context 回归
- **THEN** fixture SHALL 覆盖 source、direct-open header、inherited header、unrelated same-window header、多 proven contexts、unity/PCH evidence、unsaved overlay、CDB switch、generation switch、`--enable-config=false` exact-command injection 与 clangd restart
- **AND** 每个场景 SHALL 断言 destination identity 或明确 terminal stage/reason

#### Scenario: Known SubmitActiveCmdBuffer regression
- **WHEN** 在 fixture/真实 smoke 中从二参数调用、无参 overload、头文件 declaration 依次执行 `gd`
- **THEN** 每个调用 SHALL 保持各自 canonical identity
- **AND** 二参数 declaration 上的 `gd` SHALL 到达对应 `.cpp` definition，而不是原地结束或跳到无参 overload

#### Scenario: Known Android Vulkan derived virtual regression
- **WHEN** active Android build 中 `FVulkanCommandListContext&` receiver 调用其 `RHISubmitCommandsHint()` final override 并触发 `gd`
- **THEN** identity SHALL 为 `FVulkanCommandListContext` 派生 override，而不是 base RHI virtual method
- **AND** destination SHALL 为该 override 的 `VulkanCommands.cpp` out-of-line definition，而不是停在 `VulkanContext.h` declaration

### Requirement: Semantic sidecar deadlines SHALL terminate stalled native work

每个 semantic sidecar 请求 SHALL 有明确的 host-side deadline。请求超时后，client SHALL 完成该
请求的结构化失败、清除 pending 状态，并回收仍卡在 native parse 中而无法读取 cancel 的 sidecar
进程；不得让无响应进程继续占用 CPU 或永久阻塞后续导航。下一次请求 SHALL 能按现有 process
manager 冷启动新 sidecar。

#### Scenario: libclang parse 超过请求期限
- **WHEN** sidecar 在 native parse 中超过配置的 request timeout 且无法处理协议 cancel
- **THEN** client SHALL 终止该 sidecar，并以 timeout/provider-unavailable 完成请求
- **AND** pending map SHALL 清空，旧响应不得再产生跳转或状态覆盖

#### Scenario: 超时后的下一次语义请求
- **WHEN** 前一 sidecar 已因超时被回收，用户再次触发语义导航
- **THEN** process manager SHALL 启动新的 sidecar 并接受请求
- **AND** 系统 MUST NOT 因旧进程或旧 pending entry 永久保持 unavailable
