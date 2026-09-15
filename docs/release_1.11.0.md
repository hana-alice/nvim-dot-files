# hana-alice/nvim 1.11.0 — 独立 csearch 全量构建

> 日期：2026-09-09
> 类型：Minor（新增独立搜索索引构建命令）
> Git tag：待显式授权；未提交或打 tag。

## 归档工作记录

### 2026-09-09 — Rebuild search without preparing compiler artifacts

**Task**
- Provide a full csearch rebuild without invoking UBT, CDB or GTAGS preparation.

**Implemented**
- `:UEBuildCsearch` refreshes the workspace file enumeration and forces a full csearch reset using the existing writer protection and index publication path.
- `lua/ue/csearch_build.lua` owns this lifecycle; `ue.lua` retains a thin facade. No legacy prepare workflow was moved or rewritten.
- Existing prepare and incremental commands retain their responsibilities. The cheatsheet distinguishes all three entry points.

**Pitfalls / Gotchas**
- Rebuilding from a cached file list can miss files added by a sync; this command rescans before building.
- A successful fixture build does not establish runtime performance on a large UE checkout.

**Validation**
- Final full regression with real LLVM and `NVIM_TEST_REQUIRE_NATIVE=1`: **1621/1621 passed, 0 failed, 0 skipped**, exit 0. `git diff --check` passed.
- Focused csearch 28/28, stability 10/10 and commands 112/112 passed. AST bare-global lint passed for both changed runtime files.
- A real native experiment ran the existing fd scan, cindex reset and csearch query path twice; newly added project source was searchable, removed source stopped matching, and engine source remained searchable.
- Initial full regression: 1619/1621. The run loaded the pre-fix watcher-owner code before its new test was added; the final owner guard passes focused regression. The other failure was the facade size ratchet; moving the new lifecycle into its own module fixed it without raising the threshold.
- Spec consistency: synchronized `ue-code-search` and `keymap-command-regression`; both pass strict validation.

**Follow-ups**
- No commit, push or tag was requested. Large workspace build timing is not measured by the fixture tests.
