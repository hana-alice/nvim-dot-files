# hana-alice's Neovim — Unreal Engine Edition

> A LazyVim-based Neovim configuration for editing massive Unreal Engine C++
> projects on Windows and macOS — engineered for long-term AI-assisted development.

**English** · [中文 / Chinese](docs/README.zh-CN.md)

## Features

- **Fast cold indexing** — an optional offline prefix-PCH indexer (private
  clangd fork) plus Tier 1 SuperUnity absorption produces the clangd index
  store before the official clangd loads it: a full cold index of a large UE
  project went from **1261 s to 253–293 s** on a quiet Windows host, and the
  official clangd then loads that store without re-indexing.
- **Context-aware C++ goto-definition**: source calls use clangd's exact-cursor
  identity; headers resolve in a compiler-proven origin TU through an async
  libclang sidecar.
- **Sub-second project grep** using a trigram index over the project file list
  (`FRDGBuilder`: ~365ms versus ~14s for an NTFS tree walk).
- **CDB super-pipeline** that expands, PCH-prebuilds and prunes
  `compile_commands.json` (60–90% of `-I` flags removed) so clangd parses less.
- **Multi-platform DAP** debugging for Win64, Android and physical iOS devices, with
  per-project breakpoint persistence.
- **Host/target build drivers** that keep Windows, macOS and Linux execution
  separate from Win64, Android, Mac, IOS and Linux target policy.
- **Native macOS/iOS workflow** for UBT build, UAT package/archive, physical
  device selection, install and launch through Xcode `devicectl`.
- **File-based knowledge base** for AI agents: per-directory rules, a SESSION
  START protocol, and a regression-gated Definition of Done.

The editor remains general-purpose; UE features no-op when no UE project is present.

## Benchmarks

Measured on large UE projects on Windows/NTFS, where directory recursion and
per-TU indexing are the real bottlenecks.

### Cold full index — the headline

Wall time of the offline prefix-PCH indexer for one full cold index of the same
project (generated UHT headers were refreshed once along the way). Every run
passed the correctness gates: no fallback, no shard mismatch, and the official
clangd reloads the store with zero re-index:

```
Cold full index (lower is better)
  baseline            ████████████████████████████████████████  1261 s
  + Tier 1 absorption ██████████████████████████▎               830 s
  + ordered schedule  █████████████████▎                        545 s
  + seed gate         ████████████████▏                         510 s
  + thin-PCH filters  ███████████▎                              357 s
  + PGO/LTO/caches    ████████▌                                 268 s (median)
```

Acceptance was pre-registered as "median of a 3-run batch ≤ 300 s". Seven
consecutive batches met it (medians 254.9–294.7 s), and 15 of 15 runs after a
disk cleanup stayed ≤ 300 s. With heavy concurrent clangd/python load on the
same machine the run still takes 370–430 s, because the indexer's workers run
at idle priority and yield the CPU.

### What made it fast

Counted per batch: each batch is a set of changes measured together by one
full cold index.

| Area | Optimization | Status |
| --- | --- | --- |
| Pipeline | Tier 1 SuperUnity groups absorbed by the same offline run (receipts keyed for the official reader) | adopted |
| Pipeline | Ordered schedule (seed first per context, then by size); skip already-published shards | adopted |
| Pipeline | Parallel prepare overlay, include-graph and publish; background publish/commit overlapping the retry lane | adopted |
| Pipeline | Retry lane re-indexes failed wrappers as their original UBT rows (fallback 51 → 0) | adopted |
| Pipeline | One-shot PCH production, 4-thread Tier 1 prepare/commit, parallel index lanes | adopted |
| Pipeline | didOpen → didClose inside lanes; skip clangd's idle index rebuild | adopted |
| clangd fork | Seed gate: later TUs of a context wait for the seed, then reuse a thin PCH | adopted |
| clangd fork | Prefix-header shard preload; seeds shared across contexts that differ only in path spelling | adopted |
| clangd fork | Native-path filter + thin TUs skip loading prefix top-level decls (510 → 357 s) | adopted |
| clangd fork | rpmalloc, PGO, ThinLTO builds | adopted |
| clangd fork | Per-process cache of parsed VFS overlay files | adopted |
| Rejected | Merge contexts by path-separator spelling (output beyond noise) | opt-in only |
| Rejected | Fold Tier 1 retries into the paired lane (correct after a fix, but slower in both A/B pairs) | opt-in only |
| Rejected | Speculative PCH producer (+19% CPU) | opt-in only |
| Rejected | Higher `-j`, `-w`, EcoQoS priority, extended prefix closure, early retry overlap | dropped |

