---
name: ue-ide-bootstrap
description: |
  从零开始 (clone 完源码) 把一个大型 Unreal Engine 项目搭成 nvim IDE 的完整流程。
  覆盖 5 条索引轨道 (raw CDB / super-unity .idx / csearch / gtags / fs_event watcher)、
  .h LSP 救命方案、性能数字、内存预算、磁盘占用、常见陷阱。
  Use when 用户问 "新机器怎么搭"、"clone 完要做什么"、"索引要多久"、
  "为什么 .h 一片红"、"build 了一次还要做什么"、"IDE 体验怎么搞起来"。
trigger_keywords:
  - ue-ide-bootstrap
  - "新仓 IDE 搭建"
  - "从零开始 nvim"
  - "UEPrepare 第一次"
  - ".cpp.json"
  - ".h inject"
  - "super-unity .idx"
  - "csearch index"
  - "fs_event watcher"
related_skills:
  - clangd-pch-precompile
  - clangd-indexer-ue-defs-injection
  - super-unity-cdb-pipeline
  - clangd-h-cdb-entry-inject
  - csearch-rg-on-dirty-hybrid
  - csearch-snacks-live-finder-integration
  - codesearch-cindex-incremental-merge-traps
  - gnu-global-hlsl-via-exuberant-ctags-langmap
  - incremental-multi-index-fs-watcher
  - racing-goto-definition
created: 2026-05-08
maintainer: hana-alice
---

# ue-ide-bootstrap

> 从 git clone 完到 nvim IDE 完全可用的端到端流程。
> 大型 Unreal Engine 项目（UE4Editor / UE5Editor，源码闭包 5M-10M 行 C++ + HLSL/USF shader）。

================================================================

## 0. TL;DR

```
clone 完源码 → 110 分钟 → +71 GB 磁盘 → 一个 IDE 体验 ≥ Visual Assist 的 nvim
其中 90 分钟在 build 一次（必须，因为 .cpp.json 是真相之源）
真正"IDE 索引层"只占 6 分钟 + 1.2 GB
```

================================================================

## 1. 前置假设

```
机器:    Windows + Neovide GUI (亦支持纯 nvim TUI)
源码:    git clone 完成的 UE 仓 (~80 GB working tree)
工具链:  Visual Studio 2022 + Windows SDK 已装
         clangd (自带打了 indexer 补丁版本, 见 clangd-indexer-ue-defs-injection)
         csearch / global / rg / Python 3.12 已装
nvim:    LazyVim + 本仓 ue.lua 已就绪
```

如果 clangd 不是打过补丁的版本，super-unity .idx 步骤 97% TU 会静默失败。
如果用 uv 管理的 Python，必须 pin 绝对路径并清空 `PYTHONHOME` / `PYTHONPATH`，否则 `_sre.MAGIC` 不匹配导致 inject 脚本 crash。

================================================================

## 2. 五条索引轨道总览

```
┌──────────────────────────┬─────────────────┬─────────────────────────────┐
│ 索引                     │ 后端            │ 用途                        │
├──────────────────────────┼─────────────────┼─────────────────────────────┤
│ ① raw CDB (per-file)     │ UBT             │ clangd LSP per-file 解析    │
│ ② super-unity .idx       │ clangd-indexer  │ 全局 xref / 跨 TU goto      │
│ ③ csearch trigram        │ Google csearch  │ 全文 grep（亚秒级）         │
│ ④ gtags                  │ GNU Global      │ HLSL/USF/USH shader goto    │
│ ⑤ ripgrep on dirty       │ rg              │ csearch 兜底（已编辑文件）  │
└──────────────────────────┴─────────────────┴─────────────────────────────┘
```

设计原则：每条轨道独立可重建，单条挂掉不影响其它。

================================================================

## 3. 八步流程（顺序敏感）

### 第 1 步 — UBT Setup + GenerateProjectFiles

```bash
./Setup.bat                    # 拉 ThirdParty 二进制
./GenerateProjectFiles.bat     # 生成 .sln + UBT 元数据
```

| 项 | 数值 |
|---|---|
| 耗时 | Setup 5-15 min（看网络）/ GenerateProjectFiles 2-5 min |
| 内存 | <2 GB |
| 磁盘新增 | +5-10 GB（ThirdParty bin） |
| 产出 | `Engine/Intermediate/ProjectFiles/`、UBT 缓存 |

