# hana-alice/nvim 1.12.1 — Keep first cache writes from revoking frozen startup

> 日期：2026-09-23
> 类型：Patch；阶段范围为已复现的冷缓存启动自失效。
> Git tag：未创建，未获 tag 授权。

### 2026-09-23 — Prepare owned frozen-cache directories before input watches

**Task**
- Continue the bounded investigation of live frozen-input invalidation after v1.12.0.

**Implemented**
- `lua/ue/index/batch_runtime.lua`: prepare the canonical owned `verified/.cache/clangd/index` tree before installing input watches. Derive the path from the original semantic CDB; reject conflicting files, redirects, creation failures and foreign descriptor locations while retaining original commands.
- `tests/cases/index_batch_runtime_spec.lua`: add real native first-cache-write coverage and rejected-path checks; database changes must still revoke authority.
- Keep all event filtering, ancestor protection, receipt validation and proof identities intact. No new dependency, generic abstraction or weaker notification mask.
- `AGENTS.md`: require completed and unfinished tasks in every stage handoff. Synchronize the coverage spec and record the investigation.

**Pitfalls / Gotchas**
- In a controlled experiment using copies of the real 1,206-original / 1,199-frozen publication, directory creation and temporary-file writing alone remained ready. The following cache-file rename produced an `action=3`, `directory=true` event for the watched `verified` parent; the old guard changed from ready/epoch1 to invalidated/epoch2.
- The new runtime prepared the cache before watches. The same controlled write/rename then remained ready. Both runs preserved original/frozen CDB bytes, receipt assets and bound inputs, and cleaned up all owned processes.
- This establishes the reproduced cache-notification mechanism. The historical client14 event was not recorded and is not retrospectively assigned a unique cause. The earlier mkdir-only negative result remains valid.

**Validation**
- Native runtime regression: before 41/42 (only the new first-write case failed), after 43/43; zero skips. Full required-native regression **2117/2117**, zero failures/skips. Lua AST lint, strict coverage-spec validation and whitespace checks passed; independent review found no blocker.
- Live runtime exports were upgraded with identical before/after editor, terminal, source-watcher and dirty-file state. Normal scoped restart started one verified-CDB client with a ready guard and 26 watches; it remained ready at the check 162 seconds after process start. No editor restart or cache clearing occurred.
- Reusing the real activation options for unchanged prepare returned synchronously in **19.04 ms**, kept the same client and guard epoch, and all seven production artifact bytes/mtimes remained unchanged. Coverage remains 14,312 native sources and 2,094 shader records, with one accepted 8-to-1 batch.
- The temporary observer ran for 114 seconds and saw 53,893 callbacks. Ordinary event storage was capped at 1,000; the separately reserved first-state-change slot remained empty, with zero observer errors. The original factory was restored. This is bounded observation, not a complete retained event history or a long-session guarantee.
- Spec consistency: synchronized the owned-cache startup ordering contract in `cpp-semantic-index-coverage`. The runtime change does not modify collector/policy identities; the existing eight-to-one receipt still passed actual validation.

**Follow-ups**
- Validate longer editing sessions and legitimate-input invalidation/recovery; historical client14's exact event remains unavailable.
- Expand proven secondary compression beyond the single accepted group.
- Measure and optimize full-engine cold/warm completion, cache-transition cost and resource usage. The live existing `-j=12` run reached a sampled peak working set of **15.47 GB**; one host sample was **65.9% CPU** with roughly **36.9 GiB physical memory free**. These are observations, not a resource-cap or performance-restoration claim.
- Close the historical navigation/dirty probe items separately. Direct junction regression for the newly prepared cache components remains a test-coverage gap; path rejection has code review plus foreign/file-conflict tests.
