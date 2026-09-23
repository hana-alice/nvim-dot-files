# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)
- `v1.9.0` → `docs/release_1.9.0.md` (tag pending explicit confirmation)

- `v1.9.1` → `docs/release_1.9.1.md` (tag pending explicit confirmation)
- `v1.9.2` → `docs/release_1.9.2.md` (tag pending explicit confirmation)
- `v1.9.3` → `docs/release_1.9.3.md` (tag pending explicit confirmation)
- `v1.10.0` → `docs/release_1.10.0.md` (tag pending explicit confirmation)
- `v1.11.0` → `docs/release_1.11.0.md` (tag pending explicit confirmation)
- `v1.11.1` → `docs/release_1.11.1.md` (tag pending explicit confirmation)
- `v1.11.2` → `docs/release_1.11.2.md` (tag pending explicit confirmation)

- `v1.11.3` → `docs/release_1.11.3.md` (tag pending explicit confirmation)

## Unreleased

### 2026-09-23 — Correct Android query identity before reusing batch proofs

**Task**
- Correct the previous profile's unsupported NDK release claim and overly broad version prefix match.

**Implemented**
- Name the profile by observed compiler build (`android-clang-9.0.9-build-7019983`) and require an exact version first line.
- Advance the parser identity so older receipts cannot silently acquire the corrected policy.
- Add changed-build/commit/suffix rejection cases and an optional `UE_QUERY_DRIVER` lane exercising a real installed NDK driver, rediscovery and forged-profile rejection.

**Pitfalls / Gotchas**
- Correction: the observed SDK package reports `Pkg.Revision = 21.4.7075529`; the previous `r20b` label was not supported by evidence. Historical pair admission remains historical and requires requalification under the changed helper.

**Validation**
- Before fix: query-profile regression 6/7; a direct probe also demonstrated acceptance of an added `-custom` suffix.
- After fix: required-native query-profile regression 8/8, including the real Android driver.
- Required-native full regression: **2091/2091 passed, 0 failed, 0 skipped**, with the real NDK lane enabled.
- Spec consistency: synchronized `cpp-semantic-index-coverage`; strict OpenSpec validation, Python AST parsing and diff whitespace checks passed.

**Follow-ups**
- SuperUnity global semantic/performance restoration remains open. Independent-original timing sums are not a shared-cache performance baseline.

### 2026-09-22 — Certify the pinned Android NDK query-driver profile

**Task**
- Remove the strict-query dead end for the actual Android CDB compiler without weakening
  driver identity or receipt validation.

**Implemented**
- Added an Android clang 9.0.9 profile to the LLVM 22.1.5 query extractor (release label and version boundary corrected in the 2026-09-23 entry).
- Bound the profile name into query evidence and validation; unrelated Android/NDK builds remain
  unsupported.
- Added a native parser regression for the pinned and rejected version strings.

**Pitfalls / Gotchas**
- This profile only clears query observation. It does not accept a SuperUnity candidate or
  claim indexing performance; the current eight-wrapper qualification still needs a bounded
  semantic proof.

**Validation**
- Native query-profile regression: **7/7 passed** with the installed clangd 22.1.5.
- Spec consistency: synchronized `cpp-semantic-index-coverage` with the explicit pinned profile.
- Required-native full regression: **2090/2090 passed, 0 failed, 0 skipped**.
- Current-input two-wrapper strict qualification: **accepted 2-to-1**; original 69.9802 s +
  70.3348 s, candidate 62.5914 s; receipt revalidation `verified-receipts-current`.

**Follow-ups**
- Keep the accepted pair private until a separately bounded expansion proves the remaining
  wrappers; do not claim whole-engine performance restoration from this result.

### 2026-09-22 — Lock the Windows native filter with an OS-level regression

**Task**
- Keep the watcher fix protected against regressions in the actual Windows notification mask.

**Implemented**
- Added a native acceptance case that performs true access-only `SetFileTime` and a real write with the old mtime through the production helper path.

**Validation**
- Native watcher regression: **14/14 passed**.
- Required-native full regression: **2089/2089 passed, 0 failed, 0 skipped**.
- Stage evidence: access-only produced zero source events; preserved-mtime write produced one.
- Spec consistency: existing `host-platform-driver` and `ue-code-search` contracts remain satisfied; no new behavior drift.

**Follow-ups**
- The explicit unchanged-LAST_WRITE first observation remains conservative by design.

### 2026-09-22 — Wire Windows native source events into UE watcher

**Task**
- Make the existing Windows content-event helper the real `ue_watch` backend.

**Implemented**
- `utils.ue_watch` now obtains the optional watcher through the Windows platform driver, keeps libuv on other hosts, and falls back with an explicit unknown-coverage status when Python/helper startup is unavailable.
- Native writes bypass the csearch mtime noise filter, while overflow, protocol errors, and helper exit notify the captured source owner with coalesced coverage gaps.
- Added native integration, fallback, and resource-audit regression coverage; kept the transport in a separate module so `ue_watch.lua` remains within the 800-line gate.

**Pitfalls / Gotchas**
- A native write can preserve an older mtime; applying the libuv timestamp filter to it would drop a real source change.

**Validation**
- Required-native full regression: **2088/2088 passed, 0 failed, 0 skipped** (`nvim --headless -l tests/run.lua`).
- Targeted watcher regressions: native **13/13**, csearch **22/22**, host resource discipline **13/13**, platform **49/49**, workaround **19/19**, stability **26/26**.
- Live Windows helper check: `watch_mode=native`, `native_ready=true`, and a real file write reached `pending_adds=1`.
- Spec consistency: existing `ue-code-search` and `host-platform-driver` requirements are now wired to production code; no spec drift introduced.

**Follow-ups**
- None for the watcher path.

### 2026-09-22 — Remove shared revision contention from independent state updates

**Task**
- Resolve the repeated native regression failure replacing shared `state.revision.json`.

**Implemented**
- Delete the shared revision nonce writes. Derive cache invalidation from the exact authoritative JSON bytes sampled with state; keep independent field publication, target-pair atomicity and error propagation.
- Cache the state and its signature from the same read, so a concurrent later publication is detected on the next lookup. Retain the old revision path API for compatibility.

**Validation**
- An independent four-writer, 1600-replacement experiment reproduced 134 EPERM failures without readers. An initial eight-attempt retry passed the 23-case filter, then failed the combined full run: **2068/2069, 1 failure, 0 skips**. The retry is not an accepted fix; evidence is retained in `docs/cpp-index-restart-investigation.md`.
- Replacement implementation: state regression **26/26**, project context **15/15**, UE API **65/65** passed. Real active-bucket signature reads (six inputs, 9,243 bytes, 100 samples) measured p50 0.291 ms and p95 0.492 ms. Lua AST lint and strict spec validation passed.
- Spec synchronized: `multi-instance-state-isolation` now specifies derived invalidation and matching state/signature sampling. Final combined required-native regression on LLVM 22.1.5: **2072/2072 passed, 0 failures, 0 skips**. Structure **78/78**, strict validation of all three changed capabilities, Python AST, Lua bare-global lint and whitespace checks passed.

**Follow-ups**
- Same-field contention and persistent external file locks still report ordinary I/O failures. This state/cache change is verified in new processes; the long-lived editor's session owner has not been hot-replaced.

### 2026-09-22 — Keep indexing alive when phase priority only reorders existing commands

**Task**
- Stop repeated publication from restarting clangd when its complete commands are unchanged.

**Implemented**
- `ue.index._publish` reuses existing bytes and mtime for permutations of unique normalized files with identical complete commands. Fresh publications and real command changes retain current/hot priority; same-file variants remain order-sensitive.
- Preserve the same rule for validated frozen commands and activation metadata; receipt and coverage gates remain intact.

**Validation**
- Real before/after databases both contain1206 commands, with identical complete tuple multisets, zero additions/removals and135 reordered positions; the old publisher rewrote them. An independent phase fixture reproduces the same defect.
- Publication **19/19**, generation **35/35**, output stability **16/16** and native semantic-index **1/1** passed. Live current/hot callbacks both reported unchanged; database bytes/mtime and client identity stayed stable during those callbacks. Spec synchronized: `cpp-semantic-index-coverage` now explicitly defines permutation no-op and variant-order boundaries.
- Final combined required-native regression: **2072/2072**, 0 failures/skips. Subsequent read-only inspection retained client 29 and the same active/background CDB hashes and mtimes; the private observation autocmd group was removed.

**Follow-ups**
- The separate source-observer branch can still refresh on an unknown first observation; a Windows metadata-only fixture reproduces this path. Its content-baseline repair and full SuperUnity semantic/performance restoration remain open.

### 2026-09-22 — Compare newer LLVM with narrowly scoped legacy Android diagnostics

**Task**
- Prefer the newer passing A/B candidate while retaining the successful NDK build context and global `-Werror`; upstream latest is not mandatory.

**Implemented**
- Recover the absolute Android compiler from consistent explicit RSP toolchain/sysroot layout and record selection provenance; leave unknown contexts unchanged with a reason.
- Add isolated `clangd.legacy_android_warnings`: only proven Android Clang9.0.9 / Android C++17 / effective global Werror commands receive the two specific VLA and unused-but-set-variable demotions. Warnings, unrelated errors and explicit group controls remain effective; repeated output is unchanged.
- Compare isolated official LLVM23.1.1 with matching clang/libclang. Keep production22.1.5 after broader A/B exposes unported proof interfaces; no production version gates were widened. Add a native filename-case regression; no RIFF layout changes.

**Pitfalls / Gotchas**
- Corrected the assumption that `unused-variable` controlled `unused-but-set-variable`; official definitions and actual Renderer input prove they are siblings.
- Preserve explicit pedantic VLA errors and a registry disable made before the pipeline's first load; both were independently reproduced and fixed.
- `--query-driver` does not substitute the NDK parser. Successful build, interactive AST diagnostics and complete index records are separate evidence.

