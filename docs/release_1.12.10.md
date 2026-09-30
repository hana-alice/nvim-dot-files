# hana-alice/nvim 1.12.10 — Qualify a second SuperUnity batch

> 日期：2026-09-24
> 类型：增量交付；沿用现有实现扩大真实工程的已证明批次。
> Git tag：未创建，未获 tag 授权。

### 2026-09-24 — Expand proven compression without weakening semantic admission

**Task**
- Continue actual secondary compression beyond the previously qualified eight-to-one group. Whole-engine performance restoration remains incomplete.

**Implemented**
- Qualified a disjoint three-to-one group containing seven generated source members through the existing independent-original-TU semantic admission. Appended its receipt to the selected local proof store while preserving the earlier receipt and every existing bound asset. No runtime implementation or proof policy changed.
- Verified both groups through the normal full generator and publisher in an isolated editor, twice. The output contains **3291 records = 1197 native + 2094 shader**; native records are **984 UBT + 2 secondary + 211 exact**. All **14,312** source members remain covered; the original semantic command authority retains **1206 native records**.
- The first private publication changed the frozen products; the second reported unchanged. All generated/published bytes and mtimes remained stable on the second pass, as did the 995 shared UBT wrappers and existing proof assets.

**Pitfalls / Gotchas**
- The earlier four-original candidate failed closed on 29 ambiguous original-AST binding requests, all in the excluded original. This establishes missing proof, not a demonstrated wrong binding. The successful three-original candidate reused three independently certified original graphs; no ambiguity check was relaxed.
- The rejected attempt consumed **272.15s** including supervision. The successful attempt consumed **227.25s** supervised total: its **91.53s** admission includes **84.94s** of group proof; validation took **11.15s**, and cache reuse **10.81s**. The total also includes input checks and supervision. These are qualification costs, not indexing completion times.
- Private cold runs start with fresh isolated shard stores; warm runs reuse exactly those stores. OS file cache and host load are uncontrolled. No production cache was cleared.

**Validation**
- New-group cold BackgroundIndex completion: **30.6041s → 19.3231s**; CPU **27.9688s → 16.5938s**; peak working set **1,192,448,000 → 1,069,133,824 bytes**. Warm completion: **1.8762s → 1.8777s**, with unchanged shard bytes/mtimes. Both variants completed with no compilation failures or missing main shards.
- Private full generator: **48.18s / 45.77s**; publication: **3.899s / 0.153s** for first/repeat passes. These measurements exclude live activation and whole-engine indexing; they must not be represented as full prepare or index performance.
- Standalone new-group cache reuse and receipt validation cost **6.274s + 6.156s**. Combined receipts share inventory/query work, so these standalone costs cannot establish the marginal cost of adding the new group to an existing store.
- Two alternating old-group/combined-group measurement rounds found marginal reuse-plus-validation costs of **1.371s / 1.647s**, mean **1.509s**; cache-only reuse launched zero native processes, and combined validation required no additional native query processes. The new-group cold indexing saving is **11.281s**. Their arithmetic difference is **9.772s**, a component-level estimate from separate runs, not a measured whole-engine end-to-end speedup. All bound inputs and proof assets remained unchanged; the guarded process tree exited cleanly.
- Live normal full generation/publication completed successfully in **37.37s** of recorded build time. The seven-product audit confirmed the expected two-batch counts and complete coverage. Original native CDB bytes/mtime and the store selector stayed unchanged, as did runtime singleton ownership and the unsaved document's exact hash/tick. The changed frozen publication triggered one normal client transition **32 → 33**; the new client still uses the original reader because a modified document remains. Published frozen products are not evidence of active frozen use.
- A second normal live full generation completed in **42.95s**, with **all seven product bytes/mtimes unchanged**, the same client **33**, unchanged singleton owners and preserved unsaved document. The full-run counter advanced from five to six, build status was ready, and no job/timer remained. This proves repeat generation/publication stability; it is not a complete `UEPrepare` or whole-engine indexing benchmark.
- A later sample of the editor-owned original clangd process showed **17,586,085,888 bytes** working set, **17,743,425,536 bytes** peak working set and **225.28125s** cumulative CPU since its restart. These are process observations, not index completion measurements or usage of the new frozen batch. The substantial live memory footprint remains unresolved.
- First required-native full regression: **2217/2218**, with one concurrent target-state replacement failing with Windows `EPERM`. The unchanged `multi_instance_state` scope immediately reran **26/26**, zero failures/skips. The cause of the failed replace remains unproven; its evidence is retained as a separate follow-up, not dismissed as a repaired failure.
- Final required-native full regression: **2218/2218**, zero failures/skips; final archived-document structure **78/78**. Governing-spec strict validation and `git diff --check` passed. OpenSpec has no active change awaiting synchronization or archive; this operational acceptance record is archived with the release. The successful rerun does not establish that the earlier target-state replacement failure is fixed.
- Spec consistency: **no spec behavior change**. Existing `cpp-semantic-index-coverage` contracts already permit disjoint, independently proven cached groups and require unchanged-input stability. This stage changes local qualification evidence and documents acceptance limits; no new dependency, abstraction or runtime refactor was introduced.

**Follow-ups**
- Broader qualified compression and comparison with the last verified healthy whole-engine implementation remain open. A second accepted batch does not establish restored SuperUnity performance.
- Whole-engine cold/warm completion, CPU/peak memory, first/repeat prepare and sustained editing/recovery still require measurements. Preserve unsaved documents and the original reader until normal frozen activation is eligible.
- Investigate whether publishing changed frozen products can avoid restarting an unchanged original reader when modified documents already make frozen activation ineligible. This stage observed that transition and its resource cost; it did not change restart policy.
- Ambiguous original bindings, historical navigation failures and the reparse event-coverage gap remain separate unresolved work. Search rebuild latency is also still open.
- Reproduce and diagnose the concurrent target-state `EPERM` observed by the first full regression. This delivery does not alter project-state persistence or its assertions.
