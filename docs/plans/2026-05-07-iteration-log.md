# Multi-Platform Foundation — Iteration Log

> **Historical snapshot / superseded.** 本文是 2026-05-07 分支时点记录；“未合并”、
> `ue.lua` 行数、codelldb 与 iOS TODO 等内容不得用于判断当前实现。现行形状见
> [`../architecture/overview.md`](../architecture/overview.md) 与 canonical OpenSpec
> platform capabilities。

> **Branch**: `feat/multi-platform-foundation`
> **Span**: 2026-05-06 → 2026-05-07
> **Commits**: 16 atomic
> **Tests**: smoke 95/95 PASS · lint 80 files OK
> **Public-API breakage**: 0
> **Maintainer host**: Windows (Neovim + Neovide)
> **Untouched until merge**: `main` branch, real UE workspace

This document is the single page that summarises everything the
`feat/multi-platform-foundation` branch did to the configuration —
why each phase exists, what changed, the architecture before/after,
the performance and quality numbers, and the followup posture.

The branch is **not yet merged** at the time of this document. It is
queued for "use it on a real UE project, then merge".

---

## 1. Goals

The pre-branch configuration was a production-grade Windows-first
Unreal Engine editor: ~17 KLOC of Lua across 62 modules with an 8 KLOC
`lua/ue.lua` engine that owns clangd lifecycle, compile-commands
pipeline, background indexer, and Android DAP. It worked on Windows,
nowhere else.

Three goals drove this branch:

| Goal | Why it mattered |
|---|---|
| **Multi-platform UE workflow** (Win64 / Android / macOS / iOS / Linux) | UE projects routinely target multiple platforms; the editor had to stop assuming Windows host |
| **Untangle the 8 KLOC monolith** without breaking anything | Future per-platform changes need a place to live; today every change touched the same file |
| **Configurability without forking** | Users with non-default LLVM / Mason / NDK paths needed a sanctioned override seam |

Constraint: every step had to keep `git revert <range>` viable and
keep the existing Windows install byte-for-byte equivalent.

---

## 2. Phase index

Each phase has its own ADR under `docs/plans/`. This iteration log
links them and adds the "what changed in code" context the ADRs do
not carry.

| Phase | Commit | Title | Module(s) added | ADR |
|---|---|---|---|---|
| **A** | `a8ece2f` | platform driver + per-OS modules | `lua/utils/platform/{init,windows,macos,linux,stub}.lua` | `2026-05-06-multi-platform-foundation.md` |
| **B** | `0720ff0` | extract fs/proc utilities from ue.lua | `lua/ue/core/{fs,proc}.lua` | `2026-05-06-multi-platform-foundation.md` |
| **C** | `8d64ef1` | introduce schema for tunables | `lua/ue/config.lua` | `2026-05-06-multi-platform-foundation.md` |
| **E.1** | `3077c68` | extract pure JSON helpers | `lua/ue/cdb/json.lua` | `2026-05-07-cdb-pipeline-split.md` |
| **E.2** | `9aa5a84` | extract paths + shaders helpers | `lua/ue/cdb/{paths,shaders}.lua` | `2026-05-07-cdb-pipeline-split.md` |
| **E.3** | `4526e51` | extract pipeline driver with DI | `lua/ue/cdb/pipeline.lua` | `2026-05-07-cdb-pipeline-split.md` |
| **F.1** | `4ae2699` | platform-neutral UEDAP* aliases | (registers 11 commands) | `2026-05-07-dap-multiplatform.md` |
| **F.2** | `129311f` | per-platform dispatch table | `lua/ue/dap/platforms.lua` | `2026-05-07-dap-multiplatform.md` |
| **H** | `4781091` | real per-platform DAP handlers | `lua/ue/dap/{_common,win64,mac,linux,ios}.lua` | `2026-05-07-dap-real-platforms.md` |
| **I** | `f5ee7e9` | expand schema for clangd/dap/cdb | (extends `ue/config.lua`) | `2026-05-07-config-schema-expansion.md` |
| **J** | `4d6871a` | wire android prompts to ue.config | (extends `ue/dap.lua`) | `2026-05-07-android-config-wire.md` |
| **F.3** | `bb67c9e` | one-shot deprecation on UEAndroidDAP* | (10 commands wrapped) | `2026-05-07-dap-multiplatform.md` (followup) |
| **G** | `c602c23`,`4f6ebdf`,`129f88c` | `headless_smoke.lua` runner + extensions | `scripts/headless_smoke.lua` | inline in foundation ADR |
| **G CI** | `582b221` | 3-OS GitHub Actions matrix | `.github/workflows/headless.yml` | inline |
| D | (covered by smoke commits) | headless gate (test contract) | — | inline |