**Validation**
- Experimental LLVM 23.1.1 full A/B: **2045/2055**, 10 failures, 0 skips, including hard 22.1.5 template-proof/query-driver interfaces. The candidate is not deployed and those compatibility changes remain open. Final combined LLVM 22.1.5 required-native regression: **2072/2072**, 0 failures/skips; intermediate state-file failures and their correction are retained in the investigation.
- Two-round real-source LSP A/B produced identical diagnostics with the narrow flags on both versions; source SHA stayed unchanged. The active editor now reports both groups as warnings with no errors in the three inspected source buffers. Active coverage remains 14,312 C/C++ sources plus 2,094 shaders; background remains 995 UBT groups plus 211 exact commands, with zero secondary groups. Repeat prepare reported unchanged with no artifact publication.
- Spec synchronized: compiler provenance, A/B version preference and minimum diagnostic conditions in `macos-ios-cdb-semantic-prepare`; production version boundaries and index semantic/performance contracts unchanged.

**Follow-ups**
- Full SuperUnity semantic/performance acceptance remains open; bounded diagnostic fixes do not establish its restoration.

### 2026-09-22 — Prevent proof helpers from invalidating their own source inventories

**Task**
- Reassess the unresolved navigation/index repair using current editor evidence and the prior rejected whole-engine experiments.

**Implemented**
- In `tools/cdb_verified_batch.py` and `tools/build_super_unity_cdb.py`, disable Python bytecode writes before project imports. The filename policy's module-body guard runs too late to prevent its own loader from creating a cache file.
- Add `tests/cases/index_bytecode_spec.lua` with isolated first-import tests for dynamic qualification loading and ordinary generated-batch loading. No inventory exclusions, old receipt edits or production cache migration were introduced.

**Validation**
- New regression first reproduced both failures (dynamic loader: 6 bytecode files; ordinary loader: 3), then passed 2/2 with zero skips. Each test first proves its ordinary `python -I` process can create bytecode, then checks the real policy and complete source-directory inventory.
- Four current GUI coordinator queries resolved both `FParse` overloads, a Vulkan enum and `UE_LOG`, retaining compiler identities. Measured elapsed times were 4,947 / 1,029 / 7 / 6 ms respectively; these are navigation timings, not index-build performance. Source contents/cursor and clangd client identity remained unchanged. Temporary floating windows appeared during collection and were gone on follow-up; the initial all-window equality check is retained as false.
- Five bounded runs with the already installed official clangd 22.1.6 reproduced the same macro-header first-writer loss (4.8705 seconds total native time, one thread, peak RSS 201,240,576 bytes). Source references and shared-header bytes were independently compared; no compiler or live client was replaced.
- Required-native full regression: 2,037/2,037 passed, zero failures/skips; existing native batch regression: 27/27. Python AST checks, the new Lua test's bare-global lint and `git diff --check` passed. Synchronized the first-policy-import scenario in `cpp-semantic-index-coverage`; strict spec validation passed.

**Follow-ups**
- Shared wrapper-directory growth still invalidates earlier proofs. Stock clangd's independently reproduced macro-header first-writer loss and full SuperUnity semantic/performance acceptance remain open; this bounded repair does not authorize the rejected generated candidate.

### 2026-09-21 — Select current linker inputs before Unity source deduplication

**Task**
- Prevent obsolete response files from owning current sources and supplying outdated include paths.

**Implemented**
- Bind the selected build receipt to its existing linker response; compare real output object paths and compiler targets within proven direct-object families before expanding Unity files.
- Retain uncertain archive, architecture and missing-evidence inputs with explicit reasons. Preserve original compiler arguments and bind receipt/link hashes into Unity provenance.

**Validation**
- Link-input regression passed 10/10, zero skips, including the actual generator choosing current Unity parameters over an earlier obsolete RSP; partition regression passed 9/9. Diff checks passed.
- Real read-only selection retained all 1,189 current direct objects and 28 uncertain-family RSPs, excluding 76 obsolete RSPs including all six failed baseline commands. Twelve current Vulkan/audio/plugin Unity replacements remained selected. Five existing unsupported `.mm` inputs were reported explicitly.
- Synchronized current-link selection and uncertainty scenarios in `macos-ios-cdb-semantic-prepare`; structure 78/78 passed.
- Required-native CDB regression passed 98/98 with zero skips. Formal prepare completed in 153.9142 seconds; the resulting 14,312 C/C++ sources and 2,094 shader records differ from the previous capture only by removing two obsolete foreign-engine paths and restoring five C sources.
- A private cache continuation indexed 334 actual TUs in 522.5266 seconds, with full source coverage and no current-closure HadErrors. The raw capture retains its one orphan-header rejection; the separately audited reachable view excludes that zero-symbol/zero-definition shard without losing C/C++ references.
- Adopted the validated reachable cache with backups: 23,326 files installed, 9,686 identical files unchanged, 351.6983 seconds including checks/copying. Re-enabled configured clangd in the existing GUI without restarting the editor or moving windows/cursors; three native definition/global-symbol queries returned in under 3 ms, and all 33,012 selected cache files retained their size/mtime after startup.
- Background indexing success does not certify warning-free interactive parsing: the existing Android platform source still reports a variable-length-array diagnostic under its unchanged `-Werror` command. Stock clangd suppresses warnings during background indexing; no engine edit or warning suppression was added.
- Full regression with `NVIM_TEST_REQUIRE_NATIVE=1` passed 2,035/2,035, zero failures and zero skips, including the current linker-selection and C partition repairs.
- Refreshed the running editor's idle CDB pipeline while preserving its module table and runtime callbacks; the filename-case repair is now enabled there too. Existing client, windows, cursors and modified state stayed unchanged.
- Repeated current prepare completed in 139.5255 seconds: `changed=false`, no publication or migration, and all six CDB/receipt/marker/semantic artifacts retained both SHA and mtime. The existing clangd PID and client remained unchanged.

**Follow-ups**
- Full secondary-merge semantic/performance verification remains required. The staged continuation is not a new complete cold benchmark, and successful GUI navigation does not establish restored historical SuperUnity performance.
- Rejected the new full generated candidate after complete raw-cache comparison: all 9,499,809 source references match, but 503 referenced SymbolIDs and 423 definition locations disappear. Native indexing took 1,387.3412 seconds; no production activation or historical-speed recovery is claimed.
- A bounded stock-clangd experiment reproduced shared macro-header first-writer loss even without secondary merging; reversing two original TU runs reverses the missing target while call references remain equal. Five single-thread native runs took 5.6074 seconds. This establishes the mechanism, not the cause of every real-project difference, and does not waive missing targets. The isolated toy also retained its automatic standard-library-index warnings.

### 2026-09-21 — Keep compiler-identified Test C sources in the active partition

**Task**
- Fix five current Android-Test C sources being routed to unknown after write-output paths were removed.

**Implemented**
- When no Intermediate path identifies the configuration, read final direct `-D`/`-U` build-macro values without changing argv. Unambiguous Test, Shipping and Debug can fill the missing configuration.
- Keep conflicting, indirect or expression-valued evidence unknown. Development and DebugGame share `UE_BUILD_DEVELOPMENT=1` in UBT, so that macro alone cannot distinguish them.

**Validation**
- Pure partition regression reproduced eight failures, then passed 9/9 with zero skips; Python AST and diff checks passed.
- Read-only reclassification places all five actual unknown records in Android/Client/Test; their real response files explicitly confirm that tuple. Adding them to the previous active partition gives 14,314 entries before stale-RSP removal; this is not yet the current build's verified source count.
- Synchronized the configuration-macro fallback scenario in `macos-ios-cdb-semantic-prepare`.

**Follow-ups**
- Publish and verify the five restored commands together with current-link input selection. The immutable baseline finished with six compile failures from obsolete RSPs; it is not a clean semantic baseline. Final full regression follows final integration.

### 2026-09-21 — Preserve Windows header identities through index preparation and frozen batches

**Task**
- Repair the empty-header-shard mechanism reproduced on Windows clangd 22.1.5 while validating the selected real Android-Test project.

**Implemented**
- Add the isolated, version-gated `header_path_case` identity overlay for selected first-party headers and required filename aliases. Preserve source contents, ordered compiler arguments and complete CDB membership.
- Allow only strictly validated owned overlays in offline candidates and frozen batch proofs. Bind overlay bytes and lookup inventories; retain a closed snapshot and canonicalize only the original mapped dependency intersection.
- Add a recoverable, one-time migration for existing empty mapped-header cache shards after successful CDB commit. Keep main, nonempty, foreign and malformed shards.

**Pitfalls / Gotchas**
- Updating CDB arguments alone leaves old empty header shards fresh in stock clangd. A native hot-cache reproduction proved that moving only the bad shard restores its records while other cache bytes remain unchanged.
- A broad 66.75 MB overlay added about 0.94 seconds to a small native compile and was rejected. The scoped real overlay is 6.74 MB; one measured compile increased from 0.0918 to 0.1838 seconds. This is overhead evidence, not full-index performance acceptance.
- Canonicalizing previously unmapped system headers changes IncludeHeaders metadata. Preserve that original scope as well as path spelling; do not weaken the semantic comparison.

**Validation**
- Required-native frozen batch regression: 27/27 passed, zero failures/skips, including mapped and unmapped system-header providers and closed-snapshot lookup.
- Cache migration 8/8 and transaction 7/7 passed after the concurrent-writer guard and HadErrors exclusion; Lua lint and Python AST checks passed.
- Real post-commit migration examined 35,205 direct shards, backed up and moved 79 eligible empty headers, and retained the other 35,126. No whole-cache clearing was performed.
- One real generated pair passed strict admission: 2 UBT / 4 sources became 1, with native times 15.1223 + 13.9336 versus 14.0151 seconds and zero compile failures. Subsequent preparation correctly invalidated this proof after an actual dependency header disappeared; this is not a live delivered batch or a full-project speed result.
- Final required-native full regression: 2,016/2,016 passed, zero failures/skips. The preceding run had one query timeout (2,015/2,016); its isolated 2/2 rerun and then the unchanged complete suite passed. No timeout or semantic gate was relaxed.
- Repeating the real prepare left active CDB, receipt, original semantic CDB, full CDB, full marker and full semantic metadata hashes and mtimes unchanged. The transaction published nothing, and the completed migration skipped scanning and moving shards.
- Synchronized `macos-ios-cdb-semantic-prepare` and `cpp-semantic-index-coverage`; real secondary grouping, publication and index completion remain under verification.

