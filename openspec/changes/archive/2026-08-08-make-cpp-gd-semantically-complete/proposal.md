## Why

上一轮语义导航改动修复了特定重载误跳，但现有合同仍把“只到声明并原地终止”视为合法成功，而且旧设想把 `External.File` / monolithic binary index 当成跨 TU body 的主 authority，已被真实 clangd 实验证伪；因此 `gd` 可以拥有正确的实体身份，却仍无法持续找到该实体的定义。现在需要把局部样例修复升级为可证明的完整语义导航合同，并用真实 C++ 语料、受控 BackgroundIndex、module AST 证据和结构化运行探针约束整个链路。

## What Changes

- 将 C++ `gd` 从“一次 definition 请求”改写为确定性的语义实体路由：精确位置先解析 compiler-owned identity，再按当前位置角色解析唯一 declaration/definition；当调用点先落到声明时，声明上的下一次 `gd` 必须继续到同一实体的跨 TU 定义，而不是原地结束。
- 将 virtual call 的目标绑定到精确调用表达式实际选中的 callable identity：当静态类型、成员查找与 override 关系明确证明调用派生类 override 时，`gd` 必须落到该派生 override 的定义；只有运行时 dynamic type 无法静态证明时才禁止猜选某个派生实现。
- 要求 clangd 可见索引的定义覆盖保持单调：current/hot/full 都以 compiler-authored UBT unity wrapper CDB 与 exact-command transport 注入的同 generation compile commands 为输入；较窄刷新不得用更窄 coverage 取代已知可达的 body。每个导航结果必须绑定 active build、CDB 与 generation，并显式区分“实体不存在定义”和“当前可证明 module context 尚未覆盖定义”。
- 收紧头文件 context 生命周期：继承 context 必须绑定导航 lineage、目标文件 membership、build fingerprint 与 proven module context；不适用于当前头文件时必须重新 catalog，不能让窗口级旧 context 污染后续 `gd`。
- 将光标 URI、位置、document version、client、exact compile command 与 generation 固化为单次不可变请求快照，消除异步阶段重新读取当前窗口状态的隐含依赖。
- 统一 provider 权威边界和失败语义：不再把 libclang/clangd 的偶然能力缺失混报为 `invalid-semantic-context`，为缺 compile command、module context 未就绪、provider 不支持、USR 冲突、真实语义歧义、warm cache 失效、64-context cap 命中与 stale 等阶段提供可诊断 reason code。
- 新增结构化 explain/trace 与反馈探针，并建立覆盖 reference、declaration、out-of-line definition、重载、virtual derived override、模板、宏、多 TU context、unsaved overlay、controlled BackgroundIndex 刷新及 clangd 重启的语义一致性矩阵；Android Vulkan 的真实派生类 virtual call SHALL 成为强制 smoke，而不是只测 synthetic fixture；禁止用名称、arity、路径排序、text fallback 或已证伪的 external-index body 假设补洞。
- 为冷/暖导航定义可测延迟与资源预算；冷解析仍异步且可取消，暖查询不得重复支付完整 TU 构建成本。

## Capabilities

### New Capabilities

- `cpp-semantic-index-coverage`: 定义供 C++ 导航消费的 controlled BackgroundIndex generation、UBT unity wrapper coverage、exact-command injection、warm cache/gating 与缺口诊断合同。

### Modified Capabilities

- `cpp-contextual-definition-navigation`: 将“definition 优先、否则 declaration”改为基于 canonical entity 与 proven module AST 的完整 declaration→definition 路由，并补齐 context 生命周期、不可变请求、失败分类、可观测性、性能预算与语料矩阵。

## Impact

- 主要影响 `lua/utils/lsp_fallback.lua`、`lua/utils/ue_goto/semantic_*`、`lua/utils/ue_goto/provider.lua`、`lua/ue/index/`、clangd 启动参数 / exact-command transport 及其回归测试。
- 需要调整现有把“声明原地终止”固定为成功条件的 `tests/cases/ue_goto_behavior_spec.lua`，并新增真实 clangd controlled BackgroundIndex + module AST 端到端 fixture/探针；纯 mock 测试不再足以证明完成。
- 不修改 UE 引擎或项目代码，不引入文本 fallback，不新增运行时依赖；继续复用现有 LLVM/clangd、libclang 与 Neovim sidecar 基础设施。`clangd-indexer` / `External.File` binary index 路线保留为被记录的证伪素材，不再作为现状主架构。
- 可能改变用户可见的 C++ `gd` 终点和错误信息，但不改变非 C++ 导航行为与快捷键。
