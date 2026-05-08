# hana-alice's Neovim — Unreal Engine Edition

A LazyVim-based Neovim configuration tuned for a very specific niche:
**editing huge Unreal Engine C++ projects on Windows**, where stock clangd
takes minutes to wake up and a careless `:e` can stall the UI for seconds.

It's also a general-purpose editor that happens to know about UE.

```
  100+ commits          45 lua modules        6.6k-line UE engine
  1 PCH precompiler     1 CDB pruner          1 jumplist contract
  1 workaround registry 1 Windows installer   0 tolerance for UI stalls
```

---

## What's actually in here

### 1. UE C++ workflow (`lua/ue.lua`, `lua/ue/`, `lua/plugins/ue.lua`)

A 6,657-line monolithic engine that owns everything UE-specific:

- clangd discovery and launch, with project-aware flags
- compile_commands.json lifecycle: slim → PCH-rewrite → unify-includes
  → prune-unused-dirs (60–90% of `-I` removed, preamble parse 60s → 20s)
- background indexer with idle/cold/hot debounce so it never thrashes
  while you're typing
- DAP setup for Win64 / Android (codelldb), build commands, log tailing,
  Editor launch helpers, sidebar integration

Public API is exposed on `M.*` so it's testable in headless nvim.

### 2. Instant goto-definition (`lua/utils/ue_goto/`)

A tier-2 split of what used to be one god module. Architecture:

```
ue_goto/
  jumper.lua     - HARD-contract buffer/cursor switch + jumplist hygiene
  symbol.lua     - symbol identification at cursor (treesitter-first)
  location.lua   - precise location resolution + drift correction
  ranking.lua    - candidate scoring (UE-aware: Engine/Plugins/Project)
  provider.lua   - LSP / ws-symbol / ctags / fallback fan-out
  ui.lua         - picker + preview
```

Notable design choices:
- treesitter pre-LSP early-bail for C++ dependent names — answers in
  ~5 ms instead of waiting on clangd
- jumper is a single-responsibility module with a written post-condition
  contract (one `Ctrl-O` returns to source, exactly one jumplist entry,
  no spurious `(target_buf, 1, 0)` ghost)
- no timer-based "drift fixes"; races are synchronized via
  `BufReadPost` + `BufWinEnter` once-shot autocmds

### 3. Workaround registry (`lua/workarounds/`)

Every patch that exists *because of someone else's bug* lives in its own
file with a frontmatter contract:

```
-- WORKAROUND
-- name: snacks.projects_picker_freeze
-- scope: snacks
-- issue: internal: snacks projects MRU re-stat freezes Neovide
-- introduced: 2026-04-12
-- removal_condition: snacks.nvim ships async MRU
-- enabled: true
-- END WORKAROUND
```

Browse them with `:WorkaroundList`, toggle with `:WorkaroundDisable <name>`.
When upstream fixes the bug, cleanup is `git rm`, not archaeology.
See `lua/workarounds/README.md` for the contract.

### 4. Windows-first ergonomics

- `lua/utils/platform.lua` — `is_windows` flag threaded through
  everywhere that touches paths, processes, or file modes
- `lua/config/neovide.lua` + `lua/config/windows.lua` — Neovide tuning
  without polluting the main config
- `:set core.fileMode=false` assumed (this repo lives on NTFS via WSL)

### 5. Tooling (`tools/`, `scripts/`)

Standalone Python utilities that don't need Neovim to run:

| Tool                          | What it does                                    |
|-------------------------------|--------------------------------------------------|
| `prebuild_pch_v2.py`          | Generate `.rsp` + `.bat` to precompile UE PCHs  |
| `prune_include_dirs.py`       | Drop unused `-I` from CDB (massive preamble win)|
| `unify_include_dirs.py`       | Deduplicate include dirs across TUs             |
| `slim_compile_commands.py`    | Strip noise, keep `-include` directives         |
| `build_clangd_index.py`       | Offline `clangd-indexer` for instant cold-start |
| `restore_force_includes.py`   | Re-inject `-include X.h` after slim             |
| `android_*_probe.py`          | Hardware-breakpoint research scripts (codelldb) |

Each is idempotent and skip-writes when the output is unchanged, so you
can re-run them in a watcher loop without invalidating PCHs or restarting
clangd.

### 6. One-shot Windows installer (`scripts/install_windows.ps1`)

Sets up scoop, installs the entire toolchain (git, neovim, neovide, llvm,
fd, ripgrep, lazygit, fzf, zoxide, python, nodejs, yazi, gtags, ...),
points `%LOCALAPPDATA%\nvim` at this repo, and bootstraps lazy.nvim
headlessly. Re-runnable.