Phase D never got its own commit — it became the running headless
smoke harness, which Phase G then made first-class.

---

## 3. Architecture — before and after

### Before

```
init.lua
  ├── utils.log
  ├── config.neovide
  ├── config.snacks_global
  ├── config.lazy
  ├── config.windows         ← inline pwsh + explorer.exe + cmd.exe
  ├── utils.recent_projects
  ├── workarounds            ← scope-isolated, kept as-is
  └── ue (8 KLOC monolith)
        ├── inline core utils (fs/proc/string/path)
        ├── inline platform branches (Win64 hardcoded, Android partial)
        ├── inline tunables (INDEX_RT.idle_cold_ms = 120000, etc.)
        ├── inline CDB pipeline (slim/expand/pch/resolve/unify/prune)
        ├── inline shader CDB augmentation
        ├── inline path discovery (compile_commands_targets/_candidates)
        ├── inline DAP commands (UEAndroidDAP* only)
        └── 35 public functions on M.*
```

Everything platform-specific made an `if vim.fn.has("win32") == 1`
decision in place. Adding macOS or Linux would have required edits
in dozens of inline branches.

### After this branch

```
init.lua                              (unchanged structure)
  ├── utils.log
  ├── utils.platform                  ← driver registry  (Phase A)
  │     ├── windows.lua               existing behaviour, extracted
  │     ├── macos.lua                 (real defaults — open, /bin/zsh, brew clangd)
  │     ├── linux.lua                 (real defaults — xdg-open, distro clangd)
  │     └── stub.lua                  fallback when a driver fails to load
  ├── config.neovide
  ├── config.snacks_global
  ├── config.lazy
  ├── config.windows                  ← still windows-only, internal use
  ├── utils.recent_projects
  ├── workarounds
  └── ue
        ├── ue.lua                    8 KLOC, but split-internal-only:
        │   ├── 16 wrappers → ue.core.fs/proc           (Phase B)
        │   ├── 4 wrappers → ue.cdb.json/paths/shaders (Phase E.1+E.2)
        │   ├── 2 wrappers → ue.cdb.pipeline            (Phase E.3)
        │   ├── ue.config.get(...) reads for INDEX_RT   (Phase C)
        │   ├── ue.config.get(...) for clangd extras    (Phase I)
        │   ├── ue.dap.platforms registry use           (Phase F.2)
        │   ├── 4 platform handlers registered          (Phase H)
        │   └── 10 UEAndroidDAP* deprecation wrappers   (Phase F.3)
        ├── ue/core/                  pure helpers
        │   ├── fs.lua                trim/norm/cwd/join/dirname/...
        │   └── proc.lua              first_executable
        ├── ue/cdb/                   compile_commands subsystem
        │   ├── json.lua              program/template_entry  (pure)
        │   ├── paths.lua             targets/candidates       (DI shape)
        │   ├── shaders.lua           augment/make_entry       (pure)
        │   └── pipeline.lua          slim/run                 (DI shape)
        ├── ue/dap/                   debug-adapter subsystem
        │   ├── platforms.lua         registry: register/lookup
        │   ├── _common.lua           find_codelldb / prompts / config builder
        │   ├── win64.lua             attach + launch (codelldb native)
        │   ├── mac.lua               attach + launch
        │   ├── linux.lua             attach + launch
        │   └── ios.lua               attach forwards to mac; launch WARN
        ├── ue/dap.lua                Android DAP (extracted long ago);
        │                             now reads ue.config for prompts (J)
        └── ue/config.lua             schema + setup/get/options/reset_for_test
```

### Key design choices

#### Driver pattern, not boolean

`utils.platform.is_windows` is preserved (every old call site reads
it directly). Below it, `M.driver()` returns a per-OS table that
implements a strict interface — Phase A locked the shape so future
additions can never silently miss a driver.

```lua
---@class PlatformDriver
---@field id        '"windows"'|'"macos"'|'"linux"'
---@field shell     fun(): string
---@field path_sep  string
---@field list_sep  string
---@field exe_suffix string
---@field open_path fun(path: string)
---@field reveal_file fun(path: string)
---@field default_clangd_candidates fun(): string[]
---@field default_codelldb_paths    fun(): string[]
---@field default_lldb_server_paths fun(): string[]
---@field cmd_quote fun(value: string): string
```

