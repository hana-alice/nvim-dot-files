# hana-alice/nvim 2.12.3 — 准备流程、批次复用与搜索历史修复

> 版本：2.12.3
> 仓库：https://github.com/hana-alice/nvim-dot-files
> 日期：2026-10-29
> 类型：Patch；保留真实二次合并，修复准备流程和持久化边界。
> 发布流程：按已有授权脱敏归档、拉取/rebase、提交并推送；tag 待明确请求。

## 1. 本次交付范围

- 减少同一次准备流程中的重复 overlay 读取、工具根扫描和目录解析，保留输入变化检查。
- 保留已验证的完整批次，修复普通混合分组、较大候选和缓存缺失时的发布边界。
- 恢复被终端换行截断的编译器诊断；文件暂时无法替换时保留搜索历史增量并有界重试。
- 记录完整冷索引对照、forced-header 暖加载缺失及未完成的验收范围。

## 2. 验证与未完成事项

当前代码的 required-native 全量回归：**4419/4419 通过、0 失败、2 SKIP，259 specs**。
耗时 1225.2s，Job CPU 1159.4s；Lua 语法与 bare-global 检查通过。
两项 SKIP：未提供私有 GTAGS 原生证明输入；当前宿主具备 PCH 能力，不适用不支持场景。
一个较早的回归运行被输出清点监控中断，没有最终测试结论，成本另行保留。

真实工程保留 14319 个唯一源文件、997 个完整原始 UBT 单元、214 条 exact 与 2119 条 shader 记录。
已验证布局为 260 个二次合并、153 个原始 UBT、214 条 exact，共 627 条 native 命令。
配对空索引运行从 1295.9386s 降至 979.0467s；OS 文件缓存未控制，不能称为严格冷磁盘测量。
相对另一组 639 命令研究结果只改善约 4.2%；**180 秒目标尚未达到**。

一次当前输入收集保留全部记录并在 42.6s 完成；这不代表完整 UEPrepare 已通过。
私有发布的同进程和新进程重复验证曾保持字节与纳秒 mtime，未产生新 qualification。
正常 UEPrepare 首次、同进程、新进程及实际 reader 验收仍待完成；当前活跃编辑器共用
canonical cache，因此没有通过重启、RPC 或共享写入制造验收结果。
forced-header 暖加载缺失和完整暖启动语义仍未修复，不能据此声明全工程性能已恢复。

本次私有 CPU 诊断程序已编译并通过启动检查，但两单元对照因宿主内存余量中止，
尚无有效的分阶段 CPU 结果。安装工具与 UE 构建编译器未替换；失败数据保留在本地。
公开归档不包含真实工程路径、设备标识、私有输入或运行原始日志。

归档后 `structure` **85/85 通过、零失败、零跳过**，语义索引主规格 strict 校验通过。
公开发布继续执行本地提交、引用更新和推送隐私门禁；原始运行证据保留在本地。

## 3. 本次工作归档
### 2026-10-29 — Keep ordinary preparation within its input-evidence budget

**Task**
- Resolve the real input-inventory timeout and ordinary mixed-class scheduling failure found through the normal UEPrepare command.

**Implemented**
- Remove redundant writable descendants and repeated tool-root roles within one input collection; retain physical aliases, all input subtrees and final tool-root identity checks.
- Reuse resolved physical parent paths for ordinary directory entries while still resolving roots, links and unknown entries. Keep the existing 60-second worker timeout and directory/root budgets.
- Validate ordinary scheduling atoms using the current Tier 1 grouping policy; retain the stricter same-class rules for larger upgrades and recipe migrations.
- Keep whole mixed ordinary atoms out of same-class large-parent proposals; re-resolve an inherited duplicate directory before accepting its already-scanned identity.