**Follow-ups**
- Complete real-project secondary admission and measured full indexing. These changes alone do not establish SuperUnity performance recovery.

### 2026-09-21 — Find the installed Windows clangd when PATH omits LLVM

**Task**
- Restore the compiler prerequisite found while reproducing SuperUnity on the selected Android-Test project.

**Implemented**
- Windows driver keeps PATH priority and then checks LLVM under the native Program Files directories. Both interactive clangd and index preparation use the existing driver candidates.

**Validation**
- `nvim --headless -l tests/run.lua platform`: 49/49 passed, zero failures/skips.
- With the actual launch PATH unchanged, `ue.clangd_cmd` now resolves the installed clangd 22.1.5 and `--version` exits successfully; previously it returned an unavailable bare `clangd`.
- Synchronized the Windows installation fallback scenario in `platform-tool-resolution`; this prerequisite repair does not establish SuperUnity performance recovery.

**Follow-ups**
- Complete the selected project's CDB, secondary grouping and native indexing verification.

### 2026-09-21 — Reject generated-only live delivery after full reference-target validation

**Task**
- Test a bounded replacement for automatic cache-only secondary grouping without weakening semantic acceptance.

**Implemented**
- Retain only an offline generated-only candidate API and its five regression cases. It verifies actual members, exact ordered contexts, ownership, source budgets and unchanged outputs; it has no production admission.
- Withdraw the unqualified full-CLI, automatic build, publication and runtime integration. Preserve the experiment privately for reproducibility and retain the pre-existing proven-batch path.
- Count UBT wrappers by their actual filename identity in the full marker; custom output directories no longer report zero Unity entries.

**Validation**
- Generated wrapper regression: 5/5; full generation/manifest regression: 35/35; structure: 78/78. Focused Lua bare-global lint passed.
- Before withdrawal, publication 30/30 and live runtime 3/3 passed, including Python/Lua interoperability with output flags and Unicode paths. The first required-native full run passed 2,021/2,022; after repairing its sole 800-line-limit failure, the full run passed 2,022/2,022 with zero skips. This did not establish real-engine semantic safety.
- After exact withdrawal, required-native generation 35/35, original publication 11/11, original runtime 41/41, real compiler smoke 1/1, structure 78/78 and offline candidate cases 5/5 passed: 171/171, zero failures/skips.
- Private real input: 1,217 native commands become 964 (30 secondary + 719 UBT + 215 exact), retaining all 14,442 distinct C/C++ sources and 2,095 receipt-verified shader donors. Repeated generation preserved all 30 wrapper hashes and mtimes. These are generation results, not full-index completion evidence.
- Real full CLI and private publisher produce the same 964-command native view, preserving active/original semantic inputs. Publication took 1.979 seconds; uncached/cached repeats took 1.621/0.026 seconds without changing output bytes or mtimes. Private headless peak RSS was 2.16 GB. No live editor was modified.
- Same-profile AIModule: seven generated originals merged into one, four implementation originals retained; 354/354 sources, no compiler failures, exact CPP references and unchanged global definitions for 8,417 CPP SymbolIDs. Indexing took 48.282 seconds versus 86.525 seconds. The 14 differing header-reference shards were written by unchanged implementation tasks before the generated task started; this is not a claim of identical header graphs or full-engine performance.
- Full private candidate indexing completed in 1,421.466 seconds at j4, CPU 5,336.688 seconds, peak RSS 6.602 GiB. All 30 secondary groups completed, all 14,442 requested physical C/C++ files had shards, 17,865 bound inputs stayed unchanged, and no owned process remained. Two retained CompensatedTimeStep commands failed and three source shards carry error provenance; complete file coverage is not error-free semantic acceptance.
- The same-profile original 1,217-command control also completed with 14,442/14,442 coverage, the same two failures/three error-provenance sources, unchanged bound inputs and no surviving owned process. It took 1,711.601 seconds, CPU 6,467.078 seconds, peak RSS 6.952 GiB. The candidate was 16.95% faster with 17.48% less CPU in this observation. Both used j4 and fresh private shard caches; OS cache/load were uncontrolled, the candidate overlapped regression activity, and the respective 12/8 GiB limits were not reached. This does not establish historical 13-group performance equivalence.
- Correction: unchanged source-local refs and the equal definition sets of 569,679 source-declared SymbolIDs were insufficient. Scanning all source reference targets found 652 target IDs absent from the candidate global index and 577 IDs with lost definition locations, affecting 3,006 references. A plain `FNamedCurveValue::Value` field is among them. These are not waived by zero reference counts, symbol flags or the timing gain. Production admission is rejected.
- Spec consistency: withdrew the proposed live production contract; added the requirement to validate all referenced target IDs, including header-only declarations, before accepting generated-only candidates. Generation fixtures cannot authorize publication.

**Follow-ups**
- SuperUnity performance recovery remains incomplete. The rejected candidate was never published or used to restart the editor. The retained input failures and missing header targets remain unresolved; do not repeat the same full experiments or announce recovery from the source-local checks alone.

### 2026-09-21 — Preserve complete Unity ownership during response-file collection

**Task**
- Repair the missing real `WorldPartitionMapCheckManager.Cpp` source and its rejected Engine Unity group.

**Implemented**
- Recognize case variants of the CPP suffix while preserving the original path spelling, member order and raw Unity bytes. Missing mixed-case members invalidate incomplete provenance.
- Reuse an already selected source entry only when its complete directory, file and ordered arguments match. Equivalent standalone RSPs no longer invalidate an entire Unity; differing macros or include order still reject the group.
- Use the merged-entry path normalization for member lookups too. Parent-relative paths no longer lose valid provenance; native command spelling/hash remains unchanged, and conflicting, duplicated or malformed commands remain rejected.

**Pitfalls / Gotchas**
- Earlier 14,441/14,441 coverage figures only covered the existing CDB's expected set, which itself omitted this real source. They do not establish complete current-build source coverage.

**Validation**
- `ue_unity_origin`: reproduced the regression at 11/12, then passed 12/12 after the one-line matcher correction.
- The additional parent-relative lookup regression reproduced 12/13, then passed 13/13 after normalization was made consistent; command bytes, conflicting arguments, duplicate aliases and malformed entries are covered.
- `ue_cdb_rsp_duplicate`: the identical-command case failed before the change; all three cases pass after it, including rejection of distinct macros and include order.
- Real Engine Unity: production member extraction and RSP parsing, origin capture, receipt begin/seal and controlled generation retained all 63 ordered sources in one UBT command with zero fallback. The original 62 command tuples match exactly; 83 bound inputs remained unchanged. This bounded private check did not run a full prepare transaction or native indexing.
- Real Renderer duplicates: six actual RSPs produced 32 unique source entries and three complete origins; receipt sealing and the controlled consumer retained all 32 members in three wrappers with zero exact fallback. Nine input hashes remained unchanged. No active publication or native index was run.
- Full regression before the subsequent parent-relative lookup correction, with the installed compiler configured through `UE_CLANGD` and required-native enabled: 1,994/1,994 passed, zero failures/skips. Targeted bare-global/AST lint and whitespace checks passed.
- After the lookup correction: origin 13/13, required-native CDB 71/71, receipts 14/14, API 65/65, smoke 19/19 and structure 78/78 passed, with zero failures/skips.
- Full real raw generation without an old receipt now captures 1,002 groups / 14,227 members, versus 916 / 13,180 before the lookup correction. All 16,536 old command hashes remain equal and no source is removed; the complete private downstream check remains distinct from native indexing.
- The complete cold receipt/partition/consumer chain then produced 1,002 UBT + 213 C++ exact + 2 C exact commands for Client, preserving its 14,442 C/C++ sources and 2,095 shader donors. Repeated generation kept all 1,003 output files' bytes and mtimes unchanged. Raw generation took 13.314 seconds; eight metadata steps took 97.731 seconds. No native indexing or live publication occurred.
- Spec consistency: restores the existing complete compiler-membership contract; no new selection or fallback policy.

**Follow-ups**
- Secondary merging and full semantic/performance acceptance remain incomplete. Five real C sources still route to the existing unknown-configuration shard; Client partition coverage does not establish complete current-build coverage across languages.

### 2026-09-21 — Keep UE friend-template references stable across header-cache reuse

**Task**
- Fix the independently reproduced clangd reference instability encountered while validating SuperUnity.

**Implemented**
- Isolated the correction in `workarounds.clangd.friend_template_canonical`: prepare adds an equivalent namespace declaration before all original forced headers, inside the existing receipt transaction.
- Restricted application to the tested clangd 22.1.5 and exact approved engine-header bytes, confirmed C++/CoreUObject context and textual forced inputs. Unknown contexts remain unchanged with explicit reasons.
- Repeated preparation preserves arguments and mtimes. The existing recipe generator continues for unaffected entries; affected entries retain textual inputs because that generator drops the compatibility prefix.
- An already present workaround prefix now fails the transaction if its context cannot be validated or it is duplicated/not first; unknown contexts without that prefix remain unchanged. Rejected databases retain their bytes and mtime.

**Pitfalls / Gotchas**
- A declaration in the wrapper body fixed cold indexing only; an unchanged wrapper is skipped during warm source reindexing. The command prefix is required.
- This repairs one observable reference defect. It does not admit secondary candidates, support binary PCH, or establish restored full-project performance.

**Validation**
- Required-native: friend-template 7/7 (including a stale-prefix rejection that failed before the guard correction), diagnostic compatibility 4/4 and CDB transaction 7/7; workarounds 16/16 and smoke 19/19. Zero skips; AST/lint/diff checks passed.
- Native two-TU reproduction: original warm template references returned no locations; the prefix returned both expected locations during cold and warm indexing. No compiler or engine-source modifications.
- Real AIModule: both the 11-original and two-batch prefix runs covered all 354 sources with zero compile failures. At one worker they took 86.5254 and 41.2941 seconds respectively; generated-source references matched. Implementation files still gained 21 unresolved-overload references, so the batch remains unadmitted. The template definition still points to the engine implementation.
- Spec consistency: added the guarded prepare transformation to `macos-ios-cdb-semantic-prepare`; secondary admission requirements remain in force.

