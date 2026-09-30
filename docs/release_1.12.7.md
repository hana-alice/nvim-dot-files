# hana-alice/nvim 1.12.7 — Resume frozen activation when documents become clean

> 日期：2026-09-24
> 类型：Patch；文档清洁后的有界自动恢复。
> Git tag：未创建，未获 tag 授权。

### 2026-09-24 — Keep the original reader available while recovery validates

**Task**
- A document-blocked frozen activation previously required another startup request after the document became clean.

**Implemented**
- `lua/ue/index/batch_recovery.lua` combines buffer/client events per canonical CDB, with at most eight scopes, one timer per scope and one automatic validation at a time. It retains the original reader through full validation, respects cooldown and restart debounce, rechecks identities and confirms promotion through an accepted frozen attachment.
- `batch_runtime.lua` retains proof authority and exposes detached scalar status, isolated state notifications and attempt-scoped cancellation of unattached candidates. `batch_descriptor.lua` contains unchanged descriptor/path/cache helpers extracted to stay below the existing 800-line limit. No new dependency or polling loop was added.
- `lua/plugins/ue.lua` routes startup and attachment through the coordinator. Dirty documents still return original commands without helper work; recovery never saves/discards user text, rewrites CDBs or clears caches.
- Protect helper drain across fallback and replacement attempts, stale timer delivery, external attachment during restart backoff and rejected profile/cwd attachments. Test coverage exercises the production state machine.
- Correct the existing concurrent dirty-persistence fixture: all eight child writers now await their own path in the published JSON instead of exiting after 300ms. A real held lease exceeds the old lifetime; the final union assertion remains. Dirty persistence production code is unchanged.

**Validation**
- Final required-native full regression **2193/2193**, zero failures/skips.
- Coordinator **19/19**, activation-state API **7/7**, runtime **77/77**, stability **26/26**, smoke **19/19**, semantic client **33/33** and structure **78/78** passed; Lua AST lint and strict governing-spec validation passed.
- Three coordinator races first reproduced as **13/16**, then passed after fixes; additional replacement-attempt and rejected-attachment cases passed independent review.
- First full run: **2192/2193**, with a missing path in the existing concurrent dirty-persistence test. Its historical retry telemetry was unavailable, so its exact cause is not claimed. A separate held-lease experiment proved the old fixture's premature-exit vulnerability (**25/26**); the corrected fixture passed **26/26** without weakening the eight-writer union check.
- Final isolated real-client experiment: dirty prepare **zero helpers**, with a **0.768ms upper bound** including surrounding bookkeeping (no separately instrumented duration); one external prepare request; natural edit/undo events; cancellation during validation; measured **30.013-second** failure-to-retry interval; full retry; exactly **one** scoped restart and accepted client **1 → 2**, bound to activation attempt 2. Second-clean-to-frozen attachment took **42.361 seconds**, including cooldown; restart-to-attachment took **170.822ms**. Final coordinator state was idle with no timer.
- The original foreground reader remained alive through validation, then actually exited before its replacement started. Exact PID/creation/parent/argv evidence distinguished foreground clangd from its concurrent validation probe; unknown processes still failed the experiment gate.
- Job wall time **60.089 seconds**, total owned CPU **31.328 seconds**, zero owned processes after cleanup, with unchanged 3GiB/process and 6GiB/job limits. Maximum reported individual peak RSS was **1,347,678,208 bytes**; maximum summed sampled RSS was **2,185,629,696 bytes**. All **1050 input bindings and 3318 proof bindings** remained unchanged in worker, finalizer and post-job comparisons. The instrumented editor heartbeat had a **124.186ms** maximum gap (four above 50ms, one above 100ms); this is not a steady-edit latency guarantee.
- Failed private fixture attempts remain recorded: blocked input processing, reload-induced LSP detachment, an overly broad process-count assertion, executable-name spelling and logging from a fast event. Final verification uses natural main-loop events, actual process identities and scheduled tracing; no production guard or resource limit was relaxed.
- Spec consistency: synchronized `cpp-semantic-index-coverage` with bounded automatic recovery and abandoned-attempt demand retry; architecture and knowledge-base pointers updated. The persistence fixture changes no production behavior or additional spec contract. No active OpenSpec changes remained to archive.

**Live delivery**
- Installed the pinned runtime exports and two new modules while preserving module aliases. Updated only future-client prepare/attach callbacks in registered/raw/Lazy configurations; the existing client configuration, source watcher, index state, buffers and views remained unchanged. Fresh OS evidence confirmed retired activation helpers before installation.
- After installation, one dirty scope was already registered and waiting. The separate prime audit stopped before execution on that unexpected precondition; a read-only inspection confirmed the safe waiting state, then an idempotent dirty prepare completed with queued metadata evaluation in **6.644ms**, **zero new helper tasks**, no activation record and no restart. The scope remains subscribed without a timer for a future real clean transition.
- Original client 30 remains attached. The existing document retained its exact contents, changedtick 7, modified flag and 4053 lines; no user text was saved or discarded. The main editor's clean transition was not manufactured; actual automatic handoff was verified in the isolated real-client experiment above.
- Seven published artifacts retained exact SHA, size and mtime. Coverage remains **14,312 source members / 2,094 shader records**, original commands **1,206**, frozen **1,199 = 987 UBT + 1 secondary batch + 211 exact**.

**Follow-ups**
- Long-session editing/recovery remains to be observed. Recovery validates existing proof; saving changed on-disk inputs cannot make stale proof eligible.
- Broader actual secondary compression and whole-engine cold/warm indexing completion, CPU and memory acceptance remain unfinished. This experiment used foreground LSP with background indexing disabled and does not establish full performance restoration.
- Historical navigation/dirty/csearch dispositions, silent in-place reparse-target changes, event floods and network-path coverage remain open.