**Validation**
- The new real-tool regression failed before the repair: repeating identical operands 64 times increased metadata queries from 13 to 328. After deduplication and a real mid-collection directory-change check, required-native `ue_cdb` passed 209/209, zero failed, one skipped.
- The added ordinary scheduling case failed before its fix (21/22); required-native background regressions then passed 104/104, zero failed or skipped. Exact real-project plan replay subsequently returned eight pending groups without running qualification or writing the canonical plan.
- On the same saved actual-context inventory request, the directory-scan candidate finished in 49.3s versus 62.2s for the implementation with deduplication alone. Complete outputs matched: 16438 records, 90396 directories, 23 roots, 5149 artifact identities and 4657 tool identities. Both used statistical profiling and uncontrolled OS file caches; neither is a normal prepare or cold-index acceptance result.
- Full regression after the initial scan and scheduling changes passed 4418/4418, zero failed, two skipped (1320.1s lifecycle, 1274.4s Job CPU).
- Independent review identified two uncovered boundaries. A real alias-first directory deletion reproduces an erroneous successful inventory (22/23); two uncached mixed ordinary atoms reproduce another large-plan failure (21/22). Narrow guards address both; the final required-native full regression passes 4419/4419, zero failed, two skipped across 259 specs (1225.2s lifecycle, 1159.4s Job CPU). Lua syntax and bare-global checks pass. A preceding run was interrupted by the output-inventory monitor and has no terminal test result; its costs remain recorded separately.
- One current saved-request collection completed in 42.6s (42.9s lifecycle, 41.1s Job CPU, 1.32GiB peak Job commit), retaining all 16438 records, 90396 directories, 23 roots, 5149 artifact identities and 4657 tool identities. Eleven of twelve complete output fields equal the earlier scan candidate; the remaining field differs only in one tool-root directory's timestamps. The timestamp change's cause is unproven, so this is neither full output equality nor a matched speedup result.
- Real normal first/same/new-process preparation remains pending: an active editor owns the same canonical cache. No shared preparation, editor restart or RPC was performed to obtain a result.

**Pitfalls / Gotchas**
- The first observed normal preparation failed its input-evidence worker, so it never established a reusable process-local capsule. Generator completion and a finished queue did not establish success; the queue's plan also contained an explicit failure.
- Inventory observations are not atomic filesystem snapshots. This repair does not close the forced-header warm-load semantic gap or the approximately 180-second full cold-index target.

### 2026-10-29 — Reduce repeated overlay reads during Tier 1 reuse

**Task**
- Reduce preparation overhead while preserving qualified secondary batches and current input validation.

**Implemented**
- Share one owned-overlay byte observation within each synchronous candidate-description or input-collection call, then reread it before returning.
- Keep additional overlays, independent calls, strict validation and native qualification outside that read view; preserve receipt keys and artifacts.
- Document the observation boundary in `cpp-semantic-index-coverage` and add drift, deletion, cleanup, memory-bound and transient-ABA regressions.

**Pitfalls / Gotchas**
- Entry/exit equality is not a filesystem snapshot or proof that no intervening modification occurred. This optimization does not authorize frozen activation.

**Validation**
- New read-count regression failed on the previous implementation; all six added real-file, no-subprocess cases pass after the change.
- Four alternating old/new real-owner API passes accepted all 269 batches with identical cache records and 807 unchanged receipt/index/wrapper artifacts. Mean API wall time fell 28.7% and CPU time 27.0%; this measures reuse verification, not complete UEPrepare or cold indexing.
- Initial required-native full regression: 4406/4408 passed, two failed, two skipped. After the workbench and mixed-collection fixes below, the full suite passed 4415/4415. A later run exposed the separate history publication loss repaired below. The latest full suite passes 4419/4419, zero failed, two skipped; the earlier missing-writer incident's cause remains unresolved.

**Follow-ups**
- Full cold indexing near 180 seconds and actual UEPrepare/publication acceptance remain separate unfinished work.

### 2026-10-29 — Preserve compiler messages wrapped by a terminal

**Task**
- Resolve the real workbench regression that retained only `error: use of` from a longer compiler diagnostic.

**Implemented**
- Preserve indentation while collecting terminal output and join Clang's six-space message continuations, stopping at source gutters, caret lines, summaries and new diagnostics.

**Validation**
- Captured the unchanged native workbench test's raw channel arrays and exit output to confirm the split message.
- Added parser regression failed before the fix; build regressions passed 24/24 and unchanged required-native workbench regressions passed 20/20 afterward.

**Follow-ups**
- Latest required-native full regression passes 4419/4419, zero failed, two skipped. The later history publication loss is repaired below; the earlier missing-writer incident remains unexplained.