**Follow-ups**
- Full regression after the guard and producer corrections: 1,994/1,994 passed, zero failures/skips. Real-project semantic/performance acceptance and production SuperUnity integration remain incomplete; no accelerated production publication has occurred.

### 2026-09-21 — Preserve module state and generated-source order in secondary candidates

**Task**
- Continue SuperUnity restoration from the historical FULL path using current compiler-owned Unity inputs.

**Implemented**
- Added an offline ordered candidate producer that keeps the PCH/compiler prefix, replays explicit Definitions in their original position, scopes touched macros and separates differing feature macro states.
- Generated-only and implementation-only originals use separate candidate groups, classified by actual members; mixed originals remain unchanged. Source/original-count budgets, unsupported-input fallback and content-addressed unchanged outputs preserve coverage and repeatability.

**Pitfalls / Gotchas**
- A prior clangd `--check` result did not prove full-body compilation. Real syntax checks exposed PCH/Definitions ordering defects and generated specializations after instantiation.
- Generated-first ordering removed those diagnostics but changed actual `StaticEnum<T>()` reference targets. It was replaced by source-class separation after both a native regression and a real-engine comparison reproduced the defect.
- Candidate output has no production caller or admission authority. Search-path interactions and cross-TU declarations still require validation.

**Validation**
- Required-native `index_ordered_unity`: 7/7 passed, zero skips. The new binding regression first failed against generated-first grouping (5/7 overall), then passed after separation; both source classes still merge within their class and retain their original reference targets.
- `structure`: 78/78 passed; Python/Lua AST checks and `git diff --check` passed.
- Full required-native regression with the installed clangd explicitly configured through `UE_CLANGD`: 1,982/1,982 passed, zero failures/skips. The preceding unconfigured run exposed missing clangd on PATH; no native test was skipped or replaced.
- Complete private refinement retained all 1,307 original command owners in 124 syntax-passing candidates plus 91 originals (215 C++ tasks); 14,441 C/C++ sources and 2,095 semantic shader donors remain represented. This output is not admitted or published.
- Installed-clangd candidate indexing covered all 14,441 sources after a 600.10-second bounded cold run and a separate 38.10-second cache-preserving continuation. The current-profile original baseline completed continuously in 1,103.52 seconds. Different worker counts and the interrupted candidate run prevent a like-for-like wall-time claim; semantic comparison is still required.
- Real-engine representative: 50 UBT / 692 sources changed from ten specialization errors to zero with generated-first ordering; 28.20 seconds. This is syntax validation, not full-index completion.
- A real 28-Unity Niagara group had seven new compile errors; retaining only two conflicting original commands leaves a passing 26-Unity/277-source candidate. Both retained originals independently pass; 296 source members remain covered.
- The earlier complete candidate failed same-profile graph comparison: 6,853 of 14,441 C/C++ own-file graphs differed. It was not admitted. Separating AIModule's 11 originals into two batches subsequently indexed all 354 sources without compile failures; implementation reference removals fell to zero, while generated-code `IMPLEMENT_CLASS` identity changes remain unresolved. This is a bounded diagnostic result, not full recovery.
- Spec consistency: clarified the offline candidate boundary in `cpp-semantic-index-coverage`; production semantic admission remains unchanged.

**Follow-ups**
- Complete real-engine conflict refinement, semantic admission, full-index performance measurement and production integration. SuperUnity recovery remains incomplete.

### 2026-09-20 — Preserve empty Android API definitions when restoring the historical Full route

**Task**
- Re-examine the previously successful Full SuperUnity mechanism after correcting the mistaken inference that a failed Hot replay ruled it out.

**Implemented**
- `tools/inject_definitions_to_cdb.py::parse_definitions_h` now emits `-DNAME=` for empty replacements, including values empty after comment removal. Bare `-DNAME` previously substituted `1` and could corrupt API-decorated declarations. Existing command-line definitions and preserve-exact processing are unchanged.

**Pitfalls / Gotchas**
- The historical Full pipeline had not been run on the current Android input: its Win64 discovery policy was rejected before adapting it. The separate Hot script's source omissions do not prove that Full merging cannot be restored.
- Private generation using receipt-proven Android Unity identities produces 20 historical chunks with complete source coverage. Separating known compiler/engine/exception differences produces 26 candidates. Candidate counts establish neither native correctness nor completed indexing performance.

**Validation**
- The native legacy-injection regression reproduced the failure (4/5), then passed 5/5 with zero skips. It verifies actual empty expansion, defined state, API declaration syntax, nonempty values, explicit command-line definitions, undef semantics and repeat/exact no-op behavior.
- Required-native CDB regression passed 61/61 with zero failures/skips. A representative restored Full candidate (50 UBT / 704 source members) completed installed-clangd `--check` with zero errors in 22.3121 seconds, 21.7031 CPU seconds and 2,406,883,328 bytes peak RSS. This is preliminary diagnostics, not a complete BackgroundIndex run, binding-equivalence proof or full-build performance acceptance.
- Synced `macos-ios-cdb-semantic-prepare` for legacy empty replacements. The current preserve-exact production path has no changed behavior.

**Follow-ups**
- Continue native verification of the restored Full candidates and repair evidenced compatibility defects. No production restoration or performance result is claimed by this parser fix.

### 2026-09-20 — Bound proof memory and retain candidates after a cached selection

**Task**
- Continue the unfinished SuperUnity repair using the same real six-UBT module after the proof collector exceeded its memory bound.

**Implemented**
- `tools/cdb_verified_batch.py` interns exactly equal per-file records while reading independent original graphs. URI plus structural hash selects a bucket; full equality decides sharing. Different bindings and hash collisions remain distinct, and the pool lasts only for one candidate proof.
- Pack remaining compatible originals after excluding an already selected cached group. Previously, overlap with a larger planned group also skipped its unclaimed originals.

**Pitfalls / Gotchas**
- Sharing equal immutable records saves storage; it does not replace independent compiler runs or merge different TU contexts.
- The real module still fails semantic admission. Its four removed-reference records are shared-header primary-template versus partial-specialization targets; this observation alone does not authorize ignoring them.

**Validation**
- Candidate planning reproduced a failure (34/35), then passed 35/35. Native batching passed 23/23 with zero failures/skips, covering equal-record sharing, distinct bindings and cache reuse.
- Reading the same six retained independent graphs completed in 29.6274 seconds with peak RSS 859,779,072 bytes (about 0.80 GiB). The preceding full qualification stopped after its Python process exceeded 3 GiB; these are different phases, not an end-to-end speed comparison.
- The bounded retry compiled the candidate and reached admission in 232.324274 proof seconds, then rejected four header references. Supervisor completion was 237.809671 seconds; input identity and child cleanup checks passed. No production publication or restart occurred.
- Synced `cpp-semantic-index-coverage` for remaining-candidate packing. Record interning changes representation only; the semantic admission contract is unchanged.
- Full native-required regression passed 1973/1973, zero failures/skips (`superunity-full-regression-r3.log`). Python AST checks for five affected tools and `git diff --check` passed.
- A subsequent generated-only subgroup passed the unchanged independent-original admission: five UBTs / 21 generated sources to one batch, with five original-cache hits and zero misses. Qualification took 90.9968 seconds; the earlier native collection of those five originals separately cost 102.0177 seconds. Ordinary/candidate fresh-cache native indexing completed in 35.7403/19.2364 seconds, 33.6250/16.9531 CPU seconds, and 1,186,611,200/1,148,534,784 bytes peak RSS. Standalone receipt validation and unchanged lookup cost 5.5942/5.9241 seconds; these isolated timings are not a production end-to-end measurement.
- The measurement finisher hit its overall deadline during the additional shared-graph comparison, after both native benchmarks completed successfully. Parent cleanup and all recorded input/dependency checks passed. This timeout remains a failed harness run; it does not invalidate the separately completed qualification, and no shared-graph equivalence is claimed. Earlier helper path-guard errors and their failed results are retained.

**Follow-ups**
- Production secondary count remains zero. Full-build acceleration and automatic delivery remain unverified; this entry does not record a completed repair.
- No proof-cache migration or production restart was performed. The up-front independent indexing cost still prevents this proof-first route from demonstrating the requested first-index acceleration; a smaller isolated batch is not a full-build performance repair.

### 2026-09-20 — Restore compatible SuperUnity grouping and avoid duplicate batch work

**Task**
- Resume the original SuperUnity repair after identifying the removal of actual merging in `c634947`; stop the private clangd/PCH replacement work.

**Implemented**
- Plan ordered compatible UBT chunks with an 80-source budget and an eight-UBT limit; preserve indivisible UBT groups, generated members and exact commands. Explicit qualification can subdivide semantic rejections without weakening admission.
- Resolve generated and ordinary members to one portable source module root only when their compiler-owned module directory and complete command context agree.
- Reuse independent original-TU graph evidence across candidates after native source-digest/snapshot association and complete command, input, asset and lookup checks. Failed compilation does not certify a new original cache record.
- Publish each original command exactly once across current/hot/full candidate views. Validate actual receipt content and reject overlapping or changed commands, including differing output identities.
- Preserve Clang file identity in frozen snapshots: equal header bytes do not merge distinct files, and actual aliases retain the host compiler's behavior. Revalidate the source identity when reusing evidence.

**Pitfalls / Gotchas**
- The original scripts really did merge units; reachable-branch history initially hid the older commit objects. Direct inspection confirmed the removal commit. Passing unrelated tests did not restore that capability.
- A generated `Inc/Engine` path is not a separate compiler module. On the current input, correcting this metadata increases units eligible for candidate planning from 498 to 871; this is eligibility, not accepted acceleration.
- Preserve the existing guarded candidate CDB and original semantic authority. A shared canonical cache would require coordinating every reader; it is not enabled by this change.