不能跳——后续 `.cpp.json` / `.obj.response` 全部依赖 UBT 内部状态。

---

### 第 2 步 — Build 一次 Editor（最关键）

```bash
./Engine/Build/BatchFiles/Build.bat UE4Editor Win64 Development
```

| 项 | 数值 |
|---|---|
| 耗时 | **首次 cold build 60-120 min**（24 核机器）/ 增量 <5 min |
| 内存 | 峰值 ~30-50 GB（cl.exe 多进程，可 `-MaxParallelActions=12` 限） |
| 磁盘新增 | **+50-80 GB**（`Intermediate/Build/Win64/UE4Editor/Development/`） |
| 产出 | `.cpp.json` ~992 / `.obj.response` ~992 / `.pch` ~12 / `.obj` 数万 / `UE4Editor.exe` |

**为什么必须 build 完整一次**：
- `.cpp.json` 是 .h inject 的**唯一真相源**（UBT 编译时写下的 PCH/Includes 闭包）
- `.obj.response` 是 wrapper-donor 路径的 args 来源
- 没这两个 → 整个 .h inject 方案塌掉

⚠️ 不想跑 Editor 也可 build 一次 ClientGame target，但 `.cpp.json` 数量会少（只覆盖该 target 的 module）。**强烈建议先 build Editor**，覆盖最全。

---

### 第 3 步 — UBT GenerateClangDatabase（生 raw CDB）

```bash
./Engine/Build/BatchFiles/Build.bat \
    -Mode=GenerateClangDatabase \
    UE4Editor Win64 Development \
    -OutputDir="<repo-root>"
```

或在 nvim 里：`:UEPrepare`（ue.lua 已封装）

| 项 | 数值 |
|---|---|
| 耗时 | **60-220 s** |
| 内存 | <4 GB |
| 磁盘新增 | **+~323 MB**（`compile_commands.json` raw, 约 14k entries） |
| 产出 | raw CDB（per-file, 纯 .cpp） |

⚠️ GenerateProjectFiles 的 configuration 必须和这一步对上，否则 UBT 直接 crash。
⚠️ 不能让 LSP clangd 吃 unity CDB——gd 跳到 forward decl + 满屏红线。

---

### 第 4 步 — .h inject（让 clangd LSP 吃 .h）

```bash
python <path>/inject_h_entries.py
# 或集成到 :UEPrepare 后置钩子
```

| 项 | 数值 |
|---|---|
| 耗时 | **~7 s** |
| 内存 | ~500 MB（解析 992 个 `.cpp.json`） |
| 磁盘新增 | **+~228 MB**（CDB 323→551 MB） |
| 产出 | CDB ~14k → ~30k entries（+15k .h） |
| backup | `compile_commands.json.before_h_poc` 自动生成 |

**算法（v6 终态，零启发式）**：
- 数据源 = `.cpp.json`（UBT 已记录每 TU 的 Source/PCH/Includes 闭包）
- 谁 include 了这个 .h，谁就是 donor
- 双路径：
  - **cdb-donor**: raw CDB 命中的 .cpp donor → clone args + 补 `/FI=PCH.<Module>.h`（raw CDB 主动剥了 `/Yu /Fp /FI=SharedPCH`，但 .h parse 时需要补回）
  - **wrapper-donor**: 用 wrapper 的 `.cpp.obj.response` → 剥 `/Yu /Fp /Fo /Tp` 保留 `/FI /D /I /imsvc`

效果：单独打开 .h **34/34 0 ERROR**（baseline 多个文件 6-22 ERROR）。

**反面例子（已固化为反向警示，别再走）**：
- 同名 .cpp 启发式 ❌ 只对 pair 文件有效
- 同 module 任一 .cpp 启发式 ❌ umbrella header 1→3 ERROR
- 拼 SharedPCH /FI 到 .h 自身 args ❌ preamble 损坏
- per-module 例外名单 ❌ 架构上不可持续

---

### 第 5 步 — super-unity .idx（offline 全局索引）

```vim
:UEIndexFull   " ue.lua 封装
" 内部:
"   1. UBT GenerateClangDatabase + -ForceUnity 生 unity CDB
"   2. 按 SharedPCH 分组成 ~13 个 super-TU
"   3. 打过 -include-pch 补丁的 clangd-indexer 跑
```

