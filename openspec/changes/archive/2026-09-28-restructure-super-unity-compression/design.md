## Context

现行二次合并把**兼容性当作待证明的命题**：先假设任意同模块同上下文的 UBT 组可以合并，
再用完整 BackgroundIndex 图比较去证伪。这条路线的成本是每个原始 TU 约 36.5 秒、
每条节省的 CDB 记录约 90 秒，而且被证明**门禁本身不可满足**（见 proposal 的实测）。

本设计把兼容性**前移到分组规则**：只在编译器自己已经判定为「同一批、只因字节预算被切开」
的 unity 之间合并。证据不再是逐组图比较，而是编译器的分组算法本身。

## Goals / Non-Goals

**目标**

- 让绝大多数可合并的 UBT unity 在**不跑逐组证明**的前提下合并，把二次合并从 1 条提升到
  数百条。
- 保住 C11：不得静默退化为普通 UBT Unity 或逐文件索引；性能收益必须实测。
- 保留失效回退：任何 Tier 1 组编译或索引失败，退回其原始 exact 命令，覆盖不缩小。

**非目标**

- 不追求一次达到全工程最优压缩。跨 gen/src、跨模块的合并归 Tier 2，本 change 不承诺交付。
- 不声称条目数下降等于速度提升。
- 不修 clangd 的 context-dependent SymbolID 行为本身。

## Decisions

### D1：Tier 1 的分桶键是「一次 UBT unity 发射序列」

键 = `(module_root, compile_context_key, member_class)`，`member_class ∈ {gen, src}`。

**为什么这三项就够**：

- `compile_context_key` 已经哈希了 `{directory, 完整 argument 向量}`（去掉源路径与
  write-only flag）。宏、include 路径、target、PCH 参数不同的条目不可能同键。
- `module_root` 使用生产的 `portable_module_root`，把 `Inc/<Module>` 与
  `Source/**/<Module>` 归一到同一模块。
- `member_class` 区分 `.gen.cpp` 与普通源。UBT 对一个模块的生成源与普通源分别调用
  `GenerateUnityCPPs`，各自产生一条独立的追加序列、各自有一个余数。

**实测验证**（`falsify-byte-budget-premise-20260929.py`、`explain-short-unities-20260929.py`）：

- 只按 `(module_root, context)` 分桶：61 个多 unity 桶，**61/61** 满足「至多一个短 unity」。
- 按模块**名**分桶（把 Inc 与 Source 合并）：214 个多 unity 桶，其中 **166 个**出现 ≥2 个
  短 unity —— 违反单序列不变量。
- 加入 `member_class` 后：61 个多 unity 桶，**61/61** 重新满足不变量，0 个违反。

这条差异正是设计依据：`member_class` 不是可选优化，是不变量成立的必要条件。

### D2：预算按字节，倍数取自 UBT 自身常量

现行预算是「成员数 ≤ 80 且 unity 数 ≤ 8」。成员数与前端成本不成比例：一桶小 `.gen.cpp`
在约 200 KB 就触顶 80 成员，一桶大源文件在 3 MB 才触顶 8 unity。

改为：`sum(member bytes) <= N * NumIncludedBytesPerUnityCPP`，`NumIncludedBytesPerUnityCPP`
= `384 * 1024`（`Engine/Source/Programs/UnrealBuildTool/Configuration/TargetRules.cs:1085`）。

**为什么这不是语义改动**：`UnityFileBuilder.AddFile`
（`Engine/Source/Programs/UnrealBuildTool/System/Unity.cs:132-137`）在每次追加后检查
`CurrentCollection.VirtualLength > SplitLength` 并收尾。实测 984 个 UBT unity 中，
超预算的 516 个里有 **483 个（94%）**在移除最后一个成员后落回预算以下——正是
「追加到越界即收尾」的签名。把 `SplitLength` 调大得到的分组，就是 UBT 在更大
`NumIncludedBytesPerUnityCPP` 下自己会发射的分组。

默认取 `N = 8`（3,145,728 B）。实测该点 CDB 1197 → 777（−35%），最大块 3,131,792 B /
672 成员 / 8 unity。

### D3：Tier 1 不跑 `compare_graphs`，但仍有硬门禁

Tier 1 的验收不是「无验收」，而是**换一种证据**：

1. 候选必须编译成功（`compile_failure_count == 0`）。
2. 候选必须完成后台索引（`background_compile_success`、`indexing_complete`、
   `missing_main_shards == 0`）。