Measurement discipline: pre-registered verdicts, ABAB pairs, a start gate on
host CPU and on CPU used by outside clangd/python processes, per-run accounting
of outside CPU, a free-disk gate, and per-run scratch cleanup. Disproved claims
are kept on record rather than deleted.

Other improvements in this configuration that are not about the cold index:

- **Tier 1 / Tier 2 SuperUnity delivery** with strict graph gates, qualification
  that survives real-build inputs, and context-migration shard invalidation.
- **clangd memory reclaim** after background indexing in a quiet window, disk
  preambles with a per-session TEMP, and caches/logs that follow the engine
  directory instead of the system drive.
- **Large-CDB robustness**: bounded digest memory, staged index delivery with
  honest failure reporting, and preparation that never loses valid work.
- **Contextual goto-definition** for source and header files, and ordinary
  (non-UE) C/C++ workspaces kept on plain LSP.
- **Review workflow**: CodeDiff as the default review view with `[[` / `]]`
  hunk navigation.

### Project-wide grep

A trigram index over the project file list turns NTFS tree-walking into an
indexed lookup:

| Pattern | Hits | csearch | ripgrep (NTFS walk) | Speedup |
| --- | ---: | ---: | ---: | ---: |
| `FRDGBuilder` | 2,491 | **365 ms** | ~14,000 ms | ~38× |
| `FRHICommandList` | 6,593 | **693 ms** | ~18,000 ms | ~26× |
| `NaniteRasterPipelines` | 57 | **73 ms** | ~12,000 ms | ~164× |

```
FRHICommandList grep (lower is better)
  csearch  ▏0.7s
  ripgrep  ████████████████████████████████████████ 18s
```

## Platform support

- **Windows 10/11:** primary environment; UE build/index and Win64/Android workflows.
- **macOS:** native UE `Build.sh`, Mac/IOS target builds, the CDB semantic pipeline,
  iOS package/install/launch, iOS 17+ CoreDevice DAP and pre-iOS17 legacy USB DAP.
- **Linux:** the base editor and native UBT build planner are available; device and
  DAP workflows remain target-dependent.

## Requirements

| Component | Version / Note |
| --- | --- |
| OS | Windows 10/11 or macOS with full Xcode |
| Neovim | 0.10+ |
| Toolchain | clangd/LLVM 22.1.x — pinned; do not use mason auto-install |
| Android DAP | LLVM 22.1.6+ `lldb-dap` + NDK 27 `lldb-server` |
| iOS DAP | selected Xcode `lldb-dap` + CoreDevice (`devicectl`); pre-iOS17 additionally uses `ios-deploy` + libimobiledevice |
| Optional | Go ≥ 1.22, to build the grep index tool |
| Build prerequisite | A working Unreal Build Tool setup for the target platform |
| iOS | Xcode, iPhoneOS SDK, signing identity/provisioning, and a paired physical device |

Pinned versions are authoritative in
[`docs/CONSTRAINTS.md` §C1](docs/CONSTRAINTS.md) and
[`docs/TOOLING.md`](docs/TOOLING.md).

## Installation

```powershell
git clone https://github.com/hana-alice/nvim-dot-files.git $env:LOCALAPPDATA\nvim
cd $env:LOCALAPPDATA\nvim
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\setup.ps1
nvim
```

`setup.ps1` installs the toolchain, fonts and plugins (run from an Administrator
PowerShell). Flags: `-SkipFonts`, `-SkipCapslock`, `-SkipPlugins`, `-Force`.

On macOS, clone to the standard config path and start Neovim; Xcode and the
pinned LLVM toolchain are managed separately:

```sh
git clone https://github.com/hana-alice/nvim-dot-files.git ~/.config/nvim
nvim
```

Optionally install the indexed-grep toolchain on macOS/Linux. The installer
builds this repository's `cindex-uefilter` and the matching pinned
`csearch v1.2.0` into `$GOBIN` (or the default `$(go env GOPATH)/bin`):

```sh
sh scripts/install_csearch.sh   # requires Go >= 1.22
```

The runtime also discovers these binaries directly from `$GOBIN`, every
`$GOPATH/bin`, and the conventional `~/go/bin`, so the install directory does
not have to be added to Neovim's inherited `PATH`. Without both binaries,
generic project search falls back to ripgrep and the csearch-only picker stays
blocked until an index is prepared.

## Usage

Open a C++ file inside the UE project. Project and platform selection are
independent: steps 1 and 2 may be performed in either order.

### 1. Bind the project

```vim
:UESetProject
```

Confirms the project root (containing `.uproject`) and the engine root. The
selection is captured by the current Neovim process; its persisted selector is
only the startup default for future processes. Use `:UESetUprojectRelativePath`
if `.uproject` is not directly under the project root.

### 2. Select the platform

```vim
:UESetPlatform
```

