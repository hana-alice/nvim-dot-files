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

## Unreleased

---

### 2026-05-15 — 治本修 clangd LSP 对 UE .h / PCH-cpp 的结构性盲点

**任务**
UE 编 cl.exe 走得通，但 clangd LSP 给 .h 一片红 (`'MGShading.h' file not found` cascade)，
PCH-dependent .cpp 也红 (`unknown class FGlobalShader` fatal cascade)。根因是
UBT 出 cdb 时 (a) 只写 .cpp 不写 .h，clangd header inference 选不到正确 -I，
(b) 把 .cpp 的 /FI=SharedPCH 剥掉，cl 靠 /Yu /Fp 读 .pch 二进制能跑，但 clangd
不读 PCH binary，缺一片符号。

**完成**
- 新模块 `lua/ue/cdb/header_inject.lua` — 扫 `Engine/Intermediate/Build/<Plat>/<Target>/<Config>/*/<TU>.cpp.json`
  建 reverse-include 图，给每个 .h 选 donor (path A clone CDB entry + 补 /FI=PCH；
  path B 用 wrapper response 解析)。
- 新模块 `lua/ue/cdb/pch_fi_inject.lua` — 对 PCH-dependent .cpp 补回 /FI=SharedPCH。
- hook 进 ue.lua prepare pipeline ~L4834，按 bucket fan-out，shard 落盘前完成。
  shards 已含修复 → fast-swap 自动跟上。

**坑**
- LuaJIT 200-local cap: 不能在 ue.lua 顶层新增 local，inline require 进 trace_seg 闭包
- path A 不补 /FI=PCH 会回归 22 ERROR (skill PoC v6 数据)
- 路径必须 lowercase + slash 归一 (NTFS case-insensitive 但 map key 会撞)
- bucket roots 父 dir 即 config-level intermediate dir，不用从 rsp 反推
- pch_fi_inject 必须区分 SharedPCH/PCH.<X> vs 普通 /FI (Definitions.Renderer.h 不能加)

**验证 (subagent 阶段 — 用户实测待回填)**
- Subagent A smoke: scanned=1169 cpp.json, h_added=15341 (a=2059 b=13282), MG 三头 ✓
- Subagent B smoke: fi_added=130, MGRasterizer.cpp 拿到 SharedPCH.Engine.ShadowErrors.h
- 幂等验证: re-run fi_added=0 already_had=130
- 用户实测: TODO (重启 Neovide / 重跑 UEPrepare 后开 MGPipeline.h 看 diag)

**Follow-up**
- PCH per-platform 隔离 plan 仍待 (`.hermes/plans/2026-05-15_111637-pch-per-platform-isolation.md`)
  ── 本改用 text /FI 不读 PCH binary，对 LSP 无影响；那个 plan 后跟。

---

### 2026-05-15 — `:UESetPlatform` fast-swap (no re-prepare)

**Task** Win64 ↔ Android 切换时 `:UEPrepare` 会覆盖对方平台的产物，cdb
也会被字典序错选，clangd 出一堆假阳性。需要切平台不互相污染缓存，且
切回已 prepare 过的平台秒回。

**Implemented**
- `lua/ue.lua`: `CORE_RT.fast_swap_active_platform(engine_root)`. 不重跑
  `:UEPrepare`，直接 flip `manifest.active` → `shards.merge_shards` →
  `compile_commands_targets` 写 cdb → `run_compile_commands_pipeline` 跑
  expand/pch/resolve/unify/prune → `:LspRestart clangd`。~1s 完成（vs
  full prepare ~30-60s）。
- `lua/ue.lua` set_platform: direct-input 和 interactive 两条路径都串上
  fast_swap，成功/失败都有明确 notify。
- `lua/ue/cdb/shards.lua` `M.active_key`: 加 TODO 注释，标记 Editor vs
  game target 歧义 bug（"Win64 Development" / "Win64 Development Editor"
  当前选同一个 shard）。

**Pitfalls / Gotchas**
- **LuaJIT 200-local cap**：新增 `local function fast_swap_...` 把 ue.lua
  推过 cap → `main function has more than 200 local variables`. 解法走
  skill `luajit-200-local-cap-with-loader-cache-mask` Fix D：挂到
  `CORE_RT.fast_swap_active_platform` 这个 table field，零新增 top-level
  local。
- **`resolve_context` 缓存 stale state**：set_platform 调
  `update_state_field` 写 state.json 后再调 fast_swap，`resolve_context`
  返回的 ctx 仍持有旧 state（缓存命中）。修法：fast_swap 内部 `ctx.state
  = read_state(engine_root)` 强制重读。
- **昨天 `8724538` commit 已经在 ccjson 流程里做了 shard 写入 + manifest
  维护**，我一开始没意识到，差点重造轮子。**教训**：用户说"这个你已经做
  过"必先 `git log --grep` + `git show` 看 diff。

**Validation**
- `nvim --headless -l Temp/probe_shard_swap.lua`: 构造
  `state.target_platform=Android` → `active_key` 选
  `Android-Client-Development` → merged 中 MGRasterizer.cpp `aarch64=true`
  ✅；切回 `Win64 Development Editor` → `aarch64=false` ✅。
- 顶层 cdb 文件 `D:/project/UnrealEngine/compile_commands.json` 入盘
  35813 entries（3 shards merge）。
- 用户活 nvim 实测 pending（等 luac dir 修复后重启）。

**Follow-ups**
- Local plan (gitignored under `.hermes/plans/`):
  `2026-05-15_111637-pch-per-platform-isolation.md`. PCH 缓存按 platform
  隔离（5 处改动，~5h 估时）。当前 `.pch` 文件根本不存在 → clangd 静默
  忽略 `-include-pch` → `FGlobalShader` fatal cascade 在 cdb 正确的前提
  下仍然出现。要顺便修。
- `lua/ue/cdb/shards.lua` `M.active_key`: Editor vs game target 歧义
  bug，单 commit 修。
- 上游用户活 nvim pending 实测 `:UESetPlatform Android Development`

---

### 2026-05-15 — vim.loader luac dir ENOENT 救场

**Task** 用户重启 Neovide 报 `vim/loader.lua:128 ENOENT: ... Temp/nvim/
luac/...restart.luac`。

**Implemented**
- 一行修复：`mkdir -p
  /c/Users/lizeqiang/AppData/Local/Temp/nvim/luac`。

**Pitfalls / Gotchas**
- `vim.loader.enable()` 写字节码缓存时 `assert(io.open(path, "wb"))` 不
  `mkdir -p` 父目录，目录被外部清掉就崩。
- 我之前给 skill `luajit-200-local-cap` 建议清 `Temp/nvim/luac/` 时可能
  连父目录 `Temp/nvim/` 一起被系统清理服务收走了。**注意**：清 luac 缓
  存只清 `luac/` 子目录内容，**不要**连 `Temp/nvim/` 整层清。

**Validation** 用户重启 Neovide 不再报错（pending 实测）。

**Follow-ups** 无。
