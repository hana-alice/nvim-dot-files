# hana-alice/nvim 1.12.6 — Check unsaved documents before frozen activation

> 日期：2026-09-23
> 类型：Patch；未保存文档的启动前判断与清洁后的按需恢复。
> Git tag：未创建，未获 tag 授权。

### 2026-09-23 — Avoid activating an index that open edits immediately invalidate

**Task**
- An already-modified document previously allowed full validation and frozen client startup before attachment immediately revoked it. Document-specific failures also remained sticky after the document became clean.

**Implemented**
- `lua/ue/index/batch_runtime.lua`: inspect loaded document metadata before metadata/generation work or helper startup, then recheck description, watch installation, verification, readiness, command selection, process configuration and attachment boundaries.
- Scope checks include the requested document, actual same-CDB clangd attachments, and configured filetypes within the engine/project roots. Foreign and scratch buffers do not become blockers merely because project selection is pinned. Existing attachments remain protected when their filetype changes.
- Permit clean demand to retry `live-document-modified` and `live-document-changed` using the existing 30-second cooldown, completed-helper checks, new attempt identity and complete watch-before-validation path. A clean buffer never substitutes for unchanged disk inputs; proof failures remain sticky.
- Ignore late callbacks from cancelled description/probe work so they cannot overwrite a retryable document failure. Keep late-client retirement and immediate authority revocation.
- `batch_documents.lua` owns only loaded-buffer selection; `batch_runtime.lua` retains CDB ownership and activation state. This extraction keeps the runtime below the unchanged 800-line gate. Architecture and knowledge-base pointers are synchronized.
- `tests/cases/index_batch_runtime_spec.lua`: add fourteen actual-buffer cases covering scope, asynchronous boundaries, cancellation, cooldown, full revalidation, proof rejection and late clients. Reuse the existing fixture and state machine; no dependencies, background polling, source writes or subsystem-boundary changes.

**Validation**
- Final required-native full regression **2167/2167**, zero failures/skips; runtime **77/77**, stability **26/26**, Lua AST lint and strict governing-spec validation passed. The first full run had one 814-line runtime failure; the new helper was extracted and the final runtime has 797 lines, within the unchanged limit.
- New document cases: 10 failures reproduced before implementation, then 11/11 passed; added late-client coverage, reproduced two late-callback failures and finished at **14/14**. Independent read-only review confirmed the race fix.
- Final-source real pinned-publication fixture: modified preflight **0.617 ms / zero helpers**; clean initial activation **15.730 seconds**; real cooldown **30.108 seconds** without automatic work; clean recovery **14.913 seconds** with a new attempt and full validation; unchanged repeat **1.019 ms / zero new helpers**. Both successful activations had **62 logical watches**.
- All **1046 input bindings and 3318 proof bindings**, including both final Lua modules, matched in worker, finalizer and post-job comparisons. Only the isolated editor's buffer memory was edited and reloaded; on-disk source and immutable proof were unchanged. No main clangd was started in this experiment.
- The native job completed in **79.885 seconds**, with zero owned processes after cleanup, within 3 GiB/process and 6 GiB/job limits. Maximum sampled summed owned RSS was about **1.42 GiB**. These are validation-process measurements, not main-clangd indexing performance.
- Earlier experiment attempts remain recorded as failures: one private fixture path-selection error, and one correctly rejected source-binding mismatch during concurrent implementation. The final experiment reran against stable source; identity checks were not relaxed.
- Spec consistency: synchronized `cpp-semantic-index-coverage` with relevant-document scope, race checks and clean demand recovery. No active OpenSpec changes remained to archive.

**Live delivery**
- Installed the reviewed runtime and stateless document module only after confirming retired activation ownership and completed helpers. Existing module aliases, source watcher, clients, index state, windows and dirty state were preserved.
- A normal production `prepare` against the already-modified attached document returned `live-document-modified` in **4.984 ms**, with **zero new helper tasks**, no activation record and no client restart. Original client30 remained available. The document's contents, changedtick, modified flag and file format were unchanged; no user text was saved or discarded.
- The first private check stopped before calling `prepare` because recursively hashing historical task results exceeded its audit byte budget. The final check instead compared bounded task IDs, task/handle identities and metadata; no production gate or resource limit was relaxed.
- Seven production artifacts retained exact SHA, size and mtime. Coverage remains **14,312 source members / 2,094 shader records**, original native commands **1,206**, frozen **1,199 = 987 UBT + 1 secondary batch + 211 exact**. This stage does not change compression scale or establish whole-engine performance recovery.

**Follow-ups**
- Automatic promotion after documents become clean, without waiting for a new startup request, remains open; this stage intentionally implements demand-driven recovery.
- Long-session editing/recovery, broader actual secondary compression and controlled whole-engine cold/warm completion, CPU and memory acceptance remain unfinished. The existing eight-wrapper group is not full performance restoration.
- Historical navigation/dirty/csearch dispositions, silent in-place reparse-target changes, event floods and network-path coverage remain open. These failures were retained during the session-start probe review.
