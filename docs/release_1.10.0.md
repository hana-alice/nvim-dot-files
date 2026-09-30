# hana-alice/nvim 1.10.0 — 语义边界契约与可验证反馈

> 日期：2026-09-09
> 类型：Minor（新增版本观察、反馈处置与强制 native 验收能力）
> Git tag：待显式授权；本轮未提交、推送或打 tag。

## 归档工作记录

### 2026-09-09 — Preserve evidence across boundaries and verify the feedback lifecycle

**Task**
- Implement the confirmed design audit findings: input completeness, cancellation propagation, instance/data ownership, route-specific capabilities, successful-outcome evidence, native acceptance and field-feedback lifecycle.

**Implemented**
- `semantic_context.lua` and native catalog/definition/TU owners retain rejected CDB records, reject incomplete coverage, and invalidate native compilation-database handles by signature and full eviction.
- `semantic_protocol.lua`, `ue_clang_semanticd.lua` and client runtime enforce the frame limit independently of chunking. Stdin uses bounded libuv reads with backpressure; an oversized outgoing request fails immediately without poisoning the next request.
- `semantic_navigation.lua`, client actions/environment/transaction, LSP transport/adapter and `ue/clangd_commands.lua` enforce independent instances, copy-only lineage getters, source/header capability requirements, complete successful evidence and cancellation before compiler-command delivery. Preparation predicates include transport completion as well as action freshness.
- `probe.lua` owns revision-linked observation, bounded sampling, unread/disposition/recurrence state and fixed outcome/latency aggregates. `UEProbeResolve` and `UEProbeDefer` record evidence or a deferral reason; reading the report only acknowledges it.
- `probe_store.lua` owns locked delta merge and checked atomic publication. Failed writes preserve the previous file; bounded retries preserve pending work. Normal exit under lock contention writes an independent recovery journal, replayed exactly once through durable IDs.
- Probe persistence starts at the first dirty operation, including headless callers that never register user commands. Old-revision history cannot exhaust a new observation's distinct-key budget; compaction still bounds retained records and preserves current overflow evidence.
- `tests/harness/init.lua`, `tests/run.lua`, `utils/log.lua` and the PowerShell wrapper distinguish SKIP from PASS, support required-native acceptance, and isolate local test state/logs. Linux CI installs the project's existing LLVM 22 toolchain and requires native execution.
- Added a production header fixture exercising actual environment discovery, compiler session/NDJSON, catalog/query, destination opening and feedback persistence on normal exit. UE facade inputs point to fixture artifacts; the semantic client, sidecar and jumper are real.

**Pitfalls / Gotchas**
- A partial scan guard cannot recover compilation records discarded before scanning. The input decoder must preserve rejection/coverage evidence.
- Cancelling a UI action is insufficient: transport cancellation/timeout must also invalidate an asynchronous preparation callback before it can deliver compiler configuration.
- Registering exit persistence only in command setup missed headless producers. Concurrent exit may legitimately leave a journal, so acceptance reads through recovery and also verifies the resulting published total.
- A successful `write()` call cannot be assumed: encode/write/flush/close/rename are all checked. An unreadable existing file is not an empty database.
- Local fixtures and newly active observations are separate evidence. Neither confirms the current large UE checkout's live latency or correctness by itself.

**Validation**
- Final full regression with explicit real LLVM and `NVIM_TEST_REQUIRE_NATIVE=1`: **1612/1612 passed, 0 failed, 0 skipped**, exit 0. Smoke 97/97; bare-global AST lint 193 files, OK.
- First required-native full: 1606/1608, two failures (an old transaction fixture lacked newly required evidence; the context module exceeded its size limit). The fixture was corrected; context parsing reused existing list validation and derived completeness to reach 799 lines without changing the gate.
- Second full: 1609/1610, concurrent probe publication expected 8 but observed 5. A regression without command setup reproduced missing exit persistence; first-dirty registration and journal-aware recovery were added before rerunning acceptance.
- A subsequent run had two serialized-dispatch fixture failures and a 5-second child-exit timeout. The serialized fixtures embedded real process startup in a 400ms budget; they now use controlled protocol events and a virtual clock while preserving separate real-process tests. The unchanged CDB suite passed 31/31 on recheck. The final full run above passed all cases.
- Focused real LLVM checks: native sidecar 31/31; context 13/13; client 32/32; navigation 41/41; clangd command delivery 8/8; complete header chain 1/1. Feedback acceptance 10/10; durable store 11/11; concurrent state 19/19. Probe/store checks exercise precise failure injection and real child processes.
- Verified modules were hot-loaded into the idle running editor. Both semantic topics are armed for 14 days with observation revision `semantic-contracts-2026-09-09`; runtime status and persisted JSON agree. Existing evidence was backed up, preserved and marked deferred pending field observation; no synthetic success event was written to the user's store.
- Spec consistency: synchronized semantic navigation, probe feedback, headless harness and regression-policy specs; all four strict validations passed. Updated architecture, testing instructions and knowledge-base navigation; structure 75/75 and `git diff --check` passed.

**Follow-ups**
- Linux CI provisioning is configured and statically checked but has not been executed on a remote runner in this Windows session.
- Source clangd role tests and header whole-chain tests do not substitute for live large-UE performance or native macOS/Linux measurements.
- Compiler replacement detection remains based on realpath/size/mtime; an in-place replacement preserving all signatures is not detected.
- If both main storage and the journal directory are unwritable, persistence cannot be guaranteed; the storage error remains visible while the process is alive.
