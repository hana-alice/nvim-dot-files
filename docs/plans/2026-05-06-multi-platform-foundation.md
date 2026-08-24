# Multi-Platform Foundation — Migration ADR

> **Historical snapshot / superseded.** 本文保留 2026-05-06 的迁移计划与决策背景，
> 其中 Phase 0、stub 状态和旧 driver interface 不再描述当前代码。现行平台边界以
> [`../architecture/overview.md`](../architecture/overview.md) 与 OpenSpec 的
> `host-platform-driver`、`ue-target-driver-boundary`、`ue-target-workflow-boundary` 为准。

> **Status**: Proposed → Phase 0 in progress
> **Branch**: `feat/multi-platform-foundation`
> **Worktree**: `<LOCAL_APPDATA>/nvim-multiplatform`
> **Owner**: config maintainer
> **Created**: 2026-05-06

---

## Context

This nvim configuration is a production-grade Windows-first Unreal Engine
editor: ~17 KLOC of Lua across 63 modules, plus a workaround registry,
rotating logger, headless test harness, and an 8 KLOC `lua/ue.lua` engine
that owns clangd lifecycle, compile-commands pipeline, background indexer,
and DAP forwarding.

We now need full-platform parity for a multi-target UE workflow:
**Win64**, **Android**, **macOS**, **iOS**, **Linux**.

Today the configuration assumes:

- Windows-only shell (`pwsh`/`cmd.exe`/`explorer.exe`)
- Windows-style `cmd.exe /c start ""` for opening files
- Single boolean platform abstraction (`platform.is_windows`)
- All UE engine logic in one 8 KLOC file
- Tunables hard-coded inside `INDEX_RT` / function bodies

These assumptions block a clean port to non-Windows hosts.

## Problem statement

> **How do we evolve the existing config to first-class multi-platform
> support without breaking the working Windows install or the existing
> headless test suite?**

Three properties matter most:

1. **Reversibility** — every step must keep `git revert <range>` viable.
2. **Test parity** — existing scripts under `scripts/` and `tools/` keep
   passing throughout the migration.
3. **API stability** — `require("ue").FT_CPP`, `require("ue").clangd_cmd`,
   etc. used by `lua/plugins/ue.lua` and external callers must remain
   resolvable through every intermediate state.

## Decision

Adopt a **5-phase migration** that transforms the configuration from
"Windows-first with platform booleans" into "platform-driver-based with
modular UE engine and configurable schema", in dependency order, never
breaking the public API.

```
Phase 0  Foundation        : worktree + ADR + sanitization audit
Phase A  Platform driver   : platform.lua → driver registry + per-OS files
Phase B  ue/core extraction: split ue.lua's fs/proc/string utilities
Phase C  Config schema     : ue/config.lua centralizes tunables
Phase D  Headless gate     : nvim --headless smoke + lint_no_bare_globals
─────────────────────────────────────────────────────────────────────
Phase E  CDB pipeline split (followup ADR)
Phase F  DAP rename + multi-platform driver (followup ADR)
Phase G  Cross-OS install scripts (followup ADR)
```

Phases A–D are this ADR's scope (~1 evening of work).
Phases E–G get their own ADRs once the foundation lands.

## Architecture

### Before — coupling map

```
init.lua
  ├─ utils/log
  ├─ config/neovide
  ├─ config/snacks_global
  ├─ config/lazy
  ├─ config/windows         ← hard pwsh/explorer.exe assumptions
  ├─ utils/recent_projects
  ├─ workarounds            ← OK, scope-isolated
  └─ ue (8 KLOC monolith)
       ├─ inline core utils (fs/proc/string/path)
       ├─ inline platform branches (Win64 hardcoded, Android partial)
       ├─ inline tunables (INDEX_RT.idle_cold_ms = 120000, etc.)
       └─ M.* of 35 public functions
```

### After Phase A–C