| 项 | 数值 |
|---|---|
| 耗时 | **~50 s**（baseline 165 min，~200x 提升） |
| 内存 | 峰值 ~16 GB（13 个 super-TU 并行，每个 ~1.2 GB） |
| 磁盘新增 | **+~244 MB**（`.cache/nvim-ue/clangd/index/<repo-name>.idx`） |
| 产出 | 全局 symbol index（gd / xref 跨 TU 用） |

⚠️ clangd-indexer 必须用打过 `-include-pch` 补丁的版本，否则 `disableUnsupportedOptions` 把 PCH 剥了，UE 的 `-D` 宏全丢，`.generated.h` 解析失败，97% TU 静默 crash。

---

### 第 6 步 — csearch trigram index

```vim
:UEIndexCsearch    " ue.lua 封装
" 内部: cindex-uefilter -reset -files-from <list>
```

| 项 | 数值 |
|---|---|
| 耗时 | **~90-120 s**（76k .h + 14k .cpp + shader 等） |
| 内存 | 峰值 ~3 GB |
| 磁盘新增 | **~250-400 MB**（trigram index） |
| 产出 | csearch index（全文 grep 数据源） |

⚠️ csearch 不支持真增量（cindex `-files-from` 模式有 path-key dedup 静默 no-op）。新文件必须 `-reset` 全量。

---

### 第 7 步 — gtags（HLSL/USF/USH/HLSLI shader goto）

```bash
GTAGSCONF=<custom-with-shader-langmap> gtags -i
```

| 项 | 数值 |
|---|---|
| 耗时 | **~30-60 s**（shader 文件量小） |
| 内存 | <2 GB |
| 磁盘新增 | **~50-100 MB**（GPATH/GTAGS/GRTAGS） |
| 产出 | shader 的 goto-def 数据库 |

clangd 不解析 shader，gtags 兜底。`GTAGSCONF` 自定义 langmap 把 `.usf .ush .hlsl .hlsli` 映射到 cpp 解析器（exuberant-ctags 内嵌 DLL）。

---

### 第 8 步 — fs_event watcher 启动（增量保鲜）

```vim
:UEWatch    " ue.lua 封装, 后台进程
```

| 项 | 数值 |
|---|---|
| 耗时 | **<1 s** 启动 |
| 内存 | 常驻 ~50 MB |
| 磁盘新增 | 0 |
| 产出 | 后续文件 add/del 自动 fan-out 到 5 条索引 |

无 watcher 时：用户新建文件 → 等 60-220 s `:UEPrepare` 全量。
blocklist：`Intermediate / Build / Saved / .generated.h`（避免 Hot-Reload 引发风暴）。

================================================================

## 4. 总账单（首次冷启动）

```
┌──────────────────────────────────────┬──────────┬──────────┬───────────┐
│ 步骤                                 │ 耗时     │ 峰值内存 │ 磁盘新增  │
├──────────────────────────────────────┼──────────┼──────────┼───────────┤
│ 1. Setup + GenerateProjectFiles      │  10 min  │  <2 GB   │  +5-10 GB │
│ 2. Build 一次 Editor (cold)          │  90 min  │  ~40 GB  │  +60 GB   │
│ 3. GenerateClangDatabase             │   2 min  │  <4 GB   │  +0.3 GB  │
│ 4. .h inject (inject_h_entries.py)   │   7 s    │  0.5 GB  │  +0.2 GB  │
│ 5. super-unity .idx                  │  50 s    │  ~16 GB  │  +0.24 GB │
│ 6. csearch index                     │   2 min  │  ~3 GB   │  +0.4 GB  │
│ 7. gtags (shader)                    │   1 min  │  <2 GB   │  +0.1 GB  │
│ 8. fs_event watcher                  │  <1 s    │  50 MB   │  0        │
├──────────────────────────────────────┼──────────┼──────────┼───────────┤
│ 总计 (cold)                          │ ~110 min │  ~40 GB  │  ~71 GB   │
│   其中"必须 build 一次"占                 ~90 min                +60 GB    │
│   IDE 索引相关 (3-7) 仅                   ~6 min                +1.2 GB   │
└──────────────────────────────────────┴──────────┴──────────┴───────────┘
```

**热重建（已 build 过，只动了源码）**：
- `:UEPrepare` + .h inject + 增量 csearch ≈ **2-3 min**
- 全靠 fs_event watcher 增量 → 基本无感

================================================================

## 5. 运行时常驻成本

