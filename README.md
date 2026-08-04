# hana-alice's Neovim — Unreal Engine Edition

> A LazyVim-based Neovim configuration for editing massive Unreal Engine 5 C++
> projects on Windows — and engineered for long-term AI-assisted development.

**English** · [中文 / Chinese](docs/README.zh-CN.md)

## Features

- **Super-unity indexing** — collapses 11,593 translation units into ~23
  aggregator TUs, cutting a full cold index from **hours to ~3 minutes** on
  Windows/NTFS while keeping ≥90% of symbols.
- **Sub-100ms goto-definition** on UE-scale projects, via a 5-tier resolver
  (treesitter → cache → clangd → csearch → gtags).
- **Sub-second project grep** using a trigram index over the project file list
  (`FRDGBuilder`: ~365ms versus ~14s for an NTFS tree walk).
- **CDB super-pipeline** that expands, PCH-prebuilds and prunes
  `compile_commands.json` (60–90% of `-I` flags removed) so clangd parses less.
- **Multi-platform DAP** debugging for Win64 and Android (headless attach), with
  per-project breakpoint persistence.
- **File-based knowledge base** for AI agents: per-directory rules, a SESSION
  START protocol, and a regression-gated Definition of Done.

The editor remains general-purpose; UE features no-op when no UE project is present.

## Benchmarks

Measured on UEProj: **11,593 `.cpp` files**, 757 `-D` macros per CDB entry,
on Windows/NTFS — where directory recursion and per-TU indexing are the real
bottlenecks.

### Super-unity indexing — the headline

A naive one-index-per-TU cold build of a UE project runs for **hours**. The
super-unity pipeline collapses the 11,593 translation units into **~23
aggregator TUs**, then indexes those — a full cold index in **~3 minutes**,
keeping ≥90% of symbols.

```
Full cold index (11,593 TUs)
  naive per-TU     ████████████████████████████████████████  hours
  super-unity      ██▏ ~3 min     (collapses 11,593 TUs → ~23)
```

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

**Windows 10/11 only.** macOS and Linux are not adapted: the configuration loads
and the base editor works, but the UE subsystems (CDB pipeline, indexing, DAP,
launchers) are written against the Windows toolchain and are not supported
elsewhere.

## Requirements

| Component | Version / Note |
| --- | --- |
| OS | Windows 10/11 |
| Neovim | 0.10+ |
| Toolchain | clangd/LLVM 22.1.x — pinned; do not use mason auto-install |
| Android DAP | LLVM 22.1.6+ `lldb-dap` + NDK 27 `lldb-server` |
| Optional | Go ≥ 1.22, to build the grep index tool |
| Build prerequisite | A working Unreal Build Tool setup for the target platform |

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

Optionally build the grep index tool:

```powershell
cd tools\cindex-uefilter
go install ./...   # requires Go >= 1.22 with $GOBIN on PATH
```

Without it, project grep falls back to a slower ripgrep path.

## Usage

Open a C++ file inside the UE project, then proceed in order.

### 1. Bind the project

```vim
:UESetProject
```

Confirms the project root (containing `.uproject`) and the engine root. Both are
persisted. Use `:UESetUprojectRelativePath` if `.uproject` is not directly under
the project root.

### 2. Select the platform

```vim
:UESetPlatform
```

Choose `Win64`, `Android`, `Mac`, `IOS` or `Linux`. If unset, the current OS is
used. Caches are stored per `<Platform>-<Config>`, so switching platforms does
not invalidate other platforms' caches.

### 3. Build once for the target platform (required)

```
<leader>ub        " (space u b) → :UEBuild
```

`:UEPrepare` derives compile flags from a real build of the selected platform.
**A successful platform build must exist before indexing**; without it there are
no compile commands to process. Build Android with `:UEBuildAndroid`.

### 4. Build the index

```vim
:UEPrepare
```

Runs asynchronously with a progress UI: generates `compile_commands.json`, runs
the CDB pipeline (expand → PCH → resolve → unify → prune), builds the csearch
index, and reloads clangd. On completion, goto-definition, project grep and
clangd are ready.

Variants: `:UEPrepareIncremental` (dirty files only), `:UEPrepareReindex`
(rebuild the index), `:UEPrepareSync` (blocking).

### Common commands

| Action | Key / Command |
| --- | --- |
| Goto definition / references | `gd` / `gr` |
| Project-wide grep | `<leader>/` |
| File picker | `<leader><leader>` |
| Build (current platform) | `<leader>ub` / `:UEBuild` |
| Android SO only (skip APK) | `<leader>us` / `:UEBuildAndroidSO` |
| Android quick SO deploy (root device) | `<leader>uq` / `:UEDeployAndroidSO` |
| Launch the Editor | `:UELaunch` |
| Re-index after adding/removing files | `:UEPrepareIncremental` |
| Android: select device (name + serial, session-global) | `<leader>uA` / `:UESetAndroidDevice` |
| Android: install / attach / breakpoint on selected device | `<leader>ui` / `:UEDAPAttach` / `F9` |
| Background tasks: list / stop | `<leader>X` / `:Tasks` / `:TaskStopAll` |
| All commands cheatsheet | `<leader>?` / `:UECheatsheet` |

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
| Per-directory `CLAUDE.md` rules | 19 | Local subsystem rules; children write deltas only |
| Recorded pitfalls (`K1…`) | 39 | Every debugged trap kept with symptom → fix → source |
| Isolated workaround files | 9 | Each upstream-bug patch carries a frontmatter contract |
| Headless regression specs | 21 | Behaviour locked so refactors and migrations stay safe |
| OpenSpec specs / archived changes | 14 / 12 | Decisions and changes are spec-driven and traceable |

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
  utils/ue_goto/          5-tier goto-definition
  utils/code_search/      csearch sub-second grep
  utils/platform/         the only place OS branching is allowed
  workarounds/            isolated upstream-bug patches and registry
tools/                    cindex-uefilter (Go) and Python CDB/PCH/index utilities
docs/                     architecture, constraints, tooling, cheatsheet
tests/                    headless regression suite
```

## Documentation

| Topic | Location |
| --- | --- |
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
```

Exit code `0` indicates success, `1` indicates failure. Policy and the
change-to-filter map are in [`tests/CLAUDE.md`](tests/CLAUDE.md).

## Credits

[LazyVim](https://github.com/LazyVim/LazyVim),
[snacks.nvim](https://github.com/folke/snacks.nvim),
[clangd](https://clangd.llvm.org/),
[google/codesearch](https://github.com/google/codesearch) (forked to add `-files-from`).
