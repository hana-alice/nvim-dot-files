# hana-alice/nvim 1.11.3 — Align Espresso and restore compiler-owned navigation

> 日期：2026-09-15
> 类型：Patch（既有主题适配与 C++ 语义跳转修复）
> Git tag：未创建；本次用户授权 sync、archive、commit、push。

## 范围与隔离

本次只归档本线程的 Espresso 主题、prepare/PCH/provider 修复和宏/alias 导航审计。
工作区的分布式构建修改以及 package 文件保持未提交。共享 `lua/ue.lua` 只收录一个交付调用；
共享 changelog 只归档下列三条。原始响应、工作站路径、probe 文件和 `.omx` 日志不发布。

主规格已同步：`curated-theme-entrypoints`、`cpp-semantic-highlighting`、
`cpp-contextual-definition-navigation`、`cpp-semantic-index-coverage`。
OpenSpec 归档分别为 `match-vscode-espresso-theme` 与 `repair-compiler-owned-navigation`。

## 发布验证

- 既有本线程 native 全量回归：1686/1686，0 failures/skips。
- 实体/协议矩阵：35/35；真实文件审计和未解决项见 `docs/cpp-navigation-kind-audit.md`。
- 本次暂存提交树导出到隔离 config 后，全量回归 **1686/1686**，0 failures/skips；只加载待提交代码，未包含分布式构建修改。
- 18 个本线程 Lua 文件通过 AST bare-global lint；4 个主 spec 与 2 个 change 严格验证通过，6 个归档 requirement 块与主 spec 一致。
- 暂存区 private denylist 和通用隐私扫描通过；commit/ref/push 继续执行正常 Git hooks，审计日志仅留在 Git directory。
- 5 个 Core 函数索引缺口、4 个宏展开身份缺失仍未解决；本版本不宣称全引擎导航完成。

## 归档工作记录

### 2026-09-15 — Accept compiler macro and alias referents and audit real C++ navigation

**Task**
Fix `VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME` reporting `semantic definition unavailable`, and proactively scan the current C++ file.

**Implemented**
- `lua/utils/ue_goto/clangd_referent.lua` and `clangd_adapter.lua`: preserve clangd's unique macro identity before its expansion; prove alias/namespace roles with exact-position compiler AST and join destination/USR evidence separately for each client. Complete USR framing avoids misclassifying ordinary entities inside a namespace/class named `macro`.
- `lsp_transport.lua`: send a zero-length snapshot range for bounded `textDocument/ast` requests using existing encoding, exact-command preparation, cancellation and freshness checks.
- `semantic_navigation.lua`: retain definition-self evidence before clangd toggles to a declaration; resolve alias/namespace declarations with an honest role, and distinguish built-in macros without source locations. Removed premature self-location filtering in the source route.
- `semantic_transaction.lua` and `semantic_report.lua`: explicit declaration/macro reasons, compiler referent in Explain, and observation revision `compiler-referent-kinds-2026-09-15`.
- Added 23 real-clangd entity cases and 12 per-client evidence/cancellation cases. Updated contextual-navigation spec, architecture, K73 and the [field audit](cpp-navigation-kind-audit.md).

**Pitfalls / Gotchas**
- The previous function-only live check did not prove macro/alias navigation. clangd `symbolInfo` omits macro ranges and can include underlying identities; those are not inherently missing definitions or overload ambiguity.
- Real-file audit has 312 deduplicated compiler-token positions, preferring references. Final results: 279 definitions + 12 valid alias/namespace declarations, 8 already-at-definition, 2 built-in macros, 2 pure virtual declarations, 4 macro-expansion identity misses and 5 unresolved Core index destinations. All 84 source-backed macros passed; the audit does not claim every occurrence or the whole engine.

**Validation**
- Native full suite **1686/1686**, zero failures/skips; focused entity/protocol matrix **35/35**, structure **75/75**. One earlier full run hit a missing report link while the report was being written; the completed documentation passed the repeat full run.
- Eight-file AST bare-global lint, new module/test StyLua checks, strict contextual-navigation spec validation and `git diff --check` passed. Spec behavior synchronized.
- Current Neovim actual `gd`: `VulkanLayers.cpp:716:70` → `vulkan_core.h:13664:8`, same macro USR, `definition-resolved`, 708 ms; one `Ctrl-O` returned to source. Dry-run median/p95 for the 291 resolved positions: 49/158 ms.
- Navigation/performance revision armed; original macro failure resolved with live evidence, history preserved. Unrelated csearch bookkeeping records explicitly deferred to their owner.

**Follow-ups**
- Five Core functions have real bodies/exact commands but incomplete or erroneous background-index evidence; foreground body inspection did not durably repair their source calls. Four `UE_LOG` argument positions have no returned canonical USR. Both groups remain documented unresolved in the field audit, not counted as successful navigation.
- No dependencies, engine/project source edits, commits or tags.

### 2026-09-14 — Restore prepared C++ navigation and verify cross-TU definitions

**Task**
Repair `AllocUniformBuffer` reporting `provider method unsupported` after a successful prepare.