### 2026-10-29 — Keep qualified batches while larger ordinary groups are prepared

**Task**
- Allow current full-input ordinary groups to replace complete smaller owners without discarding valid batches while qualification is pending.

**Implemented**
- Plan and adopt reducing whole-owner replacements through existing canonical cache and receipt checks; preserve same-class upgrade rules.
- Validate phase proposals before resolving full/current/hot ownership, retaining old owners for partial overlap, stale input or missing eligibility.
- Document the producer/publisher ownership boundary in `cpp-semantic-index-coverage`.

**Validation**
- Corrected publisher fixture fails with the unchanged previous publisher (140/141); current publisher passes 141/141 with native tools required. No production rollback or host emulation was used for the old-source comparison.
- Required-native background regressions passed 103/103, including real class-split qualification, pending-owner retention, mixed-parent adoption and unchanged-repeat behavior. Updated prior expectations to count retained qualified owners and the new phase eligibility metadata explicitly.
- Full regression reached 4413/4415 and exposed inconsistent ordinary eligibility metadata when collecting a mixed Tier 1/strict result. Collection now tags the composed result consistently in both modes; the unchanged required-native residual regressions pass 38/38 afterward.
- Full required-native regression after that correction passes 4415/4415, zero failed, two skipped (1223.8s lifecycle, 1150.3s Job CPU). Source seals remained unchanged throughout the run; real-engine canonical qualification remains separate.

**Follow-ups**
- Canonical qualification and private publication have passed as recorded below; verify normal first/repeat UEPrepare and actual indexing performance separately.

### 2026-10-29 — Retain a valid batch when an advisory cache disappears

**Task**
- Prevent a missing independent catalog cache from shadowing a still-valid root-store batch for the same original inputs.

**Implemented**
- Keep an already revalidated whole owner when an advisory record covers the identical ordered scope; larger parents spanning several owners remain eligible.
- Extend the existing native fixture with separately qualified root and canonical stores, missing-cache and changed-wrapper cases, and read-only reuse checks.

**Validation**
- The new native case fails on the previous implementation with `background-proof-upgrade-selection-mismatch` (21/22); after the three-line guard, required-native background regressions pass 104/104.
- Full regression after this guard reached 4415/4416, with one search-history concurrency failure and two skips; the captured failure and repair are recorded below. Earlier full regression passed 4415/4415 before this additional case and guard.
- Separately, the real-build canonical queue qualified all 192 requested candidates and published 260 secondary batches, 153 original UBT rows and 214 exact rows: 627 native commands. File checks preserve all 14319 unique sources, 997 complete UBT ancestries and 2119 ordered shader compatibility records.
- Same-process and fresh-process private publication repeats performed zero new qualification and preserved product bytes and nanosecond mtimes. The fresh-process check took 41.3s; this is queue/publication validation, not complete UEPrepare or cold indexing.

**Pitfalls / Gotchas**
- The successful candidate count is separate from cost: the main 185-candidate run, publication and same-process repeat consumed 6077.8s lifecycle and 5856.5s Job CPU; seven candidates came from a separately retained earlier attempt. Failures and setup costs remain recorded.
- A private verifier initially compared native-only published commands with a phase that also retains shader compatibility records. The refused run remains retained; a fresh private generation with the corrected projection passed first/same-process validation in 136.9s and separate-process validation in 41.3s, with no qualification workers.

**Follow-ups**
- Current-source private publication and matched cold structural checks passed as recorded below. Complete normal UEPrepare and reader acceptance; full cold near 180 seconds and required warm semantics remain unaccepted.

### 2026-10-29 — Preserve pending history during temporary publication contention

**Task**
- Resolve the full-regression failure where two real Neovim writers saved 238 shared uses instead of 240.

**Implemented**
- Preserve uncommitted uses when atomic replacement returns `EPERM`, `EACCES` or `EBUSY`, and pass that outcome to the existing bounded asynchronous retry. Every retry reacquires the writer lease and merges against current disk contents.
- Add a native Windows case that holds a real file reader, verifies both uses remain queued, closes the reader and checks exactly-once publication without a warning.

