# hana-alice/nvim 1.0.2 — Patch Release

> Version: 1.0.2
> Repo:    https://github.com/hana-alice/nvim-dot-files
> Platform: Windows 11 + Neovide GUI (primary) / WSL2 (secondary)
> Date:    2026-05-18
> Type:    Patch release (performance)

---

## One-line summary

`:UEIndexHot` / `:UEIndexCurrent` indexing is now **~21× faster** on
large UE projects (verified 22 min 36 s → 1 min 4.3 s on a 2985-TU
hot subset) via super-unity collapse inside `build_clangd_index.py`.
The Lua-side call surface is unchanged.

---

## What changed (from 1.0.1)

### Performance

- **New `tools/build_hot_super_unity_cdb.py`** — collapses a per-file
  CDB into ~13-50 `SuperUnity.<pch>.<N>.cpp` aggregator TUs grouped
  by SharedPCH/PCH bucket. Each SharedPCH gets parsed once per chunk
  instead of once per TU; chunk size defaults to 80 member .cpp's
  to bound per-process RAM.
- **`tools/build_clangd_index.py` runs super-unity by default** —
  after `inject_definitions_to_cdb.py` and the staged-CDB copy, the
  super-unity script replaces the staged CDB with the super-only
  form before invoking `clangd-indexer`. `--no-super-unity` disables
  it for debugging. Falls back to per-file mode if the script is
  missing.
- **Zero Lua change** — `lua/ue.lua`'s `INDEX_FN.build_phase_async`
  hot/current branch already calls `build_clangd_index.py`; the new
  step is transparent.

### Measured impact

| metric          | baseline (v1.0.1, per-file) | v1.0.2 (super-unity) |
|-----------------|------------------------------|----------------------|
| wall-clock      | 22 min 36 s                  | 1 min 4.3 s ⚡        |
| speedup         | —                            | 21.1×                |
| hot.idx size    | 98.5 MB                      | 99.6 MB              |
| TU count        | 2985 per-file                | 42 super-TUs (71× compression) |
| exit code       | 0                            | 0                    |

### Engineering notes

- PCH-bucket detection must accept BOTH `SharedPCH.X[.Y].h` AND
  per-module `PCH.<Mod>.h`. The initial draft only recognised
  SharedPCH and 76% of hot entries fell into a NONE bucket — no
  compression at all. After widening the regex, 94% of hot entries
  bucket cleanly across 8 PCH groups.
- Intermediate-root probing tolerates arbitrary UBT `Platform`/`Target`
  names (no hard-coded `Win64` / `UE4Editor` segments).
- `-include-pch` is dropped from super-TU args; the surviving
  `-include <SharedPCH.h>` text token carries the correctness path
  (consistent with the v1.0.1 A-fix in `prebuild_pch_v2.py`).
- Independent gaps found during validation, **deferred**:
  - `inject_definitions_to_cdb.py` covers only 30% of hot subset
    entries because `find_dev_root()` requires a `Development` path
    segment that source-tree paths lack. Same issue in v1.0.1
    baseline; super-unity does not make it worse.
  - `resolve_cdb_paths.py` occasionally resolves relative includes
    across project boundaries. Unrelated to indexing speed.

---

## Detailed log

### 2026-05-18 — hot/current 索引走 super-unity，21× 加速

**Task** :UEIndexHot 实测 22 min 36 s wall-clock，40% CPU 持续半小时
影响交互。要求 root fix，不要 daemon / 多项目 cache / 编 .pch 这类
"用户改源码就失效"的方案。

**Implemented**
- 新增 `tools/build_hot_super_unity_cdb.py`：把 per-file CDB 按
  (PCH bucket, module) 分组，每组切片 80 .cpp，生成
  `SuperUnity.<pch>.<N>.cpp` 聚合 TU + 对应 cdb entry。
  - 复用 `build_super_unity_cdb.py` 的 -I/-D/-U 联合算法
    (split/glued form 双形态)。
  - PCH 识别同时认 `SharedPCH.X.h` 和 `PCH.<Mod>.h`，覆盖率从
    24% (709/2985) 提到 94% (2809/2985)，剩下 6% NONE 是真没 PCH
    的 .gen / .pp 等。
  - 显式 drop `-include-pch` (super-TU include 源 .cpp，原 SharedPCH.h
    通过 `-include` 文本头进入)。
- 改 `tools/build_clangd_index.py`：staged_cdb 拷贝后、调 indexer
  之前，调用 super-unity 脚本把 staged_cdb 替换成 super-unity 形态。
  默认开，加 `--no-super-unity` flag 作 debug escape hatch。
  → `lua/ue.lua` 的 hot/current phase 调用链一字不动，自动受益。

**Validation** (direct clangd-indexer probe on real hot.json 2985 TU)
| metric        | baseline (per-file) | super-unity |
|---------------|---------------------|-------------|
| wall-clock    | 22 min 36 s         | 1 min 4.3 s |
| 加速          | —                   | 21.1× ⚡    |
| hot.idx size  | 98.5 MB             | 99.6 MB     |
| super-TUs     | 2985                | 42 (71×压缩) |
| exit code     | 0                   | 0           |
| PCH buckets   | n/a                 | 8 (PCH.Engine 1209, PCH.Core 418, SharedPCH.Engine 340, ...) |

幂等性：build_clangd_index.py 重跑会复用 super_unity_cpps/ 目录
(脚本启动时清空)，上游 inject_definitions_to_cdb.py 用 marker
跳过已 inject 的 entry，双层保护。

**Pitfalls / Gotchas**
- super-unity 入口必须 KNOW 两种 PCH 形态：UE 既有跨模块 SharedPCH，
  又有每模块自己的 PCH.<Mod>。我第一版只识 SharedPCH，76% 归 NONE
  导致退化到 12 个大 NONE chunk，没有压缩效果。
- `discover_engine_intermediate_roots` 不能硬编码 'Win64' / 'UE4Editor'
  路径段。UE 项目 Target 名各不相同 (UE4Editor / UE5Editor / 客户
  内部分支名)。正则改成 `Intermediate/Build/<Platform>/<Target>/<Config>/<Module>/Definitions.X.h`，
  分隔符通配。
- clangd-indexer 的位置参数是**过滤源文件**，不是 CDB 路径。脚本
  仍走 staged dir + `cwd` trick 解决 (build_clangd_index 原有逻辑
  不动)。
- inject_definitions_to_cdb.py 在 hot subset 上覆盖率只有 30%
  (885/2985 entries 含 UE_BUILD_DEVELOPMENT 等 build config 宏)。
  baseline 22 min 跑也有同样问题，super-unity 没让它变差。**这是
  独立 bug**，留作 follow-up 单独治。

**Follow-ups**
- inject_definitions_to_cdb.py 在 per-file hot subset 上覆盖率漏
  70% (无 'Development' 目录段 → find_dev_root 失败)。
- 路径还有 `E:\...\other_project_dev` 跨项目漏出去
  (resolve_cdb_paths 残留 bug，跟 super-unity 无关)，单独修。

---

*1.0.2 — 2026-05-18*
