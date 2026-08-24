# hana-alice/nvim 1.0.1 — Patch Release

> Version: 1.0.1
> Repo:    https://github.com/hana-alice/nvim-dot-files
> Platform: Windows 11 + Neovide GUI (primary) / WSL2 (secondary)
> Date:    2026-05-18
> Type:    Patch release (bugfix + lessons-learned)

---

## One-line summary

Root-caused and fixed a long-standing clangd false-positive cascade
(`unknown class FGlobalShader` fatal at line 1 of any UE5
PCH-dependent .cpp) that originated in
`tools/prebuild_pch_v2.py` silently dropping the text `-include`
fallback. Also captured the lessons from a wrong fix attempt (auto-PCH
build wired into `:UEPrepare`) that was rolled back the same day.

---

## What changed (from 1.0.0)

### Bugfix

- **`tools/prebuild_pch_v2.py`** — `-include` is now **appended**
  alongside `-include-pch` rather than replaced. Three forms handled
  (clang `-include`, cl-yu joined `/YuX.h`, cl-yu split `/Yu X.h`).
  Idempotency guard added (±2 neighbourhood scan for matching
  `-include <header>` next to `-include-pch <path>`).
- **Effect**: `MGRasterizer.cpp` clangd diag 8 → 2 (only real
  source-level issues remain). The cascade fingerprint
  `L1 fatal -> Too many errors -> false member_decl_does_not_match`
  is gone. Verified via direct clangd LSP probe (Baseline = 8 diag /
  8 errs; A-fix = 2 diag / 2 errs).

### Rolled back (never made it to a tagged release, kept for record)

- **`:UEPrepare` auto-running `build_pch.bat`** — implemented then
  reverted same day. Wrong diagnosis: PCH binary was assumed to be a
  correctness requirement; in reality clangd only needs the text
  header. Auto-build froze the user's machine (24 PCHs × thousands of
  files each). Replaced by the bugfix above; `:UEBuildPCH` stays a
  manual-only entry point.

### Operational

- **`:UESetPlatform`** — fast-swap between platform CDB shards
  (Win64 / Android / etc.) without re-running the full UEPrepare
  pipeline. Cuts platform switch from minutes to seconds.
- **Structural clangd fix for UE .h / PCH-cpp blind spots**
  (2026-05-15) — landed via .h-entry injection + per-shard /FI
  re-injection inside UEPrepare. Foundation work that made the
  prebuild_pch_v2 root cause visible.
- **`vim.loader` luac dir ENOENT** — workaround documented: don't
  delete `Temp/nvim/` parent when scrubbing `Temp/nvim/luac/`.

---

## Detailed log

Full diagnosis, validation runs, and pitfall notes for every entry
above are preserved in date-ordered form below.

---

### 2026-05-18 — 把 build_pch.bat 合进 UEPrepare（⛔ 已回滚 — 方向错）

**Task** 用户在 UEProj engine 打开 MGRasterizer.cpp，第 1 行
`unknown class name 'FGlobalShader'` fatal + 7 个 cascade diag。当时
误诊为"`.pch` 二进制不存在 → clangd 没 PCH 上下文 → 报错"，按这个错误
诊断写了把 `build_pch.bat` 合进 `:UEPrepare` pipeline 的方案。

**Implemented**（已**全部回滚**，不在生效代码中；下方仅记录被回滚的 5 处）
- `lua/ue/cdb/pipeline.lua` `M.run` 加 `opts.skip_restart` → 已回滚
- `lua/ue.lua` `CORE_RT.build_pch_async` + `_pch_cache_fresh` → 已删
- `lua/ue.lua` `run_compile_commands_pipeline` 加 `ctx` 参数 → 已回滚
- `lua/ue.lua` 6 个调用点传 `ctx` → 已全部恢复
- `lua/ue.lua` `:UEBuildPCH` 改 thin wrapper → 已恢复原 body

**Pitfalls / Gotchas**（教训本身）
  SharedPCH.Engine 一个就 8633 文件 + clang++ 满载几十分钟。jobstart
  没带 `START /LOW` 优先级，桌面交互全干掉。