```
init.lua
  ├─ utils/log
  ├─ utils/platform         ← driver registry
  │    └─ platform/
  │         ├─ windows.lua  (existing behaviour, extracted)
  │         ├─ macos.lua    (stub returning sane defaults)
  │         └─ linux.lua    (stub returning sane defaults)
  ├─ config/neovide
  ├─ config/snacks_global
  ├─ config/lazy
  ├─ config/windows         ← internal: only runs when driver.id == "windows"
  ├─ utils/recent_projects
  ├─ workarounds
  └─ ue
       ├─ ue/core/          ← extracted utilities
       │    ├─ fs.lua       (norm/join/dirname/is_dir/...)
       │    ├─ proc.lua     (run_lines/jobstart wrapper)
       │    └─ str.lua      (trim/...)
       ├─ ue/config.lua     ← schema + getters, no behaviour change
       └─ ue.lua (still 8 KLOC; reexports core/* + reads from config)
```

### Backward-compat contract

For each extracted module, the original `ue.lua` keeps a same-named
local that does `local fs = require("ue.core.fs")` and exposes it under
the original `M.foo` name. Existing `lua/plugins/ue.lua` and the 60-test
harness must continue to pass without edits.

The `platform` module preserves `M.is_windows`, `M.is_mac`, `M.is_linux`
booleans; new `M.id`, `M.driver()` are additive.

## Public-API freeze list

These are the exported symbols **other code reads through `require()`**.
None of them may change in Phase A–D.

From `require("utils.platform")`:

- `is_windows`, `is_mac`, `is_linux` (boolean fields)

From `require("ue")`:

- `setup()`
- `clangd_cmd(root_dir?)`, `clangd_root(bufnr?)`
- `current_platform()`, `platform_path_priorities(platform?)`
- `android_build_command(opts?)`
- `picker_options(opts?)`, `picker_project_options(opts?)`,
  `current_scope_picker_options(opts?)`
- `cached_grep_file_list(opts?)`, `cached_code_file_list(opts?)`,
  `cached_files(opts?)`, `cached_grep(opts?)`
- `statusline_status(opts?)`, `index_status(opts?)`,
  `index_now(opts?)`, `index_hot(opts?)`, `index_full(opts?)`
- `ue_roots(opts?)`
- `gtags_rebuild_shaders()`, `gtags_references(symbol)`,
  `gtags_definition(symbol)`, `gtags_definition_async(symbol, on_done)`
- `launch_app()`, `toggle_log()`, `toggle_debug_log()`
- `prepare_headless()`
- `FT_CPP`, `FT_SHADER`, `FT_CODE`, `FT_CONFIG`, `FT_ALL`, `FT_GTAGS`,
  `GLOBS_CODE`, `GLOBS_ALL` (table fields)
- `dap.*` reexports (preserved as-is)
- `_async.run_lines(cmd, opts, on_done)` (test-internal but used)
- `codelldb_paths` (test-internal)

## Sanitization rules (in effect throughout)

The repo currently leaks several PII bits in historical files; the
rules below apply only to **new** or **rewritten** files in this branch.

| Forbidden pattern | Replacement |
|------------------|-------------|
| Personal username (`<USER>` or `<HANDLE>`) | `<USER>` placeholder where unavoidable |
| Absolute Windows paths (`C:\Users\...`) | `vim.fn.stdpath("data")` etc. |
| Absolute project paths (`<PROJ_DRIVE>\<NAME>\...`) | `vim.fn.getcwd()` or `:UESetProject` |
| Personal email addresses | omit |
| Hard-coded IPs / device serials | command argument or env var |
| Internal repo URLs | omit; reference upstream only |

Existing PII in `docs/plans/*`, `docs/release_*.md`, `scripts/*.ps1`,
and `lua/workarounds/*` `owner:` frontmatter is **intentionally left
untouched in this ADR** — they are historical artifacts and rewriting
them would invalidate working scripts and existing baselines.

## Phase-by-phase plan

### Phase A — Platform driver

**Goal**: replace the platform booleans with a driver registry while
preserving all current call sites.

**Files added**:

- `lua/utils/platform/init.lua` (new home, exports `id`/`is_*`/`driver()`)
- `lua/utils/platform/windows.lua` (concrete driver with current behaviour)
- `lua/utils/platform/macos.lua` (stub: nil for paths it does not yet know)
- `lua/utils/platform/linux.lua` (stub)

**Files modified**:

