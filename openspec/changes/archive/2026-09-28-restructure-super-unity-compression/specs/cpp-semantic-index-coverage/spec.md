## ADDED Requirements

### Requirement: 编译器发射序列内的合并 SHALL 由分组规则保证兼容性

当若干 compiler-authored UBT unity 属于**同一次 UBT unity 发射序列**——即
module root、完整编译上下文与成员类别（全部 `.gen.cpp` / 全部普通源）三者相同——
它们之间的切分 SHALL 被视为纯字节预算切分。系统 MAY 在该序列内按
`N × NumIncludedBytesPerUnityCPP` 的字节预算重新打包，并且 SHALL NOT 要求逐组完整
BackgroundIndex 图比较作为准入条件。

这条豁免 SHALL 建立在可核验的编译器行为之上：`UnityFileBuilder.AddFile` 在每次追加后
于 `VirtualLength > SplitLength` 时收尾，`SplitLength` 即 `NumIncludedBytesPerUnityCPP`。
提高该预算是 UBT 自身支持的配置点，不改变宏、include、target 或 PCH 语义。

该豁免 MUST NOT 外推：跨成员类别、跨 module root、跨编译上下文的合并仍受
「Secondary batches SHALL preserve independently proven compiler semantics」约束。

#### Scenario: 同一发射序列内按字节预算重新打包
- **WHEN** 若干 UBT unity 的 module root、compile context key 与成员类别完全相同
- **THEN** 规划器 MAY 将它们合并为一个候选，并 SHALL 以字节预算而非成员计数为界
- **AND** 合并 SHALL 保留原始顺序与成员不可分割性；oversized 原始 SHALL 原样保留
- **AND** 准入 SHALL NOT 依赖 `compare_graphs`

#### Scenario: 结构化候选仍须通过覆盖与构建门禁
- **WHEN** 一个结构化保证的候选被提交
- **THEN** 它 SHALL 通过三项硬门禁：编译无失败、后台索引完成且 `missing_main_shards == 0`、
  成员源集合与被替换原始的并集完全一致
- **AND** 任一门禁失败 SHALL 退回该组原始 exact 命令，覆盖 MUST NOT 缩小
- **AND** 结构化保证 MUST NOT 被用来豁免这三项

#### Scenario: 实际预算与引擎默认不一致
- **WHEN** 本 target 配置了非默认的 `NumIncludedBytesPerUnityCPP`，或启用了
  `bUseAdaptiveUnityBuild`
- **THEN** 分桶 SHALL 使用该 target 的实际取值
- **AND** 无法确证实际取值时 SHALL NOT 套用引擎默认并宣称结构化保证成立

#### Scenario: 报告结构化合并的收益
- **WHEN** 报告本机制带来的加速
- **THEN** SHALL 提供本机制自身在同一真实工程上的冷/热实测
- **AND** CDB 条目降幅、UBT unity 数下降 MUST NOT 被表述为速度提升
- **AND** MUST NOT 复用其他机制的历史 A/B 数字作为本机制的收益

## MODIFIED Requirements

### Requirement: Secondary batches SHALL preserve independently proven compiler semantics

系统 MAY 将同模块、完整编译上下文相同的 compiler-authored UBT 组再次合并；MUST NOT 合并宏、
include、target 或 PCH 参数以制造兼容性。**除由「编译器发射序列内的合并 SHALL 由分组规则保证
兼容性」结构化保证覆盖的候选外**，每个候选 SHALL 与各原 UBT **独立缓存**产生的完整
BackgroundIndex 图比较，保留真实文件、定义、符号身份、关系和引用。共享缓存的缺失记录、
`--check` 零诊断、CDB 条目数或进度结束都 MUST NOT 代替此证明。

参考基线本身 SHALL 可满足。当基线要求的符号身份集合在任何单一 TU（候选或原始）中都不存在时，
该位置 SHALL NOT 被记为合并缺陷。

#### Scenario: A union baseline demands symbol identities no single TU carries
- **WHEN** 多个原 TU 在同一 `(uri, start, end, kind)` 处绑定不同 SymbolID（模板主模板与
  偏特化、宏生成的重载集），而基线取其并集
- **THEN** 该位置 SHALL 产生可区分的 verdict，指明基线不可满足
- **AND** MUST NOT 与真实的引用丢失共用 `references-removed-or-retargeted`
- **AND** MUST NOT 据此拒绝候选并宣称候选改变了绑定
- **AND** 真实丢失（某引用存在于原始而候选与全部其他原始都没有对应绑定）SHALL 仍然拒绝

#### Scenario: A candidate changes a binding without a compiler error
- **WHEN** 合并能编译但改变重载目标、删除引用、改变符号身份或产生编译错误
- **THEN** 候选 SHALL 被拒绝，并完整保留其原 UBT 命令
- **AND** MAY 调整候选顺序后重新证明，MUST NOT 为通过门禁任意重映射 SymbolID