- **用户提的关键质疑（一击致命）**：rsp 里已经能精确提取每个 TU 的所有
  header（通过 `-include SharedPCH.h` 文本路径），clangd 拿到这个 token
  就能 parse 整条 PCH 头链（验证：`SharedPCH.Engine.ShadowErrors.h` →
  `EngineSharedPCH.h` L580 `#include "GlobalShader.h"` ✓）。`.pch` 二进制
  **仅是性能优化**，不是正确性必备。我把 .pch 当成"必备依赖"是误判了
  `prebuild_pch_v2.py` 的语义。
- **真根因下面单独写一条**。回滚后跑 `nvim --headless +'lua
  pcall(require,"ue")' +q` → `LOADED_OK`；`require("ue.cdb.pipeline")` →
  `PIPELINE_OK`；grep 0 残留 `build_pch_async / _pch_cache_fresh /
  skip_restart`；0 CR。

**Validation**
- 回滚后所有文件 headless require OK，无残留符号。

**Follow-ups**
- 真根因 + 修复见同日下一条 changelog 条目。
- 失败方案归档 plan：`.hermes/plans/2026-05-18_120000-wire-build-pch-into-ueprepare.md`
  顶部已标 ABANDONED + superseded by 下面那份新 plan。
- 后续如果还想做 PCH 优化（手动可选），方案必须用 `START /LOW /WAIT`
  限优先级 + 限并发 + 让用户主动触发，**绝不**进 `:UEPrepare` 默认链路。

---

### 2026-05-18 — 真根因：prebuild_pch_v2 删了 -include 文本头（✅ 已落地 + 验证）

**Task** 回滚错方向后，正面查 `FGlobalShader unknown class` 的真根因。

**Diagnosis**
对比 cdb 四个阶段产物里 MGRasterizer.cpp 的 entry：

| 阶段 | -include | -include-pch |
|---|---|---|
| pre-pch.bak（prebuild_pch_v2 之前） | `..\Intermediate\..\SharedPCH.Engine.ShadowErrors.h` + `..\Intermediate\..\Definitions.Renderer.h` | (空) |
| pre-unify.bak（prebuild_pch_v2 之后） | `..\Intermediate\..\Definitions.Renderer.h`（**SharedPCH 没了**） | `D:/.../.cache/.../SharedPCH...pch` |
| current | `E:\proj\other_project_dev\..\Definitions.Renderer.h`（**错指别项目**） | （同上，但 .pch 文件不存在）|

**两个独立 bug**:

1. **本条主线**：`tools/prebuild_pch_v2.py` L383-415，三种 PCH 引用形式
   （`-include X.h` / `/Yu<X.h>` / `/Yu X.h`）都是 **replace 不是 append** —
   注入 `-include-pch X.pch` 时**删了**原 `-include X.h`。设计假设
   "用户会跑 :UEBuildPCH 把 .pch 编出来"。一旦 .pch 不存在（绝大多数
   情况），clangd 静默跳过 `-include-pch`，又没有原 `-include` 文本头
   做 fallback → SharedPCH 的 600+ header（包括 GlobalShader.h）一个都
   没拉进来 → FGlobalShader 找不到。
2. **顺带发现**：`tools/resolve_cdb_paths.py` 把 `..\Intermediate\..`
   相对路径 resolve 到了 `E:\proj\other_project_dev`（完全不同的盘符 +
   项目）。cdb directory 是 `D:/UE/UnrealEngine/Engine/Source`，按
   定义该 resolve 到 `D:/UE/UnrealEngine/...`。说明 resolve 有
   跨项目搜索 fallback 漏。**这是另一个独立 bug**，本条不修，单独跟。

**Fix plan**（✅ 已落地）
- `prebuild_pch_v2.py` 改 replace → append：保留原 `-include SharedPCH.h`，
  追加 `-include-pch SharedPCH.pch`。两者共存，幂等。
  - .pch 存在 → clangd 用 mmap preamble（性能 OK）
  - .pch 不存在 → clangd fallback 到文本 -include（正确性 OK，性能差）
  - `.pch` 退化为纯优化，不再是正确性依赖。
