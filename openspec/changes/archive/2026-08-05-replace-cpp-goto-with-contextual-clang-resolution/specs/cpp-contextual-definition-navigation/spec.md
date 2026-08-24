## Purpose

定义 C++ `gd` 在 UE 大型代码库中的上下文感知语义导航合同：只有真实编译 TU 中由 Clang 证明的实体身份可以驱动跳转，并对头文件上下文、重载、缓存、失败状态和异步性能给出可验证约束。

## ADDED Requirements

### Requirement: C++ definition navigation SHALL accept only semantic targets

C++ `gd` SHALL 只接受当前 active build context 下由 Clang 语义分析返回的 referenced declaration / definition 身份。Tree-sitter、符号文本、receiver 文本、参数个数、workspace symbol、csearch、GTAGS、文件距离或候选排序 MUST NOT 选择、替换或否决 C++ 语义目标。

#### Scenario: Source TU returns one semantic target
- **WHEN** 用户在 active compile database 覆盖的 `.cpp` 调用点触发 `gd`，且 Clang 返回唯一语义目标
- **THEN** 系统 SHALL 跳转到该目标
- **AND** 跳转结果 SHALL NOT 被任何文本候选覆盖

#### Scenario: Semantic resolution is empty or invalid
- **WHEN** Clang 无法为 C++ 调用点建立有效语义目标
- **THEN** 系统 SHALL 保持当前位置并显示语义失败状态
- **AND** 系统 MUST NOT 自动调用 csearch、GTAGS、workspace symbol 或基于文本的 fallback 执行跳转

### Requirement: Header navigation SHALL use a proven translation-unit context

普通 C/C++ 头文件中的 `gd` SHALL 在一个已证明包含该头文件、且拥有真实编译命令的 source TU 上下文中求值。把非自包含头文件作为独立主文件解析所得的候选 MUST NOT 被视为真实 build context 的语义证明。

#### Scenario: Header was reached from a source TU
- **WHEN** 用户从 source TU 导航进入头文件并继续在该头文件中触发 `gd`
- **THEN** 系统 SHALL 继承该 source TU 作为 origin context
- **AND** Clang SHALL 在该 TU 的真实 include / macro / platform context 中解析头文件位置

#### Scenario: Header was opened directly with one proven context
- **WHEN** 用户直接打开头文件，且 active build dependency evidence 只证明一个可解析 source TU context
- **THEN** 系统 SHALL 使用该 context 求解语义目标

#### Scenario: Header has multiple proven contexts and none was inherited
- **WHEN** 用户直接打开头文件，且多个 source TU context 均由 active build evidence 证明
- **THEN** 系统 SHALL 要求用户选择具体 context，或展示按 context 分组的真实语义结果
- **AND** 系统 MUST NOT 按同名、同目录、同 basename、最短路径或最近使用时间自动猜选 context

#### Scenario: No context can be proven
- **WHEN** 系统找不到同时具有 include evidence 与真实编译命令的 TU context
- **THEN** 系统 SHALL 返回 `unavailable` 并说明缺少的语义上下文
- **AND** 系统 SHALL NOT 合成一个未经构建证据证明的 donor TU

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

系统 MUST NOT 持久化或复用按裸 `symbol`、`receiver::symbol`、arity 或格式化签名索引的 C++ definition location。可复用状态 SHALL 是仍然有效的 compiler TU / preamble；若缓存单次查询结果，则其有效域 MUST 至少绑定 active build context、origin TU、compile-command fingerprint、source URI、精确位置、document version 与 live TU epoch。

#### Scenario: A no-argument overload was resolved first
- **WHEN** 用户先对某个无参重载调用执行 `gd`，随后对另一个同名重载调用执行 `gd`
- **THEN** 第一次结果 MUST NOT 以裸符号或 receiver 键短路第二次语义请求
- **AND** 第二次结果 SHALL 独立来自其自身位置和 TU context

#### Scenario: Build context changes
- **WHEN** active platform、configuration、target、project、compile command 或 donor TU 发生变化
- **THEN** 旧 context 的 semantic result MUST NOT 在新 context 中命中
- **AND** 系统 SHALL 重新建立或重新解析对应 TU

#### Scenario: Unsaved buffer changes overload resolution
- **WHEN** 未保存的 C++ buffer 内容改变实参类型、可见声明或重载集合
- **THEN** 下一次 `gd` SHALL 基于该 document version 的 unsaved contents 求值
- **AND** 较早 document version 的异步结果 MUST NOT 导致跳转

### Requirement: Definition navigation SHALL expose explicit terminal states

每次 C++ `gd` SHALL 最终进入 `resolved`、`ambiguous-context`、`invalid-semantic-context` 或 `unavailable` 之一。只有 `resolved` SHALL 自动跳转；其余状态 SHALL 保持用户位置，并提供足以继续诊断或选择 context 的信息。

#### Scenario: Resolved declaration has an in-context definition
- **WHEN** Clang 为 referenced entity 同时提供 declaration 与当前语义上下文可证明的 definition
- **THEN** `gd` SHALL 按定义优先策略落到 definition
- **AND** 若 definition 不可证明存在，则 SHALL 退到同一语义身份的 declaration，而不是同名 sibling

#### Scenario: Multiple contexts produce different valid targets
- **WHEN** 同一头文件位置在多个真实 TU context 中合法地解析为不同实体
- **THEN** 系统 SHALL 返回 `ambiguous-context` 并展示 context 与目标的对应关系
- **AND** 用户选择后 SHALL 仅跳转到该 context 的真实目标

#### Scenario: Request becomes stale before completion
- **WHEN** 用户移动光标、切换 buffer、再次触发 `gd` 或 document version 变化后旧请求才返回
- **THEN** 旧请求 SHALL 被标记 stale 且 MUST NOT 改变窗口、buffer、jumplist 或光标

### Requirement: Semantic resolution SHALL remain asynchronous and reuse warm TUs

Clang 解析、TU 创建和 reparse SHALL 在 Neovim UI 主循环之外运行。系统 SHALL 复用仍有效的 warm TU；同一 context 的重复 `gd` MUST NOT 为每次按键重新启动 `clang-query`、`clang-check`、clangd 或其他完整编译器进程。

#### Scenario: Cold context parse
- **WHEN** 所需 TU 尚未加载且用户触发 `gd`
- **THEN** 命令 SHALL 立即返回 UI 控制权并异步开始解析
- **AND** 系统 SHALL 在延迟超过可感知阈值时显示可取消的进度状态

#### Scenario: Warm context query
- **WHEN** 相同 fingerprint 的 TU 已加载且 document overlays 未使其失效
- **THEN** 系统 SHALL 直接复用该 TU 处理查询
- **AND** SHALL NOT 重复支付完整 cold parse 启动成本

#### Scenario: Warm TU is invalidated
- **WHEN** compile-command fingerprint、active context 或依赖版本使已加载 TU 失效
- **THEN** 系统 SHALL 丢弃该 TU 的权威资格并异步重建
- **AND** 重建期间 MUST NOT 复用旧目标执行跳转

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
