# hana-alice/nvim 2.13.0 — 真实工程资格验证修复与可选 Tier 2

> Minor；沿用已授权的脱敏归档、拉取/rebase、提交与推送，不创建 tag。

## 新能力（默认关闭）

- **Tier 2 跨模块合并规划**（`NVIM_UE_TIER2=1`）：以完整模块为单位，可配置字节/闭包预算（`NVIM_UE_TIER2_BYTE_BUDGET`、`NVIM_UE_TIER2_CLOSURE_BUDGET`），规划前排除整模块编译失败的模块，并对跨模块文件级同名定义做保守预筛。
- **严格全局图门禁 `graph_superset`**：候选必须保留每个独立索引基线的全部符号、定义、引用位置和关系；只接受明确批准的差异（include 重复计数、宏定义位置、同位置多出引用、规范声明换到基线已有的声明位置）。
- **exact 源进入 Tier 1**（`NVIM_UE_TIER1_EXACT=1`）：同模块同上下文的单文件编译单元可作为候选，同样受严格图门禁约束。

## 修复（真实工程才暴露）

- 图门禁按 A 行而非 SymbolID 判断规范声明，误拒带前向声明行的符号。
- 冲突预筛把函数头/参数中的 elaborated type 当作类定义，导致所有 UHT `.gen.cpp` 模块两两"冲突"。
- Tier 2 include 门禁封顶 10 s，多模块预处理超时被当作依赖不一致。
- exact 图门禁深拷贝全部基线（真实工程单个 100–270 MB）。

## 实测范围与结论

在真实 Android 构建上：同模块 Tier 1 资格 278 组中 267 组通过（13 组编译失败回退），收集后为 267 个二次批次 + 152 个原 UBT + 214 个 exact，共 633 个原生 TU，14319 个源全覆盖。Tier 2 与 exact 候选在严格门禁下被拒并正确回退，因此两者保持默认关闭。新布局的全工程冷索引耗时尚未测量；本版本不宣称性能恢复。

全量回归（required-native，rebase 到 main 之后）：**4462/4462 通过，0 失败，2 个显式跳过**。此前在 worktree 以 junction 配置目录运行时出现的 15 个 `ue_cdb_prepare_cache` 失败，与未修改基线在相同 junction 配置下逐条相同，直接在仓库目录运行时不复现。原始私有输入与日志不进入公开归档。

## 归档记录

### 2026-11-02 — Guarded whole-module Tier 2 and exact Tier 1 candidates

**Task**
- Implement R32 B's production candidate expansion without relaxing graph preservation or claiming full-engine performance recovery.

**Implemented**
- `tools/build_hot_super_unity_cdb.py`: whole-module Tier 2 packing with independent `NVIM_UE_TIER2_BYTE_BUDGET` (default 3 MiB), `NVIM_UE_TIER2_CLOSURE_BUDGET` (default 8000), optional `NVIM_UE_TIER2_MAX_UNITIES`; conservative token/scope conflict screening from `tools/cdb_tier_merge.py`. Same-context exact C/C++ sources enter ordinary Tier 1, with inferred C kept separate and a `.c` wrapper; strict discovery remains unchanged. Source rewriting preserves option operands.
- `tools/cdb_verified_batch.py`: reuse actual Tier 1 module compile rejections before packing; cache independent module graphs, require global `graph_superset` plus existing compilation/include/member gates, retain Tier 1/exact originals on failure. Exact candidates additionally prove their independent source graphs. Dependency/lookup-bound conclusive graph refusals are reusable; transient failures are not.
- `tools/cdb_background_batch.py` and `lua/ue/index/_publish.lua`: exact qualification/collection, separate UBT/exact accounting, new Tier 2 gates and publication-time graph dependency/directory revalidation. Existing UBT Tier 1 receipts remain reusable. `tests/run.lua` accepts the explicit `--filter X` spelling as well as positional filters.
- Updated `openspec/specs/cpp-semantic-index-coverage/spec.md` with the selected baseline, approved superset exceptions and remaining acceptance boundary.

