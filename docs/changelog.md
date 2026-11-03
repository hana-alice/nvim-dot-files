# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)
- `v1.9.0` → `docs/release_1.9.0.md` (tag pending explicit confirmation)

- `v1.9.1` → `docs/release_1.9.1.md` (tag pending explicit confirmation)
- `v1.9.2` → `docs/release_1.9.2.md` (tag pending explicit confirmation)
- `v1.9.3` → `docs/release_1.9.3.md` (tag pending explicit confirmation)
- `v1.10.0` → `docs/release_1.10.0.md` (tag pending explicit confirmation)
- `v1.11.0` → `docs/release_1.11.0.md` (tag pending explicit confirmation)
- `v1.11.1` → `docs/release_1.11.1.md` (tag pending explicit confirmation)
- `v1.11.2` → `docs/release_1.11.2.md` (tag pending explicit confirmation)

- `v1.11.3` → `docs/release_1.11.3.md` (tag pending explicit confirmation)

- `v1.12.0` → [docs/release_1.12.0.md](release_1.12.0.md) (incremental scope; tag pending)
- `v1.12.1` → [docs/release_1.12.1.md](release_1.12.1.md) (tag pending)
- `v1.12.2` → [docs/release_1.12.2.md](release_1.12.2.md) (diagnostic stage; tag pending)
- `v1.12.3` → [docs/release_1.12.3.md](release_1.12.3.md) (demand-driven recovery; tag pending)
- `v1.12.4` → [docs/release_1.12.4.md](release_1.12.4.md) (native junction verification; later ancestor-event fallback recorded; tag pending)
- `v1.12.5` → [docs/release_1.12.5.md](release_1.12.5.md) (stable directory writes and complete ancestor watches; tag pending)
- `v1.12.6` → [docs/release_1.12.6.md](release_1.12.6.md) (modified-document preflight and clean demand recovery; tag pending)
- `v1.12.7` → [docs/release_1.12.7.md](release_1.12.7.md) (automatic clean-document recovery; tag pending)
- `v1.12.8` → [docs/release_1.12.8.md](release_1.12.8.md) (padded search query cancellation; tag pending)
- `v1.12.9` → [docs/release_1.12.9.md](release_1.12.9.md) (durable search overflow recovery; tag pending)
- `v1.12.10` → [docs/release_1.12.10.md](release_1.12.10.md) (second qualified SuperUnity batch; tag pending)
- `v1.12.11` → [docs/release_1.12.11.md](release_1.12.11.md) (retain document-blocked original readers; tag pending)

- `v2.0.0` → [docs/release_2.0.0.md](release_2.0.0.md) (CodeDiff default review; Diffview retained; tag pending)
- `v2.1.0` → [docs/release_2.1.0.md](release_2.1.0.md) (daily editing and maintenance diagnostics; tag pending)

- `v2.2.0` → [docs/release_2.2.0.md](release_2.2.0.md) (IDE experience; local validation complete; tag pending)

- `v2.3.0` → [docs/release_2.3.0.md](release_2.3.0.md) (search, reading and window recovery; tag pending)

- `v2.3.1` → [docs/release_2.3.1.md](release_2.3.1.md) (daily file protection and discovery; tag pending)

- `v2.3.2` → [docs/release_2.3.2.md](release_2.3.2.md) (navigation and editing entry fixes; tag pending)

- `v2.4.0` → [docs/release_2.4.0.md](release_2.4.0.md) (memory document find and editor reuse; tag pending)

- `v2.5.0` → [docs/release_2.5.0.md](release_2.5.0.md) (document locations and copy actions; tag pending)

- `v2.6.0` → [docs/release_2.6.0.md](release_2.6.0.md) (development workbench and run-owned evidence; tag pending)

- `v2.7.0` → [docs/release_2.7.0.md](release_2.7.0.md) (named investigations and interruption continuity; tag pending)

- `v2.8.0` → [docs/release_2.8.0.md](release_2.8.0.md) (staged index delivery, honest failure reporting and layout roles; tag pending)