#### Scenario: Original commands use an owned Windows filename identity overlay
- **WHEN** secondary qualification consumes a prepared command with the validated filename-canonicalization overlay
- **THEN** original native runs SHALL retain that option and qualification SHALL bind its exact bytes and lookup inventory
- **AND** a frozen candidate SHALL preserve the canonical original file URIs while reading only its closed, verified snapshot; a live-file fallback MUST NOT escape the snapshot
- **AND** foreign or altered VFS inputs SHALL remain unsupported, and this compatibility support MUST NOT waive the full semantic comparison

#### Scenario: Equal header bytes belong to different compiler files
- **WHEN** different source headers have equal bytes but distinct file identities under the active compiler filesystem
- **THEN** freezing SHALL retain distinct snapshot identities so `#pragma once` cannot suppress a header that the real compiler would read
- **AND** actual aliases SHALL preserve the active compiler's alias behavior; equal bytes or a cross-platform inode assumption MUST NOT substitute for that behavior
- **AND** a changed source identity SHALL invalidate cached evidence even when its bytes remain equal

#### Scenario: Compiler metadata differs after declarations merge
- **WHEN** 同一符号的前置声明与定义记录在 language 或 include provider 上不同
- **THEN** 比较 SHALL 遵循已验证的 clangd 定义优先规则
- **AND** 新 include provider SHALL 来自原输入头文件，在单一原 TU 的依赖闭包中到达已有声明；原 provider 提供定义时新 provider 也 SHALL 到达该定义
- **AND** 未解析的 literal include、新输入头、失去全部建议或指令模式变化 SHALL 被拒绝

#### Scenario: A batch exposes an additional reference
- **WHEN** 候选产生原独立图中没有的引用
- **THEN** SHALL 在所有原本包含该文件的原 UBT AST 中证明 target、role、container 与位置
- **AND** 缺失 native 能力、任一上下文不同或只在合并 TU 中查询 SHALL 拒绝候选

#### Scenario: Printed template arguments differ while typed compiler arguments agree
- **WHEN** class-template partial specialization records differ only in their printed `template_specialization_args`
- **THEN** the system MAY accept that field difference only after native compiler proof of the complete ordered argument kinds, parameter identities, types and values in every original TU containing the declaration and in the candidate
- **AND** proof SHALL use each main shard's effective command and bind the exact original/candidate records, declaration identities and locations, input/tool/profile identities and all required contexts; raw argv or a matching SymbolID alone MUST NOT substitute for proof
- **AND** the supported proof SHALL check integral parameter type and width before reading its value, preserve integer precision, and prove type-parameter bindings by declaration identity; dependent expressions, unsupported kinds/widths, ambiguous or missing declarations and compiler errors SHALL fail closed
- **AND** raw graphs SHALL remain unchanged; missing references, relation/source/definition/completion changes or other identity differences SHALL still reject before expensive template proof runs
- **AND** request/result assets SHALL be hashed into the receipt; changed evidence or policy SHALL invalidate cache-only reuse, which MUST NOT rerun the native proof
- **AND** accepted semantic equivalence SHALL NOT be reported as identical printed metadata or restored indexing performance

#### Scenario: The same inputs are prepared again
- **WHEN** 已有成功或语义拒绝的证明，输入未变化
- **THEN** MAY 复用 receipt，但 SHALL 重新验证完整命令、工具/策略身份、输入/冻结产物字节与 include 目录名称清单
- **AND** 输入同 mtime 换字节、新增条件头文件、产物损坏或工具变化 SHALL 使旧证明失效
- **AND** 首次证明成本与重复验证耗时 SHALL 分开报告，MUST NOT 把首次成本藏入缓存

#### Scenario: A proof helper imports its filename identity policy for the first time
- **WHEN** qualification or offline generated-batch tooling loads the owned filename identity policy from a writable source directory
- **THEN** the caller SHALL disable Python bytecode writes before importing that policy or its project dependencies, so first import does not itself alter a monitored lookup inventory
- **AND** the rule SHALL hold without requiring the launcher to supply `-B`; actual source changes and existing inventory mismatches SHALL still invalidate receipts
- **AND** this prevention MUST NOT delete existing bytecode, rewrite old receipts, or establish semantic or performance acceptance for any batch

#### Scenario: Automatic delivery has no reusable proof
- **WHEN** automatic current/hot/full delivery encounters a missing, stale or policy-incompatible receipt
- **THEN** it SHALL retain the original UBT commands, report deferred verification, and MUST NOT start cold compiler proofs or graph replay in the delivery path
- **AND** a separate explicitly invoked proof run MAY produce receipts; its first-run cost SHALL remain visible in performance acceptance

