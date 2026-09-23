# hana-alice/nvim 1.12.2 — Retain the event that revokes frozen inputs

> 日期：2026-09-23
> 类型：Patch；本阶段交付持续失效诊断，不代表持续冻结启用已修复。
> Git tag：未创建，未获 tag 授权。

### 2026-09-23 — Keep the first frozen-input invalidation observable

**Task**
- Identify the later live `input-changed` without losing its triggering event when a temporary trace ends or fills.

**Implemented**
- `lua/ue/index/batch_guard.lua`: retain one bounded first native event (root, filename/error, action and flags), expose independent status copies and mark truncation. Later callbacks cannot overwrite it.
- `lua/ue/index/batch_runtime.lua`: write that event once through the existing warning logger during invalidation; logging failure cannot suppress protective fallback.
- Replace the need for temporary event-history tracing with one retained invalidation record. No ordinary callback history, new dependency or notification-filter relaxation.
- Synchronize the coverage spec and record the triggering event and its limits in the [index investigation](cpp-index-restart-investigation.md).

**Pitfalls / Gotchas**
- The new live record captured a generated `Inc/CoreUObject/Timestamp` file modification (`action=3`, `directory=false`) during activation validation. Guard status and the ordinary warning log agree; the observed file mtime matches the event.
- UBT's `ExternalExecution.UpdateTimestamps` writes header-path lists after both UHT execution paths, including when generated code is already up to date. Its timestamp is not proof that generated C++ changed. This source evidence does not identify the process that wrote the observed file.
- The marker is absent from this receipt's dependencies/assets, and its containing directory's recorded name/type/link inventory still matches. One subsequent production validation accepted the actual publication and receipts. This does not authorize ignoring arbitrary files named `Timestamp`, directory events, security changes or concurrent input mutations.
- The live guard invalidated before activation completed and original client22 initialized. At the final 10:32:46Z check, normal current/hot activity had continued and original client23 was initialized; the same first-event evidence remained intact. That later restart is not assigned a cause here. Sustained frozen activation is still unfinished, and earlier unrecorded invalidations remain unattributed.

**Validation**
- Guard **18/18**, runtime **44/44**, full required-native regression **2120/2120**, zero failures/skips. Coverage includes late callbacks, mutation isolation, malformed/oversized fields and logger failure.
- Lua AST lint, strict coverage-spec validation and whitespace checks passed; independent review found no blocking issue in the watch-callback path.
- Final documentation structure regression **78/78**, zero failures/skips.
- Live runtime/guard exports upgraded with editor, terminal, source-watcher and dirty-file state preserved. The first triggering event persisted in both guard status and the existing warning log without a temporary tracing deadline.
- Single production `--validate` after the marker event: **9.847 s**, exit 0, `publication-and-receipts-current`. All 20 bound-input identities and 3,318 unique proof-bound file identities remained unchanged before/after execution and after owned-process cleanup. No requalification, CDB publication or live restart occurred during this validation.
- The validation Job completed in **16.782 s**, left no owned processes and had no cleanup errors. Sampled owned RSS sum peaked at **1.42 GB**, highest reported single-process peak RSS **1.35 GB**; these are validation-helper observations, not full-engine indexing measurements.
- Spec consistency: synchronized bounded first-event evidence for watch-callback invalidations in `cpp-semantic-index-coverage`. Readiness failures without a watch callback do not promise fabricated event details. Collector/policy identities and admission rules are unchanged.

**Follow-ups**
- Implement safe revalidation/recovery for irrelevant generated-metadata updates, then verify sustained frozen activation and longer editing sessions. Preserve immediate revocation and real input-change protection; do not add a basename exclusion.
- Expand compression beyond the accepted eight-wrapper-to-one group; full-engine cold/warm completion, cache transitions, CPU and memory acceptance remain open.
- Historical navigation/dirty/csearch dispositions and direct cache-junction regression remain open. This diagnostic stage does not close the overall SuperUnity performance task.