- `v2.9.0` → [docs/release_2.9.0.md](release_2.9.0.md) (Tier 1 SuperUnity production delivery; full regression 4079/4079, 2 skips; tag pending)

- `v2.10.0` → [docs/release_2.10.0.md](release_2.10.0.md) (Tier 1 gen/src merge, context-migration shard invalidation, opt-in Tier 2, cost ceilings; tag pending)

- `v2.11.0` → [docs/release_2.11.0.md](release_2.11.0.md) (module-priority phase barrier fix, priority refresh after activation, phase probes; full regression 4381/4381, 2 skips; tag pending)

- `v2.12.0` → [docs/release_2.12.0.md](release_2.12.0.md) (clangd memory reclaim after background index, disk preambles with per-session TEMP, headless CI fixes; full regression 4396/4396, 2 skips; tag pending)

- `v2.12.1` → [docs/release_2.12.1.md](release_2.12.1.md) (clangd reclaim quiet-window, progress timer and prepare-owner guards; full regression 4400/4400, 2 skips; tag pending)

- `v2.12.2` → [docs/release_2.12.2.md](release_2.12.2.md) (shared Scratch, single-Escape picker cancellation and bounded workspace diagnostics; full regression 4402/4402, 2 skips; tag pending)

- `v2.12.3` → [docs/release_2.12.3.md](release_2.12.3.md) (preparation and history repairs; cold180 and complete warm semantics pending; tag pending)

- `v2.12.4` → [docs/release_2.12.4.md](release_2.12.4.md) (large-CDB digest memory repair; full regression 4419/4419, 2 skips; tag pending)

- `v2.12.5` → [docs/release_2.12.5.md](release_2.12.5.md) (absent-cache preparation repair; full regression 4421/4421, 2 skips; tag pending)

## Unreleased

### 2026-10-26 — Use double brackets for review hunk navigation

**Task**
- Make previous/next hunk navigation in `<leader>gg` easier to type.

**Implemented**
- `lua/plugins/codediff.lua`: set CodeDiff view `prev_hunk` to `[[` and `next_hunk` to `]]`.
- Update the interactive cheatsheet, Markdown cheatsheet and user guide to match.

**Validation**
- Required filters all passed: `git_review` **77/77**, `review_editor` **9/9**, `keymaps` **85/85**,
  `cheatsheet` **223/223**, `workarounds` **48/48**, `smoke` **19/19**, `structure` **85/85**
  (**546/546**, zero failures/skips). Child logs were directed to writable temporary paths.
- Native CodeDiff on a temporary Git repository with hunks at lines 3 and 30: actual `]]` input
  moved 1 → 3 → 30, and `[[` returned to 3; effective mappings reported Next/Previous hunk.
- `git diff --check` passed.

**Follow-ups**
- The earlier full-regression failures remain deferred as recorded in the synchronization entry below.

### 2026-10-26 — Sync main while preserving uncommitted workspace fixes

**Task**
- Pull with rebase and retain the existing local ordinary C++ workspace changes.

**Implemented**
- `git pull --rebase` fast-forwarded `2f07c8a` to `6a4e8a9`; no local commits required replay.
- Restored tracked and untracked work from stash `3e22327`; resolved three conflicts in
  `lua/ue.lua`, this log and `docs/architecture/overview.md`.
- `ue.clangd_cmd` retains upstream disk preambles and the local workspace policy delegate;
  architecture documentation retains the new upstream subsystems and local ownership boundary.
- Retained the two local log entries without duplicating upstream entries already archived in releases.

**Pitfalls / Gotchas**
- The stash is retained as a recovery copy; all local changes remain uncommitted.

**Validation**
- `nvim --headless -l tests/run.lua`: **4217/4392 passed, 175 failed, 14 skipped**, exit 1.
  The first attempt was interrupted during the execution-environment transition; these counts are from
  the completed rerun in the restricted environment. Full output: `%TEMP%/nvim-pull-rebase-20261026.log`.
- Failures include inaccessible user/plugin/log paths, Windows `ENAMETOOLONG`, and native compiler
  version gates; installed clangd reports **22.1.8**, while qualified paths require **22.1.5**.
  Other assertions, including csearch delta `add` versus `reset` and work-context storage, remain
  unclassified; there is no clean-host baseline proving that every failure is environmental.
