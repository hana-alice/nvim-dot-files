## Context

参见 [proposal.md](proposal.md) 的动机。本设计只记录决定实现路径所需的当前事实：

- C++ `gd` 已在 `lua/utils/lsp_fallback.lua` 前置分流，不进入 legacy cache/csearch/GTAGS；现有 source/header 路径都依赖 libclang sidecar 的 proven TU context 与 canonical USR，但 destination 仍混杂旧的 clangd-only cross-TU assumptions。
- `tests/cases/ue_goto_behavior_spec.lua` 当前明确断言“clangd 只返回原声明时保持当前位置”，所以“声明处停止”不是偶发漏测，而是现有验收合同认可的不完整终点。
- header origin 目前按 `winid + build_fingerprint` 保存。`resolve_header()` 只要命中该记录就直接 dispatch，没有先证明当前 header 仍属于该 origin TU；相同 build 中在同窗口打开无关 header 会把旧 context 带入新 subject。
- provider 接口在发请求时通过当前窗口生成 position params，且 `async_clangd_symbol_info()` 把 unsupported、request error、timeout、空结果与多 client 分歧都压缩为 `usr=nil`。
- current/hot/full 目前在生成与消费层缺少统一 generation 合同。真实实验证明：仅靠 `External.File` / monolithic binary index 并不能让 clangd 的 `textDocument/definition` 对 header declaration 或 call site 稳定返回 `.cpp` body；而 controlled BackgroundIndex + compiler-authored unity wrapper 可以。
- 当前 `cpp-semantic-performance` 探针记录到 cold parse 约 7.2s、单 TU sidecar RSS 约 2.26GB；现有 probe 只记录性能，没有记录 `gd` 各 stage 的失败分布。
- 已对 active Android Test CDB 中的真实 Vulkan 调用做独立实验：`VulkanViewport.cpp` 的 `FVulkanCommandListContext&` 调用 `RHISubmitCommandsHint()`，sidecar 与 clangd `symbolInfo` 均返回 `FVulkanCommandListContext::RHISubmitCommandsHint` 的同一 USR hash，证明 exact call 选中派生类 `final override`；但 clangd 在调用点与派生 declaration 上的 `definition` 都只返回 `VulkanContext.h` declaration，`implementation` 为空，而 out-of-line body 实际存在于 `VulkanCommands.cpp`。因此该病例的 identity 阶段正确、destination 阶段不完整，不能靠改 overload/member lookup 解决。脱敏原始结果见 [evidence.md](evidence.md)。
- clangd 官方设计说明其 index 才拥有跨 AST 的 declaration/definition location，且运行时会把 live FileIndex 与后台索引合并；官方 `textDocument/symbolInfo` 扩展只解析当前位置 identity，本身不会取 definition。真实实验进一步证明：indexer YAML 可记录 `Definition=.cpp`，但 binary external index 交给 clangd 后并不保证 `definition` 返回 body；受控 BackgroundIndex shards 才是已验证可兑现到 body 的 clangd 路线。

约束：只修改本 Neovim 仓及其本地状态/工具脚本；不改 UE 引擎/项目源码，不增加文本猜测 fallback，不新增依赖，继续钉住现有 LLVM/clangd 22 工具链；非 C++ `gd` 行为保持不变。

## Goals / Non-Goals

**Goals:**

- 对 active build 中 compiler-addressable entity 建立从精确位置到 canonical identity，再到唯一 definition/body 的完整、可解释路径。
- 让 declaration 上的 `gd` 独立具备跨 TU definition 能力；前一次 navigation continuation 只用于解释，不作为正确性前提。
- 使同一 generation 中的 controlled BackgroundIndex coverage、UBT unity wrapper 基线与 live exact-command freshness 单调协作，而不是依赖被证伪的 external `.idx` body authority。
- 把 context、provider、module coverage、warm cache 与 stale 失败拆成稳定 stage/reason，并以真实 clangd controlled BackgroundIndex + module AST fixture 证明。
- 在不阻塞 UI 的前提下约束冷/暖路径和 sidecar 资源上限。

**Non-Goals:**

- 不从 base-typed polymorphic call 猜测运行时 dynamic type，也不把所有 overrides 组成 picker；但 exact call 若由 C++ 静态语义明确选中派生 override，该 override 就是 `gd` 必须解析的 definition identity，而不是可忽略的 implementation 候选。
- 不保证 active CDB 之外、未被 build evidence 覆盖或条件编译未激活的源码可导航。
- 不引入自定义 clangd fork、远程索引服务、Telescope/GTAGS/csearch destination fallback，或在 UE 引擎/项目中写入人工辅助 TU；允许消费 compiler-authored UBT unity wrapper / exact fallback 产物。
- 不借本 change 重写非 C++ 的 legacy `lsp_fallback`、搜索系统或高亮系统。