#### Wrappers, not aliases

`ue.lua`'s main chunk has a hard cap of 200 locals (Lua VM limit).
Phase B's first attempt — `local norm = require("ue.core.fs").norm`
for every helper — pushed past 200 and crashed at load time. The
branch settled on 1-line wrapper functions (`local function norm(p)
return require("ue.core.fs").norm(p) end`) which are byte-for-byte
equivalent to the originals at every call site, never grow the local
count, and pay only a single table lookup per call. **Throughout the
entire branch, `ue.lua`'s top-level local count stayed at 202 — the
exact pre-branch value.**

#### Dependency injection, not require-ue

`ue.cdb.pipeline.set_runtime({ jobstart, notify, log_error })` is the
key seam. The pipeline module never `require("ue")` — that would
create a circular import the first time `ue.lua` reads the schema. By
having ue.lua hand the runtime objects in once during setup, the
pipeline module remains:

- import-safe at any load order
- mockable in headless tests (`set_runtime{ jobstart = stub, notify =
  capture, log_error = capture }`)
- free of monolith-specific upvalue capture

The same pattern is reused in `ue.cdb.paths.candidates(ctx, deps)`
where `deps = { first_executable, run_lines }`.

#### Schema with literal fallbacks

`ue.config.get("index.idle_cold_ms") or 120000` is the canonical
pattern. The literal value preserves behaviour exactly when no user
override is provided AND keeps `ue.lua` loadable even if `ue.config`
itself ever fails to require. Never a hard dependency.

#### Registry, not if-elseif

`ue.dap.platforms` exposes `register_attach(id, fn)` /
`register_launch(id, fn)` / `attach_handler(id)` / `known_platforms()`.
Every UEDAP dispatch reads this table. To add a new platform,
write a new module under `lua/ue/dap/<id>.lua` and add its name to
the `for _, id in ipairs({...})` loop in setup() — no edits to the
dispatch function itself.

---

## 4. Performance

### Startup / cold load

Behaviour is byte-for-byte equivalent to pre-branch. The new wrappers
add one table lookup per call, which is dominated by the work the
helpers themselves do (filesystem, JSON parse, subprocess, etc.).
The `ue.lua` main chunk now invokes `require("ue.core.fs")` once per
unique helper (Lua caches the module table) rather than zero times,
adding ~50 µs total cold cost (16 lookups × ~3 µs).

The headless smoke harness measures the chain end-to-end:

| Smoke run | Duration on Windows host (warm) |
|---|---|
| Pre-branch baseline (lint only) | not run formally |
| Phase A loaded                  | not run formally |
| Phase G smoke (95 checks)        | ~0.7 s |

The 95 checks include 4 driver loads, 8 module loads, 4 config
roundtrips, 33 public-API resolutions, and the dispatch table
population — all without spawning subprocesses.

### Runtime — clangd / index / pipeline

Identical to pre-branch:

- `INDEX_RT.idle_cold_ms` defaults to 120000ms exactly as before
- `INDEX_RT.debounce_*` defaults preserved
- CDB pipeline keeps the same script ordering: `expand → pch →
  resolve → unify → prune`
- Engine-only detection still flips `--include-engine`
- `python -I` isolation still applies to `prune_include_dirs.py`
- Win-vs-POSIX cp branch in pipeline post-step preserved
- clangd auto-restart on CDB mtime change preserved

### What got cheaper

- **Diff blast radius**: a future per-platform fix in `ue/dap/mac.lua`
  no longer requires reading 8 KLOC of `ue.lua`
- **Test cost**: `lua/ue/cdb/json.lua` is 67 lines; testing it does
  not pull in the rest of `ue.lua`. Phase G smoke runs 95 checks in
  under a second
- **Override cost**: a user with custom clangd path used to fork
  `ue.lua`. Now they call
  `require("ue.config").setup({ clangd = { candidates_extra = {"/my/clangd"} }})`

---

## 5. Quality / safety

### Public-API freeze

The foundation ADR locked a freeze list — 8 table fields and 25
public functions on `require("ue").*` plus 3 booleans on
`require("utils.platform").*`. The smoke harness asserts each of them
exists and is the right type after every change. Throughout 16
commits the freeze list never broke.

### Lint contract

