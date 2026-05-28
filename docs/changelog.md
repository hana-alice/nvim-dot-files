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


---

## 2026-05-28 (#3) - csearch 漏 project 侧整个 CSharpScript / TypeScript / Config 树

**Issue**
用户希望 csearch 收 .ini / .ts / .cs，结果发现 csearch grep 完全搜不到 `E:\aki\zeqiang_aki_3.4\Source\Client\CSharpScript\...` 下的内容（GameSettingsConfig 0 hits），也搜不到 .ini 里的常见 token（AndroidPackageName 在 .ini 0 hits / .cpp 40 hits）。但 workspace_all.files 里这些路径都在。

**Root cause**
跨盘符 (project 在 E:，engine 在 D:) 导致 `workspace_root()` 退化为 `engine_root = D:/project/uetemp`，然后 `_ufs.relative_to(root, project_abs_path)` 因 `path_has_prefix` false → **返回原绝对路径**，所以 workspace_all 列表里 project 侧文件全是绝对路径 `E:/aki/...` 开头。但 ue.lua 三处构造 cindex `csearch_filelist.txt` 时无脑 `fout:write(cs_root, "/", rel, "\n")`，对 project 文件拼出 `D:/project/uetemp/E:/aki/.../GameSettingsConfig.cs` 这种荒诞路径 → cindex `os.Stat` fail → skipped++ → **整个 project 树（含 CSharpScript / TypeScript / Source / Config / Plugins）在 csearch 索引里完全不存在**。

只有 engine 侧（`Engine/...` 相对路径）拼出来是有效的，所以 csearch 看起来"能工作"，掩盖了 50%+ 文件缺失。

**Fix**
`lua/ue.lua` 三处构造 csearch filelist 的循环（7891 sync UEPrepare、8095 fast-path、8416 cold async）统一加 `_ufs.is_absolute_path(rel)` 判断——绝对路径直写，相对路径才前缀 cs_root。

顺手 `lua/utils/code_search/init.lua:143` 的 `opts.code_only` ext 白名单补 ts/tsx/js/yaml/yml/conf/py/lua/glsl/ipp/inc/m/mm/metal（之前缺 ts/tsx 等，未来如果有 caller 传 code_only=true 会误过滤）。

**Validation**
- `luac -p` 两文件 silent pass (ue.lua 9497 行 / code_search 502 行)
- nvim --headless setup() 5 commands 全 REG
- `is_absolute_path("E:/aki/x.cs") = "E:/"` (truthy), `"Engine/Source/X.cpp" = nil` (falsy)

**Validation pending (用户重启 nvim 后)**
- `:UEPrepare!` 强制重建（必须 bang，老 list/idx mtime 不能触发 freshness）
- csearch `'GameSettingsConfig'` 应有 hits
- csearch `-f '\.ini$' 'AndroidPackageName'` 应非空
- csearch `-f 'Source[\\/]Client[\\/]CSharpScript'` 应有 30k+ 文件

**Why csearch.idx 5/14 老 vintage hides this**
两个 bug 叠加：上次会话修了 set_project 不 invalidate cache（5/14 idx 一直被 fast-path 认为 fresh），但即便 invalidate 修好后重建出来的 idx 仍然缺 project 树——因为这第三个 bug 长期存在。两个 bug 修完才能真正看到完整 index。

**Follow-ups**
- 长期：考虑把 `workspace_all.files` 永久改成全绝对路径（统一格式），cindex filelist 构造时永不前缀。这是更干净的设计，但要改 list 消费者（picker、status 显示）所有 caller。这次先打 fix 不改格式契约。
- 验证 GTAGS 那条链是否也踩同样 bug（gtags 用 workspace.files 不含 .cs/.ts 反而幸免）


---

## 2026-05-28 (#4) - prepare_freshness 自指 anchor 假 stale WARN

**Issue**
`:UEPrepare!` 跑完后任何 `<leader>/` (cached_grep) 都立刻弹 `[grep] :UEPrepare is stale (worktree changed since last run) — results may miss new files`，但实际什么都没变。

**Root cause**
`prepare_freshness` (lua/ue.lua:~3253) 把 `iso_to_epoch(state.updated_at)` 算进 anchor max。但 state.updated_at 是 `:UEPrepare` finalize 阶段写的——`list_dump → cindex csearch ~120s → finalize 写 state.json`——所以 state.updated_at **必然** = list_mt + 2~3 分钟。于是 `list_mt < anchor_max(state.updated_at)` 永远 true → freshness 报 `stale` → notify_freshness (5612) 弹 WARN。每次 :UEPrepare 跑完下次 grep 100% 触发。

**Fix (方案 A)**
从 anchors 列表里删 `iso_to_epoch(state.updated_at)`。剩四个 anchor (git index×2 / dir mtime×2) 仍能感知真实 stale 信号。state.updated_at 原本想 catch project 重配置，现在 :UESetProject 走 invalidate_project_scoped_cache 删 list → list_stat==nil → "never" 分支已覆盖，所以 anchor#5 已是冗余 + 倒置语义。

**Validation**
- luac -p silent pass (9503 行)
- nvim --headless setup() 5 commands 全 REG

**Pending user validation**
- 重启 nvim → :UEPrepare!（让前面 cross-drive 修复也生效）→ 立刻 `<leader>/` → **不应**弹 stale WARN
- 后续真改文件（git pull / 新建文件）→ 仍应正确报 stale

**已归档**
- skill `ue-cdb-missing-new-files` Pitfall 12: prepare_freshness anchor 自指 stale
