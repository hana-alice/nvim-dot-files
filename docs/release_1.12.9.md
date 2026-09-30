# hana-alice/nvim 1.12.9 — Preserve search overflow across recovery and restarts

> 日期：2026-09-24
> 类型：Patch；dirty 截断证据持久化与完整搜索重建。
> Git tag：未创建，未获 tag 授权。

### 2026-09-24 — Retain incomplete search coverage after dirty tracking overflows

**Task**
- A real watcher had reached its 1000-path cap. Its overflow flag was memory-only, and incremental completion could empty the retained paths without repairing dropped modifications.

**Implemented**
- Persist a sibling overflow marker under the existing dirty lease before publishing a truncated path array. Preserve path-array and legacy newline compatibility; share the existing persistence reader instead of duplicating it in the watcher.
- Keep empty-but-capped state stale. Smart build selects reset; the incremental command routes capped state to the existing search-only full rebuild. Successful resets acknowledge only strictly older overflow and covered paths; concurrent changes remain dirty.
- Guard write, close, publication and marker-deletion failures. Keep the existing bounded retry and captured project owner. Synchronize `ue-code-search`, architecture and knowledge-base pointers; open bounded repair-revision observations.

**Validation**
- New overflow regression **19/19**; watcher **22/22**; build guard **28/28**; stability **26/26**; four-file Lua AST lint and strict governing-spec validation passed.
- Archived documentation structure **78/78** and `git diff --check` passed.
- Original overflow cases failed **0/10**; two additional failed-write acknowledgement cases reproduced before the write/close guards were added. A native cindex/csearch fixture proved an actually evicted modified source went from **0** fresh-token hits to **1** after smart reset, with **0** old-token hits and cleared covered overflow; measured build-and-query sequence **223.929ms**, not a whole-engine benchmark.
- First required-native full run **2216/2217**: only the watcher's 800-line gate failed. Shared-reader reuse fixed it without increasing the gate. Final required-native full regression **2218/2218**, zero failures/skips, including legacy newline-reader coverage.
- The live delivery retained original function dependencies and watcher owner; its audit confirmed unchanged handles, pending queues, dirty contents, buffers, windows and client identities. Migrating the positively observed live overflow left the original dirty file's SHA unchanged.
- Current-engine search-only rebuild scanned a **304,244-entry** workspace list and published a usable **386,648,929-byte** index. Its completion notification reported **162.0s** for the backend; command-start to publication was approximately **278s**, including about **115s** before backend launch. Dirty state became **0 paths / uncapped**, freshness became **fresh**, and the two reported token queries returned **6** and **4** matches.
- Existing client identity/configuration and both modified documents retained their exact hashes/ticks through the rebuild. Seven CDB/semantic-index/proof-routing artifacts retained exact SHA, size and mtime; semantic coverage remains **14,312 source members / 2,094 shader records**, original commands **1,206**, frozen **1,199 = 987 UBT + 1 secondary + 211 exact**. No CDB generation or clangd restart was triggered by this recovery.
- The temporary callback observer expired during the long scan and missed backend completion; its replacement hook was removed. Completion is independently established by the actual success notification, published index, released writer, clean dirty state, fresh verdict and real search results. No complete process-tree CPU/peak-memory or UI-latency measurement was captured; launcher CPU must not be mistaken for worker CPU.

**Follow-ups**
- A legacy path array without overflow evidence cannot prove or reconstruct past truncation. Older writers cannot erase the new sibling marker, but must be upgraded to produce new overflow evidence. A stale owner's marker may conservatively reappear and require another reset; unknown marker timestamps are not automatically acknowledged.
- Long-session observation, historical probe attribution and whole-engine secondary-compression/indexing performance acceptance remain open.
- Search rebuild's long pre-backend phase and editor responsiveness need separate measurement/optimization. This repair establishes correctness, not a csearch rebuild performance improvement.