Choose `Win64`, `Android`, `Mac`, `IOS` or `Linux`. If unset, the current OS is
used. Caches are stored per `<Platform>-<Config>`, so switching platforms does
not invalidate other platforms' caches.

### 3. Build the selected target

```
<leader>ub        " (space u b) → :UEBuild
```

`:UEBuild` remains build-only. With IOS selected, `<leader>ub` uses the same IOS
target driver as `:UEBuildIOS`. Wait for it to finish before preparing; build and
prepare intentionally never overlap.

### 4. Build the index

```vim
:UEPrepare
```

Runs asynchronously with a progress UI. For an IOS target on macOS, it first
validates the pinned clangd 22.1.x toolchain and generates the tuple-scoped UBT
semantic CDB that the IOS build does not retain; it also imports prepared signing
evidence and selects the device on first use. This IOS prelude uses `GenerateClangDatabase` with no compile,
cook, package, deploy, or run actions. All targets then generate
`compile_commands.json`, run the CDB pipeline (expand → PCH → resolve → unify →
prune), build the csearch index, and reload clangd.

`:UECompileForNvim` remains as a compatibility convenience that performs a build
and then delegates to this same `:UEPrepare` path; it is not required by the
normal workflow. Tree-sitter syntax highlighting works without a CDB, while
clangd navigation and diagnostics require it.

Variants: `:UEPrepareIncremental` (dirty files only), `:UEPrepareReindex`
(rebuild the index), `:UEPrepareSync` (blocking).

### Common commands

| Action | Key / Command |
| --- | --- |
| Goto definition / references | `gd` / `gr` |
| Project-wide grep | `<leader>/` |
| File picker | `<leader><leader>` |
| Build (current platform) | `<leader>ub` / `:UEBuild` |
| Compatibility: build, then run the normal prepare path | `:UECompileForNvim` |
| Build IOS C++ only (safe AOT reuse, no automatic dSYM) | `:UEBuildIOS` |
| Package IOS from existing cooked data | `:UEPackageIOS` |
| Generate and UUID-check IOS dSYM on demand | `:UEIOSSymbols` |
| IOS device / install / launch | `:UESetIOSDevice` / `:UEInstallIOS` / `:UELaunch` |
| IOS debug attach / debug launch / stop | `:UEDAPAttach` / `:UEDAPLaunch` / `:UEDAPStop` |
| Android SO only (skip APK) | `<leader>us` / `:UEBuildAndroidSO` |
| Android quick SO deploy (root device; does not launch) | `<leader>uq` / `:UEDeployAndroidSO` |
| Launch the selected target app | `:UELaunch` |
| Re-index after adding/removing files | `:UEPrepareIncremental` |
| Android: select device (name + serial, current Neovim only) | `<leader>uA` / `:UESetAndroidDevice` |
| Android: install without launch / attach / breakpoint | `<leader>ui` / `:UEDAPAttach` / `F9` |
| Background tasks: list / stop | `<leader>X` / `:Tasks` / `:TaskStopAll` |
| All commands cheatsheet | `<leader>?` / `:UECheatsheet` |

After `PrepareIOSQADebug.sh` and `InstallIOSClient.sh` succeed, the complete IOS
flow is `:UESetProject` and `:UESetPlatform IOS` in either order, then
`<leader>ub` → `:UEPrepare` → `<leader>ui`. The IOS prepare branch owns the
one-time signing/private-key/device setup and Apple semantic CDB generation.

For iOS 17+, DAP freezes the selected CoreDevice backend and uses structured
`devicectl` app/process JSON. Debug launch is start-stopped; Xcode `lldb-dap`
then runs `target create` → `device select` → `device process attach -p`.
The local dSYM must pass `dwarfdump --verify --quiet`, and a run is successful
only after a verified breakpoint, real breakpoint stop, exact source:line frame,
expression evaluation, loaded-image UUID proof and owner cleanup all pass.
The headless gate is `tools/nvim_ios_dap_smoketest.lua`; provide every
`NVIM_IOS_DAP_SMOKE_{MODE,DEVICE,BACKEND,BUNDLE,BINARY,DSYM,SOURCE,LINE}` input
explicitly. Its persisted result is redacted and reports an external artifact or
device prerequisite as `blocked`, never as `passed`.

Full keymap and workflow handbook:
[`docs/ue_lazyvim_cheatsheet.md`](docs/ue_lazyvim_cheatsheet.md).

## Built for long-term AI-assisted development

This repository is engineered so an AI agent can join, understand the codebase,
and make safe changes **from files alone** — without relying on chat history.
The premise: durable AI participation depends on a clear engineering system, not
on a stronger model.