- Within that same full run, the clangd command/workspace, semantic-client, navigation-architecture
  and independent C++ call-site groups passed **87/87**.
- `git diff --check` passed; no unmerged entries; `HEAD...origin/main` is **0/0**. All 18 original
  modified/untracked paths are retained, and the index is unstaged as it was before synchronization.

**Follow-ups**
- The 175 regression failures are explicitly deferred in this Git synchronization task. Restoring
  host access/toolchain prerequisites and investigating the remaining assertions are still required
  before claiming a green regression suite; no guards were weakened to manufacture a pass.
- Historical `semantic-sidecar-unavailable` probe evidence is deferred: this task only synchronizes
  Git and does not provide a current UE project or same-build performance measurement.

### 2026-10-03 — Pull/rebase while preserving ordinary C++ workspace fixes

**Task**

按用户要求同步远端，并保留本机未提交的非 UE workspace 修复；远端近期已重构导航模块、
二次批次运行时与规格文档，不能直接把旧模块内容覆盖回去。

**Implemented**

- 同步前保存原 HEAD 与包含 untracked 文件的 stash，恢复引用仅放在 `refs/private-backup/`；
  `pull --rebase` 从 `2566830` 快进到 `2f07c8a`，本机没有需要重写的独有提交。
- 解决恢复 stash 时的 8 个冲突。ownership / toolchain gate 迁入只读 `semantic_environment`，
  普通 C++ 的 LSP-only 策略迁入 `compat_navigation`，公共 provider 只转发路由选项；
  `semantic_client_runtime` 保持远端队列/进程 owner，不重新加入旧环境发现实现。
- 保留远端 source exact-command clangd、header libclang 与 SuperUnity/batch-runtime 接线，
  以及本地普通 CMake CDB 发现和项目 `.clangd` 策略。普通 C++ 不调用 UE exact-command preparation，
  空结果、缺少 LSP 和打开失败均不进入文本 cache/csearch/GTAGS。
- 将原 workspace isolation 方向合入精简后的 `cpp-contextual-definition-navigation` 主规格，
  不恢复旧的逐字段规格；同步架构文档与项目速查。所有本地修改仍未提交，未 push。

**Pitfalls / Gotchas**

- 远端把旧 fallback/runtime 的职责拆到了新 owner，解决文本冲突不等于正确迁移行为。
- 首次纯远端回归时 CodeDiff 尚未安装；测试启动后 Lazy 自动安装冻结 lockfile 中的 CodeDiff，
  最终回归已执行其原生用例，不能直接把两轮总数视为相同覆盖范围。

**Validation**

- 同步后、恢复本地修改前的基线：2280/2290，10 failed、16 skipped。
- 设置 `NVIM_TEST_REQUIRE_NATIVE=1` 后的最终全量：2335/2351，16 failed、1 skipped；
  13 个失败来自现有 clangd/libclang 22.1.8 与新版本要求的 22.1.5 不匹配，
  3 个来自 Windows 创建 symlink 的权限不足；另一个 host symlink 用例明确 skip。
  这些分别对应基线中的失败或跳过，未发现迁移导致的新逻辑失败。
- 定向：`cpp_semantic_client` 34/34、`ue_goto_behavior_spec` 9/9、
  `ue_goto_behavior_architecture` 7/7、`utils` 51/51、`ue_api` 66/66、`structure` 78/78。
- 真实普通项目 ownership 为非 UE，clangd 使用 `build/debug` 的 CDB 且保留项目配置；
  隔离的原生 clangd + 继承 CMake preset fixture 中，实际 `gd` 从 source 调用跳到 header 声明，
  即使 UE preparation seam 拒绝调用也成功。
- `git diff --check` 通过，index 无 unmerged entry，`HEAD...origin/main` 为 0/0；
  原始 stash 与私有恢复引用保留。`stylua` / `openspec` executable 本机仍未安装。

**Follow-ups**