**Implemented**
- `lua/ue.lua`: successful asynchronous cold finalization now calls `schedule_prepare_delivery` before checking clangd readiness. The regression extracts and executes that actual callback, covering pending, failed and successful CDB completion instead of counting callsites across unrelated branches.
- `lsp_transport.lua`, `semantic_navigation.lua`, `semantic_transaction.lua` and `semantic_report.lua`: distinguish no eligible attached client from unsupported capability, retain method/client evidence, and report missing/stale index readiness with an actionable explanation.
- `clangd_destination.lua`: verify out-of-line source destinations with the same clangd client, exact target compile command, matching USR and a definitionRange at the target. Keep original action and target-buffer freshness checks; do not jump for declarations, identity conflicts or stale results. Unused temporary buffers are cleaned without discarding edits.
- `tools/prebuild_pch_v2.py`: generate recipes without adding unbuilt binary PCH inputs; repair only missing generator-owned adjacent binary/text pairs supported by an existing matching recipe and header. Preserve external PCH semantics and unchanged CDB bytes. Removed the old premature injection loop.
- Updated navigation/index specs, architecture notes and K72. Existing theme changes remain separate.

**Pitfalls / Gotchas**
- Live report initially showed zero LSP clients, missing coverage, and zero index delivery runs despite an existing 227,873,263-byte active CDB. Cold completion omitted scheduling; the previous global call-count test missed the branch.
- Subsequent HOT/FULL failures exposed 6,503 missing binary PCH references added by the recipe generator. Its old comment claiming automatic text fallback was false: real Clang rejects a missing explicit binary PCH even when the text include is present. Current input validation remains strict.
- `symbolInfo` uses the queried AST and does not consult the background index ([clangd extension contract](https://clangd.llvm.org/extensions#symbol-info-request)). Source identity plus a returned location was not yet complete proof: an independent Clang 22.1.5 fixture and the live target confirmed the same USR and body at the destination.

**Validation**
- Before the cold-path fix, the new actual-callback regression failed: expected `delivery,clangd`, got `clangd`; afterwards `index_delivery` 88/88 passed.
- Native full regression: 1651/1651 passed, zero failures/skips, including legacy jumper, with `NVIM_TEST_REQUIRE_NATIVE=1` and LLVM 22 clangd. After the final report/native-skip adjustment, focused `ue_goto_behavior` 52/52 passed.
- Eleven-file AST bare-global lint, new destination-module StyLua check, Python syntax compilation and `git diff --check` passed. Both changed specs passed strict OpenSpec validation; structure checks cover the updated references.
- Live recovery held the active CDB writer lease and repaired 6,503 proven generated PCH pairs. HOT/FULL generation then completed successfully; selected coverage remained HOT (13 modules), so this is not a full-coverage readiness claim.
- Actual editor `gd`: `VulkanUniformBuffer.cpp:165:16` → `VulkanMemory.cpp:4074:22`, `state=resolved`, `reason=definition-resolved`, role `definition`, one provider/location, matching USR, 508 ms. First injected attempt was correctly cancelled after cursor movement; the stationary retry succeeded.
- Probe revision `source-delivery-definition-2026-09-14` is armed for navigation/performance. The recurring unsupported/missing and performance/missing records were resolved with the live result, without deleting history. Fixture success, armed observation and this one live navigation are separate evidence.

**Follow-ups**
- Full background generation succeeded, but selection currently retains HOT coverage; definition verification is proven for this call and native regressions, not every engine symbol.
- The running editor received navigation hot reload and explicit delivery recovery. The cold-prepare branch repair loads normally in future Neovim processes; no broad reload of the UE runtime was attempted.
- No build/package/install operation, commit or tag was requested or performed.

### 2026-09-14 — Match the active VS Code Sonokai Espresso theme

**Task**
Reproduce the user's active VS Code theme in Neovim, using the installed Sonokai Espresso 0.2.9 color definitions and live window captures as reference.

**Implemented**
- `lua/sonokai_vscode.lua` adapts editor, selection/search, popup, picker, tab and mini.statusline colors; RGBA backgrounds are composited onto the editor background.
- `lua/highlights.lua` applies the adapter only for Espresso and maps C/C++ fields/locals to white, parameters to orange, functions to green, types to cyan and enum members/macros to purple. Plain comments and keywords no longer receive forced italic/bold; built-in types and storage modifiers retain syntax italics.
- Reuse the existing Sonokai dependency and six-entry registry. No new plugin or theme alias.
- `tests/cases/theme_spec.lua` checks exact source RGB, composed backgrounds, style boundaries and existing theme-switch contracts.

**Pitfalls / Gotchas**
- The earlier global semantic mapping intentionally separated fields from locals, unlike this VS Code theme. Espresso now has an explicit exception; other themes retain their contract.
- The running editor's module cache initially missed the new Lua file during live reload. Explicitly loading that file recovered the existing process; independent full startup loaded it normally. No cache workaround was added to runtime code.
- Report-first: historical csearch reset (six events), dirty-cap (nine events), scan-root and semantic probe evidence was retained and deferred for separate index/watcher investigation; this color-only change does not verify or repair those systems.

**Validation**
- `theme` 12/12, `smoke` 19/19 and `structure` 75/75 passed; zero failures/skips.
- Three-file AST bare-global lint, new-module StyLua check and `git diff --check` passed.
- Full `init.lua` startup, including delayed plugin loading, verified Espresso colors. Live Neovide RPC confirmed the applied field/comment highlights and one semantic ColorScheme callback; before/after captures were inspected.
- Synchronized `curated-theme-entrypoints` and `cpp-semantic-highlighting`; both passed strict OpenSpec validation. No registry/default-theme change.

**Follow-ups**
- Fonts, rainbow bracket coloring and syntax-provider classification remain editor-specific. Some CJK comment glyphs look slanted in the live capture despite verified non-italic attributes; rendering cause is unverified. No pixel-identical rendering claim.
- Scoped color adjustment remains Unreleased; no commit, release or tag requested.