**Validation**
- Generator regression: 35/35 passed, including red-to-green source-budget and generated-module cases.
- Small native independent-original cache and snapshot-identity regression: 20/20 passed, zero skips. The original 17 cases remain green; three new NTFS cases compare real and frozen distinct headers, hardlinks and symlinks. POSIX identity handling has not had native validation on this host. Lightweight batch publication/activation regression: 11/11 passed after reproducing duplicate coverage.
- Current real-input generation covers all 16,536 input records with 3,402 output records: 998 UBT groups covering 14,132 members and 2,404 exact records (309 C/C++ and 2,095 shader records). It does not publish to the live editor.
- Synced `cpp-semantic-index-coverage` for chunk planning, original-evidence reuse, generated module ownership and frozen file identity. Full native-required regression passed 1970/1970, zero failures/skips (`superunity-full-regression-r2.log`). A final one-line review correction removed extra Windows case folding; all 20 native batching cases passed again with zero skips (`superunity-snapshot-identity-final.log`). Python AST checks for five changed tools, Lua AST lint for both changed index modules and `git diff --check` also passed.
- A real AndroidRuntimeSettings pair passed independent-TU admission (2 UBT / 4 members to 1 SuperUnity). Ordinary/candidate indexing was 23.6143/18.2162 seconds, but qualification took 141.3903 seconds, repeated lookup 5.9035 seconds and separate receipt validation 7.1046 seconds. This single-pair result does not establish a net delivery speedup. Raw shared-cache graphs have 30 additional candidate SymbolIDs; the independent-original comparison is a separate proof.

**Follow-ups**
- Production remains at zero secondary groups. The automatic cache-only path cannot qualify new/changed inputs; simply enabling cold proof would expose the measured setup cost. This production-path and net-performance gap is unresolved; do not report the grouping or passing tests as completed recovery.

### 2026-09-20 — Keep legacy template diagnostics usable with the selected semantic compiler

**Task**
- Resolve a reproduced LLVM 22.1 diagnostic incompatibility without hiding other compiler errors or changing build inputs.

**Implemented**
- Add a named prepare transformation after response expansion and before PCH recipe generation. It uses the actual selected clangd and admits only LLVM 22.1.x Android C++17 commands.
- Add only `-Wno-error=missing-template-arg-list-after-template-kw`; retain global `-Werror`, visible warnings, explicit per-group choices, raw provenance, sealed final commands, source membership and shader donor routing.
- Reuse existing transaction, receipt and CDB digest handling for publication and invalidation. No additional foreground/background command adapter or generation mechanism is introduced.

**Pitfalls / Gotchas**
- This diagnostic is a DefaultError independently of global `-Werror`; a general warning downgrade does not repair it.
- A source-named token may be an `-include` operand. Insert the new compiler option after the executable, preserving every original token's order, instead of splitting an option from its operand.

**Validation**
- One real original TU preserves all 1824 decoded shard records, apart from the declared Cmd option and cleared error flags. The remaining 18 affected original TUs also compile with zero errors while retaining the warning; their complete 7761-file related input closure is unchanged. This does not claim graph comparisons for those additional 18 TUs.
- A separate native precedence check verifies warning retention and the compile-time assertion with the option before global `-Werror`; a genuinely invalid non-template call is still rejected.
- Pure transformation/provenance tests pass 4/4 and configuration tests pass 11/11. Full integration validation and activation are pending the independent full-build performance measurement.
- Updated `macos-ios-cdb-semantic-prepare` and `cpp-semantic-index-coverage` to define the bounded prepare policy and distinguish retained build provenance from final sealed semantic argv.

**Follow-ups**
- The live CDB has not yet been regenerated with this transformation. Two independent missing-source failures still require correct build inputs; they are not excluded from complete index coverage. Full SuperUnity performance recovery remains unfinished.

### 2026-09-20 — Report missing build commands before querying symbol identity

**Task**
- Diagnose a live navigation probe that reported a missing symbol identity before any symbol query was sent.

**Implemented**
- Preserve the compile-command preparation failure as `unavailable/context/active-compile-command-missing`, including the original provider evidence. Explain that the selected build must include the file's module or plugin before preparing again.

**Pitfalls / Gotchas**
- The observed source was absent from both build inputs and the active database. No command was fabricated and no plugin or build selection was changed. A ready index does not establish a compiler context for every open file.

**Validation**
- Required navigation filters pass 232/232 with zero failures or skips: context 13, client 33, sidecar 31, navigation 89, utils 49, platform boundary 17. Existing LLVM is explicitly selected and native capability is required for tool-bearing groups; an initial run with two tool-discovery skips was superseded by this verified run.
- The new regression follows navigation through the real adapter and transport: preparation failure issues zero symbol queries; successful preparation with an empty identity remains a distinct identity failure. Neither case moves the cursor or jumps.
- Bare-global AST lint passes for all three changed Lua files. The existing contextual-navigation spec already requires unavailable behavior for missing commands; no spec amendment is needed.

**Follow-ups**
- The repair is loaded through the existing `UEDefReload` and its self-test passes. All 50 buffers and five windows/cursors/modified states are preserved; the clangd client and process are unchanged. Previous transaction and trace evidence were saved before the expected navigation-context reset. No new `gd` action was triggered, and the observed file still needs an actual command from an intended build. Full-build indexing performance is tracked separately below.

### 2026-09-20 — Validate prefix reuse and repair stale shard error state

**Task**
- Resume the unfinished private clangd performance experiment from the latest workspace session.

**Implemented**
- Recorded the private two-writer experiment in `docs/cpp-index-restart-investigation.md`. Kept atomic disk publication, FIFO memory updates and a maximum of two in-flight shards; retained all earlier binaries and evidence.
- Added private phase instrumentation and improved supervision diagnostics for continued measurement. The installed toolchain and production configuration were not replaced.

**Pitfalls / Gotchas**
- The four-TU native worker passed, but its outer supervisor failed with an unclassified assertion. Graph equality and cleanup success do not override that failure. An exited-handle OS experiment demonstrates a possible query failure, not its historical attribution.

**Validation**
- Private v9 builds successfully; ten actual native fixture runs pass, covering bounded overlap, guard fallback, repeated replacement, a Windows deny-DELETE failure preserving the old shard, recovery and shutdown with writers active.
- Four original TUs preserve the complete graph, commands, multiplicity and all 1679 RIFF shard bytes. One serial/two-writer sample takes 29.7873/28.2279 seconds; CPU rises from 44.6250 to 45.7344 seconds. The outer supervisor failure remains recorded; no full-build performance acceptance is claimed.
- Private v10 adds only gated phase spans: four original TUs retain the complete graph and all 1679 RIFF bytes; supervisor exit is clean, all owned processes end, and 1720 tracked inputs remain unchanged. ExecuteAction totals 17.3181 seconds: deferred work 4.1536 seconds and other frontend work 13.1645 seconds. This does not attribute the remainder to a particular parser/Sema/PCH operation.
- A separate Engine TU passes discovery, prefrozen baseline, one native producer and PCH consumption: all 2190 file graphs and RIFF bytes match, with clean supervision and unchanged inputs. Ordinary indexing is 21.6846s; PCH consumption plus construction is 26.1184s, so single-TU first use is slower. Discovery costs another 22.3054s; complete supervised validation takes 134.9717s. The remaining 221 Engine TUs and full-build performance are unverified.
- Private v11 enables bounded LLVM profiling only: all 1679 RIFF bytes and complete graphs still match, with clean supervision and unchanged inputs. Pending template instantiation covers 9.0278s of 18.2762s measured ExecuteAction time. Nested spans and asynchronous Source intervals are counted separately; this identifies a candidate path, not a completed performance repair.
- Private v12 reuses the existing body-selection predicate for a second PCH, admitted only after every prefix source has a matching error-free shard. Three tiny TUs retain all graph/RIFF data and forwarding constructor refs; partial configuration rejects before publication. An initial fixture assumption failed on the ordinary baseline and is retained, with the source-backed corrected fixture passing. Four real TUs also retain every graph/RIFF byte: consumption falls to 21.9005s, but the additional 6.3262s producer makes this four-TU use slower overall than the prior full-PCH consumer. Both supervisors and all input/artifact identity checks pass; full-build recovery remains unverified.
- The complete ten-TU Vulkan context retains all 1693 RIFF files, native commands and source coverage: ordinary indexing takes 71.8821s; fresh full/thin construction plus consumption takes 45.9036s (36.14% less). The successful supervised comparison takes 189.8538s, separately from the retained 75.1565s discovery. Earlier CDB-identity, path-comparison and Windows main-Cmd failures remain recorded; only private file locators were canonicalized, with compiler arguments unchanged. This single context does not establish full-build recovery.
- Private v13 removes an upstream inverted publication guard. A real three-TU regression first reproduces the stale live error state, then verifies clean recovery: the third TU uses the eligible thin PCH and writes one shard instead of two, with equal final graphs/RIFF bytes. The deliberate error is confined to the first test TU. Cross-TU concurrent disk arbitration remains outside this change.
- Private v14 routes an immutable manifest by complete native command identity. A five-TU/two-context run preserves all eight RIFF files, full graphs, commands and multiplicity; each context selects full then thin, and an Output-only mismatch takes ordinary indexing. Invalid schema and even an empty legacy-variable conflict reject before publication. Build, clean supervision, input and artifact checks pass. This is a routing check, not full-build performance evidence.
- The current-profile full ordinary capture covers all 1307 commands and 14441 sources, with 33211 prefrozen own shards and no unknown dependencies. Native indexing takes 1445.3528s, 9845.1562 CPU seconds and 7520575488 peak RSS. An independent audit recovers a false-positive log detector without changing original failed evidence; 21 real compile failures remain, so this is not a clean semantic baseline.
- A real one-TU diagnostic compatibility pair preserves all 1824 complete shard records, permitting only the explicit warning option in Cmd and cleared HadErrors bits. The compiler still emits the target warning, reports zero errors, and rejects an independent genuinely invalid template call. Inputs and supervised cleanup pass. This private experiment neither changes production policy nor resolves the other 20 failures.
- No production behavior/spec change; no spec amendment required. Documentation structure regression passes 78/78, with zero failures or skips.

**Follow-ups**
- Classify the remaining full-build failures, then measure a bounded multi-context candidate against a prefrozen full baseline including every producer cost. SuperUnity recovery remains unfinished.

### 2026-09-20 — Resume native PCH repair from the failed real-project gate

**Task**
- Continue the latest workspace session and resolve the remaining semantic and performance gaps.

