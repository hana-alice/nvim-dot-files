# What This Config Adds On Top Of LazyVim

> Repo:    https://github.com/hana-alice/nvim-dot-files
> Baseline: LazyVim (latest stable, pinned by `lazy-lock.json`)
> Audience: someone reading the source who has used LazyVim but never
>           seen a UE-centric Neovim setup.

LazyVim is treated as a **library**, not a finished product. We import
`lazyvim.plugins`, then layer ~45 custom Lua modules on top.
`init.lua` is two pages long; the real engine lives in
`lua/ue.lua` (323 KB single module) plus `lua/ue/`, `lua/utils/`, and
`lua/workarounds/`.

This document is the audit trail of **what we changed and why**. Every
section follows the same shape:

1. **LazyVim default** — what the upstream behaviour is.
2. **What we do instead** — the override.
3. **Why** — the concrete pain that motivated the change.
4. **Where** — files / functions / commands.

---

## 0. The big picture

```
+--------------------------------------------------------------------+
|                         init.lua                                   |
|   (bootstrap shada cleanup -> log -> neovide -> snacks_global ->   |
|    config.lazy -> windows -> recent_projects -> workarounds -> ue) |
+--------------------------+-----------------------------------------+
                           | imports
        +------------------v------------------+
        |       lazy.nvim + LazyVim spec      |   <- upstream LazyVim
        |  ("LazyVim/LazyVim" + "plugins")    |     plugins / keymaps
        +------------------+------------------+     / options / autocmds
                           | overrides via lua/plugins/*
        +------------------v------------------------------------+
        |             Our override layers                       |
        |                                                       |
        |  +--------------------------------------------------+ |
        |  | UE engine     (lua/ue.lua, lua/ue/*)             | |  (+) new
        |  | ue_goto       (lua/utils/ue_goto/*)              | |  (+) new
        |  | code_search   (lua/utils/code_search/*)          | |  (+) new
        |  | workarounds   (lua/workarounds/*)                | |  (+) new
        |  | DAP stack     (lua/ue/dap/*, lua/plugins/dap)    | |  (+) new
        |  | snacks tuning (lua/plugins/snacks.lua, 668 lines)| |  (~) override
        |  | Windows + Neovide ergonomics                     | |  (+) new
        |  | rotating logger, persistent state, restart       | |  (+) new
        |  +--------------------------------------------------+ |
        +-------------------------------------------------------+
```

Three architectural commitments distinguish this from a plain LazyVim:

- **No periodic ticker pollution.** Every plugin that polls (file
  watchers, MRU re-stat, "config reloaded" toasts) is either disabled or
  routed through `nio` async + skip-write checks.
- **Workarounds are first-class artefacts**, not unmarked `vim.api`
  monkey-patches scattered across `config/`. They live in their own
  files with removal conditions.
- **Self-verifiable modules.** Public API on `M.*`, callable from
  `nvim --headless -l`, so the entire stack can be regression-tested
  without a real Neovide.

---

## 1. UE C++ workflow — the headline feature

### LazyVim default
`clangd` is a default LazyVim LSP under `lazyvim.plugins.extras.lang.clangd`.
It launches against whatever `compile_commands.json` the project ships,
with no PCH support, no per-project flag tuning, no awareness of UE's
billion include directories. On a real UE project (Engine + Project
together), preamble parse takes ~60s, the file-watcher gets blown up by
`Intermediate/` churn, and goto-definition often misses generated
`*.gen.cpp` artifacts.

### What we do instead
A 323 KB module (`lua/ue.lua`) plus a `lua/ue/` subtree own the entire
UE C++ workflow:

```
ue/
  config.lua              user-tunable knobs (paths, toolchain, flags)
  ccjson_subprocess.lua   spawn workers for CDB transforms (off main thread)
  cdb/
    pipeline.lua          slim -> PCH-rewrite -> unify-includes -> prune-unused
    header_inject.lua     -include directives for forced UE headers
    pch_fi_inject.lua     forced-include companion to PCH precompile
    shards.lua            super-unity collapse (~13-50 aggregator TUs)
    paths.lua             path canonicalization (drive-letter forms)
    shaders.lua           HLSL/USF/USH GTags integration
  core/
    fs.lua                Blob-safe file IO (E976 trap, see workarounds)
    proc.lua              child-process spawning with Win32 quoting
  dap/                    see Section 6
```

### Why
- **Cold start under 20 seconds** on UE projects (was 60+s, sometimes
  minutes). PCH precompile + `-include` injection + prune-unused-dirs
  cuts preamble work by 60-90%.
