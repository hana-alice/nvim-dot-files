# C++ navigation entity audit — 2026-09-15

The live failure for `VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME` was a local rejection of a valid compiler result.
clangd returned `vulkan_core.h:13664`; the coordinator rejected it because `symbolInfo` contained no definition range.
The previous `AllocUniformBuffer` repair verified a function call, but did not establish that macros or aliases worked.
That verification gap is corrected here with a compiler entity matrix and a real-file audit.

## Evidence and repair

- Clang 22.1.5 `getSymbolInfo()` reports macro identity without declaration/definition ranges. `locateSymbolAt()`
  gives the macro priority over its expansion, and `locateMacroReferent()` treats its definition as the navigation target.
  The adapter now preserves that relation rather than requiring a range that the provider does not produce.
- Alias/namespace references can include both written and underlying identities. Exact-position `textDocument/ast`
  proves `Typedef/type` or `Namespace/specifier`; a unique destination joined to the same client's declaration evidence
  selects the written entity. The result remains `declaration-resolved`, not a fabricated function body.
- Identity, AST and destination are joined by client ID. Missing or conflicting clients cannot contribute evidence
  to another client's identity. Macro identification follows complete compiler USR framing; namespace/class names
  such as `macro` cannot accidentally promote ordinary declarations.
- Source definition ranges are checked before clangd's definition-to-declaration toggle. Being at the definition now
  reports `already-at-definition` without moving or blaming index coverage. Built-in macros without a navigable
  source location report `macro-no-source-definition`.

Compiler references: [clangd 22.1.5 XRefs.cpp](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.5/clang-tools-extra/clangd/XRefs.cpp),
[macro USR generation](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.5/clang/lib/Index/USRGeneration.cpp).

Changed runtime owners: `clangd_adapter.lua`, `clangd_referent.lua`, `lsp_transport.lua`,
`semantic_navigation.lua`, `semantic_transaction.lua` and `semantic_report.lua` under `lua/utils/ue_goto/`.
The contextual-navigation spec and architecture notes describe the resulting role contract.

## Verification method

The live audit enumerates compiler semantic tokens across `VulkanLayers.cpp` and deduplicates by token kind and spelling,
preferring a reference over a declaration where both exist. This gives 312 symbol positions, not every occurrence or
every possible overload. Each case uses the actual exact-command provider and source coordinator, with an isolated
action snapshot and a recording jump hook. It leaves user windows and source text unchanged. Dry-run resolution is
distinct from an actual editor jump, which is checked separately for the reported macro.

The initial run produced 194 definition resolutions, 94 definition-not-found results, 11 identity conflicts,
9 index-incomplete results and 4 missing identities. The final same-file run produced:

| Outcome | Positions | Evidence |
|---|---:|---|
| Definition resolved | 279 | Includes all 84 source-backed macro references |
| Alias/namespace declaration resolved | 12 | Compiler AST classification and same-client identity/location join |
| Already at definition | 8 | Source range proves current position; no jump |
| Built-in macro without source | 2 | `__FILE__`, `__LINE__` |
| Pure virtual declaration without selected body | 2 | `IConsoleManager::FindConsoleVariable`, `IConsoleVariable::GetInt`; headers explicitly contain `= 0` |
| Compiler identity unavailable | 4 | `Error`, `Display`, `Warning`, `Log` in `UE_LOG` expansions; no canonical USR was returned |
| Existing Core body not reachable through index | 5 | Detailed below; unresolved, not counted as passed |

The 291 resolved dry runs had median 49 ms and p95 158 ms; the slowest took 8312 ms, so this is not an all-requests
latency guarantee. Individual index results can change as clangd warms; counts describe the recorded run.
The local detailed response artifacts remain under the ignored
`.omx/state/macro-navigation/` directory; private project paths are omitted from this public report.

Native regression covers object/function/type-expanding macros, typedef/using aliases, namespaces and namespace aliases,
fields, enum constants, parameters, complete classes, inline and out-of-line functions, definition-self behavior,
pure declarations, forward classes, extern variables, ambiguous overloads, built-in macros, and ordinary entities in
a namespace/class named `macro`. Protocol tests cover per-client identity joins, missing/mismatched evidence and cancellation.

- Native entity and protocol matrix: **35/35**, zero skipped.
- Native full suite: **1686/1686**, zero failed/skipped. An earlier concurrent run failed one documentation-reference
  assertion because this report had not yet been written; after the file existed, structure **75/75** and the repeated
  full suite passed. The failed run is retained in the local evidence directory.
- Eight changed Lua files passed AST bare-global lint; new module/tests passed StyLua. Strict contextual-navigation
  spec validation and `git diff --check` passed.
- Actual editor jump: `VulkanLayers.cpp:716:70` → `vulkan_core.h:13664:8`, macro USR preserved, `definition-resolved`,
  708 ms. One `Ctrl-O` returned to `VulkanLayers.cpp:716:70`. The dry-run target query itself took 58 ms.
- Navigation/performance observation revision `compiler-referent-kinds-2026-09-15` is armed. The reported macro failure
  was resolved with this evidence without deleting probe history.

## Remaining Core index gap

`FPaths::ConvertRelativePathToFull`, `FAndroidMisc::GetEnvironmentVariable`, `FString::ParseIntoArray`,
`FParse::Param` and `FParse::Value` still returned only declarations in the recorded follow-up.
Their bodies exist at `Paths.cpp:1321`, `AndroidPlatformMisc.cpp:615`, `String.cpp:963` and `Parse.cpp:288/554`.
This is an index/compile-context issue owned by the controlled clangd coverage path, separate from entity-role classification.

Evidence collected without modifying engine/project sources:

1. The actual background CDB contains 16532 entries, including 504 Core entries and all four body files. For each body,
   the active and background CDB have identical directories and 72-element argument arrays. A generator argv mismatch
   is therefore not established by these current files.
2. At inspection time, three body shards were absent. The `String.cpp` shard had `IsTU | HadErrors` source flags;
   its body SymbolID differed from the caller's identity. An existing shard is not proof of valid semantic coverage.
   The correct USR hashes to `E2479699115CE5CC`; substituting recovery type `int&` for the array parameter hashes to
   the shard's `911813D299831052`. Together with `HadErrors`, this supports an erroneous background AST rather than a
   TCHAR mismatch. The cause of that AST divergence remains unverified without its original diagnostics.
3. Bounded foreground exact-command parsing returned the same USRs as the callers for the four requested entities.
   `Paths.cpp` and `String.cpp` had no error-severity diagnostics in that request; `AndroidPlatformMisc.cpp` and `Parse.cpp`
   had other compile errors. This does not prove the whole Core module is healthy.
4. clangd changed from client 2 to client 3 during this investigation; the trigger was not established. A subsequent
   five-position query against client 3 still returned only declarations. Opening the bodies was not a durable repair.

Follow-up acceptance: establish why background and exact foreground identity differ despite the current matching
commands, repair that owner, and re-run these five source calls with matching body USRs. Do not substitute text-search
locations or report these declarations as definitions. The four macro-expansion identity misses likewise remain explicit.

## Boundaries

Function declarations, extern variables and incomplete types still require genuine definition evidence. No text search,
workspace symbol, filename heuristic or standalone header parse is used to invent a destination. Unknown AST kinds,
including alias-template forms not proven by this classifier, remain conservative. The audit does not claim full-engine
or every-occurrence coverage. Current live semantic coverage is HOT.
