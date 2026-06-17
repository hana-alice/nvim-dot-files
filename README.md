# hana-alice's Neovim — Unreal Engine Edition

**English** · [中文](#hana-alices-neovim--unreal-engine-edition-中文)

A Neovim configuration tuned for one very specific scenario: **editing
ten-thousand-file Unreal Engine 5 C++ projects on Windows**, where stock clangd
takes minutes to wake up and one careless `:e` can stall the UI for seconds.
This config compresses that into: 3-minute full index, sub-100ms
goto-definition, one-shot Android headless DAP attach, every error flushed to
disk, and 24/7 unattended operation that never silently dies.

LazyVim is the base, but here it's a **library, not a finished product**; the
real engine is `lua/ue.lua` (a ten-thousand-line monolithic hub) plus
`lua/ue/`, `lua/utils/`, `lua/workarounds/`. It's also a general-purpose editor
that happens to know UE — all UE features no-op gracefully when no UE project is
around.

```
  95 lua modules       10k-line UE engine hub   5-tier goto fallback
  CDB super-pipeline   sub-second csearch grep  1 jumplist contract
  workaround registry  Windows one-shot setup   0 tolerance for UI stalls
  AI persistence KB    headless regression      multi-platform DAP (Win64/Android)
```

> **First time here?** For a module-by-module audit of what's added on top of
> upstream LazyVim — defaults, overrides, why, where:
> [`docs/architecture-vs-lazyvim.md`](docs/architecture-vs-lazyvim.md).
> For the overall architecture (subsystems / data flow / platform layer /
> ownership boundaries): [`docs/architecture/overview.md`](docs/architecture/overview.md).

---

## Contents

- [Install](#install)
- [Usage steps (get a UE project running)](#usage-steps-get-a-ue-project-running)
- [Daily workflow](#daily-workflow)
- [Android DAP debugging](#android-dap-debugging)
- [What's actually in here](#whats-actually-in-here)
- [Repository layout](#repository-layout)
- [Conventions (not optional)](#conventions-not-optional)
- [Regression tests](#regression-tests)
- [Credits](#credits)

---

## Install

### Windows (preferred — this is what it's built for)

```powershell
# Open a PowerShell 7 (pwsh) prompt
git clone https://github.com/hana-alice/nvim-dot-files.git $env:LOCALAPPDATA\nvim
cd $env:LOCALAPPDATA\nvim

# One-shot toolchain + plugin install (pick one)
.\setup.ps1                       # interactive: installs neovim/neovide/fonts/llvm/rg/fd/python… + syncs plugins
#   or
.\scripts\install_windows.ps1     # variant that points at this repo via a directory junction

nvim                              # first launch: LazyVim auto-installs plugins
```

`setup.ps1` supports `-SkipFonts` / `-SkipCapslock` / `-SkipPlugins` / `-Force`.
It needs an Administrator PowerShell, and you must first relax the execution
policy: `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`.

> **Toolchain versions are pinned** (clangd/LLVM 22.1.x, Android DAP uses LLVM
> 22.1.6+ lldb-dap, Neovim 0.10+). **Do not** use mason auto-install — it causes
> version-drift bugs. Authoritative list:
> [`docs/CONSTRAINTS.md` §三 C1](docs/CONSTRAINTS.md) and
> [`docs/TOOLING.md`](docs/TOOLING.md).

### Anywhere else

```bash
git clone https://github.com/hana-alice/nvim-dot-files.git ~/.config/nvim
nvim
```

On non-Windows the UE subsystems mostly no-op; the editor itself works fine.

### Sub-second grep needs a small Go tool (optional but strongly recommended)

The `<leader>/` project-wide grep relies on a trigram index tool (a fork of
[google/codesearch](https://github.com/google/codesearch) that adds
`-files-from`). Build it once:

```bash
cd tools/cindex-uefilter && go install ./...     # needs Go ≥ 1.22, with $GOBIN on PATH
```

The next `:UEPrepare` auto-detects it and builds `.cache/nvim-ue/csearch.idx`.
When the index is missing, the picker silently falls back to the rg-batched slow
path (the title is tagged `slow fallback`).

---

## Usage steps (get a UE project running)

This is the core. The shortest path to get a **real UE project** working for the
first time after install:

### 1. Open nvim inside the UE project directory

Open any C++ file under the directory containing your `.uproject`, or launch
`nvim` from that directory. The config auto-detects that this is a UE project.

### 2. `:UESetProject` — bind the project and engine

```vim
:UESetProject
```

The first run asks you to confirm the **project root** (where `.uproject` lives)
and the **engine root** (the UE5 install/source root). Both persist to state, so
no need to repeat. Changing the engine root auto-invalidates the all-platform
grep/cdb caches.

If your `.uproject` is not directly under the project root, use
`:UESetUprojectRelativePath` to specify the relative path.

### 3. (multi-platform) `:UESetPlatform` — pick the target platform

```vim
:UESetPlatform        " pick Win64 / Android / Mac / IOS / Linux
```

Unset → auto-detect from the current OS. **grep/cdb caches are split by
`<Platform>-<Config>` directory**, so switching platforms doesn't cross-pollute
and old-platform caches are kept.

### 4. `:UEPrepare` — one-shot indexing (the most important step)

```vim
:UEPrepare
```

Fully automatic, fully async with a progress UI. It does all of this:

```
UBT -SkipBuild to grab compile args
  → generate compile_commands.json
  → super-pipeline pruning: expand → PCH prebuild → resolve paths → unify includes → prune
     (drops 60–90% of -I; preamble parse ~60s → ~20s)
  → cindex builds the csearch trigram index (sub-second grep)
  → restart clangd to load
```

When it finishes you have: precise goto-def, sub-second grep, stable clangd.
Variants:

- `:UEPrepareIncremental` — only process dirty files (fast refresh after edits)
- `:UEPrepareReindex` — force-rebuild the csearch index
- `:UEPrepareSync` — synchronous (blocking) version, for debugging
- `:UEIndexStatus` / `:UEIndexTimings` — index status and per-stage timings

### 5. Start working

| What you want | How |
|---|---|
| Goto definition | `gd` (5-tier fallback, ~70% hit via cache, sub-100ms) |
| Find references | `gr` |
| Project-wide grep (Engine+Project) | `<leader>/` |
| File picker (recent/smart) | `<leader><leader>` |
| See all commands | `<leader>?` or `:UECheatsheet` |
| Build the project | `:UEBuild` (Android: `:UEBuildAndroid`) |
| Launch the Editor | `:UELaunch` |
| Inspect paths/status | `:UEPaths` / `:UECDBStatus` |

Full keymap & workflow handbook: `:UECheatsheet` (floating) /
[`docs/ue_lazyvim_cheatsheet.md`](docs/ue_lazyvim_cheatsheet.md) (full text).

---

## Daily workflow

```
First time:    :UESetProject → (:UESetPlatform) → :UEPrepare
Editing code:  clangd senses content edits live (nothing to do manually)
After add/del files: :UEPrepareIncremental   # or watcher dirty auto-merges on next manual :UEPrepare
Switch platform: :UESetPlatform              # caches split by platform dir, instant switch, no rebuild
Switch project:  :UESetProject               # project or engine change invalidates all-platform caches
Diagnostics:   :UEIndexStatus / :UEGrepDiagDump / :UEDirtyStatus / :UEWatchStatus
```

> Only file-**set** changes (add/delete/rename) require rebuilding the csearch
> index; content edits to existing files are handled live by clangd and are out
> of csearch freshness scope. Freshness is decided by a content fingerprint, not
> mtime proxies (avoids false-stale from build artifacts touching the tree).

---

## Android DAP debugging

Android attach is a hardcore capability of this config, via **lldb-server
platform mode + serial-form connect URL** (not `gdbserver --attach`, which is
disproven).

```
Prep:    :UEInstallAndroid        # push the arm64 lldb-server to /data/local/tmp
         :UESetAndroidPackage     # set the package name (or be prompted on first attach)
Attach:  :UEDAPAttach             # platform select → serial connect → process attach
Breakpt: F9 (:UEDAPToggleBreakpoint)  # persisted per project; planted live via lldb-dap evaluate in-session
Stepping: F10 step over / F11 step in / Shift-F11 step out / F5 continue
UI:      :UEDAPToggleUI / :UEDAPStatus / :UEDAPDiag
```

Full commands under the DAP category in `:UECheatsheet`. The hard-won Android
knowledge (ASLR slide, platform mode, serial URL, breakpoint-hit criteria) is
authoritative in [`docs/CONSTRAINTS.md` §二 K30–K37](docs/CONSTRAINTS.md) and
[`docs/TOOLING.md`](docs/TOOLING.md).

---

## What's actually in here

### 1. UE C++ workflow hub (`lua/ue.lua` + `lua/ue/`)

A ten-thousand-line monolithic hub owning everything UE-specific: clangd
discovery and launch, compile_commands.json lifecycle (slim → PCH → unify →
prune), a background indexer with idle/cold/hot debounce, multi-platform DAP,
build commands, log tailing, Editor launch, sidebar integration. Public API on
`M.*`, headless-testable. Submodules:

```
lua/ue/
  cdb/      compile_commands.json generate/prune/shader/inject (pure fns + subprocess, skip-write if unchanged)
  core/     fs / proc pure functions (zero upward deps, headless-assertable)
  dap/      multi-platform attach/launch; the platforms registry is the only dispatch seam
  config.lua  index/context/clangd/dap/cdb defaults schema (literal defaults, no back-dep on the hub)
```

### 2. Sub-100ms goto-definition (`lua/utils/ue_goto/`)

A 5-tier fallback single chain, strung by "save the call → hit precision →
fallback coverage":

```
treesitter early-bail → cache (~70% hit) → clangd (LSP, authoritative) → csearch → gtags
```

Design choices: treesitter only does "save the call" decisions and **never
substitutes clangd's answer** (it can't see across translation units / templates
/ macros); the cache-HIT path is a pure lua table lookup, touching no
subprocess; jumper is a single-responsibility module with a written
post-condition contract (one `Ctrl-O` returns to source, exactly one jumplist
entry, no ghost cursor); no timer-based drift fixes, races synchronized via
once-shot autocmds. Authoritative:
[`docs/architecture-symbol-resolution.md`](docs/architecture-symbol-resolution.md).

### 3. Sub-second grep (`tools/cindex-uefilter` + `lua/utils/code_search`)

The `<leader>/` project grep used to walk the directory tree on every keystroke
(14–32s on UEProj; NTFS recursion is the physical bottleneck). Now `:UEPrepare`
also builds a trigram index, feeding the clean file list via the fork's
`-files-from` (skipping `Intermediate/`, `DerivedDataCache/`, etc.). Measured on
UEProj (~43k files):

| Pattern | Hits | csearch | rg (walk) |
|---|---|---|---|
| `FRDGBuilder` | 2491 | **365 ms** | ~14 s |
| `FRHICommandList` | 6593 | **693 ms** | ~18 s |
| `NaniteRasterPipelines` | 57 | **73 ms** | ~12 s |

### 4. Workaround registry (`lua/workarounds/`)

Every patch that exists *because of someone else's bug* lives in its own file
with a parseable frontmatter contract
(name/scope/issue/introduced/removal_condition/enabled…). Browse with
`:WorkaroundList`, toggle with `:WorkaroundDisable <name>`. When upstream fixes
it, cleanup is `git rm`, not archaeology. Contract:
[`lua/workarounds/README.md`](lua/workarounds/README.md).

### 5. Platform drivers (`lua/utils/platform/`)

`windows/macos/linux/stub` four drivers, one interface (shell / open_path /
cmd_quote / default_*_paths). **This is the only place OS branching is
allowed** — everything else reads `platform.is_*` or calls a driver.

### 6. Standalone Python/Go tools (`tools/`, `scripts/`)

CDB / PCH / index / DAP-probe tools that don't need Neovim to run. CDB pipeline
core:

| Tool | What it does |
|---|---|
| `prebuild_pch_v2.py` | Generate `.rsp` + `.bat` to precompile UE PCHs |
| `prune_include_dirs.py` | Drop unused `-I` from the CDB (huge preamble win) |
| `unify_include_dirs.py` | Deduplicate include dirs across TUs |
| `slim_compile_commands.py` | Strip noise, keep `-include` directives |
| `expand_response_cdb.py` / `resolve_cdb_paths.py` | Expand response files / resolve paths |

Each is idempotent and skip-writes when output is unchanged, so you can re-run
them in a watcher loop without invalidating PCHs or restarting clangd.

### 7. AI persistence knowledge base

Lets a continuously-engaged AI agent discover rules **from files, not chat
history**: one `CLAUDE.md` per major directory (children write deltas only), the
SESSION START protocol + Definition of Done in the root `CLAUDE.md`/`AGENTS.md`,
a four-zone KB (memory / decisions / lessons / architecture), and a
`structure_spec` regression that guards "rules are discoverable in place".

---

## Repository layout

```
.
├── init.lua                      LazyVim entrypoint (fixed startup order, see CONSTRAINTS C3)
├── setup.ps1                     Windows one-shot installer (interactive)
├── lua/
│   ├── config/                   keymaps / options / autocmds / lazy / neovide / windows
│   ├── plugins/                  per-plugin setup (snacks-only, no copilot)
│   ├── ue.lua                    UE engine hub (~10k lines, single module)
│   ├── ue/
│   │   ├── cdb/                  compile_commands.json pipeline
│   │   ├── core/                 fs/proc pure functions
│   │   ├── dap/                  multi-platform DAP (win64/mac/linux/ios/android)
│   │   └── config.lua            tunables schema
│   ├── utils/
│   │   ├── ue_goto/              5-tier goto-def architecture
│   │   ├── code_search/          csearch sub-second grep
│   │   ├── platform/             the only OS-branch sink (four drivers)
│   │   ├── lsp_fallback.lua      fall-through gd resolver
│   │   └── ...
│   ├── workarounds/              isolated upstream-bug patches + registry
│   └── nio/, trouble/, theme.lua, highlights.lua
├── tools/
│   ├── cindex-uefilter/          Go fork of google/codesearch (adds -files-from)
│   └── (Python tools…)           PCH / CDB / index / DAP probes
├── scripts/                      Windows install + regression wrapper + profiling
├── docs/
│   ├── architecture/overview.md  architecture overview (start here)
│   ├── CONSTRAINTS.md            forbidden / pitfalls / load-bearing constraints (authoritative index)
│   ├── TOOLING.md                pinned toolchain versions and status
│   ├── testing-regression.md     regression policy + change→filter map
│   ├── changelog.md              change log
│   └── ue_lazyvim_cheatsheet.md  keymap + workflow handbook (:UECheatsheet)
├── memory/                       stable project knowledge for AI (start here)
├── decisions/                    ADR navigation
├── lessons/                      platform quirks / hard-won debugging knowledge
├── openspec/                     spec-driven change workflow
├── tests/                        headless regression suite
├── <every major dir>/CLAUDE.md   recursive local subsystem rules (child = delta)
└── CLAUDE.md                     ROOT: SESSION START protocol + Definition of Done
```

**AI persistence layer**: a new context starts at root `CLAUDE.md`
(auto-injected) → SESSION START reads `docs/CONSTRAINTS.md` →
`memory/project_overview.md` → the current dir's `CLAUDE.md` (falls back to the
nearest ancestor). Every major directory carries its own `CLAUDE.md` (children
write only deltas over the parent). "Done" is gated by the root Definition of
Done: run scoped regression, append to `docs/changelog.md`, and follow the
milestone policy on version wrap.

---

## Conventions (not optional)

The rules this config follows — they are not suggestions:

- **AST/treesitter over regex** for any structural code question
- **Async over blocking** — multi-second waits OK, blocking the main thread not
- **Workaround isolation** — anything that exists only to dodge an upstream bug
  goes in `lua/workarounds/<scope>/<name>.lua`
- **Self-verifiable modules** — public API on `M.*`, headless-testable
- **No periodic ticker notifications** — at most start + middle update, natural
  fade after success (no `:messages` spam)
- **Skip-write when unchanged** — every generator (CDB/PCH/.clangd) compares
  before writing so downstream caches don't invalidate

For the full checklist of what's **forbidden**, what **pitfalls** have cost
time, and which **constraints** are load-bearing, see
[`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md). For the full agent contract, see
[`CLAUDE.md`](CLAUDE.md).

---

## Regression tests

Any `.lua` runtime code or `tests/` change must run the scoped regression and be
all-green before completion; **a full run is mandatory before commit/merge**:

```
nvim --headless -l tests/run.lua            # full (cross-platform, authoritative)
nvim --headless -l tests/run.lua <filter>   # only *_spec.lua whose filename contains <filter>
pwsh -File scripts/run_regression.ps1       # Windows convenience wrapper
```

Exit code `0` = all pass, `1` = any failure. New cases go in
`tests/cases/<area>_spec.lua` (auto-discovered). The change → required-filter
quick map is in [`tests/CLAUDE.md`](tests/CLAUDE.md); authoritative details in
[`docs/testing-regression.md`](docs/testing-regression.md).

---

## Credits

- [LazyVim](https://github.com/LazyVim/LazyVim) — the base distribution
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) — picker / statusline / dashboard
- [clangd](https://clangd.llvm.org/) — the C++ LSP that does all the real work
- [google/codesearch](https://github.com/google/codesearch) — trigram index base (this repo's fork adds `-files-from`)

---
---

# hana-alice's Neovim — Unreal Engine Edition （中文）

[English](#hana-alices-neovim--unreal-engine-edition) · **中文**

为一个非常具体的场景打磨的 Neovim 配置：**在 Windows 上编辑万级 C++ 文件的
Unreal Engine 5 工程**——原生 clangd 要几分钟才唤醒、一次不小心的 `:e` 能卡死
UI 好几秒。这套配置把它压成：3 分钟全量索引、亚 100ms goto-definition、一键
Android headless DAP attach、错误全落盘、24 小时无人值守也不静默挂。

底座是 LazyVim，但 LazyVim 在这里是**库**不是成品；真正的引擎是 `lua/ue.lua`
（万行单模块中枢）+ `lua/ue/`、`lua/utils/`、`lua/workarounds/`。它同时也是一个
顺带懂 UE 的通用编辑器——没有 UE 工程时所有 UE 功能优雅 no-op。

```
  95 lua 模块         10k 行 UE 引擎中枢      5 层 goto fallback
  CDB 超级流水线       亚秒级 csearch grep     1 条 jumplist 契约
  workaround 注册表    Windows 一键安装        0 容忍 UI 卡顿
  AI 持久化知识库      headless 回归套件        多平台 DAP（Win64/Android）
```

> **第一次来？** 想看相对上游 LazyVim 逐模块加了什么、为什么、在哪：
> [`docs/architecture-vs-lazyvim.md`](docs/architecture-vs-lazyvim.md)。
> 想看整体架构（子系统 / 数据流 / 平台层 / 归属边界）：
> [`docs/architecture/overview.md`](docs/architecture/overview.md)。

---

## 目录

- [安装](#安装)
- [使用步骤（让一个 UE 工程跑起来）](#使用步骤让一个-ue-工程跑起来)
- [日常工作流](#日常工作流)
- [Android DAP 调试](#android-dap-调试)
- [里面到底有什么](#里面到底有什么)
- [仓库布局](#仓库布局)
- [约定（不可选）](#约定不可选)
- [回归测试](#回归测试)
- [致谢](#致谢)

---

## 安装

### Windows（首选，这套配置就是为它建的）

```powershell
# 用 PowerShell 7（pwsh）打开
git clone https://github.com/hana-alice/nvim-dot-files.git $env:LOCALAPPDATA\nvim
cd $env:LOCALAPPDATA\nvim

# 一键安装工具链 + 插件（任选其一）
.\setup.ps1                       # 中文交互式：装 neovim/neovide/字体/llvm/rg/fd/python… + 同步插件
#   或
.\scripts\install_windows.ps1     # 用 directory junction 指向本仓的变体

nvim                              # 首次启动 LazyVim 自动装插件
```

`setup.ps1` 支持 `-SkipFonts` / `-SkipCapslock` / `-SkipPlugins` / `-Force`。
需要管理员 PowerShell，并先放开执行策略：
`Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`。

> **工具链版本是钉死的**（clangd/LLVM 22.1.x、Android DAP 用 LLVM 22.1.6+
> lldb-dap、Neovim 0.10+）。**不要**用 mason auto-install，会制造版本漂移 bug。
> 权威清单见 [`docs/CONSTRAINTS.md` §三 C1](docs/CONSTRAINTS.md) 与
> [`docs/TOOLING.md`](docs/TOOLING.md)。

### 其它平台

```bash
git clone https://github.com/hana-alice/nvim-dot-files.git ~/.config/nvim
nvim
```

非 Windows 上 UE 子系统大多 no-op；编辑器本体可用。

### 亚秒级 grep 需要构建一个 Go 小工具（可选但强烈推荐）

`<leader>/` 的工程级 grep 依赖一个 trigram 索引工具
（[google/codesearch](https://github.com/google/codesearch) 的 fork，加了
`-files-from`）。构建一次：

```bash
cd tools/cindex-uefilter && go install ./...     # 需 Go ≥ 1.22，且 $GOBIN 在 PATH
```

下次 `:UEPrepare` 会自动探测到它并建 `.cache/nvim-ue/csearch.idx`。索引缺失时
picker 静默回落到 rg-batched 慢路径（标题会标 slow fallback）。

---

## 使用步骤（让一个 UE 工程跑起来）

这是核心。装完之后对**一个真实 UE 工程**第一次跑通的最短路径：

### 1. 在 UE 工程目录里打开 nvim

打开你的 `.uproject` 所在目录下任意 C++ 文件，或在该目录启动 `nvim`。配置会
自动识别这是个 UE 工程。

### 2. `:UESetProject` — 绑定工程与引擎

```vim
:UESetProject
```

首次会让你确认 **工程根**（`.uproject` 所在）与 **引擎根**（UE5 安装/源码根）。
这两个会持久化进 state，后续无需重复。引擎根变化会自动失效全平台 grep/cdb 缓存。

如果你的 `.uproject` 不在工程根直下，用 `:UESetUprojectRelativePath` 指定相对路径。

### 3.（多平台）`:UESetPlatform` — 选目标平台

```vim
:UESetPlatform        " 选 Win64 / Android / Mac / IOS / Linux
```

不设则按当前 OS 自动探测。**grep/cdb 缓存按 `<Platform>-<Config>` 分目录**，切
平台不会互相污染，旧平台缓存保留。

### 4. `:UEPrepare` — 一键建索引（最重要的一步）

```vim
:UEPrepare
```

这一步全自动、全程 async + 进度 UI，做完这些：

```
UBT -SkipBuild 取编译参数
  → 生成 compile_commands.json
  → 超级流水线裁剪：expand → PCH 预编译 → resolve 路径 → unify includes → prune
     （砍掉 60–90% 的 -I，preamble 解析从 ~60s 降到 ~20s）
  → cindex 建 csearch trigram 索引（亚秒级 grep）
  → 重启 clangd 加载
```

跑完就拥有：精确 goto-def、亚秒 grep、稳定 clangd。变体：

- `:UEPrepareIncremental` — 只处理脏文件（日常改动后快速刷新）
- `:UEPrepareReindex` — 强制重建 csearch 索引
- `:UEPrepareSync` — 同步（阻塞）版，调试用
- `:UEIndexStatus` / `:UEIndexTimings` — 看索引状态与各阶段耗时

### 5. 开始干活

| 想做的事 | 怎么做 |
|---|---|
| 跳定义 | `gd`（5 层 fallback，~70% 命中走 cache，亚 100ms） |
| 找引用 | `gr` |
| 工程级 grep（Engine+Project） | `<leader>/` |
| 文件 picker（最近/智能） | `<leader><leader>` |
| 看全部命令速查 | `<leader>?` 或 `:UECheatsheet` |
| 编译工程 | `:UEBuild`（Android：`:UEBuildAndroid`） |
| 启动 Editor | `:UELaunch` |
| 看路径/状态 | `:UEPaths` / `:UECDBStatus` |

完整键位与工作流手册：`:UECheatsheet`（浮窗）/
[`docs/ue_lazyvim_cheatsheet.md`](docs/ue_lazyvim_cheatsheet.md)（全文）。

---

## 日常工作流

```
首次：  :UESetProject → (:UESetPlatform) → :UEPrepare
改代码：clangd 实时感知内容编辑（无需手动）
增删文件后：:UEPrepareIncremental    # 或下次手动 :UEPrepare 时 watcher dirty 自动并入
切平台：:UESetPlatform              # 缓存按平台分目录，秒切不重建
切工程：:UESetProject              # 工程或引擎变即失效全平台缓存
诊断：  :UEIndexStatus / :UEGrepDiagDump / :UEDirtyStatus / :UEWatchStatus
```

> 文件**集合**变化（增/删/改名）才需要重建 csearch 索引；已有文件的**内容编辑**
> 归 clangd 实时处理，不在 csearch freshness 范围。freshness 用内容指纹判定，不靠
> mtime 代理（避免编译产物 touch 引发假 stale）。

---

## Android DAP 调试

Android attach 是这套配置的硬核能力，走 **lldb-server platform 模式 +
serial-form connect URL**（不是 `gdbserver --attach`，那条路已证伪）。

```
准备：  :UEInstallAndroid        # 把 arm64 lldb-server 推到 /data/local/tmp
        :UESetAndroidPackage     # 设置包名（或首次 attach 时提示）
attach：:UEDAPAttach             # platform select → serial connect → process attach
断点：  F9（:UEDAPToggleBreakpoint）# 按工程持久化，会话内经 lldb-dap evaluate 即时下发
步进：  F10 step over / F11 step in / Shift-F11 step out / F5 continue
界面：  :UEDAPToggleUI / :UEDAPStatus / :UEDAPDiag
```

完整命令见 `:UECheatsheet` 的 DAP 分类。Android 路线的硬知识（ASLR slide、
platform 模式、serial URL、断点命中判据）权威在
[`docs/CONSTRAINTS.md` §二 K30–K37](docs/CONSTRAINTS.md) 与
[`docs/TOOLING.md`](docs/TOOLING.md)。

---

## 里面到底有什么

### 1. UE C++ 工作流中枢（`lua/ue.lua` + `lua/ue/`）

万行单模块中枢，统管 UE 相关一切：clangd 发现与启动、compile_commands.json
生命周期（slim → PCH → unify → prune）、带 idle/cold/hot 防抖的后台索引器、
多平台 DAP、编译命令、日志 tail、Editor 启动、sidebar 集成。公共 API 挂 `M.*`，
headless 可测。子模块：

```
lua/ue/
  cdb/      compile_commands.json 生成/裁剪/shader/inject（纯函数 + 子进程，写前 skip-if-unchanged）
  core/     fs / proc 纯函数（零上层依赖，可 headless 断言）
  dap/      多平台 attach/launch；platforms 注册表是唯一 dispatch seam
  config.lua  index/context/clangd/dap/cdb 默认值 schema（literal defaults，禁反依赖中枢）
```

### 2. 亚 100ms goto-definition（`lua/utils/ue_goto/`）

5 层 fallback 单链，按「省调用 → 命中精度 → 兜底覆盖」串成：

```
treesitter 早退判定 → cache(~70% 命中) → clangd(LSP, 权威) → csearch → gtags
```

设计要点：treesitter 只做「省调用」判定**绝不替 clangd 给答案**（跨翻译单元/
模板/macro 它看不见）；cache HIT 路径纯 lua table lookup，不动任何子进程；
jumper 是单一职责模块，带书面后置条件契约（一个 `Ctrl-O` 回源、恰好一条
jumplist 条目、无幽灵光标）；无 timer-based 漂移修复，竞态用 once-shot autocmd
同步。权威：[`docs/architecture-symbol-resolution.md`](docs/architecture-symbol-resolution.md)。

### 3. 亚秒级 grep（`tools/cindex-uefilter` + `lua/utils/code_search`）

`<leader>/` 工程级 grep 曾经每次按键遍历目录树（UEProj 上 14–32s，NTFS 递归是
物理瓶颈）。现在 `:UEPrepare` 顺手建 trigram 索引，用 fork 的 `-files-from` 喂
干净文件清单（跳过 `Intermediate/`、`DerivedDataCache/` 等）。UEProj（~43k 文件）实测：

| 模式 | 命中 | csearch | rg（遍历） |
|---|---|---|---|
| `FRDGBuilder` | 2491 | **365 ms** | ~14 s |
| `FRHICommandList` | 6593 | **693 ms** | ~18 s |
| `NaniteRasterPipelines` | 57 | **73 ms** | ~12 s |

### 4. workaround 注册表（`lua/workarounds/`）

每个「因为别人的 bug 才存在」的补丁都独立成文件，带可解析的 frontmatter 契约
（name/scope/issue/introduced/removal_condition/enabled…）。`:WorkaroundList` 浏览、
`:WorkaroundDisable <name>` 切换。上游修了就 `git rm`，无需考古。契约见
[`lua/workarounds/README.md`](lua/workarounds/README.md)。

### 5. 平台驱动（`lua/utils/platform/`）

`windows/macos/linux/stub` 四驱动，统一接口（shell / open_path / cmd_quote /
default_*_paths）。**这是唯一允许做 OS 分支的地方**，其余代码读 `platform.is_*`
或调驱动。

### 6. 独立 Python/Go 工具（`tools/`、`scripts/`）

不依赖 Neovim 即可运行的 CDB / PCH / 索引 / DAP 探针工具。CDB 流水线核心：

| 工具 | 作用 |
|---|---|
| `prebuild_pch_v2.py` | 生成 `.rsp` + `.bat` 预编译 UE PCH |
| `prune_include_dirs.py` | 从 CDB 删未用 `-I`（preamble 巨大收益） |
| `unify_include_dirs.py` | 跨 TU 去重 include 目录 |
| `slim_compile_commands.py` | 剥噪声，保留 `-include` 指令 |
| `expand_response_cdb.py` / `resolve_cdb_paths.py` | 展开 response 文件 / 解析路径 |

每个都幂等、输出未变就 skip-write，可在 watcher 循环里反复跑而不失效 PCH / 重启 clangd。

### 7. AI 持久化知识库

让持续介入的 AI agent **从文件而非 chat 历史**发现规则：每个主要目录一份
`CLAUDE.md`（子级只写增量）、根 `CLAUDE.md`/`AGENTS.md` 的 SESSION START 协议 +
Definition of Done、四区知识库（memory / decisions / lessons / architecture）、
以及守护「规则就地可发现」的 `structure_spec` 回归。

---

## 仓库布局

```
.
├── init.lua                      LazyVim 入口（固定启动顺序，见 CONSTRAINTS C3）
├── setup.ps1                     Windows 中文一键安装
├── lua/
│   ├── config/                   keymaps / options / autocmds / lazy / neovide / windows
│   ├── plugins/                  per-plugin setup（snacks-only，不集成 copilot）
│   ├── ue.lua                    UE 引擎中枢（~10k 行单模块）
│   ├── ue/
│   │   ├── cdb/                  compile_commands.json 流水线
│   │   ├── core/                 fs/proc 纯函数
│   │   ├── dap/                  多平台 DAP（win64/mac/linux/ios/android）
│   │   └── config.lua            可调项 schema
│   ├── utils/
│   │   ├── ue_goto/              5 层 goto-def 架构
│   │   ├── code_search/          csearch 亚秒 grep
│   │   ├── platform/             OS 分支唯一收口（四驱动）
│   │   ├── lsp_fallback.lua      fall-through gd resolver
│   │   └── ...
│   ├── workarounds/              隔离的上游 bug 补丁 + 注册表
│   └── nio/, trouble/, theme.lua, highlights.lua
├── tools/
│   ├── cindex-uefilter/          google/codesearch 的 Go fork（加 -files-from）
│   └── (Python 工具…)            PCH / CDB / 索引 / DAP 探针
├── scripts/                      Windows 安装 + 回归包装 + profiling
├── docs/
│   ├── architecture/overview.md  架构总览（从这开始）
│   ├── CONSTRAINTS.md            禁止 / 踩过的坑 / 承重约束（权威索引）
│   ├── TOOLING.md                工具链版本钉死与现状
│   ├── testing-regression.md     回归政策 + change→filter 映射
│   ├── changelog.md              变更记录
│   └── ue_lazyvim_cheatsheet.md  键位 + 工作流手册（:UECheatsheet）
├── memory/                       AI 稳定项目知识（先读这里）
├── decisions/                    ADR 导航
├── lessons/                      平台怪癖 / 调试硬知识
├── openspec/                     spec-driven change 工作流
├── tests/                        headless 回归套件
├── <每个主要目录>/CLAUDE.md       递归本地子系统规则（子级=增量）
└── CLAUDE.md                     根：SESSION START 协议 + Definition of Done
```

**AI 持久化层**：新 context 从根 `CLAUDE.md`（自动注入）开始 → SESSION START 读
`docs/CONSTRAINTS.md` → `memory/project_overview.md` → 当前目录 `CLAUDE.md`（无则
回落最近祖先）。每个主要目录带自己的 `CLAUDE.md`（子级只写相对父级的增量）。
「完成」由根 Definition of Done 把关：跑分范围回归、追加 `docs/changelog.md`、
版本收尾走 milestone 政策。

---

## 约定（不可选）

这套配置遵守的规矩，不是建议：

- **AST/treesitter 优先于 regex** —— 任何结构化代码问题
- **async 优先于阻塞** —— 多秒等待 OK，阻塞主线程不 OK
- **workaround 隔离** —— 仅为绕过上游 bug 的代码进 `lua/workarounds/<scope>/<name>.lua`
- **可自验证模块** —— 公共 API 挂 `M.*`，可 headless 测试
- **不做周期性 ticker 通知** —— 至多 start + 中段更新，成功后自然消退，不刷 `:messages`
- **未变更时跳过写入** —— 每个生成器（CDB/PCH/.clangd）写前先比对，避免使下游 cache 失效

完整的「**禁止**什么、已踩过哪些**坑**、哪些**约束**承重」清单见
[`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md)。完整 agent 契约见
[`CLAUDE.md`](CLAUDE.md)。

---

## 回归测试

任何 `.lua` 运行时代码或 `tests/` 改动，完成前必须跑对应范围回归并全绿；
**提交/合并前必跑全量**：

```
nvim --headless -l tests/run.lua            # 全量（跨平台、权威）
nvim --headless -l tests/run.lua <filter>   # 只跑文件名含 <filter> 的 *_spec.lua
pwsh -File scripts/run_regression.ps1       # Windows 便捷包装
```

退出码 `0` = 全绿，`1` = 任意失败。新用例进 `tests/cases/<域>_spec.lua`（自动发现）。
改动 → 必跑 filter 的速查映射见 [`tests/CLAUDE.md`](tests/CLAUDE.md)；权威细则见
[`docs/testing-regression.md`](docs/testing-regression.md)。

---

## 致谢

- [LazyVim](https://github.com/LazyVim/LazyVim) —— 底座发行版
- [folke/snacks.nvim](https://github.com/folke/snacks.nvim) —— picker / statusline / dashboard
- [clangd](https://clangd.llvm.org/) —— 干所有真活的 C++ LSP
- [google/codesearch](https://github.com/google/codesearch) —— trigram 索引底座（本仓 fork 加 `-files-from`）