- `lua/utils/platform.lua` becomes a 3-line shim that requires
  `utils.platform.init` and re-exports the table — this keeps
  `require("utils.platform").is_windows` working byte-for-byte.

**Driver interface (versioned, additive only)**:

```lua
---@class PlatformDriver
---@field id        '"windows"'|'"macos"'|'"linux"'
---@field shell     fun(): string                -- "pwsh", "/bin/zsh", ...
---@field path_sep  '"\\"'|'"/"'                 -- native separator
---@field list_sep  '";"'|'":"'                  -- PATH separator
---@field exe_suffix '".exe"'|'""'
---@field open_path fun(path: string)            -- explorer / open / xdg-open
---@field reveal_file fun(path: string)          -- /select equivalent
---@field default_clangd_candidates fun(): string[]
---@field default_codelldb_paths   fun(): string[]
---@field default_lldb_server_paths fun(): string[]
---@field cmd_quote fun(value: string): string
local DRIVER = ...
```

Stub drivers for macOS and Linux return empty/`nil` for unknown fields.
Callers must `pcall` or check before using non-windows drivers in
this phase. **No existing call site changes** — Phase A is purely
additive plumbing.

**Test gate**:

```lua
-- nvim --headless -c 'lua require("utils.platform")' +qa
```

Must exit code 0 on Windows. The shim guarantees current behaviour.

### Phase B — `ue/core/` extraction

**Goal**: lift `ue.lua`'s local `trim`/`norm`/`cwd`/`join`/`dirname`/
`is_dir`/`is_file`/`ensure_dir`/`file_stat`/`file_mtime`/`path_has_prefix`/
`is_absolute_path`/`split_path`/`common_ancestor`/`relative_to`/
`first_executable` into `lua/ue/core/fs.lua` (and a few `proc/str` peers),
without changing `ue.lua`'s observable behaviour.

**Files added**:

- `lua/ue/core/fs.lua` — path utilities
- `lua/ue/core/proc.lua` — `run_lines` + first_executable
- `lua/ue/core/str.lua` — trim and any pure string helpers

**Files modified**:

- `lua/ue.lua` — top of file replaces local definitions with
  `local fs = require("ue.core.fs")` etc. The original `local function trim`
  / `local function norm` / ... become locals bound to the module fields
  to keep all internal call sites byte-for-byte equivalent:

  ```lua
  local fs = require("ue.core.fs")
  local norm    = fs.norm
  local join    = fs.join
  local dirname = fs.dirname
  -- ... etc
  ```

  This is a **mechanical extraction**, not a refactor. The functions move;
  no new behaviour, no signature change.

**Test gate**:

```bash
nvim --headless -c 'lua assert(require("ue").FT_CPP)' +qa
nvim --headless -c 'lua require("ue").clangd_cmd()' +qa
```

Plus `scripts/run_all_tests.ps1` if the user is on Windows.

### Phase C — `ue/config.lua` schema

**Goal**: pull tunables out of code into a single `ue.config` schema with
`vim.tbl_deep_extend`-friendly user override.

**Files added**:

- `lua/ue/config.lua` — schema + `setup()` + `get(path)`

**Schema initial contents** (only the tunables that already exist in code,
no new policy):

```lua
{
  index = {
    idle_cold_ms       = 120000,
    debounce_current_ms = 1200,
    debounce_hot_ms    = 8000,
    restart_debounce_s = 45,
    status_ttl_s       = 30,
  },
  context = {
    ttl_s = 30,
  },
  paths = {
    state_dir = vim.fn.stdpath("state") .. "/ue",
    cache_dir = vim.fn.stdpath("cache") .. "/ue",
  },
  platforms = {
    enabled = { "Win64", "Android", "Mac", "IOS", "Linux" },
    -- when nil, current_platform() auto-detects
    default = nil,
  },
}
```

**Files modified**:

- `lua/ue.lua` — `INDEX_RT.idle_cold_ms = 120000` becomes
  `INDEX_RT.idle_cold_ms = require("ue.config").get("index.idle_cold_ms")`
  with a fallback to current default if config has not been initialised
  (paranoid — `ue/config` initialises on require).