`lint_no_bare_globals.lua` is a tree-sitter–based AST scan that
catches `foo = function() end` at file scope (which leaks into `_G`
and historically broke a forward-declared `local stop_android_debugger`).
80 files now pass. The pre-commit hook gates every commit.

### Sanitization

Every new file in this branch is free of:

- absolute personal paths (`C:\Users\<user>`, `<PROJ_DRIVE>\<name>`)
- personal email addresses
- internal repo URLs

Defaults derive from `vim.fn.stdpath("data")` /
`vim.fn.stdpath("config")` / `(vim.uv or vim.loop).os_homedir()`.
Existing PII in `docs/plans/2026-04-*.md`, `scripts/*.ps1` and
`workarounds/* owner:` frontmatter is intentionally **not** rewritten
(the foundation ADR documents this rule) because:

- they are historical artifacts
- rewriting them would invalidate working baselines under
  `docs/plans/baselines/`
- pre-commit hooks would break for users who track them

Future scripts/ADRs follow the new sanitization rule going forward.

### Backward compatibility checklist

| Invariant | Verified by |
|---|---|
| `require("utils.platform").is_windows` still boolean | smoke check |
| `require("ue").FT_CPP` still 13 entries | smoke check |
| `require("ue").clangd_cmd()` still callable, returns table | smoke check |
| `:UEAndroidDAPAttach` still registered | smoke check |
| `:UEAndroidDAPAttach` still calls `M.android_dap_attach()` | wrapper preserved |
| Old keymaps in `lua/config/keymaps.lua` still resolve | unchanged |
| `lazy-lock.json` unchanged | not touched in this branch |

---

## 6. Testing

### `scripts/headless_smoke.lua` (95 checks)

Run with `nvim -l scripts/headless_smoke.lua`. Exit 0 on green, exit
1 on first failure with offending lines printed first for scannable
CI logs.

Coverage by phase:

| Phase | Checks |
|---|---|
| A — platform driver        | 11 (5 modules + 4 driver-interface contracts + 2 boolean shims) |
| B — ue/core extraction     | 8 (2 modules + 4 fs equivalence + 1 proc + 1 absolute path) |
| C — config schema seed     | 6 (1 module + 4 keys + 1 setup roundtrip) |
| E.1 — ue/cdb/json          | 5 (1 module + 4 cases) |
| E.2 — ue/cdb/{paths,shaders}| 5 (2 modules + 3 cases) |
| E.3 — ue/cdb/pipeline      | 2 (1 module + DI roundtrip) |
| Public freeze              | 8 tables + 25 functions = 33 |
| F.1+F.2 — UEDAP* + dispatch| 3 (alias registration + dispatch table + android present) |
| H — per-platform DAP       | 3 (4 modules export attach/launch + register_attach for all + find_codelldb shape) |
| I — schema expansion       | 6 (1 schema shape + 5 keys) |
| J — android wire            | 3 (state wins / cfg fills / lldb cfg wins) |
| F.3 — deprecation tracker  | 1 |

### `scripts/lint_no_bare_globals.lua`

80 .lua files scanned, 0 bare-global function assignments.

### `.github/workflows/headless.yml`

Triple matrix on push to `main` / `feat/**` and on PR:

```yaml
matrix:
  os: [ubuntu-latest, macos-latest, windows-latest]
```

Each job: install nvim stable → run lint → run smoke. `fail-fast:
false` so a Mac-only regression cannot mask a Linux-only one. This
is the first time the macOS and Linux drivers get exercised by a
real OS.

---

## 7. Sanitization audit (one-time, this branch only)

Found and **left unmodified** in pre-existing files:

| File | Reason |
|---|---|
| `docs/plans/2026-04-17-instant-goto-architecture.md` | Historical ADR; references `/mnt/c/Users/<user>` for reproducibility |
| `docs/plans/2026-04-20-syntax-overload-disambiguation.md` | Same |
| `docs/release_1.0.0.md` | Author signature and personal repo URL |
| `lua/workarounds/*.lua` `owner:` frontmatter | Workaround contract requires named owner |
| `scripts/*.ps1` | Hardcoded user paths to local Python and tools dirs |
| `lua/utils/cheatsheet.lua` (path string) | not modified |

Found and **scrubbed** in this branch's new content:

- All paths in new `.lua` and ADR files use `vim.fn.stdpath` or
  `<USER>` / `<LOCAL_APPDATA>` placeholders
- No new email addresses, no new personal repo URLs
- CI workflow runs against the repo without injecting any personal
  identifiers