- **Hot index 21x faster** (22 min 36 s -> 1 min 4.3 s on a 2985-TU hot
  subset) via super-unity collapse — see `release_1.0.2.md`.
- **No UI stalls** during `:UEPrepare` / reindex. All heavy lifting
  runs in subprocesses and only the final swap is on the main thread.

### Where
- `lua/ue.lua` — the monolithic engine (`:UEPrepare`, `:UEBuild`,
  `:UEAttach`, `:UELogs`, `:UECheatsheet`, ~150 `M.*` functions).
- `lua/plugins/ue.lua` — plugin spec entrypoint, fires `ue.setup()`.
- `tools/*.py` — out-of-process CDB / PCH / index utilities, also
  callable from CI.
- `tools/cindex-uefilter/` — Go fork of google/codesearch with
  `-files-from FILE` for clean indexing.

---

## 2. Contextual C++ goto-definition (`lua/utils/ue_goto/`)

### LazyVim default
`gd` -> `vim.lsp.buf.definition()`. On clangd-against-UE this means:
- 200-2000 ms wait for clangd to respond,
- if clangd is still parsing the preamble, you wait the full preamble
  time (~20s),
- on dependent names (templates) clangd often returns nothing — Vim
  falls back to `<cword>` tag search, which lands on the first match
  alphabetically, not the right one.

### What we do instead
C++ `gd` has a compiler-identity authority boundary; non-C++ keeps a
separate compatibility chain. The implementation is split by responsibility:

```
ue_goto/
  semantic_context.lua  pure proven-context / compiler-evidence model
  semantic_protocol.lua versioned NDJSON request/response contract
  semantic_sidecar.lua  libclang CDB/TU/canonical-USR resolution
  semantic_client.lua   async process, stale tokens, overlays, contexts
  provider.lua          exact-cursor clangd requests for source TUs
  jumper.lua            HARD-contract buffer/cursor switch + jumplist hygiene
  location.lua          location normalization/dedup
  cache.lua             non-C++ compatibility cache only
  csearch_fallback.lua  non-C++ compatibility fallback only
  ui.lua                progress/picker UI
```

### Why
- **Correct overload identity**: source calls require clangd's exact-cursor
  unique USR; headers are parsed by libclang in a compiler-emitted origin TU.
  Function name, arity, candidate order and text indexes never select a C++ target.
- **Honest terminal states**: missing/invalid/ambiguous semantic context keeps
  the cursor in place instead of silently choosing a same-name declaration.
- **Async warm-TU reuse**: cold parse and overlay reparse run in a headless
  sidecar; repeated queries reuse the same TU without a compiler process per keypress.
- **Hard jumper contract**: one `<Ctrl-O>` returns to source, exactly
  one jumplist entry, no spurious `(target_buf, 1, 0)` ghost. Written
  as a post-condition in `jumper.lua` and verified in CI.

### Where
- `lua/utils/ue_goto/jumper.lua` — the contract. Single responsibility.
- `lua/utils/lsp_fallback.lua` — the C++ authority boundary and non-C++ router.
- `scripts/ue_clang_semanticd.lua` — isolated libclang process entry.
- `docs/architecture-symbol-resolution.md` — the long-form architecture
  doc for this stack.

---

## 3. Workaround registry (`lua/workarounds/`)

### LazyVim default
Vendored patches live wherever they fit: a `vim.api.nvim_create_autocmd`
in `config/autocmds.lua`, a `vim.lsp.handlers["..."]` override in some
plugin spec, an inline monkey-patch buried in a `keys` callback. After
six months nobody remembers why a particular line exists or what would
break if it were removed.

### What we do instead
Every patch that exists *because of someone else's bug* lives in its
own file with a frontmatter contract:

```lua
-- WORKAROUND
-- name: snacks.projects_picker_freeze
-- scope: snacks
-- issue: internal: snacks projects MRU re-stat freezes Neovide
-- introduced: 2026-04-12
-- removal_condition: snacks.nvim ships async MRU
-- enabled: true
-- END WORKAROUND
```

### Why
- **Discoverable.** `:WorkaroundList` shows everything, including
  what would let us delete each entry.
- **Toggleable per-instance.** `:WorkaroundDisable <name>` to A/B
  test a vanilla behaviour without rebooting.
- **Self-pruning.** When upstream fixes the bug, cleanup is `git rm`,
  not archaeology.