### 7. Cheatsheet (`docs/ue_lazyvim_cheatsheet.md`)

468-line keymap + workflow handbook covering vanilla Vim, LazyVim, and
the UE/DAP additions. Open in-editor with `:UECheatsheet`.

### 8. Sub-second grep on 100k-file UE workspaces (`tools/cindex-uefilter` + `lua/utils/code_search`)

`<leader>/` (the project grep picker) used to walk the directory tree
on every keystroke — ~14-32s per query on UEProj because NTFS
recursion is the physical bottleneck and `rg --files-from` doesn't
exist.

`:UEPrepare` now also builds a trigram index using a small Go fork of
[google/codesearch](https://github.com/google/codesearch). The fork
adds one flag, `-files-from FILE`, which lets us index exactly the
clean file list `:UEPrepare` already produces (skipping
`graphify-out/`, `Intermediate/`, `DerivedDataCache/`, etc. that the
upstream walker would otherwise vacuum up).

Numbers measured on UEProj (~43k files):

| Pattern                     | Hits | csearch     | rg (walk) |
| --------------------------- | ---- | ----------- | --------- |
| `FRDGBuilder`               | 2491 | **365 ms**  | ~14 s     |
| `FRHICommandList`           | 6593 | **693 ms**  | ~18 s     |
| `NaniteRasterPipelines`     | 57   | **73 ms**   | ~12 s     |

Build the binary once: `cd tools/cindex-uefilter && go install ./...`
(Go ≥ 1.22 + a working `$GOBIN` on `$PATH`). The next `:UEPrepare`
will detect it and produce a `.cache/nvim-ue/csearch.idx` (~70 MB on
UEProj). When the index is missing, the picker silently falls back to
the rg-batched path.

---

## Layout

```
.
├── init.lua                    LazyVim entrypoint
├── lua/
│   ├── config/                 keymaps, options, autocmds, lazy bootstrap
│   ├── plugins/                per-plugin setup (snacks, treesitter, dap, ...)
│   ├── ue.lua                  UE engine (6.6k lines, single module)
│   ├── ue/                     UE submodules (DAP)
│   ├── utils/
│   │   ├── ue_goto/            instant goto-def architecture
│   │   ├── code_search/        sub-second grep via csearch + cindex-uefilter
│   │   ├── lsp_fallback.lua    fall-through gd resolver
│   │   ├── recent_projects.lua MRU without re-statting NTFS
│   │   ├── platform.lua        is_windows / is_mac / is_linux flags
│   │   └── ...
│   ├── workarounds/            isolated quirk patches + registry
│   ├── nio/                    async logger
│   ├── trouble/sources/        custom trouble sources
│   └── theme.lua, highlights.lua
├── tools/
│   ├── cindex-uefilter/        Go fork of google/codesearch's cindex
│   │                           (adds -files-from FILE for clean indexing)
│   └── (Python utilities...)   PCH, CDB, index, DAP probes
├── scripts/                    Windows installer + cleanup + profiling
├── docs/
│   ├── ue_lazyvim_cheatsheet.md
│   └── plans/                  architecture decision records
└── CLAUDE.md                   instructions for AI agents working here
```

---

## Install

### Windows (preferred, what this is built for)

```powershell
# from a PowerShell 7 prompt
git clone https://github.com/hana-alice/nvim-dot-files.git $env:LOCALAPPDATA\nvim
cd $env:LOCALAPPDATA\nvim
.\scripts\install_windows.ps1
nvim
```

### Anywhere else

```bash
git clone https://github.com/hana-alice/nvim-dot-files.git ~/.config/nvim
nvim
```

LazyVim will install plugins on first launch. UE-specific features no-op
gracefully when there's no UE project around.

---

## Conventions

These are the rules this config follows. They are not optional:

- **AST/treesitter over regex** for any structural code question
- **Async over blocking** — multi-second waits OK, blocking the main
  thread is not
- **Workaround isolation** — anything that exists only to dodge an
  upstream bug goes in `lua/workarounds/<scope>/<name>.lua`
- **Self-verifiable modules** — public API on `M.*`, headless-testable
- **No periodic ticker notifications** — at most start + middle update,
  natural fade after success (no `:messages` spam)
- **Skip-write when unchanged** — every generator (CDB, PCH, .clangd)
  must compare before writing so downstream caches don't invalidate

See `CLAUDE.md` for the full agent contract.

---

## Credits

- [LazyVim](https://github.com/LazyVim/LazyVim) — the base distribution
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) — picker, statusline, dashboard
- [clangd](https://clangd.llvm.org/) — the C++ LSP that does all the real work
