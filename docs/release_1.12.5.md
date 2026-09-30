# hana-alice/nvim 1.12.5 — Preserve activation across stable directory writes

> 日期：2026-09-23
> 类型：Patch；目录通知分类与祖先监听修复。
> Git tag：未创建，未获 tag 授权。
> 在线状态：修复已交付；已有未保存文档触发保护回退，持续冻结运行及完整性能验收仍未完成。

### 2026-09-23 — Keep ordinary directory writes from revoking frozen activation

**Task**
- Fix the experimentally reproduced ordinary-directory write invalidation path while retaining namespace, metadata and file-write protection. The historical directory event's writer and category remain unknown.

**Implemented**
- `tools/clangd_batch_activation.py`: install actual parent-entry watches for ancestors of every protected recursive root, including tools and publication files. Bind the explicit `stable-directory-write-v1` policy into description and validation.
- `lua/workarounds/libuv/content_events.py` and `.lua`: split grouped input subscriptions into metadata/name (`0x147`) and size/last-write (`0x18`) streams. Require both streams to be armed and fail closed on either error. Attest only exact configured ordinary directories with unchanged nonzero device/inode and non-reparse attributes.
- `lua/ue/index/batch_runtime.lua`: accept that narrow attestation only under the matching descriptor policy and installed directory set. Legacy, unknown, file, changed-identity, metadata and namespace events retain invalidation. `batch_guard.lua` preserves the stream in bounded first-event evidence.
- Extend activation, guard, transport and runtime regressions; add `tests/cases/index_input_directory_spec.lua` for four real Windows notification cases and include its filter in all three regression maps.
- Reuse the existing grouped helper, root budgets, asynchronous validator and fallback. No new dependency, source-only watcher change, proof requalification or module-boundary change.

**Pitfalls / Gotchas**
- Native action 3 does not identify a notification category. Directory names and timestamps alone cannot establish identity.
- In one controlled native experiment, an in-place junction retarget preserved inode/attributes while changing reparse data, and emitted no notification with either the old combined mask or the split masks. This existing capability gap remains open; the patch does not claim complete reparse protection. An actual write to the junction object itself was observed and remained unattested.

**Validation**
- Full required-native regression **2153/2153**, zero failures/skips. New policy cases failed **2/9** before implementation and passed **9/9** afterward. Focused native backend **22/22**, real directory-event cases **4/4** and documentation structure **78/78** passed. Lua/Python AST checks, whitespace checks and strict governing-spec validation passed.
- Maximum **288 logical roots / 576 subscriptions**: normal close, missing root, abrupt owned-parent exit and stdin EOF all passed; no owned processes remained. Normal readiness was 0.352 seconds; sampled helper peaks were **104.12 MiB RSS**, 583 threads and 2630 handles. Sampled idle CPU grew 0.015625 seconds over 2.960 seconds. These are bounded observations, not event-flood guarantees.
- Two isolated real-publication activations each used **62 roots / 124 subscriptions** and full receipt/query validation, taking **16.256 / 16.416 seconds**. Unchanged repeats took **2.432 / 1.459 ms**, with zero new helpers. A real owned directory write retained ready authority; its next prepare took **1.487 ms**, also zero helpers. A subsequent byte write to the private original CDB immediately revoked authority and selected original commands.
- All **3318 proof bindings** remained unchanged. Of **1045 input bindings**, only the deliberately modified private CDB changed. The native jobs stayed within 3 GiB/process and 6 GiB/job limits and left no processes. The isolated activation heartbeat had a **108.44 ms** maximum gap; this is not a claim of sub-100 ms responsiveness.
- Seven production artifacts retained exact bytes, sizes and mtimes after live delivery. Coverage remains **14,312 sources / 2,094 shader records**; original native commands **1,206**, frozen **1,199 = 987 UBT + 1 secondary batch + 211 exact**. The secondary group remains eight wrappers covering eleven members; this patch does not expand compression.
- Spec consistency: synchronized `cpp-semantic-index-coverage` with complete ancestor topology, two-stream readiness, the versioned directory policy and the retained reparse limitation. There were no active OpenSpec changes to archive.

**Live delivery**
- Replaced only the reviewed public runtime/guard/grouped-backend exports after verifying retired ownership and actual helper completion. Module aliases, index state, source helper, windows, buffers and dirty-file state were unchanged.
- The first installation attempt was deferred because a validation helper was still running; the later completed-helper check allowed installation. No gate was bypassed.
- One scoped restart used the new policy with **14 recursive + 42 direct roots**. Live full validation passed (`publication-and-receipts-current`, inner validation **9.657 seconds**) and started frozen client29.
- A C++ buffer was already modified before installation and retained the same changedtick afterward. On attachment, the existing `live-document-modified` rule revoked frozen authority. At **12:15:58Z**, initialized original client30 was the only remaining client, with zero guard watches. No user edit was saved or discarded.
- A temporary documented `LspProgress` observer retained per-client begin/end events and was removed. The frozen client's cycle was already revoked; the original cycle used existing caches. Neither supplies a controlled whole-engine frozen-performance comparison.

**Follow-ups**
- Handle already-modified documents before frozen startup to avoid activating and immediately falling back; assess safe demand-driven recovery after documents become clean.
- Continue long-session editing/recovery and proactive promotion; broaden actual secondary compression and independently measure full-engine cold/warm completion, CPU and memory against a valid baseline.
- Close the host's silent in-place reparse-retarget gap without weakening correctness or adding unbounded work. Sustained event-flood/network-path coverage and historical navigation/dirty/csearch dispositions remain open.