- **Auditable in CI.** A linter rejects unscoped `vim.api` patches
  that bypass the registry.

### Where
- `lua/workarounds/init.lua` — registry, autocmd installer,
  `:Workaround*` commands.
- `lua/workarounds/README.md` — the contract.
- `lua/workarounds/TEMPLATE.lua` — copy-paste skeleton.
- 11 active workarounds today across `snacks/`, `clangd/`, `neovide/`,
  `lazy/`, `lazyvim/`, `blink_cmp/`.

---

## 4. snacks.nvim tuning (`lua/plugins/snacks.lua`, 668 lines)

### LazyVim default
LazyVim wires snacks.nvim with a default picker, dashboard, statusline,
explorer, notifier, etc. Out of the box it's pretty good for ~1 K-file
projects. On UE (~43 K files) the picker freezes on first open, the
explorer re-stats on every focus event, and the dashboard shows the
generic logo.

### What we do instead
A 668-line override that touches almost every snacks subsystem:

| Subsystem  | Override |
|-----------|----------|
| Picker     | File-type filter + grep filter helpers, blank history on open, custom layouts for grep/files/scope. |
| Pickers - grep | Toggle word/regex/case/file-filter at runtime via stateful mode toggles. |
| Pickers - files | `-files-from` integration with the codesearch index for sub-100ms `<leader>ff`. |
| Pickers - scope | "Current module/plugin" — UE-aware: respects engine/plugin/project boundaries. |
| Plugin spec picker | Browse loaded plugin specs with diffs against `lazy-lock`. |
| Dashboard | Custom pixel-art portrait header (`lua/dashboard_pix.lua`, 15 KB of ANSI). |
| Explorer  | Replaced re-stat-on-focus with a cached, fs_event-watched tree. |
| Notifier  | Stale-popup cleanup at DAP attach entrypoint (see Section 6). |
| Animate   | `scroll_animation_far_lines=200` — far cross-buffer jumps teleport instead of animating 5,000 lines of scroll (Neovide-specific fix). |

### Why
- **Sub-second pickers on UE.** Blank history + index-backed file
  search + scope-aware grep. `<leader>/` on `FRDGBuilder` returns in
  365 ms (was ~14 s).
- **Cross-buffer jumps don't flash.** The animate fix (scroll +
  cursor teleport via `vim.api.nvim__redraw{cursor=true, flush=true}`)
  eliminates the "jump -> scroll-anim -> cursor-anim" double-flash on
  goto-definition.
- **Notifier doesn't gaslight.** Stale popups from previous sessions
  are explicitly cleared, so when the user reports "still buggy" you
  can trust the popup count.

### Where
- `lua/plugins/snacks.lua` — the big override file.
- `lua/dashboard_pix.lua` — pixel-art header rendering.
- `lua/workarounds/snacks/*.lua` — bug-bypass patches separated out.

---

## 5. Windows-first ergonomics

### LazyVim default
LazyVim works on Windows but doesn't optimize for it. Default file
modes assume POSIX, path separators are inconsistent, Neovide-specific
quirks (animation pacing, ALT-key handling, IME wakeup latency) are
left to the user.

### What we do instead

| Concern | Default behaviour | Our override |
|---------|-------------------|--------------|
| Path separators | mixed `/` and `\` | normalize through `core.norm()` everywhere |
| File mode | `core.fileMode=true` (track exec bits) | assumed `false` (NTFS via WSL2) |
| Process spawn | `vim.fn.system()` | `lua/ue/core/proc.lua` with Win32 quoting |
| Neovide ALT-keys | swallowed by NVIDIA App on Alt+R/Z/F1/F9/F10/F12 | documented as OS-hook hijack |
| stdpath cleanup | grows forever | `cleanup_stale_shada_tmp()` on every startup |
| Lua module loader | luac cache breaks on missing parent dir | `mkdir -p Temp/nvim/luac` |
| Restart | `:qa!` then re-launch | `lua/utils/restart.lua` — graceful state save / Neovide re-spawn |

### Why
- This config lives on **Windows + Neovide**. Linux/macOS are
  secondary targets. We optimize for the primary platform and let
  the others fall back via stubs in `lua/utils/platform/`.
- Restart cycles during dev (reloading after a `lua/ue.lua` change)
  drop from "save -> close -> re-open -> re-attach DAP" to one command.

### Where
- `lua/config/windows.lua` — Win32-specific tunables.
- `lua/config/neovide.lua` — GUI animation pacing, ALT-key passthrough.
- `lua/utils/platform/{windows,linux,macos,stub}.lua` — platform
  capabilities table.
- `lua/utils/restart.lua` — restart command, Neovide-aware.
- `scripts/install_windows.ps1` — one-shot installer.

---

## 6. DAP stack — codelldb / lldb-dap on Android + Win64

### LazyVim default
DAP is opt-in via `lazyvim.plugins.extras.dap.core`. Wires `nvim-dap`
+ `nvim-dap-ui` + `mason-nvim-dap`, default adapter discovery via
Mason. No platform-specific config, no Android, no UE awareness, no
session-state machine, no breakpoint persistence across runs.

### What we do instead
A full DAP stack across `lua/ue/dap/` and `lua/plugins/dap.lua`:

```
ue/dap/
  _common.lua       adapter env (LLDBDAP_LOG, PYTHONHOME=""),
                    auto_continue_if_many_stopped=false, env-array form
  _persist_bp.lua   breakpoint persistence across nvim restarts,
                    per-project JSON under .cache/nvim-ue/breakpoints/
  _progress.lua     6-step progress popup during attach
  android.lua       Android: packageInfo.txt auto-discovery, lldb-server
                    push + platform-mode attach, signal disposition,
                    logcat sidecar, source-map injection
  win64.lua / linux.lua / mac.lua / ios.lua  per-platform stubs
  platforms.lua     route picker (which adapter for which buffer)