```
A new agent context boots like this:

  root CLAUDE.md  (auto-injected)
        │  SESSION START protocol
        ▼
  docs/CONSTRAINTS.md ──► forbidden / pitfalls / load-bearing constraints
        │
        ▼
  memory/project_overview.md ──► subsystems + "read this first" map
        │
        ▼
  <current dir>/CLAUDE.md ──► local subsystem rules (falls back to nearest ancestor)
```

What makes it AI-durable, by the numbers:

| Mechanism | Count | Purpose |
| --- | ---: | --- |
| Per-directory `AGENTS.md` rules (`CLAUDE.md` stubs) | 23 | Local subsystem rules; children write deltas only |
| Recorded pitfalls (`K1…`) | 77 | Every debugged trap kept with symptom → fix → source |
| Isolated workaround files | 23 | Each upstream-bug patch carries a frontmatter contract |
| Headless regression specs | 263 | Behaviour locked so refactors and migrations stay safe |
| OpenSpec specs / archived changes | 41 / 51 | Decisions and changes are spec-driven and traceable |

Four knowledge zones, each with a fixed entry point:

| Zone | Entry | Holds |
| --- | --- | --- |
| `memory/` | [`project_overview.md`](memory/project_overview.md) | Stable project knowledge, navigation |
| `decisions/` | [`README.md`](decisions/README.md) | Architecture decision records (ADR) |
| `lessons/` | [`README.md`](lessons/README.md) | Platform quirks, hard-won debugging knowledge |
| `docs/architecture/` | [`overview.md`](docs/architecture/overview.md) | Subsystems, data flow, ownership boundaries |

Every change is gated by a **Definition of Done** (run scoped regression, append
a changelog entry, follow the milestone policy on version wrap). Discoverability
itself is regression-tested: `structure_spec` fails if a directory rule, a
knowledge-base file, or an internal link goes missing. The full agent contract
is in [`CLAUDE.md`](CLAUDE.md).

## Layout

```
init.lua                  LazyVim entrypoint
setup.ps1                 Windows installer
lua/
  config/                 keymaps / options / autocmds / lazy bootstrap
  plugins/                per-plugin setup (snacks-only)
  ue.lua                  UE engine hub (~10k lines)
  ue/{cdb,core,dap}/      CDB pipeline, pure functions, multi-platform DAP
  utils/ue_goto/          contextual C++ + non-C++ compatibility navigation
  utils/code_search/      csearch sub-second grep
  utils/platform/         the only place OS branching is allowed
  workarounds/            isolated upstream-bug patches and registry
tools/                    cindex-uefilter (Go) and Python CDB/PCH/index utilities,
                          including the offline prefix-PCH indexer
docs/                     architecture, constraints, tooling, cheatsheet, releases
tests/                    headless regression suite (+ tests/py for Python tools)
```

## Documentation

| Topic | Location |
| --- | --- |
| **User guide (daily workflow, keys, troubleshooting)** | [`docs/USER_GUIDE.md`](docs/USER_GUIDE.md) |
| Architecture overview | [`docs/architecture/overview.md`](docs/architecture/overview.md) |
| Additions over LazyVim | [`docs/architecture-vs-lazyvim.md`](docs/architecture-vs-lazyvim.md) |
| Symbol resolution internals | [`docs/architecture-symbol-resolution.md`](docs/architecture-symbol-resolution.md) |
| Forbidden / pitfalls / constraints | [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) |
| Pinned toolchain | [`docs/TOOLING.md`](docs/TOOLING.md) |
| Contributing / agent contract | [`CLAUDE.md`](CLAUDE.md) |

## Regression tests

```powershell
nvim --headless -l tests/run.lua            # full suite (authoritative)
nvim --headless -l tests/run.lua <filter>   # scoped
pwsh -File scripts\run_regression.ps1       # Windows wrapper
python -B -I tests/py/test_clangd_pch_offline.py   # offline indexer unit tests
```

Exit code `0` indicates success, `1` indicates failure. Policy and the
change-to-filter map are in [`tests/CLAUDE.md`](tests/CLAUDE.md).

To check the real local startup, Tree-sitter parsers, rg/csearch backends,
clangd/CDB prerequisites and read-only UE integration separately from mocked
regressions:

```sh
nvim --headless -l scripts/nvim_core_health.lua
nvim --headless -l scripts/nvim_core_health.lua --json
```

The same audit is available inside Neovim as `:NvimCoreHealth`. `DEGRADED`
means the editor core passed while an external capability such as csearch or
the pinned clangd is blocked. See [`docs/core-health.md`](docs/core-health.md).

## Credits

[LazyVim](https://github.com/LazyVim/LazyVim),
[snacks.nvim](https://github.com/folke/snacks.nvim),
[clangd](https://clangd.llvm.org/),
[google/codesearch](https://github.com/google/codesearch) (forked to add `-files-from`).