## Decisions

### 1. 以一笔 Semantic Transaction 取代分散 callback 决策

每次 C++ `gd` 创建不可变 `NavigationSnapshot`：

```text
subject = { action_token, winid, bufnr, uri, line, column, document_version }
build   = { build_key, cdb_fingerprint, toolchain_fingerprint, index_generation }
context = { origin_tu, compile_fingerprint, provenance, subject_membership }
entity  = { canonical_identity, opaque_id?, kind, subject_role, declaration }
index   = { coverage_level, coverage_set_hash, readiness, artifact_fingerprint }
result  = { state, stage, reason, destination_role, locations, evidence[] }
```

一个 coordinator 负责阶段推进和唯一 terminal callback；provider 只返回证据，不直接跳转、不发最终通知。所有 LSP params 从 snapshot 的 URI/position 构造，禁止在异步阶段读取当前窗口。每阶段进入前及结果应用前都验证 snapshot/generation；stale 只写 trace，不产生 UI side effect。

**替代方案：保留现有嵌套 callback 并补几个条件。** 拒绝，因为状态分类、取消和 provider 证据散在 `lsp_fallback`、client、provider 三处，正是“同一失败被多种路径解释”的来源，也无法测试一次且仅一次终止。

### 2. Context authority、entity authority 与 destination authority 明确分工

- **Context authority**：active build generation 下由 compiler-authored UBT unity wrapper、active CDB membership、dependency evidence 与 exact-command transport 共同证明的 module context；sidecar 只在 proven TU 中解析 header，source/header 都必须绑定 exact active compile command。
- **Entity authority**：source 与 header 都以 proven libclang AST 中的 canonical USR 为准；clangd `symbolInfo` 只作为 exact-cursor corroboration 与 transport sanity check，不再承担主 identity authority。virtual call 保留 exact member lookup 选中的 override identity，MUST NOT 沿 overridden-method relation 向上折叠成 base identity。
- **Destination authority**：先在 subject 所属 module 的 proven UBT TU AST 中按 exact canonical USR 找唯一 body。若 module contexts 暂不可用，再允许 secondary clangd 协助补齐同 generation 的 destination；零个或多个 body 都 fail closed，不能按顺序猜选。
- `symbolInfo` 的 `usr`、可用时的 clangd opaque `id`、client id、capability/error/elapsed 均完整保留；不再用 `(usr|nil, client_ids)` 丢失失败原因。

这不是两个独立分析器“投票”。每个 provider 只在其有权证明的层级发言；跨层关联必须通过 canonical identity + generation，而非 name/signature。

**替代方案 A：只用 libclang 扫完整工程建立全局 USR 索引。** 拒绝，因为当前单个 UE TU 冷解析已约 7.2s/2.26GB，全 CDB 重复索引会复制 clangd-indexer 已承担的高成本工作。

**替代方案 B：只用 clangd 解析所有 direct-open header。** 拒绝，因为一个非自包含 header 可属于多个真实 TU；没有 chosen build provenance 时，clangd 的 header command 不能证明当前 macro/include context。

**替代方案 C：把 `External.File` / clangd-indexer binary index 作为 body definition 主 authority。** 已证伪。真实实验表明：indexer YAML 虽可记录 `Definition=.cpp`，但 binary external index 交给 clangd 后，`textDocument/definition` 对 call/declaration 仍可能停在 header declaration；因此它只能作为 falsification 记录，而不是现状主架构。

**替代方案 D：自定义 clangd RPC/fork 按 SymbolID 查 definition。** 当前不采用；先落地已证实可工作的 exact-command + controlled BackgroundIndex + module AST 路线，不引入维护分叉。

### 3. 把 declaration→definition 定义为角色驱动的同一 entity route

coordinator 根据 compiler evidence 标记 subject role：`reference/call`、`declaration`、`definition` 或 `other-addressable`。行为固定为：

| Subject role | `gd` destination |
| --- | --- |
| reference/call | 同一 selected canonical entity 的唯一 definition；静态语义选中 derived override 时即为该 derived definition；partial coverage 时可落同一 declaration 并标注 continuation gap |
| declaration | 同一 canonical entity 的唯一 definition；不得把当前 declaration 当成功结果 |
| definition | 不跳转，`unavailable/already-at-definition` |
| dependent/recovery/ambiguous | 对应 compiler-owned failure，禁止猜测 |

若 reference 在 partial coverage 下先落 declaration，后一次 `gd` 会从 declaration 重新解析 identity，因此即使 window/context continuation 丢失也仍正确。continuation record 只改善 explain 与预热，不是 location cache。