lua/ue/dap.lua      session orchestration: state machine
                    (idle / attaching / stopped / running / resuming),
                    F10 client throttle, focus-thread seeding, dapui
                    layout with right-bottom tab host
lua/plugins/dap.lua dap-ui layout only — left rail + bottom split
```

### Why
- **F10 spam no longer crashes the inferior.** Re-entrancy guard
  + 750 ms watchdog + optimistic `resuming` state mirror the
  `request_dap_continue` pattern; see commit
  `7c70462` and `release_1.0.3.md`.
- **lldb-dap 22 multi-thread stopped burst doesn't break focus.**
  `before.event_stopped` listener seeds the expected focus thread
  before nvim-dap sees non-`threadCausedFocus` events.
- **Android attach is one command** (`:UEDAPAttach android`):
  package + symbol-lib + lldb-server are auto-resolved from
  `packageInfo.txt` written by UE on every cook.
- **No popup wall.** Stale notifier toasts are cleared at every
  attach so DAP diagnostics aren't drowned in pre-fix residue.
- **VS-style layout**: left rail (locals / call stack / watches) +
  right-bottom tab host (REPL / console / breakpoints / logcat),
  switchable via `<leader>d1..d4` or `:UEDAPTab`.

### Where
- `lua/ue/dap.lua` — orchestrator (1,798 lines).
- `lua/ue/dap/android.lua` — Android attach driver (1,358 lines).
- `lua/ue/dap/_common.lua` — adapter env + nvim-dap defaults.
- `lua/plugins/dap.lua` — UI layout.
- `lua/config/keymaps.lua` — `<F5>`/`<F6>`/`<F10>`/`<F11>`/`<F12>` +
  `<leader>d*` family.

---

## 7. Sub-second grep on 100k-file workspaces (`lua/utils/code_search/`)

### LazyVim default
`<leader>/` (snacks grep picker) walks the directory tree on every
keystroke. On a UE workspace this is ~14-32 s per query because NTFS
recursion is the physical bottleneck.

### What we do instead
A trigram index built once per `:UEPrepare`, queried via a small Go
fork of `google/codesearch`. The fork adds one flag, `-files-from
FILE`, which lets us index exactly the clean file list `:UEPrepare`
already produces (skipping `graphify-out/`, `Intermediate/`,
`DerivedDataCache/`, etc.).

| Pattern               | Hits | csearch     | rg (walk) |
|-----------------------|------|-------------|-----------|
| `FRDGBuilder`         | 2491 | **365 ms**  | ~14 s     |
| `FRHICommandList`     | 6593 | **693 ms**  | ~18 s     |
| `NaniteRasterPipelines` | 57 | **73 ms**   | ~12 s     |

### Why
Trigram lookup is **O(answers)**, not O(workspace). The
post-filter step is on a few hundred files instead of forty thousand.

### Where
- `tools/cindex-uefilter/` — Go fork. `go install ./...` builds the
  binary; `:UEPrepare` detects it and writes
  `.cache/nvim-ue/csearch.idx` (~70 MB on a representative UE
  project).
- `lua/utils/code_search/init.lua` — picker integration; falls back
  to `rg --files-from` when the index is missing.

---

## 8. Rotating debug logger + persistent state

### LazyVim default
`:messages` for diagnostics. Lost on `:q`. No structured logging, no
persistent state across nvim restarts beyond shada.

### What we do instead
- `lua/utils/log.lua` — rotating file logger (24 KB). Auto-installs
  `:NvimLog*` commands. Module-aware levels, ANSI-stripped, written
  to `stdpath('cache')/nvim-rotating.log`.
- `lua/utils/restart.lua` — graceful restart with state preservation
  (cursor, jumplist, current buffer set). Used by `:UEReload` after
  a `lua/ue.lua` change so the user keeps their session.
- `cleanup_stale_shada_tmp()` in `init.lua` — purges shada tempfiles
  older than 5 minutes so a crashed nvim doesn't leak megabytes.
- `_persist_bp.lua` — DAP breakpoints persist across nvim restarts.

### Why
Debugging the config itself was painful: `:messages` truncates,
notifiers disappear, snacks history accumulates forever. The
rotating logger gives us a real audit trail. Restart was painful:
every `lua/ue.lua` change required closing the session.

### Where
- `lua/utils/log.lua`
- `lua/utils/restart.lua`
- `lua/ue/dap/_persist_bp.lua`
- `init.lua` lines 5-30

---

## 9. Self-verifiable modules + headless probes

### LazyVim default
Most config code is plugin-callback bodies that can only run inside a
live UI session. Testing requires the user to open nvim, do the
gesture, and report what happened.

### What we do instead
Every module exposes its public API on `M.*` and is callable from
`nvim --headless -l <script>.lua`:

```lua
-- example: ue/dap/android.lua test surface
function M._pick_package_for_test(ctx)    return pick_package(ctx)    end
function M._pick_symbol_lib_for_test(ctx) return pick_symbol_lib(ctx) end
function M._lldb_dap_attach_config_for_test(session, source_map)
  return lldb_dap_attach_config(session, source_map)
