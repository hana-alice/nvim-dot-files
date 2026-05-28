# Neovim Config Changelog

Working log for every change inside `~/AppData/Local/nvim/`. Every commit
should add an entry here even if it's tiny — the goal is total recall across
sessions, not curated release notes. When entries pile up, slice off a
versioned `RELEASE_vX.Y.Z.md` (see `release_1.0.0.md` for the format) and
keep this file rolling forward as the unreleased section.

## Entry template

```
### YYYY-MM-DD — Short title

**Task** (one line — why you touched the config)

**Implemented**
- bullet list of concrete changes (file paths + function names)

**Pitfalls / Gotchas**
- traps hit during the change, with the fix

**Validation**
- how you proved it works (headless probe, live nvim test, etc.)

**Follow-ups**
- links to `.hermes/plans/*.md` or TODO bullets
```

## How to use

1. Before touching anything under `~/AppData/Local/nvim/`, skim the latest
   N entries here. Fresh sessions don't carry context — this is where you
   recover it.
2. After landing a change (even a one-line patch), append an entry.
3. When 8–12 entries have piled up OR a coherent multi-change effort wraps,
   move them into `docs/release_vX.Y.Z.md`, tag the commit, leave a
   one-line cross-link under "Released" below.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`

## Unreleased

_No entries yet — append `### YYYY-MM-DD — Title` blocks here as work lands._


### 2026-05-28 — UE cache invalidation: setproject auto-invalidates, freshness uses external anchors, picker lazy-starts watcher

**Task** — The `<space><space>` picker and `:UEPrepare` were silently returning 5/14-era results on `D:\project\uetemp` after `z uetemp` + `:UESetProject E:\aki\zeqiang_aki_3.4` + build. Three compounding bugs hid behind one symptom.

**Implemented**
- `lua/ue.lua` — `set_project()` wrapped in `do ... end` + exposed as `CORE_RT.set_project` (dodges the 200-local LuaJIT cap). When `state.project_root` differs from incoming `project_root`, calls new `invalidate_project_scoped_cache(engine_root, "switch")` which removes the project file lists (project.files / workspace.files / workspace_all.files), csearch index (idx + ~ + ~~), gtags DBs under both `gtags_root` and `workspace_db`, all 4 cdb shards, `index_state` / `index_queue`, `dirty.json`, and every `*.idx` under `clangd/index/`. Clears `freshness_notified` + `context_cache` and stops/clears the watcher. Loud WARN toast lists what was invalidated and instructs the user to run `:UEPrepare` (or `:UEPrepare!`). **No auto-prepare** — explicit user-rule.
- `lua/ue.lua` — `CORE_RT.prepare_freshness(ctx)` rewritten against EXTERNAL anchors instead of self-validating against the list it consumes. `git_index_mtime(repo)` now resolves `.git` files (worktrees) by reading `gitdir: <path>` and stat-ing `<gitdir>/index`. Anchor set now includes `dir_mtime(engine_root)`, `dir_mtime(project_root)`, and `state.updated_at` (ISO8601 -> epoch). Watcher overlay: any non-empty `watch.persistent_dirty_status().count > 0` short-circuits to `stale`. The `"unknown"` return is gone — absence of all anchors now leans `stale`.
- `lua/ue.lua` — `prepare_async()` fast-path `need_index` block now delegates to `prepare_freshness(ctx)` instead of re-implementing a half-baked staleness check. Kills the self-validating loop where `csearch.idx.mtime >= workspace_all.files.mtime` always held because they were written within 1 minute of each other.
- `lua/ue.lua` — `M.cached_files()` lazy-starts `ue_watch` when entered with no live handle, so sessions that only ever open the picker still accumulate dirty data.
- `lua/utils/code_search/init.lua` — `build_index(ctx, abs_list, cb, opts)` learned `opts.mode = "reset" | "add"`. `"reset"` keeps `-reset -files-from`; `"add"` drops `-reset` for incremental cindex append.
- `lua/ue.lua` — `:UEPrepare` learned `bang = true`. Bare `:UEPrepare` runs the normal flow with the now-trustworthy external-anchor freshness check. `:UEPrepare!` marks engine_root dirty in `dirty_index_roots`, clears persistent dirty set, forces cold-path full rebuild with `force_csearch=true`.
- `lua/ue.lua` — `:UEPrepareIncremental` (new) snapshots the watcher's persistent dirty set and calls `build_index(..., { mode = "add" })` to append those files to csearch.idx without a full rebuild. Clears the dirty set on success. Only refreshes csearch — gtags/cdb still need normal `:UEPrepare`.

**Pitfalls / Gotchas**
- LuaJIT 200-local cap (skill `luajit-200-local-cap-with-loader-cache-mask`): adding `invalidate_project_scoped_cache` as a main-chunk `local function` pushed us over. Fixed by wrapping the pair in `do ... end` (block scope) and exposing `set_project` through `CORE_RT.set_project`. Updated `:UESetProject` command to call `CORE_RT.set_project(opts.args)`.
- A "function arguments expected near '5'" parse error reported at EOF turned out to be hermes-terminal stderr appended into the tail of `lua/ue.lua` and `code_search/init.lua` during patching (`/bin/bash: line 5: ...hermes-snap-*.sh: No such file or directory`). Detected via `wc -l` mismatch vs expected source length. Stripped via `head -n <last_legit> | cp` and re-verified with luac + loadfile. Worth a follow-up entry in `hermes-windows-io-traps`.
- `.git` as a file (worktree) is invisible to a naive `fs_stat(".git/index")`. Now there is one canonical `git_index_mtime` inside the `do ... end` containing `prepare_freshness`.
- `cindex-uefilter` (and upstream `cindex`) is documented as "add the file or directory tree to the index" when run WITHOUT `-reset`. That is the incremental contract `:UEPrepareIncremental` relies on.

**Validation**
- `luac -p` silent pass on both `lua/ue.lua` (9473 lines) and `lua/utils/code_search/init.lua` (499 lines).
- `nvim --headless ... loadfile()` returns a function for both (LuaJIT parse).
- Live nvim `M.setup()` registers all 5 expected commands with correct bang flag: `UEPrepare BANG-OK`, `UEPrepareIncremental noBang`, `UEPrepareReindex noBang`, `UESetProject noBang`, `UEWatchStatus noBang`.
- worktree-aware `git_index_mtime("D:/project/uetemp")` returned `1779855279` (vs old broken path returning `0`).
- Live anchor comparison on the actual failure case: list mtime 1778734024 (5/14) vs project_root dir mtime 1779351832, engine_root dir mtime 1779937352, state.updated_at epoch ~ 1779887792 -> max anchor far exceeds list -> `prepare_freshness` correctly returns `stale`.

**Follow-ups**
- Run `:UESetProject E:\aki\zeqiang_aki_3.4` on `D:\project\uetemp` and confirm: WARN toast with invalidation summary, then the picker shows freshness banner, then `:UEPrepare` / `:UEPrepareIncremental` both work.
- Update `hermes-windows-io-traps` skill with the "hermes stderr noise appended into edited file" trap.
- Extend invalidation hook to `:UESetUproject` and other state-changing config commands.


---

## 2026-05-28 (#2) - Engine/Config 没进文件 picker / csearch

**Issue**
`<space><space>` 文件 picker 找不到 engine 那份 `AndroidEngine.ini`（`D:\project\uetemp\Engine\Config\Android\AndroidEngine.ini`），只能找到 project 那份。`rg AndroidEngine.ini workspace_all.files` 确认 engine 那份**根本没进 list**。

**Root cause**
`UE_CONST.ENGINE_INDEX_DIRS = { "Engine/Source", "Engine/Plugins", "Engine/Shaders" }` —— **没有 `Engine/Config`**。project 侧 `PROJECT_INDEX_DIRS` 有 `Config`，engine 侧没有，不对称。`scan_relative_files` 走 `fd --search-path <whitelist>`，目录不在白名单就永远扫不到。文件扩展名层面没过滤（fd 全收），所以单纯加目录就够。

**Fix**
`lua/ue.lua:1515-1520` `ENGINE_INDEX_DIRS` 追加 `"Engine/Config"`。

**Validation**
- `luac -p lua/ue.lua` silent pass (9474 lines)
- nvim --headless `require("ue").setup()` ENGINE_INDEX_DIRS 内容: `Engine/Source, Engine/Plugins, Engine/Shaders, Engine/Config`，5 commands 全 REG
- `D:\project\uetemp\Engine\Config` 文件总数 = 85（list 增量可忽略）

**Follow-ups**
- 用户重启 nvim 后必须 `:UEPrepare!`（bang 强制重扫），否则 ENGINE_INDEX_DIRS 改了但 anchor mtime 没变，freshness 仍判 fresh，list 不会重生
- 同理：检查 `ENGINE_SHADER_DIRS` / `PROJECT_SHADER_DIRS` 是否也少目录（shader 扫描独立）
- 若以后 engine 侧再加目录（如 `Engine/Programs`），同步加入这里