#### Scenario: A project delivers a qualified subset before broader optimization
- **WHEN** a project/target selects an existing proof directory in `batch-store.json` adjacent to its semantic CDB (`schema: 1`, absolute `path`)
- **THEN** automatic current/hot/full generation SHALL pass that directory to the existing cache-only verification path and SHALL retain every unselected original and shader record
- **AND** both generators MAY accept `--verified-batch-store` only together with `--verified-batches` and `--reuse-verified-only`; the default store and original-wrapper directory SHALL remain unchanged when no selection exists
- **AND** the selection SHALL grant no semantic authority: current exact commands, compiler/profile/environment, dependencies, lookup inventories and frozen assets SHALL still pass the existing receipt checks
- **AND** missing or stale receipts SHALL retain their original commands without cold qualification; malformed, relative or oversized selection metadata SHALL fail before generation while preserving published artifacts
- **AND** the selected proof directory SHALL remain available for the lifetime of its published receipts; receipts and bound assets MUST NOT be rewritten merely to relocate proof ownership
- **AND** a verified incremental version MAY be delivered with explicit measured scope and remaining optimization work, without claiming whole-engine performance restoration or waiving coverage, fallback and unchanged-prepare checks

#### Scenario: Compatible Unity groups are packed into a larger SuperUnity
- **WHEN** compiler-authored UBT groups belong to the same module and complete compile context
- **THEN** candidate planning SHALL preserve their original order and indivisible membership, bounded by a **member-source byte budget** derived from the target's `NumIncludedBytesPerUnityCPP`
- **AND** generated sources SHALL count toward the same budget; oversized originals and exact commands SHALL remain available without being dropped
- **AND** 成员计数上限 MAY 作为附加保护保留，但 MUST NOT 成为唯一界限，因为成员数与前端成本不成比例
- **AND** an explicit qualification run MAY subdivide a semantically rejected candidate and reuse valid independent original-TU evidence; automatic cache-only delivery MUST NOT start these cold qualifications

#### Scenario: A different candidate reuses an independently indexed original TU
- **WHEN** an original TU already has complete independent graph evidence
- **THEN** qualification MAY reuse it only after checking its original entry, native effective command, compiler/profile/environment, complete dependencies, lookup inventories and stored assets
- **AND** persisted evidence SHALL bind the native source digests to the actual source bytes; a successful frozen candidate with matching source digests and unchanged SHA-bound snapshots MAY establish that association even when later semantic admission rejects the candidate
- **AND** an unlinked source digest or failed candidate compilation MUST NOT certify a newly collected original graph for persistent reuse
- **AND** historical collection cost SHALL remain recorded separately from the new candidate's actual compilation cost

#### Scenario: A proven group is noncontiguous in the full input
- **WHEN** a previously accepted ordered group is present among other compatible original UBT entries
- **THEN** cache-only discovery MAY use bounded compact selection hints without scanning all proof graphs or rejected records
- **AND** a hint SHALL remain untrusted: exact current entries, module/context, the existing proof cache key, compiler/policy identities, receipt originals and all existing input/asset validations SHALL still match
- **AND** the configured maximum group size SHALL remain a hard limit; selected groups SHALL not overlap, and every unselected original entry SHALL remain present
- **AND** planning additional candidates SHALL first exclude already selected originals, then pack the remaining compatible entries; overlap with an accepted hint MUST NOT hide otherwise eligible unclaimed groups
- **AND** invalid, stale, oversized or absent hints SHALL NOT authorize a batch or start a cold proof during automatic delivery

#### Scenario: Experimental ordered candidates are not admitted batches
- **WHEN** an offline candidate producer explores secondary groups with explicit module Definitions headers
- **THEN** it SHALL preserve the original ordered PCH/compiler prefix and replay Definitions after that prefix, isolate touched macros, and keep differing feature macro states in separate groups
- **AND** candidates SHALL classify actual member files and keep generated-only and implementation-only originals in separate groups; originals containing both classes SHALL remain unchanged
- **AND** candidates SHALL preserve original ordering within each class and each Unity's internal order, retaining complete original ownership and coverage; moving generated specializations ahead of implementation calls MUST NOT manufacture compatibility
- **AND** unsupported headers, ambiguous membership and oversized originals SHALL remain unchanged; unchanged inputs SHALL NOT rewrite candidate artifacts
- **AND** candidate generation and syntax-only success SHALL NOT authorize production publication, stand in for independent semantic proof, or be reported as restored full-index performance

#### Scenario: Generated-only grouping passes source-local checks but loses header targets
- **WHEN** an offline generated-only candidate preserves source-local reference records and definitions of symbols declared in source shards
- **THEN** qualification SHALL also check the global availability and definitions of every referenced target ID, including targets declared only in headers
- **AND** a missing header target SHALL reject publication; unchanged reference tuples, zero reference counts, symbol flags or speed improvements MUST NOT waive the loss
- **AND** `build_super_unity_cdb.build_generated_batches` SHALL remain an offline candidate API until full semantic and performance acceptance succeeds; it MUST NOT be enabled automatically merely because generation fixtures pass