This is the smallest possible Phase C that proves the schema works,
without touching every site that reads a constant. Future phases can
migrate more keys.

**Test gate**:

```lua
nvim --headless -c 'lua print(require("ue.config").get("index.idle_cold_ms"))' +qa
-- expects: 120000
```

### Phase D — Headless gate

**Goal**: ensure the whole pipeline still loads cleanly on a stock nvim,
and re-validate `lint_no_bare_globals.lua` so we did not accidentally
introduce a global.

**Test commands** (all run from worktree root):

```bash
# 1. Init succeeds (LazyVim cold install path is skipped because lazy is
#    already cloned; if cold, lazy.nvim would auto-clone)
nvim --headless +qa 2>&1 | tee .test/init.log
# Exit: 0

# 2. Each new module loads
nvim --headless -c 'lua require("utils.platform")' +qa
nvim --headless -c 'lua require("utils.platform.windows")' +qa
nvim --headless -c 'lua require("utils.platform.macos")' +qa
nvim --headless -c 'lua require("utils.platform.linux")' +qa
nvim --headless -c 'lua require("ue.core.fs")' +qa
nvim --headless -c 'lua require("ue.core.proc")' +qa
nvim --headless -c 'lua require("ue.core.str")' +qa
nvim --headless -c 'lua require("ue.config")' +qa

# 3. Public API still resolves
nvim --headless -c 'lua assert(require("ue").FT_CPP)' +qa
nvim --headless -c 'lua assert(type(require("ue").clangd_cmd) == "function")' +qa

# 4. Lint
nvim --headless -c 'luafile scripts/lint_no_bare_globals.lua' +qa
```

If any of these fail, **the change is reverted and the ADR is updated**.

## Out of scope for this ADR

- Splitting `cdb/` (Phase E) — the pipeline is the highest-coupling part
  and warrants a dedicated ADR with its own dependency graph
- Renaming `UEAndroidDAP*` → `UEDAP*` (Phase F) — affects user keymaps,
  needs a deprecation period
- macOS/Linux installer scripts (Phase G) — needs a real Mac/Linux host
  to validate
- Existing PII in historical scripts and ADRs — intentionally untouched

## Risks and mitigations

| Risk | Likelihood | Mitigation |
|------|-----------|-----------|
| `require("utils.platform")` shim does not preserve identity table | Low | Shim uses `return require("utils.platform.init")` so `M.is_windows == M.is_windows` is the same table reference across both old/new entry points |
| Mechanical core extraction misses an upvalue capture | Med | Keep `local fn = mod.fn` aliases for every extracted symbol; no inline call-site rewrite in Phase B |
| `ue.config` initialisation order races with `ue.lua` first read | Low | `ue.config` is a leaf module with no `require("ue")` — safe to load first |
| Windows driver loses `_G.ue_term_buf` global | Low | Preserved in `lua/config/windows.lua`; Phase A does not touch it |
| LazyVim auto-loads change detection picks up new files and notifies user | Low | `change_detection.notify = false` is already set in `lua/config/lazy.lua` |
| User has uncommitted edits in main worktree during phase A | Med | Worktree branch is isolated; user can keep working on `main` |

## Rollback

Each phase is a separate commit on `feat/multi-platform-foundation`.
Rollback at any step is `git reset --hard <prev-commit>` inside the
worktree, or `git checkout main` to abandon the entire branch.

The main worktree at `<LOCAL_APPDATA>/nvim` is untouched throughout.

## Acceptance criteria

Branch `feat/multi-platform-foundation` is mergeable into `main` when:

1. All Phase D headless tests pass locally on Windows
2. No new file contains absolute personal paths or PII
3. `lint_no_bare_globals.lua` reports zero new globals
4. Every public-API symbol in the freeze list resolves the same way
   it did before
5. This ADR is updated with measured before/after numbers

## Followup work (separate ADRs)

- `docs/plans/<date>-cdb-pipeline-split.md` — Phase E
- `docs/plans/<date>-dap-multiplatform.md` — Phase F
- `docs/plans/<date>-cross-os-install.md` — Phase G
- `docs/plans/<date>-config-schema-expansion.md` — migrate remaining
  inline constants to `ue.config`