**替代方案：把 declaration fallback 视为最终 resolved。** 拒绝；它已经被现有测试证明会产生用户报告的原地终止。

### 4. 索引采用 generation + controlled BackgroundIndex baseline + live exact-command overlay

新增 index manifest，至少包含：

```text
generation_id = hash(build_key, normalized_cdb_digest, toolchain_identity)
artifact      = { phase, cdb_digest, module_set_hash, coverage_level, built_at, manifest_gate }
```

选择规则：

1. 同 generation 中优先维护 compiler-authored full/current/hot module coverage 的超集关系；`full > hot > current` 由 manifest 与 module-set hash 证明，而不是由最后完成时间决定。
2. full/current/hot 各自的 active CDB 只包含对应 phase 的 compiler-authored UBT unity wrapper / exact fallback TU；clangd 以 `--enable-config=false` 启动，通过官方 `compilationDatabaseChanges` 注入当前打开文件与头文件的 exact commands。
3. full 存在时，controlled BackgroundIndex 只对该 generation 的 synthetic/full TU 建立 shards；current/hot 不得用更窄 baseline 覆盖该 generation 已知 body reachability。打开/修改文件的新鲜语义由 exact-command transport 与 sidecar unsaved overlay 提供。
4. 尚无 full 的新 generation 允许 partial coverage，但所有 miss 都标记 `index-incomplete`；full 通过现有 idle 调度收敛。manifest gating 决定 clangd restart 与 shard 回收，而不是 `.clangd` 文件写入。
5. generation 真正改变、manifest gate 变化或 warm module cache 与 exact commands 不再匹配时才重启 clangd；仅产生一个未被选择的窄 artifact 不重启。
6. sidecar 维护 warm module lookup cache，并对 direct-open header catalog 加 64-context cap；超限时返回可解释的 cap/staleness reason，而不是静默扩张。

这保留 current/hot 的启动价值，同时消除“最后完成者赢”的 coverage 降级，并避免把已证伪的 external `.idx` 作为 body authority。

**替代方案：重新开启不受控的全工程 BackgroundIndex。** 拒绝；仓库已有 17GB/32min 资源事故约束。只有 compiler-authored unity wrapper / exact fallback TU 可被允许进入 controlled BackgroundIndex。

### 5. Header context 绑定 lineage 与 subject membership

`window_contexts[winid]` 改为 lineage record，而不是裸 origin TU。record 至少绑定 generation、source action、origin TU、proven dependency evidence fingerprint 与允许继承的 header membership。只有当前 subject path 被该 evidence 覆盖才可继承。

direct-open header 仍走 catalog。若 inherited context 在 query 阶段报告 `query-file-not-in-tu`，coordinator 使它失效并在同一 snapshot 下 catalog 一次；这不是 heuristic fallback，而是撤销一条已被编译器证伪的 context 证据。catalog 后的多 context 仍要求用户选择。

context 不以“同窗口 + 同 build fingerprint”跨无关 header 永久复用，也不持久化为 definition cache。

### 6. 保留四个公开 terminal state，增加正交 stage/reason

为兼容现有协议与本地约束，顶层仍只有：

- `resolved`：已证明 destination 且实际跳转；可标注 `destination_role=definition|declaration`。
- `ambiguous-context`：多个 proven TU context 导致不同合法 identity/result。
- `invalid-semantic-context`：compiler cursor/AST/recovery/dependent/identity 本身无效或冲突。
- `unavailable`：环境、compile command、provider capability/readiness、index coverage、destination absence、already-at-definition 等外部条件不满足。

正交 `stage` 固定为 `snapshot/environment/context/catalog/tu/entity/provider/index/destination/jump/stale`；`reason` 是稳定枚举，例如 `active-compile-command-missing`、`context-not-member`、`provider-method-unsupported`、`provider-timeout`、`identity-conflict`、`index-incomplete`、`index-stale-for-module`、`definition-absent-in-complete-index`、`multiple-definitions`、`already-at-definition`。

通知显示一句摘要和 explain 入口；完整 diagnostics/evidence 不塞进 toast。

### 7. 结构化 explain 与 probe 是完成条件，不是事后 debug 开关

保存最近一次 transaction 的有界脱敏 record，并提供稳定命令查看。trace 与 probe 复用同一 event model：

- trace 记录每阶段耗时、输入 fingerprint 摘要、provider client 与筛选决策；
- probe 仅聚合 failure `stage/reason/generation-class` 与性能 `cold/warm/index-wait/RSS`；
- project/engine path 转为 root-relative，USR/signature 只保留 hash/短摘要；
- 写时去重、TTL、cap 与 `pcall` 遵守 `probe-feedback-loop` 现有合同。