**Pitfalls / Gotchas**
- Exact main-to-member comparison clears only IsTU; it must not ignore the member's references. Cached graphs bind their content hash; graph comparison indexes reference sites rather than scanning each shard quadratically. File-scope scanning is conservative, not a C++ compatibility certificate.

**Validation**
- Test-first targeted headless runs, sequential and BelowNormal: `index_verified_batch` 127/127 (includes 27 new R32 cases), `index_batch` 539/539, `index_generated_super_unity` 27/27, `index_tier1_cohort` 28/28, `index_graph` 12/12, `index_inventory` 18/18, `index_generation` 46/46, `index_subset_async` 11/11, `cpp_semantic_index` 1/1, `clangd_commands` 23/23, `ue_api` 66/66, `ue_platform_boundary` 20/20, `host_resource_discipline` 13/13, `structure` 85/85, `index_input_directory` 4/4, `index_vfs_aliases` 6/6, `cpp_semantic_client` 70/70. `index_query_profile` first reported one prerequisite skip (clangd absent from PATH); rerun with the existing installed LLVM executable explicitly selected passed 7/7. Every intermediate red/green run is recorded in the R32 B handoff/log.
- ROOT review fix: `graph_superset` judged canonical declarations per A row, so a SymbolID with a forward-declaration row in another shard was rejected after merging kept only the definition row. It now judges per SymbolID (still rejecting declarations outside A's declaration sites); 2 new cases (`graph_forward_row`, `graph_decl_unknown`) red→green. File-only replay on retained R31 calibration arms: user-accepted medium passes (0 violations), user-rejected large10 rejects. Required-native reruns: `index_verified_batch` 129/129, `index_batch_background` 104/104, `index_batch_publication_spec` 115/115.
- ROOT real-build finding: default `NVIM_UE_TIER2_BYTE_BUDGET` 3 MiB excludes 16/291 real modules (largest project module 6.3 MB); 16 MiB excludes 1. Conflict screen recorded elaborated types in function heads/parameters (`class UScriptStruct* F::StaticStruct() {`, `const TArray<struct FRepRecord>&`) as class definitions, so every UHT `.gen.cpp` module pair "conflicted" and real Tier 2 produced no candidate. Fixed: only a `class`/`struct` tag outside any parentheses starts a definition, and the name skips API macros before `final`/`:`; red→green case added. Whole-project screen now flags 63 names (e.g. `FSC_Log`, `TNameAndValue`, matching the R31 large12 compile failures).
- ROOT real-build finding: Tier 2 include gate was capped at `min(timeout, 10)` s; real per-module preprocessing of a 3-module project group took 2.8/4.0 s and the third timed out at the remaining 1.7 s, rejecting the candidate as `tier2-include-resolution-mismatch`. The gate now uses the run timeout (timeouts stay non-conclusive); `include_budget` case red→green; `index_verified_batch_tier2` 12/12, `index_verified_batch` 130/130, `index_batch_background` 104/104.
- Exact-in-Tier1 is now opt-in (`NVIM_UE_TIER1_EXACT=1`, default off): on the real build every exact candidate was rejected by the strict graph gate (main-file-only symbols gain completion fields once included), so planning them by default only spends qualification time. `exact_default_off` case red→green; `index_verified_batch` 131/131, `index_batch_background` 104/104, `index_generation` 46/46, `index_generated_super_unity` 27/27, `index_batch_publication_spec` 115/115.
- Exact-graph gate no longer deep-copies baseline graphs (100-270 MB each on the real build); a 30-file real group stalled 15 min before the fix. Native execution was limited to existing test cases; new R32 cases use unit seams and do not grant native qualification.

**Follow-ups**
- ROOT must perform the full-suite merge gate and real-build qualification/coverage, first/repeat prepare, cold/warm reader and CPU/RSS measurements. Tier 2 stays opt-in; qualification graph/inventory memory and I/O cost, lookup aliases, full-engine compression and the 180-second goal remain unverified. No performance-restoration claim.
