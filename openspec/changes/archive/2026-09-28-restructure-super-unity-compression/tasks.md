> **归档说明（2026-09-30）**：随 SDD 轻量化（spec 只规定大方向、记录选型与踩坑）以
> `--skip-specs` 归档保存调查与方向。**下列任务全部未实现**；方向与关键证据已浓缩进
> `openspec/specs/cpp-semantic-index-coverage/spec.md` 的「选型与踩坑」段，后续实现直接以该方向推进，
> 无需重开本 change。本清单仅作为待办参考，不代表任何收益已兑现。

本清单按「结构化保证替代逐组证明」推进。未闭环项一律保留为未勾选，不以纸面数字充当交付。

## 1. 前置闭环（实现前必须完成）

- [ ] 1.1 读取本 target 的实际 `NumIncludedBytesPerUnityCPP` 与 `bUseAdaptiveUnityBuild`
      取值（`*.Target.cs` / `BuildConfiguration.xml`），确认 393,216 是本工程真实预算，
      而非仅引擎默认。取值不同则按实测值重算分桶。
- [ ] 1.2 处置活跃的 `compiler-environment-changed` 激活失败（PATH 中
      `...Microsoft VS Code\bin` 已不在磁盘）。激活不恢复则无法交付任何机制。
- [ ] 1.3 记录当前基线证据：live cache 33,014 shard = 995 `SuperUnity.UBT` + 1
      `SuperUnity.Batch` + 0 `SuperUnity.Generated`；verified CDB 1,197 条
      = 984 UBT + 211 other + 2 Batch，覆盖 14,083 成员源。

## 2. Tier 1：按 UBT 发射序列分组

- [ ] 2.1 在 `tools/build_hot_super_unity_cdb.py` 引入 `member_class`（`gen` / `src`）
      并把分桶键改为 `(module_root, compile_context_key, member_class)`。
- [ ] 2.2 把 `secondary_unity_chunks` 的预算从「成员数 ≤80 且 unity ≤8」改为
      字节预算 `N * NumIncludedBytesPerUnityCPP`，默认 `N = 8`，可配置。
- [ ] 2.3 保留 oversized 原始（单源 ≥ 预算，实测 12 个）不拆不丢；
      跨模块 context（实测 12 个）不进入 Tier 1。
- [ ] 2.4 单元回归：单序列不变量（≤1 个短 unity）在生产分桶键下对 61/61 桶成立。

## 3. Tier 1 验收门禁（替换而非取消）

- [ ] 3.1 Tier 1 组不跑 `compare_graphs`，改为三项硬门禁：编译成功、索引完成
      （`missing_main_shards == 0`）、成员源集合与被替换原始的并集完全一致。
- [ ] 3.2 任一门禁失败 → 退回该组原始 exact 命令，记录退化原因，覆盖不缩小。
- [ ] 3.3 回归覆盖失败回退路径，断言覆盖面与退回前一致。

## 4. Tier 2：区分不可满足基线与真实引用丢失

- [ ] 4.1 在 `tools/clangd_batch_admission.py` 识别「union 要求的 symbol id 集合
      任何单 TU 都不携带」的位置，产生独立 verdict
      `baseline-unsatisfiable-context-dependent-symbol-id`。
- [ ] 4.2 `references-removed-or-retargeted` 仅保留给真实丢失
      （如 `GameplayEffect.h:1609` 的 `friend class AAbilitySystemDebugHUD;`，
      8 个原始中仅 1 个携带）。
- [ ] 4.3 同步 `tests/cases/index_batch_admission_spec.lua`（含 `retarget` 分支）
      与 `tests/cases/index_verified_batch_spec.lua`。
- [ ] 4.4 Tier 2 的可满足基线设计**不在本 change 交付**，明确记为未完成。

## 5. 实测（不得以条目数替代）

- [ ] 5.1 同一真实工程，冷缓存 A/B：现状（995 UBT + 1 Batch） vs Tier 1。
      记录源文件数、UBT unity 数、二次合并数、exact fallback 数、shader 记录数、
      覆盖/缺失、索引完成耗时、CPU/峰值内存。
- [ ] 5.2 热缓存重复 prepare：确认输入不变时不重写产物、不重启 clangd、不全量重索引。
- [ ] 5.3 验证最大块（8× 下 3,131,792 B / 672 成员 / 8 unity）确实能编译并完成索引；
      不能则下调预算并重测，不得以「理论可行」收尾。
- [ ] 5.4 报告边界：唯一受控 A/B 为 1115.23 s → 1028.51 s（7.78%）。Tier 1 的加速
      必须用 5.1 的自有测量表述，禁止复用该数字或用 CDB 降幅代替。

## 6. 收尾

- [ ] 6.1 同步 `openspec/specs/cpp-semantic-index-coverage/spec.md`
      （结构化分组保证、Tier 1 门禁、不可满足基线的报告要求）。
- [ ] 6.2 `docs/changelog.md` Unreleased 追加条目，Validation 写明回归范围与结果、
      spec 一致性处置。
- [ ] 6.3 全量回归 `nvim --headless -l tests/run.lua` 全绿。
- [ ] 6.4 残余未完成显式列出：Tier 2 基线、跨模块/跨 class 合并、
      `clangd_query_profile.py:304` 的 10 s 共享观察预算、
      `cdb_verified_batch.py` 图 dump 的 `MemoryError`、`ue_probes.json` 19 条未处置探针。
