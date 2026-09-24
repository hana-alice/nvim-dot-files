# hana-alice/nvim 1.12.8 — Keep pasted searches alive across whitespace normalization

> 日期：2026-09-24
> 类型：Patch；修复搜索输入首尾空白引起的错误取消。
> Git tag：未创建，未获 tag 授权。

### 2026-09-24 — Match cancellation identity to the actual finder query

**Task**
- An existing indexed symbol returned six matches through the backend but zero in the live picker. A forced finder refresh restored all six without rebuilding the index.

**Implemented**
- `lua/ue.lua` reuses the existing trim function in three cancellation checks: watchdog, result drain and final delivery. Snacks trims the finder query; the checks previously compared it with raw input and treated surrounding whitespace as a different query.
- Removing that whitespace did not recover the cancelled search because Snacks deduplicates unchanged normalized queries. Both initial padded input and subsequent removal now retain results; a genuinely changed query still cancels the old stream.
- `tests/cases/grep_query_lifecycle_spec.lua` exercises the production finder with a controlled asynchronous backend. No dependency, additional abstraction, index rebuild or CDB change was introduced.

**Pitfalls / Gotchas**
- The live clipboard contained the reported token plus one trailing ASCII space. The original keystroke sequence was not recorded; its exact historical order is not claimed. The matching failure sequence was reproduced independently with real Snacks and the existing real backend.
- Index age alone did not explain this case: the existing index already returned all six matches. Separate process-exit/pipe-order experiments did not reproduce result loss; that hypothesis is not reported as this defect's cause.

**Validation**
- Required-native full regression **2199/2199**, zero failures/skips. Query lifecycle **1/6 before**, **6/6 after**; grep cache **34/34** passed. Lua AST lint passed for both changed Lua files; strict `ue-code-search` spec validation passed.
- Real Snacks plus real csearch: both leading and trailing padding produced **0 → 0 → 6** for padded input, padding removal and forced refresh before the fix. After the fix, both sequences returned **6 → 6 → 6**.
- Installed only the corrected `cached_grep` function into the current editor, retaining its original six captured dependencies. The installation audit confirmed unchanged other exports, module aliases, buffers, windows and live client identity/configuration.
- In the current editor, padded input returned **6** and removing the padding retained **6**, without forced refresh. Temporary diagnostic autocmds were removed and tracing disabled after preserving private evidence.
- Spec consistency: synchronized `ue-code-search` with normalized cancellation identity. No architecture or subsystem boundary changed; no additional spec impact.
- Documentation structure regression **78/78** and `git diff --check` passed after archiving this entry.

**Follow-ups**
- Long-session observation remains open. This fixes the reproducible whitespace cancellation defect; it does not establish the cause of every historical zero-result report or clear historical csearch probe failures.
- The earlier secondary-compression, whole-engine cold/warm indexing time, CPU/memory acceptance and broader recovery/watch coverage remain unfinished. This search-only change supplies no new performance-restoration claim.