没有 explain record 的失败回归视为未完成，因为“gd 不动”无法再依赖用户重现并临时开 log。

### 8. 用分层 conformance matrix 取代单点 mock 证明

测试分四层：

1. **纯 Lua contract**：snapshot 不变性、一次 terminal callback、reason 分类、context membership、generation selector 与 promotion 单调性。
2. **真实 libclang fixture**：overload、template、macro、alias、declaration/definition role、多 TU context、unsaved overlay。
3. **真实 clangd + controlled BackgroundIndex E2E**：磁盘 CDB 只含 compiler-authored synthetic/full TU 或 partial fallback，clangd 以 `--enable-config=false` 启动，并通过官方 `initializationOptions.compilationDatabaseChanges` / `workspace/didChangeConfiguration` 注入 exact commands。验证 full baseline 可使 call/declaration 到 `.cpp` body、partial miss 停 declaration、以及 full→partial→full 的 generation/restart stale。
4. **真实 UE smoke**：以脱敏位置描述运行 SubmitActiveCmdBuffer 重载/declaration continuation，以及 Android Test CDB 下 `FVulkanCommandListContext&` 的 `RHISubmitCommandsHint()` derived `final override` call；必须同时断言 selected identity 与最终 `.cpp` definition，只作为环境证据，不替代可重复 fixture。

纯 mock 仍用于异常注入，但不能证明 clangd index 行为。测试必须包含一个在旧实现下失败的 partial-after-full fixture和一个 declaration-self-result fixture。

### 9. 性能采用 UI 硬门槛、暖路径结构门槛和真实数据基线

- `gd` Lua 入口 50ms 内归还事件循环；150ms 后才展示 progress，取消/新请求立即使旧 action stale。
- warm 同 fingerprint/generation 请求必须命中 live TU/index，不创建新进程、不重读全 CDB、不重新 cold parse；fixture 记录 P50/P95，但在拿到稳定实测前不虚构跨机器绝对毫秒 SLA。
- sidecar 继续 LRU/idle eviction；probe 记录 TU count、cold/reparse/query 时间与 RSS。验收要求 RSS 随 cache 上限有界，而不是承诺低于当前单 TU 真实成本。
- index artifact 未覆盖时立即给出 `index-incomplete`/进度证据；不让 UI 静默等待 full index 构建。

## Risks / Trade-offs

- **[新 generation 的 full 索引尚未完成时，跨模块 definition 仍可能不可达]** → 使用最宽 partial bootstrap，但把 miss 明确标为 `index-incomplete`；不以错误 declaration 或旧 generation 冒充完成。
- **[保持 full static base 会让 dirty closed TU 的定义暂时陈旧]** → dirty module mask 使不新鲜 destination fail closed；打开 buffer 由 dynamic FileIndex 覆盖，idle full rebuild 最终收敛。
- **[libclang 单 TU 已有约 2GB 级 RSS]** → 不扩展为全工程 libclang index；严格 LRU/idle cap，真实探针作为回归门禁。
- **[`textDocument/symbolInfo` 是 clangd extension，协议可能演进]** → 钉住当前 LLVM 22，运行时显式 capability/protocol 校验并输出 `provider-method-unsupported`；不降级到文本身份。
- **[多 context header 必然需要用户选择]** → 只在 compiler evidence 证明结果确实分歧时提示，选择绑定本次 lineage；不以“最近选择”猜测。
- **[真实 clangd controlled BackgroundIndex E2E 比纯 Lua 测试慢]** → 作为 semantic filter 与提交前全量门禁分层运行，fixture 保持小型；不能为了速度删除真实协议层。

## Migration Plan

1. 先加入会在旧实现下失败的 declaration continuation、unrelated-header context、immutable-position 与 partial-after-full E2E 回归，冻结目标行为。
2. 加入 index manifest/generation selector；把 clangd 消费面改为 `--enable-config=false` + official exact-command transport + controlled BackgroundIndex gating，先阻止同 generation coverage downgrade，再让 clangd restart 仅跟随 chosen manifest gate。
3. 引入 transaction/evidence 数据模型与 provider structured result；在不跳转的 shadow trace 中对现有 fixture 比较 identity/destination，确认 reason 分类。
4. 将 C++ `gd` 一次性切换到 coordinator，删除旧 header/source 分叉中的 destination 决策和“声明原地终止”验收；非 C++ 路径不动。
5. 加入 explain/probe、性能与真实 UE smoke，跑 semantic filters 后跑全量回归并更新 changelog/架构文档。

回滚以 change 的独立提交组为单位恢复旧 coordinator/index selector；index manifest 与新测试/诊断数据均位于 Neovim cache/repo，不修改项目资产。若回滚实现，必须同时把本 spec 标为未实现，不能保留“已完整”声明。