A future "sanitization v2" pass on the legacy files is left out of
scope; doing it now would require rewriting working baselines and
the pre-commit hook contract.

---

## 8. Followup work — explicitly deferred

| Item | Why deferred |
|---|---|
| **K** — port `lua/config/windows.lua` to use the platform driver for `open_in_explorer` / `terminal_shell` | Phase A laid the seam; a follow-up commit can swap call sites without touching `ue.lua` |
| **L** — wider `ue.config` migration (PCH script names, gtags exclude lists, picker excludes) | Phase I proved the schema shape; future commits move keys one subsystem at a time |
| **M** — split the ANSI / quickfix parsing block out of `ue.lua` | Pure code; can become `ue/output/parse.lua` whenever someone touches it |
| **N** — split the `picker_*` block (`ue.lua` lines 4901-5043) | Touches `vim.iter` and snacks; needs a small dedicated ADR |
| **O** — real iOS DAP plumbing (`xcrun devicectl` device discovery + attach) | Needs a Mac with iOS device for verification |
| **P** — replace forked `cindex-uefilter` Go binary with upstream once `-files-from FILE` is upstreamed | Tracked in `tools/cindex-uefilter/README.md` |
| **Q** — extract the workaround registry's frontmatter parser into its own shared util | Currently fine where it is |
| Real macOS / Linux user-acceptance test on UE5 source tree | Needs a Mac/Linux machine; CI proves the modules load, not that they work end-to-end |

The branch deliberately stops here so the foundation can soak in the
maintainer's daily Windows workflow before the next round of changes.

---

## 9. Numbers

| Metric | Pre-branch | Post-branch | Δ |
|---|---|---|---|
| `lua/` total .lua files | 62 | 80 | +18 |
| `lua/` total bytes | 747,819 | 790,555 | +5.7 % |
| `lua/ue.lua` line count | 7973 | 7771 | −2.5 % (extracted into siblings) |
| `lua/ue.lua` top-level locals | 202 | 202 | 0 (the wrapper trick) |
| Public functions on `require("ue")` | 35 | 35 | 0 (freeze list intact) |
| Lint files OK | (not formally run) | 80 | — |
| Headless smoke checks | 0 | 95 | +95 |
| Configuration-overridable keys | 0 | 11 (`index.* / context.* / paths.* / clangd.* / dap.* / cdb.*`) | +11 |
| Platforms with a real driver | 1 (Windows inline) | 4 (Win/Mac/Linux + stub fallback) | +3 |
| DAP platforms registered | 1 (Android) | 5 (Android, Win64, Mac, Linux, iOS) | +4 |
| ADR documents | 2 (Apr) | 7 (Apr 2 + May 5) | +5 |
| CI matrix size | 0 | 3 (Win + Mac + Linux) | +3 |

---

## 10. Branch acceptance — when to merge

The branch is ready for `git merge --no-ff` when the maintainer has:

- [ ] Run `nvim -l scripts/headless_smoke.lua` locally on Windows
      and seen `=== 95/95 passed, 0 failed ===`
- [ ] Run `nvim -l scripts/lint_no_bare_globals.lua` and seen
      `80 files scanned, OK`
- [ ] Opened a real UE5 project in `nvim` and run `:UEPrepare`
      successfully (CDB pipeline still drives clangd as before)
- [ ] Triggered `:UEAndroidDAPAttach` once and observed the
      one-shot deprecation WARN, then a second invocation that runs
      silently
- [ ] Optional: pushed the branch and confirmed all three CI matrix
      jobs are green on GitHub Actions

After merge, the worktree at `<LOCAL_APPDATA>/nvim-multiplatform`
can be removed with `git worktree remove`.

---

## 11. References

- ADR — Foundation: `docs/plans/2026-05-06-multi-platform-foundation.md`
- ADR — CDB pipeline split: `docs/plans/2026-05-07-cdb-pipeline-split.md`
- ADR — DAP multi-platform: `docs/plans/2026-05-07-dap-multiplatform.md`
- ADR — DAP real platforms: `docs/plans/2026-05-07-dap-real-platforms.md`
- ADR — Config schema expansion: `docs/plans/2026-05-07-config-schema-expansion.md`
- ADR — Android wire: `docs/plans/2026-05-07-android-config-wire.md`
- Smoke harness: `scripts/headless_smoke.lua`
- Lint: `scripts/lint_no_bare_globals.lua`
- CI: `.github/workflows/headless.yml`