**Implemented**
- Updated `docs/cpp-index-restart-investigation.md` with the previously unreported v6 real-project result and the non-reproducing provider-order fixture. Preserved the private experimental source, original inputs and failed evidence for continued diagnosis.

**Pitfalls / Gotchas**
- Equal file coverage and clean compilation did not imply full graph equality: 88 symbol records changed include suggestions and 266 references changed containers. One-TU candidate cost exceeded the ordinary baseline before adding PCH construction.

**Validation**
- Recovered the previous session and inspected its complete comparison report, tiny verdicts and probe dispositions. The prior 1945/1945 production regression is historical evidence only.
- Private v7: 11 positive TU pairs have exact full graphs; 3 producer and 4 consumer rejection cases pass. Real single-TU off/on graphs are equal; first-use cost including PCH remains 24.0178s versus 22.6474s. Independent v6/v7 baseline review found only 487 canonical include-suggestion changes, explicitly documented; source/definition/ref/relation fields remain identical.
- The subsequent four-original-TU run has exact full graphs (1679 files, 774783 refs), native commands and shard multiplicity. First use including PCH is 36.9399s versus 39.2978s (one sample, 6.00%); all inputs remain unchanged and no resource guard fires. This is not full-build performance acceptance; phase profiling continues privately.
- Private v8 phase profiling also preserves the complete v7 baseline and candidate graphs. First use is 39.8434s versus 41.0117s (one traced sample, 2.85%); all 1707 frozen inputs remain unchanged and owned processes exit. Shard output totals 8.7916 wall seconds, including 0.4884 seconds in serialization; individual OS-call costs remain unverified. The next bounded-writer experiment is not yet validated.
- No production behavior/spec change at this checkpoint; no spec amendment is required. Documentation structure regression passes 78/78, with no failures or skips.

**Follow-ups**
- Repair and verify both native differences, then measure real end-to-end cost including PCH construction. Full SuperUnity performance remains open.

### 2026-09-17 — Record native PCH feasibility and uncovered semantic boundaries

**Task**
- Investigate shared-prefix acceleration while retaining each original translation unit and full index coverage.

**Implemented**
- Recorded the authorized, isolated LLVM 22.1.5 experiment and its native evidence in `docs/cpp-index-restart-investigation.md`. The private compiler prototype is not installed or selected by the production configuration.

**Pitfalls / Gotchas**
- Actual PCH loading does not replay prefix macro/include callbacks. Restoring those from the same construction action makes the original and nested tiny graphs equal, but does not restore IWYU provider state.
- Context-sensitive builtin values can change even when symbol/ref/relation fields match; native errors remain a rejection condition. The invalid initial forced-include base-file expectation is retained and corrected using a separate preprocessing observation.

**Validation**
- Four positive tiny TUs have strict full raw graph equality. The expanded suite additionally ran three producers, thirteen TU servers and one preprocessing observation; used-macro mismatches reject, while sensitive builtins and five pragma provider changes expose remaining gaps.
- The follow-up private build restores all five pragma provider fields: original/nested/pragma five-TU candidates match their complete baselines. Three producer rejection cases publish no artifacts; two inactive/ordinary-macro cases retain exact graphs. This round used eight producers and fourteen TU servers, with the earlier failures preserved.
- No production runtime/spec behavior changed in this experimental checkpoint; no spec amendment is required. Documentation structure regression passes 78/78. The last production-code native full regression remains 1945/1945; it does not validate the private prototype.

**Follow-ups**
- Verify the real unguarded-prefix shape and measure representative same-process net cost. Full SuperUnity performance remains open.

### 2026-09-17 — Reuse proven noncontiguous batches and move CDB selection off the editor thread

**Task**
- Preserve usable SuperUnity groups in full inputs and remove synchronous large-CDB work from source-save delivery.

**Implemented**
- `cdb_verified_batch.py` discovers accepted ordered subsets through a bounded advisory index. Exact entry/context/cache identities and complete receipts still authorize reuse; maximum group size remains a hard limit and rejected hints retain original entries.
- `lua/ue/index/_build.lua` passes a small module selection request to the existing generator instead of parsing the active CDB on the editor thread. The isolated `build_index_subset.lua` worker reuses the original classifier and preserves entry/argv order.
- `build_clangd_index.py` stages the subset before its existing normalization/injection path. Input/parent checks, atomic publication and JSON-equivalent no-op handling protect the active CDB and prior subset; completion rejects a changed active input.
- Cold subset classification skips recursive discovery only for ordinary Unity names that cannot match any selected root basename. Direct scopes, same-name root priority, irregular-name fallback and full classification remain unchanged.
- The root agent contract explicitly says subordinate rules, specs, skills and passing tests do not waive the performance requirement without a user-directed change.

**Pitfalls / Gotchas**
- A hint is not proof. Null/list/string cache records and receipts must fall back instead of raising an uncaught exception. Automatic reuse never changes hints or starts a compiler proof.
- Moving only file reads is insufficient: the old classifier still spent 917.89 ms in a warm-input hot run and 1176.19 ms on current in an isolated real-data measurement. These are measured blocking costs, not post-fix GUI results.
- JSON object key order can differ between worker processes. Semantic equality must preserve existing bytes/mtime while array and argv order remain significant.
- A live Python parent does not prove the editor still owns the build lease. The worker checks both processes and the lease token/PID; failed or malformed temporary writes cannot replace the previous subset.
- A missing unselected Unity module accounted for 6.824 seconds of an 8.065-second cold classifier run through four recursive lookups. Moving work off the UI does not eliminate that filesystem cost.

**Validation**
- Final native-required full regression after the cold lookup fix: **1945/1945**, zero failures/skips. Collector integration 14/14, asynchronous subset tests 11/11 and structure 78/78. The editor-dispatch test failed before the change and now forbids opening the active CDB on the parent thread; four new cold-cache golden comparisons preserve original selection semantics.
- Independent review closed malformed-record, ignored-write and lost-owner defects. Real helper/generator tests cover exact selection/argv, stable output mtimes, stale inputs, an exited editor owner, a replaced lease and invalid temporary output. Actual junction aliases to the active CDB are rejected.
- The preceding 1936/1937 full run failed solely while cleaning up a temporarily locked real compiler clone. The native fixture now retries only Windows sharing-violation cleanup for at most two seconds; query-profile 6/6 and the final full run pass. The lock holder was not established.
- A fresh real four-UBT proof passed under the final collector: first proof 256.05 seconds. Full 3402-entry cache-only integration selects the noncontiguous group and keeps every member, takes 5.56 seconds and starts no proof/compiler. Maximum size two skips the group before expensive validation.
- Corrected live GUI measurement: current/hot private workers took 9.22/9.39 seconds, with 624 requested 20 ms heartbeat intervals bounded by 34.45 ms and identical ordered output. Client, buffer/cursor/changedtick, input and production state remained unchanged. This measures the subset step, not the full pipeline; its cold classifier cost differs from the earlier warm-lookup lower bound. Two rounds/four reads were made because the first probe lost heartbeat serialization; its evidence and remaining private report-handle caveat are preserved.
- After the conservative lookup filter, one matched cold hot run fell from 8.0648 to 1.2756 seconds (CPU 7.907 to 1.266 seconds; four recursive lookups to zero), with all 2589 ordered records unchanged. One later GUI hot run took 1.5691 seconds with a maximum 32.54 ms heartbeat interval; client/input/state remained unchanged and owned processes exited. Peak worker RSS remains about 1.077 GiB. These are subset measurements, not complete indexing acceptance.
- The verified `_build` loader was applied in place after full regression, preserving module/runtime/dependency identities and clangd client 7; no restart or frozen-batch activation was requested. Synced both specs and regression mappings; strict validation, lint and diff checks pass.
- Project memory now explicitly separates the historical performance target from the still-open full-index acceptance. Its navigation contract is unchanged; the cold-selection behavior is synced to the coverage spec.

**Follow-ups**
- Overall SuperUnity performance remains unaccepted. The previous Vulkan four-group proof preserves all 21 members, but first proof costs 215.63 seconds and its 3.744-second margin excludes cache delivery; a cross-volume copy alone took 43.54 seconds. No frozen live batch is enabled.

### 2026-09-17 — Verify template argument identity without rewriting index graphs

**Task**
- Distinguish different printed counter expressions from genuinely different template arguments, while retaining every other secondary-batch semantic gate.

**Implemented**
- `clangd_batch_admission.py` defers only printed template-argument differences to a dedicated compiler proof. Missing references, source/definition/relation changes and other identity/completion differences still reject first; raw graphs remain unchanged.
- `clangd_batch_bindings.py` verifies the supported LLVM 22.1.5 class-partial shape using actual FullArgv: bounded `int` values and declaration-bound type parameters, across every declaring original TU and the candidate. Unsupported, dependent, ambiguous or missing evidence fails closed.
- `cdb_verified_batch.py` checks exact requests, effective commands and context sets, seals request/result assets in receipts, and keeps cache-only reuse free of new compiler work.

**Pitfalls / Gotchas**
- A matching SymbolID or similar printed expression is insufficient. Check integer type/width before native value getters; preserve precision and actual type-parameter ownership.
- Windows spelling separators initially failed the private audit's raw string assertion. The original failed summary is retained; a separate filesystem-identity audit verified matching files, positions and facts without rerunning or rewriting the AST results.

**Validation**
- Full native-required regression: 1933/1933 passed, zero failures/skips. Focused admission 20/20, native bindings 10/10 and collector integration 13/13; new admission checks first failed before implementation.
- Actual-profile original/candidate ASTs prove all 19 previously differing declarations have equal complete typed arguments; all 3403 input hashes are unchanged. Tiny negative controls detect changed values, dependent expressions, unsupported widths, wrong bindings and missing contexts.
- Independent review found no blocking issues. Python AST/explicit whitespace checks, Lua global lint (205 files), strict semantic-index spec validation and diff checks pass. Synced `cpp-semantic-index-coverage` with this limited semantic-equivalence proof.

**Follow-ups**
- The previous five-TU Vulkan candidate still loses references and remains rejected. A separate four-TU candidate passed its own complete native proof and ordinary shared-cache comparison; delivery costs still prevent a net performance claim. Full SuperUnity performance restoration and live activation remain unaccepted.

