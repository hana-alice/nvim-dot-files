# UEPrepare: incremental csearch + semantic-goto pipeline

- **Status**: Draft (planning only — no implementation yet)
- **Branch**: TBD (to be cut from `main` when work starts)
- **Owner**: <USER>
- **Created**: 2026-05-07

## Predecessors

- [`2026-05-07-cdb-pipeline-split.md`](./2026-05-07-cdb-pipeline-split.md) — `ue/cdb/` already owns `compile_commands.json` generation; this plan reuses that pipeline rather than duplicating it
- [`2026-04-17-instant-goto-architecture.md`](./2026-04-17-instant-goto-architecture.md) — tier-2 goto engine in `lua/utils/ue_goto/`; this plan adds a complementary text-tier (csearch) below the semantic tier (clangd)
- [`2026-05-07-config-schema-expansion.md`](./2026-05-07-config-schema-expansion.md) — `ue.config` schema; new `csearch.*` and `prepare.*` keys land here

## Context

Today the user runs three separate commands to get a UE project ready for editing:

1. `ueprepare` — generates `*.sln` / `.uproject` parsing / Intellisense metadata
2. `uebuild` — full UBT compile + link (minutes; produces `.dll`/`.exe` we don't need for editing)
3. `ueindexfull` — symbol index for nvim

Two problems:

1. **`ueindexfull` depends on `uebuild` artifacts** — specifically the per-module `.rsp` files and UHT-generated `*.generated.h`. These are written during UBT's *preparation* phase, **before** `cl.exe`/`link.exe` are invoked. So `uebuild` is paid in full just to harvest preparation-stage byproducts.
2. **Nothing is incremental at the orchestration layer.** Each tool has internal incrementality, but the user's workflow re-runs all three end-to-end, blocking the editor for minutes.

Goal: a single `:UEPrepare` nvim command that drives the full pipeline incrementally, asynchronously, with visible progress, **without invoking the C++ compiler**, and lands at the state where:

1. `csearch -l "FString"` returns in well under a second across the whole repo (project + engine)
2. clangd does AST-level goto-definition, completion, and find-references on any `.cpp`
3. Re-running after a `.cpp` body edit completes in < 5s (incremental hit)

## Decision

Build `lua/ue/prepare/` as a coordinator module that orchestrates a 6-step DAG, persists a per-project fingerprint in `<project>/.ueprepare/state.json`, runs steps via `vim.system` (async), and renders a floating-window progress UI. The C++ build is replaced with `UnrealBuildTool ... -SkipBuild` (fallback `-XGEExport`) so we get `.rsp` + UHT artifacts without compiling.

**Non-goals**:

- Not replacing `ueprepare` / `ueindexfull` themselves — we *call* them, preserving their current behavior (the "all" requirement).
- Not removing `uebuild` from the user's toolbox — it's still needed to actually run the editor; this command is for the **edit-only** workflow.
- Not adding a new LSP — we feed the existing clangd that `ue/cdb/` already configures.

## Architecture

### Step DAG

```
            [S0 detect changes]
                   │
        ┌──────────┼──────────┐
        ▼          ▼          ▼
   [S1 project]  [S2 UHT]  [S3 csearch]
   ueprepare     UBT          cindex
   (existing)    -SkipBuild   (incremental)
        │          │          │
        └──────────┤          │
                   ▼          │
            [S4 rsp→ccjson]   │
            (reuses ue/cdb/)  │
                   │          │
                   ▼          │
            [S5 clangd reload]│
                   │          │
                   └────┬─────┘
                        ▼
                 [S6 verify smoke]
```

S1, S2, S3 are independent and run in parallel. S4 depends on S2. S5 depends on S4. S6 gates "done".

### Step responsibilities

| Step | Responsibility | Owns / Produces | Async tool |
|---|---|---|---|
| S0 | Read `state.json`, hash inputs, decide which steps to skip | `state.json` (read), step bitmask (write to coordinator) | sync, fast |
| S1 | Wrap existing `ueprepare` — preserve all its current behavior | `*.sln`, `.vcxproj`, IDE metadata | `vim.system` |
| S2 | `UnrealBuildTool <Proj>Editor Win64 Development -Project=... -SkipBuild` | `*.generated.h`, `*.gen.cpp`, `<Module>.rsp`, no `.obj`/`.lib`/`.dll` | `vim.system` |
| S3 | `cindex` over `Source/`, `Plugins/`, engine `Source/`, engine `Plugins/` | `<project>/.ueprepare/csearch.index` | `vim.system` |
| S4 | Translate `.rsp` → `compile_commands.json` (delegate to `ue/cdb/pipeline.lua`) | `compile_commands.json` | `vim.system` (python helper) |
| S5 | Restart clangd / send `workspace/didChangeConfiguration` | clangd in-process state | LSP API |
| S6 | Run smoke tests (csearch query, ccjson parse, clangd diagnostic on canary file) | exit code → state.json mark | `vim.system` |

### Module layout (proposed additions)

```
lua/ue/prepare/
├── init.lua          # public surface: prepare.run(opts) / prepare.cancel()
├── coordinator.lua   # DAG scheduler, joins step jobs, owns state machine
├── state.lua         # read/write .ueprepare/state.json, fingerprint diff
├── progress.lua      # floating window UI (spinner + per-step bars)
├── steps/
│   ├── s1_projectfiles.lua
│   ├── s2_uht_rsp.lua
│   ├── s3_csearch.lua
│   ├── s4_ccjson.lua   # thin wrapper around ue/cdb/pipeline.lua
│   ├── s5_clangd.lua
│   └── s6_verify.lua
└── parsers.lua       # progress regex per step (UBT [n/N], cindex per-file, ...)

scripts/ueprepare/
├── rsp_to_ccjson.py  # if ue/cdb/pipeline.lua doesn't already cover .rsp ingestion
└── verify_smoke.sh
```

`lua/ue/config.lua` schema additions:

```lua
{
  prepare = {
    enabled              = true,
    ubt_skipbuild_flag   = "-SkipBuild",   -- fallback "-XGEExport"
    parallel_steps       = true,
    progress_ui          = "floating",     -- "floating" | "statusline" | "off"
  },
  csearch = {
    cindex_bin           = "cindex",
    csearch_bin          = "csearch",
    index_path           = ".ueprepare/csearch.index",  -- per-project, repo-relative
    include_engine       = true,
    include_engine_plugins = true,
    extra_paths          = {},
  },
}
```

### Incremental decision matrix (S0 logic)

`state.json` records the last successful run's fingerprint:

```json
{
  "uproject_hash":      "sha256:...",
  "build_cs_hash":      "sha256:...",
  "target_cs_hash":     "sha256:...",
  "engine_version":     "5.4.2",
  "engine_root":        "<EngineRoot>",
  "source_max_mtime":   1730000000,
  "last_full_index_at": 1730000000,
  "step_completion": {
    "s1": 1730000004,
    "s2": 1730000040,
    "s3": 1730000180,
    "s4": 1730000185,
    "s5": 1730000186,
    "s6": 1730000188
  }
}
```

| Trigger | S1 | S2 | S3 | S4 | S5 |
|---|---|---|---|---|---|
| `.cpp` body edit only | skip | skip | incr | skip | skip |
| `.h` non-reflection edit | skip | skip | incr | skip | skip |
| `UCLASS`/`UPROPERTY`/`UFUNCTION` edit | skip | run | incr | skip | reload |
| New `.h`/`.cpp` file | skip | run | incr | run | reload |
| `*.Build.cs` change | skip | run | incr | run | reload |
| `.uproject` change | run | run | incr | run | reload |
| Engine version change | run | run | **full reset** | run | reload |
| First run / missing artifact | run | run | full | run | reload |

"incr" for S3 = pass the same paths to `cindex`; cindex itself decides per-file by mtime.

### Why `-SkipBuild` (and the fallback)

| UBT mode | `.generated.h` | `.rsp` | `cl.exe` | `link.exe` | First-run cost |
|---|---|---|---|---|---|
| (default) | ✓ | ✓ | ✓ | ✓ | minutes |
| `-SkipBuild` | ✓ | ✓ | ✗ | ✗ | ~30–60s |
| `-XGEExport` | ✓ | ✓ | ✗ (exported only) | ✗ | ~30–60s |
| `-Mode=GenerateClangDatabase` | ✗ (in some versions) | ✗ (own format) | ✗ | ✗ | ~10–30s |

`-SkipBuild` is the primary path. Fallback to `-XGEExport` if a given UE version still triggers link with `-SkipBuild`. `GenerateClangDatabase` is rejected as primary because it skips UHT — clangd would then red-line every `*.generated.h`.

### Async + progress UI

- Each step is a `vim.system` job; coordinator holds the handles.
- Stdout lines flow through `parsers.lua` regex → fractional progress (0.0–1.0).
- `progress.lua` redraws every 100ms via `vim.defer_fn`, not on every stdout line.
- Floating window:

  ```
  ┌─ UEPrepare ─────────────────────────────────────────┐
  │ [✓] S1 ueprepare              done    (4.2s)        │
  │ [⠹] S2 UHT + rsp              [████░░░░] 47/247     │
  │ [⠼] S3 csearch index          [██░░░░░░] 12k/180k   │
  │ [ ] S4 rsp → ccjson           pending               │
  │ [ ] S5 clangd reload          pending               │
  │ [ ] S6 verify                 pending               │
  │                                                     │
  │ q: detach (jobs continue)   <C-c>: cancel all       │
  └─────────────────────────────────────────────────────┘
  ```

- `q` detaches the window; jobs keep running and the user gets a `vim.notify` on completion.
- `<C-c>` calls `coordinator.cancel()` which `:kill`s all child handles and writes a partial-state marker to `state.json`.

### Progress sources per step

| Step | Source | Regex / mechanism |
|---|---|---|
| S1 | wrap existing `ueprepare`, no progress | spinner only |
| S2 | UBT stdout `[n/total] Compiling ...` and `Parsing headers for X` | `^%[(%d+)/(%d+)%]` |
| S3 | `cindex` stderr — one line per file | line count vs pre-counted `find` total |
| S4 | python helper emits `MODULE k/n` | trivial parse |
| S5 | none (single LSP call) | spinner |
| S6 | 3 sub-steps, equal weight | manual ticks |

## Public-API impact

### New user commands

```vim
:UEPrepare              " smart incremental, auto-decides skip set
:UEPrepare!             " force full (ignore state.json)
:UEPrepare csearch      " S3 only
:UEPrepare rsp          " S2 + S4 + S5
:UEPrepareStatus        " print state.json + any in-flight jobs
:UEPrepareLog s2        " open the log buffer for a given step
:UEPrepareCancel        " kill all in-flight prepare jobs
```

### Freeze-list deltas (`ue.config` schema)

Adds `prepare.*` and `csearch.*` keys (see schema block above). No removals. No renames. Existing `clangd.*` / `dap.*` / `cdb.*` keys untouched.

### `lua/ue/cdb/pipeline.lua`

May gain a `from_rsp(rsp_dir)` entry point if it doesn't already have one. If it does, S4 is a one-line call. Decision deferred to implementation — not pre-committed here.

### Existing modules

- `ue.lua`, `ue/dap.lua`, `ue/cdb/*` — no changes required. `prepare/` is purely additive.
- `lua/utils/ue_goto/` — unchanged. csearch is a *complement* to instant-goto, not a replacement: instant-goto still wins for symbol-known cases, csearch wins for "where is this string used" / "find all TODOs".

## Test gate

Cannot land `:UEPrepare` without all six passing:

1. **Cold start, project only**: fresh clone, `:UEPrepare!` runs all 6 steps, finishes, `:UEPrepareStatus` shows all green. Must complete in ≤ 5 min on the reference repo.
2. **Cold start, project + engine**: same as above but `csearch.include_engine = true`. Must complete in ≤ 10 min.
3. **Incremental no-op**: immediately re-run `:UEPrepare`. Must complete in ≤ 2s with all steps marked "skipped".
4. **Incremental .cpp edit**: edit one `.cpp` body, `:UEPrepare`. Only S3 runs (incr), completes ≤ 5s.
5. **Reflection edit**: add a `UPROPERTY` to a `UCLASS`. S2, S3, S5 run; S1, S4 skip. clangd's diagnostics on the modified file no longer red-line the new property.
6. **Cancel mid-flight**: `:UEPrepare!`, then `<C-c>` during S2. All UBT processes killed within 2s. `state.json` has a `partial: true` marker. Next `:UEPrepare` treats it as cold.

Smoke (S6) inside each run:

```bash
csearch -l "UCLASS" | head -1                            # must produce ≥ 1 match
jq -e 'length > 0' compile_commands.json                  # must be valid + non-empty
# clangd: query diagnostics on a canary .cpp; must have 0 "file not found" errors
```

## Sanitization

- All paths in this ADR use `<project>`, `<EngineRoot>`, `<USER>`, `<LOCAL_APPDATA>` placeholders.
- `state.json`, `csearch.index`, and step logs live under `<project>/.ueprepare/` — **per-project**, never `~`-global. Add `.ueprepare/` to the user's global gitignore template.
- No engine paths, project names, or repo URLs in this ADR.
- When implementing, log files must redact `<EngineRoot>` to `$UE_ENGINE_ROOT` before write.

## Rollback

`prepare/` is purely additive. Rollback steps:

1. Delete `lua/ue/prepare/` and `scripts/ueprepare/`.
2. Remove `prepare.*` and `csearch.*` blocks from `lua/ue/config.lua` schema.
3. Delete `<project>/.ueprepare/` in any project that ran the new pipeline.
4. No changes to `ue.lua`, `ue/cdb/`, `ue/dap/`, `lua/utils/ue_goto/` to revert.

The user's existing `ueprepare` / `uebuild` / `ueindexfull` shell commands are untouched throughout.

## Open decisions (resolved before implementation, not now)

1. **S4 implementation**: extend `ue/cdb/pipeline.lua` to ingest `.rsp` directly, vs. shell out to a python helper. Depends on whether `ue/cdb/` already parses MSVC response files.
2. **Unity build handling**: UBT collapses many `.cpp` into one TU; ccjson must either expand back to per-file entries (clangd-friendly) or accept unity (lower fidelity). Default tentatively: expand.
3. **csearch index location override**: `$CSEARCHINDEX` env var vs. `.csearchindex` in cwd vs. `.ueprepare/csearch.index`. Plan picks the third for per-project isolation; revisit if csearch tooling expects one of the other two.

## Implementation phases (when work starts — not now)

| Phase | Scope | Done when |
|---|---|---|
| P1 | Synchronous skeleton: S1–S6 serial, no progress UI, no incrementality | One command takes a fresh project to csearch + clangd working |
| P2 | S4 polish: rsp→ccjson translator, `.clangd` config, unity-build expansion | clangd shows zero red lines on engine types in a sample file |
| P3 | Async: `vim.system` everywhere, floating progress UI, cancel | nvim stays responsive during a full run |
| P4 | Incrementality: `state.json`, fingerprint diff, per-step skip | `.cpp` body edit → re-run completes in ≤ 5s |
| P5 | Polish: log viewer, `:UEPrepareStatus`, engine-version reset, gitignore template | One-week daily-driver soak with no regressions |