- 本轮只同步和迁移已有修复，不更换系统 LLVM 或调整 Windows 权限，也不关闭原生验收门禁。
  待提供受支持的 LLVM 22.1.5 与 symlink 能力后重跑全量及实际 UE SuperUnity 性能验收；
  当前不能宣称原生全量全绿或 SuperUnity 性能已验收。

### 2026-09-13 — Restore ordinary C++ workspace isolation

**Task**

修复非 UE C/C++ 工程被错误识别为 UE semantic workspace，导致 `gd` 启动 UE sidecar、记录
`semantic-sidecar-unavailable` probe，且普通 CMake build tree 中的 compilation database 未被 clangd 使用的问题。

**Implemented**

- 用当前 buffer 的 canonical path 与已解析 UE engine/project roots 建立显式 ownership 边界；只有根内
  C/C++ buffer 进入 controlled-CDB / semantic-sidecar，普通 C/C++ 直接请求附着 language server 的
  definition，且不读取文本键缓存、不降级到 csearch/GTAGS。
- 新增有界的普通 clangd workspace 策略：支持 workspace 根、继承的 CMake configure preset、常规
  build 目录及最多 64 个直接 build child，不递归扫描 workspace/vendor tree；普通项目保留 `.clangd`
  与 clang-tidy 策略，UE 项目原有参数及 controlled CDB 选择不变。
- 同步 `cpp-contextual-definition-navigation` 主规格、symbol-resolution architecture、architecture overview
  与项目速查，并补齐 ownership、CMake CDB、普通 C++ LSP-only 和 UE 不回归测试。

**Pitfalls / Gotchas**

- 当前 cwd/recent project 能解析 UE context 不代表外部 buffer 属于该 context；ownership 必须再验证
  buffer path 位于 engine/project root 内。
- clangd 默认不会向 source root 的子目录寻找 `compile_commands.json`；`RunAwayAndUseMetal` 的数据库位于
  `build/debug`。发现逻辑必须有界，不能为便利递归捡到 vcpkg/vendor 的数据库。
- 首次全量回归同时暴露 `ue.lua` 新增 17 行违反单调下降门禁，以及一次既有 Windows 原子 rename
  `EPERM`；策略移入新模块后前者消除，后者在完整复跑中未复现。

**Validation**

- 定向回归：`cpp_semantic_context` 11/11、`cpp_semantic_client` 17/17、`cpp_semantic_sidecar` 15/15、
  `ue_goto_behavior` 9/9、`utils` 51/51、`ue_api` 64/64、`smoke` 19/19、
  `ue_platform_boundary` 9/9、`commands` 106/106、`stability` 10/10、`structure` 71/71。
- 全量 `nvim --headless -l tests/run.lua`：1330/1330；`git diff --check`：通过。
- `nvim --headless -l scripts/nvim_core_health.lua --json`：deterministic audit overall PASS；startup、
  editor、C/C++/HLSL syntax、rg/csearch、clangd 22.1.8、CDB 与 host-target plans 全部通过。
- 实际打开 `D:/project/RunAwayAndUseMetal/framework/platform/windows/window.cpp`：root 为项目根，
  clangd argv 含 `--compile-commands-dir=D:/project/RunAwayAndUseMetal/build/debug`，ownership 为非 UE；
  `textDocument/definition` 将 `updateSurface` 解析到 `framework/platform/common/window.h:7`，probe 文件未改写。
- `openspec validate --all` 与 `stylua` 未运行：本机均未安装对应 executable；主规格由 `structure` 的
  spec 引用完整性检查覆盖，全部变更 Lua 已由上述 headless/全量回归加载。

**Follow-ups**

- 无。

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
- No full suite, commit/push, standalone native experiments, real-engine prepare, or user-process interaction in this worktree task. Native execution was limited to existing test cases; new R32 cases use unit seams and do not grant native qualification.

**Follow-ups**
- ROOT must perform the full-suite merge gate and real-build qualification/coverage, first/repeat prepare, cold/warm reader and CPU/RSS measurements. Tier 2 stays opt-in; qualification graph/inventory memory and I/O cost, lookup aliases, full-engine compression and the 180-second goal remain unverified. No performance-restoration claim.