### 2026-09-17 — Preserve compiler inputs and stop unnecessary background indexing

**Task**
- Repair the renewed large index queue and make unchanged prepare a real no-op, without trading away compiler semantics or source coverage.

**Implemented**
- `lua/ue.lua`: remove the automatic `__INTELLISENSE__` definition while retaining explicit RSP flags; stabilize source-root ordering.
- `lua/ue/cdb/transaction.lua`, `tools/cdb_transaction.py`, `pipeline.lua`, and `prebuild_pch_v2.py`: stage raw generation, transformation, partition and recipes outside monitored roots. Preserve logical PCH paths and publish only changed artifacts under the live writer lease. Manual partition/switch uses that lease; failed rollback preserves recovery backups.
- `shaders.lua`, `unity_origin.lua`, and `cdb_unity_receipt.py`: record only actually added shader donors and seal their complete final command identities. Both phase generators and `_publish.lua` route matching donors out of C++ BackgroundIndex while keeping active/semantic CDBs and existing GTAGS navigation intact. Native, modified and unproven shader commands remain eligible.
- `tools/clangd_*`, `cdb_verified_batch.py`, and `lua/ue/index/batch_*.lua`: independently compare original-TU index graphs before accepting secondary batches, including native proof of additional references, frozen input validation and scoped invalidation. Preserve a separate original semantic CDB and exact-command transport. Automatic delivery only reuses valid receipts; an uncertified query-driver profile stays on original UBT commands.
- Separate actual source-content revisions from CDB publication. Preserve pending refresh through generator completion, debounce and restart failures; acknowledge it only when a new matching clangd client attaches. Equal source bytes and prepare bookkeeping remain no-ops.
- Certify supported query-driver profiles using native driver discovery, actual cwd/environment and original main-shard commands. Binding and alias checks use FullArgv. Driver candidate/ancestor watches are nonrecursive and separate from source-tree watches; validation follows complete watcher installation.

**Pitfalls / Gotchas**
- The real ControlRig TU had 17 type errors after merely suppressing warning promotion; removing only the injected IntelliSense macro restored its generated event-parameter declarations and zero errors.
- Matching final CDB bytes does not excuse intermediate writes. Windows burst experiments produced 37 missing-filename notifications inside the watched root and zero outside; such events still fail closed.
- A historical full strategy uses Win64 Editor products, not the current Android build. An unchanged historical hot strategy lost 4,847 C/C++ inputs in the same-build replay and failed native compilation. Neither is a valid full-coverage speed baseline.
- Independent secondary proof is costly: an earlier no-query Vulkan pair took 171.51 seconds initially and 28.33 seconds to revalidate. The later actual-profile results below supersede that diagnostic proof; cold proof remains excluded from automatic delivery and no frozen live batch is activated.

**Validation**
- Native-required full regression: 1927/1927 passed, zero failures/skips. The preceding 1921/1922 run caught direct OS branching in batch activation; environment-name and directory-link behavior now use the four existing host drivers. Runtime review also fixed duplicate Windows environment keys, absolute clangd executable binding, drive-root watches and describe/validate watch-topology changes.
- Strict real unchanged prepare: 44.6932 / 44.7221 seconds, both with zero publications, zero file events and zero watcher errors, including missing-filename events.
- The same exact 16,536-record CDB is retained: 14,441 C/C++ sources and 2,095 shader compatibility records. Original C++ background workload is 998 UBT wrappers plus 309 exact commands; shader routing is provenance-based, not extension-based.
- Cold private baseline, clangd 22.1.5, eight workers: all 3,402 main records processed in 1115.23 seconds, CPU 7496.84 seconds, peak working set 10.06 GiB. All 14,441 C/C++ source shards exist; compiler-error flags remain for 1,011 sources in 21 original UBT/exact tasks. Queue completion is not a claim of error-free compilation.
- Under the same controlled benchmark profile, routing synthetic shaders leaves 1,307 original C++ commands and completes in 1028.51 seconds, CPU 6874.45 seconds, peak working set 9.05 GiB: wall time improves 7.78%, CPU 8.30%. All 14,441 C++ source shards and their error status are preserved; the same 21 C++ tasks fail. The 17,905 input files remain byte-identical. This benchmark does not include the live query-driver setting and does not demonstrate restored secondary-batch acceleration.
- Full graph equivalence remains unproven: despite equal C++ commands and source bytes, shard comparison found documentation/provider differences and reference-record differences in 54 C++ files. The relevant generated-registration SymbolID targets are not resolved by the inspected shards; do not equate source digests with complete semantic graphs.
- Live delivery retained the editor's module/runtime/watcher identities and unsaved buffers, with 74 isolated migration checks; one controlled clangd restart published 1,307 standard commands. Repeat publication took 1.97 ms, changed no bytes/mtime and kept the same client. All five historical Core targets, the extension macro and `AllocUniformBuffer` resolve definitions; the sampled Core/macro queries took 453–5296 ms during initial indexing, so responsiveness is not yet accepted.
- Follow-up live audit: 31/31 navigation requests resolve without changing source contents, UI or client identity. Retained-target repeats take 43–58 ms for three Core functions, 450/473 ms for the other two, 16 ms for the macro and 22 ms for `AllocUniformBuffer`. Target checks are 4–10 ms; the slower Core requests spend about 400 ms on source symbolInfo. Earlier no-op-jump audits deleted their temporary destination buffers and were not warm-target measurements. Profile/driver fixes were hot-reloaded after strict live preflight and 30 isolated transaction checks; the same client remained active, with no frozen activation.
- Inventory optimization preserves both scans and existing link/error semantics: 15/15 behavioral comparisons and 74 real-root digest comparisons passed. The measured double scan fell from 27.098 to 5.037 seconds; this is receipt-validation work, not an end-to-end indexing speedup.
- Under the actual live query profile, the historical Vulkan pair passes complete graph/binding proof: two original native runs total 43.8872 seconds versus 23.6882 seconds for the candidate, with all nine members retained. First proof costs 135.42 seconds and isolated cache reuse 8.41 seconds. A private full-CDB cache-only integration takes 7.47 seconds, reuses that receipt, preserves every input occurrence, and changes native entries from 1,307 to 1,306; the other 253 eligible groups remain original. No compiler or graph-proof calls run on cache reuse. These are bounded group/integration measurements, not a full-engine speedup claim.
- The live-profile five-TU Vulkan candidate compiles but is rejected: complete comparison finds 19 template-expression differences and three missing original references. Its 24.02-second native index time is not an accepted optimization.
- Correct ordinary-pair baseline: both original commands in one process and shared fresh cache take 27.4289 seconds, versus 23.6882 seconds for the candidate. The 3.7407-second saving is smaller than the 7.47–8.41-second cache-only overhead, before activation validation. The separate-cache original proof times above must not be treated as the ordinary performance baseline. This semantically accepted receipt is held outside the automatic cache lookup, with its proof assets preserved, until net performance is accepted.
- A private native refs-only repair restores one observable template reference in a tiny fixture, but does not establish performance or lifetime safety. Real AIModule owner-first indexing still loses a reference. Targeted donor screening then finds a required non-reference relation absent from the donor, so that prepared-cache candidate is rejected before production expansion. The installed 22.1.0 indexer also fails the tiny PCH control (20 errors, 21 original refs missing despite exit 0); it was not substituted for live 22.1.5. This follow-up changes evidence only, with no runtime/spec behavior change; production regression remains 1927/1927, and the documentation/entry-point check passes 78/78 with diff whitespace checks clean.
- Synced `cpp-semantic-index-coverage`, `macos-ios-cdb-semantic-prepare`, architecture and regression mappings; the shared agent constraint remains the single rule source.

**Follow-ups**
- Genuine secondary-batch performance recovery remains in progress. Actual-profile proof and runtime regression are complete, but the one certified pair does not demonstrate net acceleration. A separate frozen CDB also selects a separate native shard cache; activating one accepted pair without verified reuse would cold-index the unchanged commands, so no frozen live activation has been performed. An earlier 1,306-task experimental run was resource-aborted during external UE shader compilation and is not a completed performance result.

### 2026-09-17 — Make SuperUnity performance preservation mandatory for every agent

**Task**
- Prevent another silent loss of SuperUnity acceleration, including work performed without OpenSpec.

**Implemented**
- Put the complete performance-preservation contract near the top of the shared root `AGENTS.md`.
  Require real workload, coverage, timing and resource evidence alongside compiler correctness; distinguish
  ordinary UBT Unity from secondary aggregation, and normal baselines from already degraded states.
- Link the same contract from CONSTRAINTS C11, project memory, and the CDB/index/tools local rules.
  Preserve the existing Claude import stubs and one shared rule source.
- Add three discoverability regressions protecting the root text and required entry points.

**Validation**
- New checks first failed on all three missing surfaces; `structure` now passes 78/78, zero skips.
- Both changed specs pass strict validation; Lua global lint passes (201 files), and `git diff --check` passes.
- Synced `project-constraints-doc` and `cpp-semantic-index-coverage`; this entry changes governance,
  not runtime indexing behavior, and does not claim that historical indexing performance is restored.

**Follow-ups**
- The actual SuperUnity performance repair and real-workspace acceptance remain in progress.

### 2026-09-16 — Preserve compiler context while avoiding repeated large indexing work

**Task**
- Repair the renewed 12456-task clangd queue and verify the actual generated workload.

**Implemented**
- Capture compiler RSP/nested RSP/unity membership outside native CDBs; seal exact final commands only
  after a successful writer pipeline, and revalidate that evidence before grouping transformed commands.
- Preserve exact fallback on stale evidence or semantic conflict, including Apple responses that exist
  but do not match. Fix Windows response leading whitespace and multiline parsing.
- Remove sampled include pruning from default prepare: two dropped search paths were independently
  shown to introduce Vulkan type/member errors. Keep source/RSP ordering and bucket selection deterministic.
- Reuse stable wrapper paths across phases; skip identical CDB/marker/wrapper writes. Roll back paired
  CDB/marker write failures and reject artifacts that no longer match their successful manifests.
- Compare successful final command digests across prepare runs; unchanged commands do not restart clangd.
  Cache verified publication signatures without retaining large argv tables, and report actual Unity/exact counts.