3. 候选覆盖的成员源文件集合必须与被替换的原始 unity **逐字节相同的并集**（成员清单比较，
   不是图比较）。
4. 任一项失败 → 该组退回原始 exact 命令，记录退化原因。

这三项在现有 10 个证明组里**全部通过**，也就是说 Tier 1 的门禁不是放水后的新宽松标准，
而是保留了实际发现过问题的那几项，去掉了被证明不可满足的那一项。

### D4：被证伪的 union 基线必须修，但归 Tier 2

`clangd_batch_admission._collect` 把引用基线构造成所有原始图的 UNION，
`clangd_index_graph._record_key` 把 `symbol_id` 计入引用身份。在模板主模板/偏特化、
宏生成重载集处，同一 `(uri, start, end, kind)` 在不同 TU 绑定不同 SymbolID，union 因此
要求一个**任何单 TU 都携带不了**的 id 集合。

实测：GameplayAbilities group-0 的 10 个分歧位置 9 个不可满足，group-2 的 2 个全部不可满足，
项目插件模块 group-0 的 151 个中 113 个不可满足。形状如 `(1,1,1,1,1,1) -> union 2`。

Tier 2 若要可用，基线必须改为**可满足**的形式。本 change 不实现 Tier 2 的新基线，只：

- 在 spec 中明确「不可满足的基线 MUST NOT 被报告为合并缺陷」；
- 在代码中让该情形产生**可区分的 verdict**（例如
  `baseline-unsatisfiable-context-dependent-symbol-id`），而不是与真实的引用丢失共用
  `references-removed-or-retargeted`；
- 保留 `references-removed-or-retargeted` 用于**确实**丢失引用的情形（585 条中的 2 条
  单 id 位置，`GameplayEffect.h:1609` 的 `friend class AAbilitySystemDebugHUD;`
  前向声明，仅存在于 8 个原始中的 1 个）。

### D5：不触碰的既有保证

- oversized 原始（单源已超预算，实测 12 个 ≥2× 预算）继续保留，不拆不丢。
- 非 UBT 的 213 条 CDB 记录（exact、shader）原样保留。
- 跨模块 context（实测 12 个 context 跨越 >1 模块名，如 `ControlRig`+`AHEasing`、
  `Chaos`+`ChaosCloth`）不进入 Tier 1。

## Risks / Trade-offs

| 风险 | 处置 |
|---|---|
| Tier 1 纸面降幅（−35%）低于现行规划器纸面（−46%） | 现行 −46% 从未兑现，实际只有 1 条 Batch。差额归 Tier 2，明确记为未完成。 |
| 大块（3 MB / 672 成员）可能触发前端内存或超时 | 预算可调；失败即退回原始，覆盖不缩小。首次落地按 8× 实测后再考虑上调。 |
| 「UBT 自己会这么分」是对编译器行为的推断 | 已用 UBT 源码（`Unity.cs:132-137`、`TargetRules.cs:1085`）+ 984 个 unity 的字节分布双向验证；61/61 桶满足单序列不变量。但**本项目的 build 是否使用非默认 `NumIncludedBytesPerUnityCPP` 或 `bUseAdaptiveUnityBuild`，尚未直接读取该 target 的配置——待验证**。 |
| 加速幅度未知 | 唯一受控 A/B 为 7.78%（1115.23 s → 1028.51 s）。Tier 1 必须自己做冷/热实测，不得复用该数字，也不得用条目数替代。 |
| `cdb_verified_batch.py` 图 dump 循环的 `MemoryError`（项目插件模块实测触发，9 张 200–255 MB JSON 同时持有） | Tier 1 不物化完整图，天然规避；Tier 2 若保留该路径需单独处理。 |

## Open Questions（必须在实现前闭环）

1. 本 target 的 `NumIncludedBytesPerUnityCPP` 与 `bUseAdaptiveUnityBuild` 实际取值——
   需读该 target 的 `BuildConfiguration.xml` / `*.Target.cs`，不能沿用引擎默认。
2. Tier 1 的实测加速：同一真实工程，冷/热缓存分别测，与当前 995 UBT + 1 Batch 的基线对照。
3. 活跃的 `compiler-environment-changed` 激活失败（PATH 中 `...Microsoft VS Code\bin`
   已不存在于磁盘）尚未处置——激活不恢复则任何机制都无法交付。