**Validation**
- Captured native failure: one output rename returned `EPERM`, then the two-entry pending queue was cleared. The process causing that transient denial is unknown; this does not establish the cause of the earlier missing-writer incident.
- New real-handle regression fails on the previous source (16/17, pending expected two but observed zero). After the fix, required-native `search_` regressions pass 137/137, zero failures or skips (125.6s lifecycle, 112.8s Job CPU), including the original two-writer case.
- Required-native full regression after this repair passes 4417/4417, zero failures, two explicit skips (1202.6s lifecycle, 1134.0s Job CPU).

**Follow-ups**
- Continue normal UEPrepare and reader acceptance; this history repair is not an indexing speed improvement.

### 2026-10-29 — Measure full-build compression against the latest normal selection

**Task**
- Measure actual cold indexing on the current machine without shrinking source coverage or using a degraded baseline.

**Implemented**
- Reconstructed the recorded pre-qualification normal selection from its exact owner IDs and currently validated receipts: 92 secondary batches, 513 raw UBT rows and 214 exact rows (819 native commands). This is a reconstructed control, not an invented historical timing.
- Revalidated current-source private publication and both repeat paths: 260 secondary batches, 153 raw UBT and 214 exact rows (627 native commands), all 14319 unique sources, 997 complete UBT ancestries and 2119 phase shader records.

**Validation**
- Current-source first plus same-process private publication: 117.7s lifecycle / 112.0s Job CPU; fresh-process validation: 34.8s / 32.2s. Both repeats performed zero qualification and preserved delivery bytes and nanosecond mtimes. This is not complete UEPrepare.
- Matched empty-index runs, both j8/Idle with 16GiB process and Job caps: baseline 1295.9386s indexing / 9445.75s Job CPU; candidate 979.0467s / 7014.4375s. Observed reductions are 24.45% wall and 25.74% CPU. Whole native lifecycles were 1298.5253s and 981.2681s.
- Independently decoded all 32637 baseline and 32445 candidate shards. Both contain every required main and all 14319 member own nodes, with no missing sources or HadErrors; whole-owner, exact and shader-order checks remain intact. Structural coverage does not prove all LSP semantics.
- Required-native production regression passes 4417/4417, zero failures and two explicit skips. Qualification, failed setup and file postprocessing costs remain separate from the cold indexing time.

**Pitfalls / Gotchas**
- The experiment verifier initially rejected a valid main immediately after `-std=c++17`. Pinned Clang option/parser source and actual command tokens proved it is a joined option. A separate corrected verifier passed positive and negative file checks; the original refusal, plan, shards and verifier were retained. No expected argument was removed to pass.
- This is one sequential pair with uncontrolled OS file cache and external load. Peak Job commit was 13.42/13.71GiB; minimum host commit headroom was 18.81/20.03GiB. Sampled total host CPU peaked at 88.3%/89.4%; startup admission and Idle priority do not guarantee a global CPU ceiling or GUI responsiveness.
- Against the separate earlier 639-command research run (1022.2383s), 979.0467s is only about 4.2% faster. It still exceeds the 180s target by about 5.4 times; the earlier research run is not substituted for the matched normal baseline.

**Follow-ups**
- Finish real ordinary UEPrepare first/same/new-process and normal configured reader acceptance. Forced-header warm-loading loss, full semantic parity and the approximately 180-second cold target remain open.

### 2026-10-29 — Verify forced-header loss during stock clangd cache reload

**Task**
- Check whether a complete saved shard inventory actually preserves background definitions and references after restart.

**Implemented**
- Recorded the confirmed loader limitation and its acceptance implications in the semantic-index spec and restart investigation. The installed binary and cache implementation remain unchanged.

**Validation**
- Two isolated stock clangd 22.1.5 readers used identical commands, UTF-16, sources and unchanged shard bytes/mtimes. Cold lookup reached a forced-header definition and call reference; warm lookup fell back to the foreground declaration and omitted that header reference, with zero warm background compilations and the same canonical USR.
- Actual combined native lifecycle was 1.5190s and Job CPU 1.703125s. This is a small causal check, not a project indexing-speed measurement.

**Follow-ups**
- Full warm semantic acceptance and a separately qualified remedy remain open; no cache rewrite, compiler replacement or cold-performance recovery is claimed.
