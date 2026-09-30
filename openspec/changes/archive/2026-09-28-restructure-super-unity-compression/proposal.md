## Why

SuperUnity 的二次合并当前**实际交付量为零**。实测证据：

- 活跃索引缓存 `background-cdb/verified/.cache/clangd/index` 共 33,014 个 shard，其中
  `SuperUnity.UBT` 995 个，`SuperUnity.Batch` **仅 1 个**。
- 现行机制靠**事后逐组语义证明**（`_index` 每个原始 TU 单独编译 → `_candidate_index`
  编译候选 → `compare_graphs`）。实测 `proof-dh_3vwmh`：8 个原始 UBT，7 轮证明、
  579.9 秒，最终只接受 2 个原始 UBT 合成 1 条记录，其余 6 个退回 exact。

更关键的是，**门禁本身要求了一个任何单个 TU 都达不到的目标**，因此它拒绝的不是合并缺陷：

- 10 个证明组全部 `compile_failure_count=0`、`background_compile_success=True`、
  `indexing_complete=True`、`missing_main_shards=0`；`file-coverage-changed` 与
  `symbol-identities-changed` **从未触发**（独立脚本复核：完整组 `missing 0 / extra 0`）。
- 唯一触发的是 `references-removed-or-retargeted`：7 组共 585 条 removed ref，
  **0 条落在该组自己拥有的成员源文件里**（582 条 `.h`、3 条 `.inl`，全是共享头）。
- 585 条里 **583 条**所在的 `(uri, start, end, kind)` 位置**原始图之间本来就互不一致**
  （同一处有多个 symbol id）。
- 更强的结论：在这些分歧位置上，**没有任何单个 TU（候选或原始）能同时携带 union 要求的
  全部 id**。GameplayAbilities group-0 的 10 个分歧位置里 9 个、group-2 的 2 个里 2 个、
  项目插件模块 group-0 的 151 个里 113 个如此。典型形状 `(1,1,1,1,1,1) -> union 2`：每个贡献原始
  只带 1 个 id，union 却要 2 个。**拿一个原始 TU 去对它自己所在组的 union 回放，同样会被拒。**
- 碰撞 id 始终是**同一个 (name, scope, kind)**：GameplayAbilities 全部是
  `TMulticastDelegate`（`DelegateSignatureImpl.inl` 主模板 :625 与偏特化 :637）；
  项目插件模块是 `operator!` 等宏生成重载集（最多 92 个 id）。
- 规模对照：每张图 60.4 万–71.4 万条引用，被否决的是其中约 10 条
  （GameplayAbilities 上限 3.26e-06 ~ 1.57e-05，项目插件模块 7.71e-04）。

结论：`_collect` 把基线构造成**所有原始图的 UNION**、且 `_record_key` 把 `symbol_id`
计入引用身份，这个基线在模板主模板/偏特化、宏生成重载集这类 context-dependent SymbolID
面前**结构性不可满足**。继续逐组磨证明不可能到达工程规模。

本 change 按用户决策（选项 B）**更换压缩机制**：兼容性由**分组规则结构性保证**，
不再依赖事后逐组证明。

## What Changes

- 新增 **Tier 1 结构性合并规则**：只合并属于**同一次 UBT unity 发射序列**的 UBT unity，
  即 `(module_root, compile_context_key, member_class)` 三元组相同；按**字节预算**打包，
  预算取 UBT 自身 `NumIncludedBytesPerUnityCPP` 的整数倍，而非现行的成员数上限。
- Tier 1 **不需要**逐组 `compare_graphs` 语义证明，理由是编译器自身的分组语义：UBT 在
  `UnityFileBuilder.AddFile` 中按排序顺序追加、一旦累计字节越过预算就收尾
  （`Unity.cs:132-137`，预算 `TargetRules.cs:1085` = `384 * 1024`）。把预算调大得到的
  分组，就是 UBT 在更大 `NumIncludedBytesPerUnityCPP` 下会自己发射的分组——这是**配置点，
  不是语义改动**。
- 保留并降级现行证明机制为 **Tier 2**：跨 gen/src 类、或同 context 跨模块的合并仍需证明。
- 修复 `compare_graphs` 的引用基线：现行 union 基线已被证明**不可满足**，Tier 2 必须改用
  可满足的基线，否则 Tier 2 同样无法交付。
- 所有分层都保留：原始 exact 命令可回退、覆盖不缩小、oversized 原始不丢弃。

## Capabilities

### New Capabilities

无。

### Modified Capabilities

- `cpp-semantic-index-coverage`：
  - `Secondary batches SHALL preserve independently proven compiler semantics`
    需要增加 Tier 1 的结构性豁免条款，并明确其证据形态（编译器分组语义 + 编译/索引/覆盖检查），
    而不是取消证明要求。
  - `Compatible Unity groups are packed into a larger SuperUnity` 的预算语义由
    「原始 TU 数 + 成员源文件数」扩展为「UBT 字节预算倍数」。
  - 需要新增场景：当引用基线在 context-dependent SymbolID 下不可满足时，门禁 MUST NOT
    把它报告为合并缺陷。

## Impact

- `tools/build_hot_super_unity_cdb.py`：`secondary_unity_chunks` 的分桶键与预算。
- `tools/cdb_verified_batch.py`：Tier 1 路径绕过 `_index`/`_candidate_index`/`_admit`；
  Tier 2 保留现行路径。
- `tools/clangd_batch_admission.py`：引用基线构造。
- `tests/cases/index_batch_admission_spec.lua`、`tests/cases/index_verified_batch_spec.lua`
  需与策略同步。

### 实测规模（同一 build，`verified/compile_commands.json`，1197 条）

| 方案 | 产出 TU | CDB 条目 | 降幅 | 最大块 |
|---|---|---|---|---|
| 今天实际交付 | — | 1197 | 0%（1 个 Batch shard） | — |
| 现行规划器（纸面，成员≤80、unity≤8） | 437 | 650 | −46% | 8,575,915 B / 229 成员 |
| Tier 1，预算 4× | 649 | 862 | −28% | 2,578,433 B / 511 成员 |
| **Tier 1，预算 8×** | **564** | **777** | **−35%** | 3,131,792 B / 672 成员 / 8 unity |
| Tier 1，预算 16× | 532 | 745 | −38% | 6,280,246 B / 1170 成员 |

Tier 1 纸面降幅低于现行规划器（−35% vs −46%），差额来自现行规划器允许跨 gen/src 合并——
那部分归 Tier 2，需要证明。**但现行规划器的 −46% 从未兑现，实际只有 1 条 Batch。**

### 不得越界的报告边界

条目数下降 **不等于** 速度提升。本仓唯一一次受控冷启动 A/B 实测为
1115.23 s → 1028.51 s，即 **7.78%** 墙钟收益
（`docs/cpp-index-restart-investigation.md`）。Tier 1 的加速必须用**同一真实工程的独立
冷/热实测**报告，不得用条目数或 CDB 分母替代。