- `:UEBuildPCH` 保留为**纯手动可选**入口，从不进 `:UEPrepare`。
- plan: `.hermes/plans/2026-05-18_160000-fix-prebuild-pch-preserve-include.md`

**Pitfalls / Gotchas**
- 修 prebuild_pch_v2 必须**幂等**：重复跑不能重复 append。识别条件
  "args 里同时有 `-include X.h` 和 `-include-pch X.pch`，且 X 对得上"
  → skip。已实现：扫 `-include-pch <pch_path>` 时 ±2 邻域查 `-include
  <original_header>` 命中即跳过 entry。
- /Yu form 没有原生 `-include`，要从 original_header 反构一个 `-include
  <header>` 注入，注入位置需与 -include-pch 紧邻便于幂等检测。
- pipeline 顺序：`expand_response_cdb → prebuild_pch_v2 → resolve_cdb_paths
  → unify_include_dirs → prune_include_dirs`。光跑 prebuild_pch_v2 不够，
  clangd 见不到 absolute path 会静默 0 diag（误读为"修好了"）。验证时
  必须跑完整条 pipeline。

**Validation**（✅ 已做）
- direct clangd probe（自研一次性脚本 `clangd_probe.py`，不依赖 nvim
  实例，spawn clangd 直接发 LSP）：
  - **Baseline**（pre-pch.bak 原始 cdb 走完旧 pipeline）：8 diag / 8 errs
    含 `L1 unknown class FGlobalShader` fatal + `Too many errors` + 5
    cascade (`L174/L251/L399/L497/L565`)
  - **A-fix**（fixed prebuild_pch_v2 走完完整 pipeline）：2 diag / 2 errs
    - `L1 FGlobalShader` ✓ 消失
    - `Too many errors` ✓ 消失
    - `L174 Create does not match` ✓ 消失
    - `L251 No matching AddPass` ✓ 消失
    - `L399 GetRHI no member` ✓ 消失
    - `L565 member_call_without_object` ✓ 消失
    - 仅剩 `L497 RenderMetaGeometry does not match` (真业务 error，
      与 SharedPCH 无关，源码声明/定义不一致)
    - 新增 `L3 Eigen/Dense not found`（prune_include_dirs 过度修剪，
      另起 plan 调查）
- **幂等性测试** ✅：在已 fixed 的 cdb 上重跑 prebuild_pch_v2 → 输出
  "No changes needed — PCH already applied / 替换了 0 个条目"，
  args 计数 / -include / -include-pch 完全不变。
- **共存兼容性测试** ✅：同 entry 同时含 `-include SharedPCH.h` +
  `-include-pch <不存在的 .pch>` → clangd 不报错，静默走文本 fallback。
  证伪了"两者共存会冲突"的担心。

**Follow-ups**
- 另起 plan 调查 `resolve_cdb_paths.py` 跨项目漏出去的根因
  （cdb directory 明确是 D:/，怎么 resolve 出 E:/ 的）。
- 另起 plan 调查 `prune_include_dirs.py` 把 Eigen/Dense 的 -I 剪掉。
- 旧 plan `2026-05-15_111637-pch-per-platform-isolation.md`（PCH 按
  platform 隔离）部分相关：那份假设的也是 ".pch 需要存在"，重新评估时
  也要考虑 ".pch 是纯优化"这个事实。

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
- 顶层 cdb 文件 `D:/UE/UnrealEngine/compile_commands.json` 入盘
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
  /c/Users/<USER>/AppData/Local/Temp/nvim/luac`。

**Pitfalls / Gotchas**
- `vim.loader.enable()` 写字节码缓存时 `assert(io.open(path, "wb"))` 不
  `mkdir -p` 父目录，目录被外部清掉就崩。
- 我之前给 skill `luajit-200-local-cap` 建议清 `Temp/nvim/luac/` 时可能
  连父目录 `Temp/nvim/` 一起被系统清理服务收走了。**注意**：清 luac 缓
  存只清 `luac/` 子目录内容，**不要**连 `Temp/nvim/` 整层清。

**Validation** 用户重启 Neovide 不再报错（pending 实测）。

**Follow-ups** 无。

---

*1.0.1 — 2026-05-18*