**Pitfalls / Gotchas**
- Original response flags and processed editor flags are not interchangeable evidence. Ignoring their
  differences would have hidden semantic errors; receipt validation preserves both provenance and final argv.
- A generated full database does not prove clangd has completed background parsing.

**Validation**
- Native-required full regression: 1760/1760 passed, zero skips. Lua lint and Python compilation passed.
- Two independent production prepare replays: 16535 active sources covered by 3401 commands
  (998 Unity + 2403 exact); second final digest identical, zero restart requests, 1004 artifacts unchanged.
- Native String source and both representative Unity wrappers: zero diagnostics. Vulkan source retains
  exactly the same seven existing unused diagnostics as the previous live CDB; the new type errors disappear.
- Synced `cpp-semantic-index-coverage`; local CDB/index ownership documentation updated.
- Live editor: published 3401 commands / 998 Unity; hot completion retained the full baseline and the same
  clangd client. A repeat publication returned `changed=false` in 0.25ms. Private and generic privacy scans passed.
- Live compiler-owned navigation: extension macro resolved in 46ms; after its exact source command became
  ready, `AllocUniformBuffer` resolved in 27ms with destination identity validation.

**Follow-ups**
- First publication after a content change still performs synchronous decoding; unchanged repeated publication
  performs no JSON reads. Existing same-platform multi-architecture selection and five unclassified C sources
  remain separate limitations. Original investigation and sanitized evidence: `docs/cpp-index-restart-investigation.md`.
- Background shard production is still in progress; five previous Core cross-file definition gaps were
  still unavailable at sampling. The initial cold `AllocUniformBuffer` miss was subsequently resolved.

### 2026-09-16 — Explain the renewed large clangd indexing queue

**Task**
- Investigate why the current editor reports indexing 12456 tasks again.

**Implemented**
- Added `docs/cpp-index-restart-investigation.md` with the live prepare/restart timeline,
  actual current/hot/full CDB counts, rejected Unity grouping evidence and source-shard coverage sampling.

**Pitfalls / Gotchas**
- Restoring prepare delivery does not prove background indexing is finished or compressed.
- The actual published CDB has 16541 independent sources and zero Unity wrappers; old cache files
  include headers, and at least 11523 uniquely named sources had no corresponding source shard at sampling.
- The existing super-unity progress wording is inaccurate for this run. Task count is not edited-file count.

**Validation**
- Read-only live RPC/process/state/CDB/marker/cache inspection and installed-version clangd source comparison.
- Documentation structure regression 75/75 passed; `git diff --check` passed. No spec impact and no runtime code changes.

**Follow-ups**
- Repair compatible Unity grouping and validate background cache completion separately; do not bypass semantic input checks.
- No cache deletion, prepare, compiler restart or process termination was performed during this investigation.

### 2026-09-15 — Follow active distributed build output without interrupting log reading

**Task**
- Fix the streamed log staying at the initial configuration output while compilation advances below it.

**Implemented**
- `lua/ue/workflows/android/distributed.lua` follows appended output only for log windows already
  at the last line. Readers who scroll up retain their position; tail following survives bounded history trimming.

**Pitfalls / Gotchas**
- A successful process does not imply its completion output was visible; the previous buffer append never advanced the cursor.

**Validation**
- The new tail-follow assertion reproduced the failure before the fix; `ue_distributed` then passed 9/9,
  including scroll-up preservation and tail following after 5000-line retention.
- Related checks passed: `ue_workflows` 24/24, `ue_target_tasks` 8/8, `ue_platform_boundary`
  17/17, `stability` 10/10, `structure` 75/75, and `git diff --check`.
- Synced the log behavior into `ue-target-workflow-boundary` spec; no real build was launched for this fix.

**Follow-ups**
- The external runner owns task names, execution locations and final build summaries.

### 2026-09-15 — Preserve distributed build configuration across editor restarts

**Task**
- Fix new editor instances failing to find the executor when their parent process has stale environment variables.

**Implemented**
- `lua/ue/workflows/android/distributed.lua` resolves `script`, `worker_config`, and `python`
  from `stdpath('data')/ue-builddispatch.json` on each invocation. Nonempty editor globals override
  environment variables, which override JSON. Python finally defaults to `python`.
- The local file remains outside the public configuration. Invalid JSON, nonobjects and invalid
  selected field types produce explicit errors; an absent file is normal.

**Pitfalls / Gotchas**
- A user environment registry update does not update an already running terminal's inherited environment.
  The earlier successful live Plan therefore did not prove a newly opened editor could find the runner.

**Validation**
- `ue_distributed`: 9/9 passed, including restart-style module reload without globals/environment,
  per-invocation reread, precedence, empty overrides, malformed JSON and absent files.
- Related checks passed: `ue_workflows` 24/24, `ue_target_tasks` 8/8, `ue_platform_boundary`
  17/17, `stability` 10/10, `structure` 75/75, and `git diff --check`.
- Live editor Plan succeeded with both script global and environment variable absent, using the local JSON fallback.
- Synced the persistence behavior into `ue-target-workflow-boundary` spec.

**Follow-ups**
- Real build execution remains separate from configuration and Plan verification.

### 2026-09-15 — Run distributed Android builds from the active editor selection

**Task**
- Provide an opt-in external build executor without repeating engine/project configuration.

**Implemented**
- `lua/ue/build_snapshot.lua` captures the current planner's exact arguments, workspace,
  target and selected configuration, retaining project SDK flags and an action-export placeholder.
- `lua/ue/workflows/android/distributed.lua` registers `:UEBuildDistributed` and
  `:UEBuildDistributedPlan`; `lua/ue/target_tasks.lua` passes JSON stdin to the async runner.
- Configure the external `build_android.py` through `NVIM_UE_BUILDDISPATCH` or
  `vim.g.ue_builddispatch_script`. Optional worker config uses `NVIM_UE_BUILDDISPATCH_CONFIG`
  or `vim.g.ue_builddispatch_worker_config`; Python defaults to `python` and is overridable
  through `vim.g.ue_builddispatch_python`.
- With no arguments, both commands reuse current selection. Explicit
  `:UEBuildDistributedPlan Android Development` previews an invocation without changing
  editor selection. The build command accepts the same arguments. Output opens in a bounded
  log buffer; `:Tasks` / `:TaskStop` use the existing process registry.

**Pitfalls / Gotchas**
- The runner owns synchronization, compilation and full disk logs; this bridge exports no P4
  credentials and never runs P4 login or sync. The workspace path identifies the selected checkout.
- Plan mode does not run build preflight. Existing local build entrypoints remain available;
  concurrent builds in one editor are rejected, and prepare sees distributed builds as active.
- Existing unrelated changes and previously dispositioned probe failures were preserved.

**Validation**
- Full regression: 1694/1694 passed; final bounded-stream changes additionally passed
  `ue_distributed` 6/6 and `ue_target_tasks` 8/8. Architecture boundary 17/17 and
  `git diff --check` passed. No formatter/linter executable was installed.
- Initial full regression exposed one direct concrete workflow import from the facade;
  moved command setup to the existing workflow bootstrap and verified zero boundary exceptions.
- Synced the external executor behavior into `ue-target-workflow-boundary` spec.

**Follow-ups**
- Full remote UE build remains a separate execution check; plan validation does not prove compilation.

### 2026-09-11 — Keep project SDK mappings outside the public mirror

**Task**
Preserve local SDK selection while removing private identifiers from public code, fixtures and documentation.

**Implemented**
- Define the external JSON policy selected by `ue.config`'s `android.sdk_policy_file`, defaulting
  to `stdpath('state')/ue-android-sdk-policy.json`; its fields are `config_file`, `key`, and `disable_argument`.
- Normal builds append the policy's actual argument; SO builds use generic `-SdkArgument` forwarding;
  metadata exposes the `sdk_disabled` boolean. Public examples use `Config/SDK/Runtime.ini`,
  `UseSDK`, and `-skip-project-sdk` only.
- Sanitize the release's incident/log summary and K71 navigation; preserve historical test counts
  and mark them as preceding this migration. Actual mappings belong outside the worktree.

**Pitfalls / Gotchas**
- Removing private data from public source requires external configuration, not renamed, encoded,
  or assembled private identifiers that evade the scanner. Normal privacy hooks remain required.
- Missing policy preserves the Target default; invalid policy fails. Migration must verify that
  each existing checkout still receives its intended argument from the external mapping.

**Validation**
- Spec synchronized: `ue-target-driver-boundary` and `android-so-quick-deploy`.
- Migration documentation checks: `structure` 75/75 passed, zero failures/skips; both changed
  specs passed strict OpenSpec validation; scoped `git diff --check` passed.
- Migration acceptance: `ue_target` 91/91; final full suite with `NVIM_TEST_REQUIRE_NATIVE=1`
  1638/1638, zero failures/skips, exit 0. Five-file AST lint passed.
- Both real local checkouts preserved their original disable argument in new-process normal/SO plans.
- Worktree-added-content review passed both private and generic scanners with no findings;
  normal commit/ref privacy hooks remain enabled for the commit.

**Follow-ups**
- Real mappings were installed outside the worktree. The running editor did not return its update
  request, so in-process migration is unverified; next startup loads the verified files and policy.

### 2026-09-11 — Explain the first SDK-disabled rebuild from live evidence

**Task**
Explain why the user's next Android build recompiles after the SDK-argument repair.

**Implemented**
- Append live command, UBT makefile invalidation, 1214-action count and global-macro/PCH
  evidence to `docs/release_1.11.2.md`; record the omitted rebuild-cost explanation.

**Pitfalls / Gotchas**
- A global compiler definition affects engine PCHs/modules. Argument propagation is not
  a promise of an incremental first build; the log does not explain every action individually.

**Validation**
- Read-only live terminal, process argv, Target source, Core PCH/RSP and UBT source checks.
- Documentation structure regression: 75/75 passed, zero failures/skips. No spec impact:
  investigation only, no behavior change.

**Follow-ups**
- No subsequent unchanged build has been observed; current user build is left running.

原始修复及外部策略迁移见 [1.11.2](release_1.11.2.md)；脱敏后的最终全量回归 1638/1638，spec 已同步。
