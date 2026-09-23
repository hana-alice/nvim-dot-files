# hana-alice/nvim 1.12.3 — Recover current frozen proofs on later startup

> 日期：2026-09-23
> 类型：Patch；按需恢复阶段，不代表长会话或全引擎性能已验收。
> Git tag：未创建，未获 tag 授权。

### 2026-09-23 — Allow a later startup to recover a still-valid frozen batch

**Task**
- A watch event made failure sticky even when publication metadata and receipts remained valid. Continue the generated-marker investigation without weakening input protection.

**Implemented**
- `lua/ue/index/batch_runtime.lua`: permit a later normal startup to retry `input-changed` after a 30-second monotonic cooldown and confirmed helper completion. Concurrent startup requests share the fresh describe/watch/validate attempt. Other failures remain sticky, and elapsed time alone starts no work.
- Bind frozen process configuration to an activation attempt so late clients cannot claim a newer guard with the same publication stamp. Preserve original commands until full validation succeeds; keep stale results rejected.
- Reuse existing activation and scoped restart paths. No new timer, notification-name exclusion, dependency or admission bypass.
- `tests/cases/index_batch_runtime_spec.lua`: cover cooldown boundaries, concurrent requests, helper exit versus cancellation, duplicate/late completion, validation rejection, profile/generation/environment changes and previous-attempt clients. Synchronize the coverage spec.

**Pitfalls / Gotchas**
- Cancellation only requests termination. Recovery waits for the activation helper's completion callback; a duplicate callback cannot decrement a newer attempt's pending count.
- A publication stamp identifies disk metadata, not the client activation attempt. Reusing only the stamp would allow a late old frozen client to acquire the new guard.
- This version recovers on a subsequent normal startup. It does not proactively promote an already running original client or create a restart loop. Actual input changes may still reject the proof and retain original commands.

**Validation**
- Tests first: **45/49**, four new recovery failures. Final runtime **50/50**, including the added helper-exit regression; full required-native **2126/2126**, final documentation structure **78/78**, zero failures/skips. Lua AST lint, strict coverage-spec validation and independent review passed.
- Native Windows experiment used fresh copies of the complete real publication and the accepted eight-to-one proof. Only the private original-CDB copy's mtime changed; its bytes stayed identical. The real watcher reported `action=3`, `directory=false` and revoked authority.
- Initial activation **14.797 s**; early demand and the following **30.106 s** cooldown started zero helpers. Later demand installed fresh native watches and repeated description/full validation, restoring frozen selection in **13.697 s**. Unchanged ready prepare took **1.488 ms**, with zero new helpers.
- All **1,041** bound-input identities remained equal except the explicitly controlled private mtime; all **3,317** proof-bound file identities remained equal. Historical donor and production artifacts were untouched. The Job completed in **73.891 s**, with sampled owned RSS sum peaking around **1.41 GiB**, no cleanup errors and no remaining owned process. No main clangd client ran in this experiment.
- Live delivery replaced only runtime public exports after checking closed old ownership and six actual helper-exit results. Editor, terminal, source watcher, dirty state and index runtime snapshots were identical across the upgrade. Normal scoped restart replaced original client23 with initialized frozen client24; at **10:59:25Z** the guard was ready with **26 watches**.
- Live unchanged prepare reused actual production options, returned synchronously in **15.088 ms**, and retained client24 and the same guard. All seven production artifacts retained bytes, size and mtime; coverage remains **14,312 native sources**, **2,094 shader records**, **987 retained UBT + 1 secondary batch + 211 exact commands** (1,199 native commands versus the original 1,206).
- At **11:03:10Z**, more than four minutes after scoped restart, the same initialized client24 still used the frozen CDB with a ready guard and 26 watches. This is a bounded observation, not long-session acceptance or an index-completion measurement.
- Spec consistency: synchronized demand-driven recovery and attempt ownership in `cpp-semantic-index-coverage`. Runtime changes do not alter proof collector/policy identities. The controlled native event is a recovery test, not a direct reproduction or attribution of every historical Timestamp event.

**Follow-ups**
- Sustained live editing, legitimate invalidation/recovery and direct cache-junction coverage remain open. Proactive recovery of an already running original client is outside this demand-driven version.
- Expand compression beyond the single accepted eight-wrapper group and measure full-engine cold/warm completion, cache-transition costs, CPU and memory. At **11:03:49Z**, the live existing `-j=12` client had **14.87 GB** RSS and a reported peak of **16.70 GB**; a 1.006-second process sample consumed **46.3%** of the 24-logical-processor host. A separate host counter returned **77%**, including other work. Helper limits do not cap this main indexer; full-engine resource/performance restoration remains unfinished.
- Historical navigation/dirty/csearch dispositions remain open. No cache clearing, coverage reduction or source modification was used to obtain these results.
