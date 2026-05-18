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

## Unreleased

### 2026-05-18 — `.clangd` External.File 自动同步进 :UEPrepare

**Task**: 用户 :UEPrepare 跑完后 clangd 依然 background-index 烧 17GB+ /
32min CPU，根因是 `.clangd` 的 `Index.External.File` 留在 v3 cache 迁移前
的老路径 `<root>/.clangd-index/`，而真实 idx 已经搬到
`<root>/.cache/nvim-ue/clangd/index/`。LSP 找不到 external idx 静默回落
到 background build。修复 = 让 :UEPrepare 的 hot/current/full 索引完成
路径自动把 `.clangd` 的 External 块改写到 `cache_paths().active_index` 的
权威路径。

**Implemented**
- `lua/ue.lua` 新增 `INDEX_FN.sync_dot_clangd(ctx)` (放在
  `INDEX_FN.promote_active_index` 后面)：surgical 编辑 `<engine_root>/.clangd`
  里的 `Index.External.{File,MountPoint}` 两行；用 Lua pattern 局部替换
  保留 `CompileFlags:` (/vctoolsdir + MSVC 14.29.30133 + winsdkversion
  pin) / 注释 / Diagnostics 等用户内容；atomic write (tmp + fs_rename) 避
  免 clangd 中途读到半截文件；idempotent — 内容一致直接返回 unchanged
  不写盘。
- `lua/ue.lua` 在 `INDEX_FN.build_phase_async` 的 success 分支
  (L~2914)、`promote_active_index` 之后 `clear_module_dirty_flags` 之前
  `pcall(INDEX_FN.sync_dot_clangd, ctx)`。pcall 兜底网络盘 / 只读盘失败
  不阻断 pipeline。
- `.hermes/plans/2026-05-18_112303-sync-dot-clangd-into-ueprepare.md`
  Plan 落盘（Goal / 6 风险 / 验证矩阵）。
- `.hermes/tests/test_sync_dot_clangd.lua` 单测脚本（headless luafile）：
  覆盖三件事 — 路径正确切换、CompileFlags byte-preserve、二次调用 byte-
  identical。

**Pitfalls / Gotchas**
- Lua pattern 不是真 regex：先 `gsub(..., 1)` 拿到 `_, n_replaced`，n==0
  时再走 inject fallback，避免 "External: 有但 File: 没" 的边角 case
  整段被吞。
- `vim.fn.environ()` 在 Windows 下 `key = nil` 移除不掉 — 这是另一条
  既有教训，不在本次范围。
- `pcall` 包 sync_dot_clangd：网络盘 / 只读 .clangd / engine_root 是文
  件 (而非目录) 都不应炸断 pipeline 后续 `maybe_restart_clangd_for_index`。
- LuaJIT 200-local 上限：新增的 helper 全部挂 `INDEX_FN.` 表（不增 main
  chunk local 数），headless require 通过。
- 已存 clangd 进程是用旧 .clangd 启的，sync 后必须 :LspRestart / 杀进程
  才会读新配置。本次直接 `Stop-Process` PID 42792 (1.6h CPU/14.8GB) 让
  nvim 下次 attach 自动新生。

**Validation**
- `nvim --headless +'lua print(pcall(require,"ue"))' +q` → OK (无 200
  local 爆 / 无语法错)。
- `nvim --headless -c 'luafile .hermes/tests/test_sync_dot_clangd.lua'`
  → ALL TESTS PASSED：
  - CALL 1: ok=true msg=updated, File 从 `.clangd-index\` → `.cache\nvim-ue\clangd\index\`
  - CALL 2: ok=true msg=unchanged (byte-identical)
  - CompileFlags /vctoolsdir + 14.29.30133 完整保留
  - 注释块 (VS2026 STL builtins 说明 11 行) 完整保留
- 杀 clangd PID 42792 完成，下次 nvim attach 读新 .clangd 直接 mmap
  external idx (沿用 v1.0.2 super-unity 产物 hot.idx 99 MB)。

**Follow-ups**
- inject_definitions_to_cdb.py per-file 路径 70% TU 缺 UE_BUILD_DEVELOPMENT
  (独立 follow-up，与 sync 无关)。
- ue.lua `clangd_cmd` 还在传 `--background-index`，跟 `.clangd` 的
  `Background: Skip` 冲突 (clangd 行为：.clangd 覆盖 CLI，所以是 cosmetic
  not functional)。可选清理。
- state.json 残留 project_root=`E:/proj/other_project_dev` (跨项目)，对当
  前 D:/project/UnrealEngine 场景无害但要 follow-up 修 (resolve_context
  没 invalidate)。