```
nvim + Neovide GUI               ~400 MB
clangd LSP (打开 1-3 文件)        500 MB - 2 GB（per TU preamble ~150 MB）
fs_event watcher                  50 MB
csearch (按需 spawn, 不常驻)      0 (临时进程 ~200 MB)
─────────────────────────────────────
总计待机                          ~1 GB
总计活跃 (3 buffer)               ~3-4 GB
```

================================================================

## 6. 效果验证（用户实际体感）

| 操作 | 数值 |
|---|---|
| 打开 .cpp（cold clangd attach） | 5-15 s（首个 TU），后续 <2 s |
| 打开 .cpp（warm） | <1 s |
| 打开 .h（v6 inject 后） | <2 s，0 ERROR |
| `gd` jump（racing） | 200 ms（命中 .idx）/ 5-30 s（raw LSP，已被 racing 覆盖） |
| `:UESearch` 全文 grep | ~50 ms 出首批结果 |
| 搜 shader 函数 | ~50 ms（gtags） |
| `:UEPrepare` 增量 | <30 s（fast-path 命中时直接复用） |
| 新建 .cpp 后等多久能搜到 | watcher debounce ~3 s |

================================================================

## 7. 容易踩的坑（按优先级）

1. ⚠️ **必须先 build 一次 Editor** —— `.cpp.json` 不存在 = .h inject 整套塌掉
2. ⚠️ **GenerateProjectFiles 的 configuration 必须和 build 的对上** —— 错配 UBT 直接 crash（→ skill `ue-cdb-missing-new-files`）
3. ⚠️ **clangd-indexer 必须打过 `-include-pch` 补丁** —— 否则 97% TU 静默失败（→ skill `clangd-indexer-ue-defs-injection`）
4. ⚠️ **不能让 LSP clangd 吃 unity CDB** —— gd 跳到 forward decl + 满屏红线（→ skill `clangd-asymmetric-diag-vs-gd-cdb-shape-mismatch`）
5. ⚠️ **csearch 不支持真增量** —— 必须 `-reset` 全量重跑（→ skill `codesearch-cindex-incremental-merge-traps`）
6. ⚠️ **ghost clangd-indexer 进程** —— bench 前必须 `tasklist /fi "imagename eq clangd-indexer.exe"` 清场，不然 24 核被吃光（→ skill `clangd-lsp-benchmark-isolation`）
7. ⚠️ **uv-managed Python 跑 inject 脚本会 crash** —— `_sre.MAGIC` 不匹配。pin 绝对 Python 3.12 路径 + 清空 `PYTHONHOME/PYTHONPATH`（→ skill `nvim-spawn-python-pin-absolute`）

================================================================

## 8. 一键脚本草图（待落地）

```bash
#!/usr/bin/env bash
# ue-ide-bootstrap.sh - 从零开始一条龙

set -e
REPO=$1; cd "$REPO"

echo "[1/8] Setup + GenerateProjectFiles..."
./Setup.bat
./GenerateProjectFiles.bat

echo "[2/8] Build UE4Editor (this takes ~90 min)..."
./Engine/Build/BatchFiles/Build.bat UE4Editor Win64 Development

echo "[3/8] Generate raw CDB..."
./Engine/Build/BatchFiles/Build.bat -Mode=GenerateClangDatabase \
    UE4Editor Win64 Development -OutputDir="$REPO"
cp compile_commands.json compile_commands.json.before_h_poc

echo "[4/8] Inject .h entries..."
python <path>/inject_h_entries.py

echo "[5/8] Super-unity .idx..."
nvim --headless +':UEIndexFull' +qa

echo "[6/8] csearch index..."
nvim --headless +':UEIndexCsearch' +qa

echo "[7/8] gtags..."
GTAGSCONF=<path>/gtags-ue.conf gtags -i

echo "[8/8] fs_event watcher..."
nvim --headless +':UEWatch' +qa &

echo "DONE - 大约 110 分钟"
```

================================================================

## 9. 哲学

- **离线 + 增量** —— 不在 LSP 实时跑重活
- **多轨道并行** —— 一条挂掉，其它继续工作
- **零启发式 / 让 build system 告诉你** —— UBT 的 `.cpp.json` 是真相，路径/文件名启发式必死
- **不动源码 / 不全局污染** —— 三条红线
- **Windows 原生第一公民** —— 不依赖 WSL