end
```

Combined with pynvim RPC over `\\.\pipe\nvim.PID.0` for live-session
inspection, we can:
- run a Python probe that drives `:UEPrepare` end-to-end and asserts
  outputs;
- inspect a live nvim's `package.loaded[...]` without disturbing it;
- hot-reload a Lua module + re-run its `setup()` to apply fixes in
  a running nvim instead of restarting.

### Why
Iterating on `lua/ue.lua` (323 KB) without headless tests is
unsustainable. A regression in PCH injection on one platform isn't
caught until someone opens a project there.

### Where
- Every `M._*_for_test` function in `lua/ue/**/*.lua`.
- `tools/probe_*.py` — out-of-process integration probes.
- `scripts/lldb_dap_*.py` — DAP smoke probes.

---

## What we deliberately *don't* do

A few common "improvements" we declined:

- **No telescope.** LazyVim ships snacks.picker now; we doubled down
  on it. Avoids two picker abstractions arguing in the same session.
- **No which-key cheatsheet.** We render our own (`:UECheatsheet`,
  `docs/ue_lazyvim_cheatsheet.md`) because which-key's auto-generated
  cheatsheet leaks plugin keys we never bound.
- **No copilot/codeium plugin in-config.** Reasoning is offloaded to
  external CLI tools (Claude Code, Codex) so the editor stays a text
  editor.
- **No `vim.lsp.handlers` global overrides.** Anything that touches
  LSP behaviour goes through `lua/utils/lsp_fallback.lua` or
  `lua/workarounds/clangd/*.lua` — never `vim.lsp.handlers["..."] = ...`
  in random callsites.
- **No mason auto-install.** We pin tooling versions (`docs/TOOLING.md`)
  and use `winget`/`scoop` for the toolchain. Mason's drift caused
  too many "works on my machine" bugs.

---

## Reading order if you're new to the repo

1. `README.md` — the elevator pitch.
2. This file — the architecture.
3. `docs/CONSTRAINTS.md` — the consolidated 禁止 / 坑 / 约束 checklist.
4. `docs/TOOLING.md` — version constraints (LLVM, lldb-dap, etc.).
5. `docs/architecture-symbol-resolution.md` — deep-dive on goto-def.
6. `docs/ue_lazyvim_cheatsheet.md` — every keymap.
7. `lua/workarounds/README.md` — the workaround contract.
8. `lua/ue.lua` head + `function M.setup()` — engine entrypoint.
9. `docs/release_1.0.*.md` — what each version changed.
