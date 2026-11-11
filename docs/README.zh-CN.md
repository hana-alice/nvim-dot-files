# hana-alice's Neovim — Unreal Engine 版

> 基于 LazyVim 的 Neovim 配置，用于在 Windows 与 macOS 上编辑超大型 Unreal Engine
> C++ 工程——并为长期 AI 辅助开发而设计。

[English](../README.md) · **中文**

## 特性

- **快速冷索引**：可选的离线前缀 PCH 索引器（私有 clangd fork）加上 Tier 1
  SuperUnity 吸收，在官方 clangd 加载之前预先产出索引存储。大型 UE 工程的全量冷索引
  在安静的 Windows 宿主上从 **1261 s 降到 253–293 s**，官方 clangd 加载时零重建。
  fork 源码在 `hana-alice/llvm-project` 的 `clangd-pch/v26` 分支，以子模块
  `third_party/llvm-project` 挂入仓库，默认不拉取。Windows x64 二进制附在 release
  `v2.15.0` 中，解压到 `~/.cache/clangd-pch-22.1.5/metadata-v26/bin` 即可使用。
- **上下文感知 C++ 跳定义**：source 用 clangd exact-cursor identity；header 在
  compiler-emitted evidence 证明的真实 origin TU 中由异步 libclang sidecar 解析重载。
- **亚秒级工程 grep**：对工程文件清单建 trigram 索引（`FRDGBuilder` 约
  365ms，对比 NTFS 目录遍历的约 14s）。
- **CDB 超级流水线**：对 `compile_commands.json` 做 expand / PCH 预编译 / 裁剪
  include（删掉 60–90% 的 `-I`），让 clangd 解析更少。
- **多平台 DAP**：Win64、Android 与 iOS 物理设备调试，断点按工程持久化。
- **Host/target 双层构建驱动**：Windows/macOS/Linux 宿主执行与
  Win64/Android/Mac/IOS/Linux target 策略分离。
- **macOS/iOS 原生流程**：UBT 编译、UAT 打包归档、物理设备选择、安装与启动。
- **基于文件的 AI 知识库**：逐目录规则、SESSION START 协议、回归门禁的
  Definition of Done。

编辑器本体仍是通用编辑器；没有 UE 工程时所有 UE 功能 no-op。

## 性能数据

实测于 Windows/NTFS 上的大型 UE 工程，目录递归与逐 TU 索引才是真正的瓶颈。

### 冷全量索引——核心亮点

离线前缀 PCH 索引器跑一次全量冷索引的墙钟，始终是同一个工程（中途刷新过一次 UHT 生成头）。
每次运行都过了正确性门禁：回落 0、shard mismatch 0、官方 clangd 重载零重建。

```
冷全量索引（越低越好）
  基线                ████████████████████████████████████████  1261 s
  + Tier 1 吸收       ██████████████████████████▎               830 s
  + 有序调度          █████████████████▎                        545 s
  + seed gate         ████████████████▏                         510 s
  + thin PCH 过滤     ███████████▎                              357 s
  + PGO/LTO/缓存      ████████▌                                 268 s（中位）
```

验收判据事先登记为「一批 3 次的中位数 ≤ 300 s」。连续 7 批达标，中位数 254.9–294.7 s；
清理磁盘之后的 15 次运行 15/15 ≤ 300 s。同机有大量 clangd/python 并发负载时仍要
370–430 s，原因是索引器的 worker 以 IDLE 优先级运行，会让出 CPU。

### 提速靠的是什么

按批次统计：一个批次是一组一起用一次全量冷索引计时的改动。

| 方面 | 优化 | 状态 |
| --- | --- | --- |
| 流水线 | 同一次离线运行吸收 Tier 1 SuperUnity 组（receipt 按官方 reader 的 key 写） | 采用 |
| 流水线 | 有序调度（每个上下文先跑 seed，其余按规模）；跳过已发布的 shard | 采用 |
| 流水线 | prepare overlay、include 图、publish 并行；后台 publish/commit 与 retry lane 重叠 | 采用 |
| 流水线 | retry lane 把失败的 wrapper 按原 UBT 行重新索引（回落 51 → 0） | 采用 |
| 流水线 | PCH 一次性产出、Tier 1 prepare/commit 4 线程、index lane 并行 | 采用 |
| 流水线 | lane 内 didOpen 后立即 didClose；跳过 clangd 的 idle 索引重建 | 采用 |
| clangd fork | seed gate：同上下文的后续 TU 等 seed 结束，再复用 thin PCH | 采用 |
| clangd fork | prefix 头 shard 预载；只差路径拼写的上下文共用 seed | 采用 |
| clangd fork | 原生路径过滤 + thin TU 不加载 prefix 顶层 decl（510 → 357 s） | 采用 |
| clangd fork | rpmalloc、PGO、ThinLTO 构建 | 采用 |
| clangd fork | 进程内缓存已解析的 VFS overlay 文件 | 采用 |
| 否决 | 按路径分隔符合并上下文（输出差异超噪声） | 仅 opt-in |
| 否决 | Tier 1 retry 并入 paired lane（修复后正确，但两对 A/B 都更慢） | 仅 opt-in |
| 否决 | 投机 PCH producer（CPU +19%） | 仅 opt-in |
| 否决 | 提高 `-j`、`-w`、EcoQoS 优先级、扩展 prefix 闭包、提前 retry 重叠 | 放弃 |

测量纪律：判据预登记、ABAB 配对、起跑门禁（宿主 CPU + 外部 clangd/python 实际占用）、
逐次统计外部 CPU、磁盘剩余空间门禁、每次运行后清理 scratch。被证伪的结论留底，不删除。

与冷索引无关的其他改进：

- **Tier 1 / Tier 2 SuperUnity 交付**：严格图门禁、资格验证经得起真实构建输入、
  上下文迁移时失效对应 shard。
- **clangd 内存回收**：后台索引结束后在安静窗口回收；preamble 落盘并使用每会话 TEMP；
  缓存/日志跟随引擎目录，不写系统盘。
- **大 CDB 健壮性**：digest 内存有界、分阶段交付索引且如实报告失败、准备阶段不丢有效工作。
- **上下文感知跳定义**：覆盖 source 与 header；普通（非 UE）C/C++ 工程只走 LSP。
- **评审流程**：CodeDiff 为默认评审视图，`[[` / `]]` 跳 hunk。

### 工程级 grep

对工程文件清单建 trigram 索引，把 NTFS 目录遍历变成索引查询：

| 模式 | 命中 | csearch | ripgrep（NTFS 遍历） | 加速 |
| --- | ---: | ---: | ---: | ---: |
| `FRDGBuilder` | 2,491 | **365 ms** | ~14,000 ms | ~38× |
| `FRHICommandList` | 6,593 | **693 ms** | ~18,000 ms | ~26× |
| `NaniteRasterPipelines` | 57 | **73 ms** | ~12,000 ms | ~164× |

```
FRHICommandList grep（越低越好）
  csearch  ▏0.7s
  ripgrep  ████████████████████████████████████████ 18s
```

## 平台支持

- **Windows 10/11**：主环境，支持 UE 构建/索引与 Win64/Android 工作流。
- **macOS**：支持原生 UE `Build.sh`、Mac/IOS target、CDB 语义流水线及 iOS
  打包/安装/启动、iOS 17+ CoreDevice DAP 与 pre-iOS17 legacy USB DAP。
- **Linux**：基础编辑器与原生 UBT build planner 可用；设备与 DAP 能力取决于 target。

## 环境要求

| 组件 | 版本 / 说明 |
| --- | --- |
| 操作系统 | Windows 10/11，或安装完整 Xcode 的 macOS |
| Neovim | 0.10+ |
| 工具链 | clangd/LLVM 22.1.x —— 钉死；不要使用 mason auto-install |
| Android DAP | LLVM 22.1.6+ `lldb-dap` + NDK 27 `lldb-server` |
| iOS DAP | selected Xcode `lldb-dap` + CoreDevice（`devicectl`）；pre-iOS17 另需 `ios-deploy` + libimobiledevice |
| 可选 | Go ≥ 1.22，用于构建 grep 索引工具 |
| 构建前置 | 目标平台可用的 Unreal Build Tool 环境 |
| iOS | Xcode、iPhoneOS SDK、签名/provisioning、已配对物理设备 |

钉死版本的权威清单见 [`CONSTRAINTS.md` §C1](CONSTRAINTS.md) 与
[`TOOLING.md`](TOOLING.md)。

## 安装

```powershell
git clone https://github.com/hana-alice/nvim-dot-files.git $env:LOCALAPPDATA\nvim
cd $env:LOCALAPPDATA\nvim
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
.\setup.ps1
nvim
```

`setup.ps1` 安装工具链、字体与插件（在管理员 PowerShell 中运行）。参数：
`-SkipFonts`、`-SkipCapslock`、`-SkipPlugins`、`-Force`。

macOS 使用标准配置目录；Xcode 与钉死版本的 LLVM 工具链需另行管理：

```sh
git clone https://github.com/hana-alice/nvim-dot-files.git ~/.config/nvim
nvim
```

可选：构建 grep 索引工具。

```powershell
cd tools\cindex-uefilter
go install ./...   # 需 Go >= 1.22，且 $GOBIN 在 PATH
```

不构建时，工程 grep 回落到较慢的 ripgrep 路径。

## 使用

在 UE 工程内打开一个 C++ 文件。工程与平台选择已经解耦，步骤 1、2 可按任意顺序执行。

### 1. 绑定工程

```vim
:UESetProject
```

确认工程根（含 `.uproject`）与引擎根。选择会被当前 Neovim 进程捕获；磁盘 selector
只作为未来新进程的启动默认值，不会反向改写已运行实例。若 `.uproject` 不在工程根直下，
使用 `:UESetUprojectRelativePath`。

### 2. 选择平台

```vim
:UESetPlatform
```

选择 `Win64`、`Android`、`Mac`、`IOS` 或 `Linux`。不设则按当前 OS。缓存按
`<Platform>-<Config>` 分别存储，切换平台不会使其它平台缓存失效。

### 3. 编译当前 target

```
<leader>ub        " （space u b）→ :UEBuild
```

`:UEBuild` 仍然只构建。选中 IOS 后，`<leader>ub` 与 `:UEBuildIOS` 使用同一个 IOS target
driver。必须等编译结束后再 prepare；build 与 prepare 按 WAW 约束不允许重叠。

### 4. 构建索引

```vim
:UEPrepare
```

全程异步并带进度 UI。macOS 主机上的 IOS target 分支先检查 clangd 22.1.x，并为 IOS 构建补充当前
tuple 的 UBT semantic CDB；IOS 首次还会自动导入 prepared 签名、实测私钥访问并选择设备。该 IOS
前置阶段使用 `GenerateClangDatabase`，不会触发 compile、Cook、Package、Deploy 或 Run。随后所有
平台统一生成 `compile_commands.json`、运行 CDB 流水线（expand → PCH → resolve → unify → prune）、
构建 csearch 索引并重启 clangd。

`:UECompileForNvim` 作为兼容入口保留：它先 build，再委托同一条 `:UEPrepare` 路径；正常流程不再
需要单独调用它。Tree-sitter 语法高亮不依赖 CDB；clangd 导航、诊断和编译器语义需要 CDB。

变体：`:UEPrepareIncremental`（仅脏文件）、`:UEPrepareReindex`（重建索引）、
`:UEPrepareSync`（阻塞）。

### 常用命令

| 操作 | 键 / 命令 |
| --- | --- |
| 跳定义 / 找引用 | `gd` / `gr` |
| 工程级 grep | `<leader>/` |
| 文件 picker | `<leader><leader>` |
| 编译（当前平台） | `<leader>ub` / `:UEBuild` |
| 兼容入口：编译后进入正常 prepare 路径 | `:UECompileForNvim` |
| 只编译 IOS C++（安全复用 AOT，默认不生成 dSYM） | `:UEBuildIOS` |
| 一次性导入 IOS prepared 签名、实测私钥访问并选择设备 | `:UEIOSSetup` |
| 为当前工程导入 prepared identity 或选择 / 清除 IOS 签名证书 | `:UESetIOSSigningCertificate` / `:UESetIOSSigningCertificate!` |
| 复用已有 cooked 数据组 IOS 包 | `:UEPackageIOS` |
| 按需生成并校验 IOS dSYM | `:UEIOSSymbols` |
| IOS 选设备 / 原地安装更新 / 启动 | `:UESetIOSDevice` / `<leader>ui`（或 `:UEInstallIOS`）/ `:UELaunch` |
| IOS debug attach / debug launch / stop | `:UEDAPAttach` / `:UEDAPLaunch` / `:UEDAPStop` |
| 仅编译 Android SO（跳过 APK） | `<leader>us` / `:UEBuildAndroidSO` |
| Android SO 快速部署（root 设备；替换后不启动） | `<leader>uq` / `:UEDeployAndroidSO` |
| 启动当前 target 应用 | `:UELaunch` |
| 增删文件后重建索引 | `:UEPrepareIncremental` |
| Android：选择设备（名称 + serial，仅当前 Neovim 进程） | `<leader>uA` / `:UESetAndroidDevice` |
| 当前平台安装（不启动） | `<leader>ui` / `:UEInstall`（Android 替换 APK；IOS 保留应用身份原地更新、不先卸载） |
| Android：attach / 断点 | `:UEDAPAttach` / `F9` |
| 后台任务：列出 / 停止 | `<leader>X` / `:Tasks` / `:TaskStopAll` |
| 全部命令速查 | `<leader>?` / `:UECheatsheet` |

完整键位与工作流手册见
[`ue_lazyvim_cheatsheet.md`](ue_lazyvim_cheatsheet.md)。

iOS 在外部 `PrepareIOSQADebug.sh` / `InstallIOSClient.sh` 成功后，完整流程就是：
`:UESetProject <workspace>` 与 `:UESetPlatform IOS` 任意顺序 → `<leader>ub` → `:UEPrepare` →
`<leader>ui`。IOS prepare 分支自动完成一次性签名/私钥/设备 setup 与 Apple semantic CDB 生成；
prepared 清单缺失、执行中切换工程或状态落盘失败时都会中止，不会误报 ready。

iOS 17+ DAP 会冻结已选 CoreDevice backend，并只消费结构化 `devicectl` app/process JSON。
debug launch 以 start-stopped 启动；随后 Xcode `lldb-dap` 固定执行
`target create` → `device select` → `device process attach -p`。本地 dSYM 必须通过
`dwarfdump --verify --quiet`；只有 verified breakpoint、真实 breakpoint stop、精确 source:line frame、
expression、loaded-image UUID 与 owner cleanup 全部成立，才算成功。headless 入口是
`tools/nvim_ios_dap_smoketest.lua`，必须显式提供全部
`NVIM_IOS_DAP_SMOKE_{MODE,DEVICE,BACKEND,BUNDLE,BINARY,DSYM,SOURCE,LINE}` 输入；落盘结果会脱敏，
外部 artifact/device 前置不满足时只能写 `blocked`，不能写 `passed`。

## 为长期 AI 辅助开发而建

本仓库的工程设计让 AI agent 能加入、理解代码库、安全改动——**仅凭文件，不依赖 chat
历史**。前提是：AI 能否长期参与，取决于清晰的工程系统，而非更强的模型。

```
一个新的 agent context 这样启动：

  根 CLAUDE.md（自动注入）
        │  SESSION START 协议
        ▼
  docs/CONSTRAINTS.md ──► 禁止 / 踩过的坑 / 承重约束
        │
        ▼
  memory/project_overview.md ──► 子系统 + 「先读什么」导航
        │
        ▼
  <当前目录>/CLAUDE.md ──► 本地子系统规则（无则回落最近祖先）
```

让它「AI 可长期维护」的硬数据：

| 机制 | 数量 | 用途 |
| --- | ---: | --- |
| 逐目录 `AGENTS.md` 规则（`CLAUDE.md` 为 stub） | 23 | 本地子系统规则；子级只写增量 |
| 记录在案的踩坑（`K1…`） | 77 | 每个调试陷阱都留有 症状 → 解决 → 出处 |
| 隔离的 workaround 文件 | 23 | 每个上游 bug 补丁带 frontmatter 契约 |
| headless 回归 spec | 263 | 锁定行为，保证重构与迁移安全 |
| OpenSpec spec / 已归档 change | 41 / 51 | 决策与变更可规格化、可追溯 |

四个知识区，各有固定入口：

| 区 | 入口 | 放什么 |
| --- | --- | --- |
| `memory/` | [`project_overview.md`](../memory/project_overview.md) | 稳定项目知识、导航 |
| `decisions/` | [`README.md`](../decisions/README.md) | 架构决策记录（ADR） |
| `lessons/` | [`README.md`](../lessons/README.md) | 平台怪癖、调试硬知识 |
| `docs/architecture/` | [`overview.md`](architecture/overview.md) | 子系统、数据流、归属边界 |

每次改动由 **Definition of Done** 把关（跑分范围回归、追加 changelog、版本收尾走
milestone 政策）。可发现性本身也被回归守护：目录规则、知识库文件或内链一旦缺失，
`structure_spec` 即失败。完整 agent 契约见 [`../CLAUDE.md`](../CLAUDE.md)。

## 仓库布局

```
init.lua                  LazyVim 入口
setup.ps1                 Windows 安装脚本
lua/
  config/                 keymaps / options / autocmds / lazy 引导
  plugins/                per-plugin setup（snacks-only）
  ue.lua                  UE 引擎中枢（~10k 行）
  ue/{cdb,core,dap}/      CDB 流水线、纯函数、多平台 DAP
  utils/ue_goto/          上下文感知 C++ 跳定义 + 非 C++ 兼容导航
  utils/code_search/      csearch 亚秒 grep
  utils/platform/         唯一允许做 OS 分支的地方
  workarounds/            隔离的上游 bug 补丁与注册表
tools/                    cindex-uefilter（Go）与 Python CDB/PCH/索引工具（含离线前缀 PCH 索引器）
docs/                     架构、约束、工具链、速查表、release 记录
tests/                    headless 回归套件（tests/py 为 Python 工具单测）
```

## 文档

| 主题 | 位置 |
| --- | --- |
| **使用手册（日常流程、按键、排障）** | [`USER_GUIDE.md`](USER_GUIDE.md) |
| 架构总览 | [`architecture/overview.md`](architecture/overview.md) |
| 相对 LazyVim 的增量 | [`architecture-vs-lazyvim.md`](architecture-vs-lazyvim.md) |
| 符号解析内部 | [`architecture-symbol-resolution.md`](architecture-symbol-resolution.md) |
| 禁止 / 踩坑 / 约束 | [`CONSTRAINTS.md`](CONSTRAINTS.md) |
| 钉死的工具链 | [`TOOLING.md`](TOOLING.md) |
| 贡献 / agent 契约 | [`../CLAUDE.md`](../CLAUDE.md) |

## 回归测试

```powershell
nvim --headless -l tests/run.lua            # 全量（权威）
nvim --headless -l tests/run.lua <filter>   # 分范围
pwsh -File scripts\run_regression.ps1       # Windows 包装
python -B -I tests/py/test_clangd_pch_offline.py   # 离线索引器单测
```

退出码 `0` 表示通过，`1` 表示失败。政策与 change→filter 映射见
[`../tests/CLAUDE.md`](../tests/CLAUDE.md)。

若要把 mock/fixture 回归与“本机真实能力”分开检查，可运行：

```sh
nvim --headless -l scripts/nvim_core_health.lua
nvim --headless -l scripts/nvim_core_health.lua --json
```

Neovim 内对应命令为 `:NvimCoreHealth`。报告分别验证真实启动、Tree-sitter parser、
rg/csearch、clangd/CDB 与只读 UE 集成；`DEGRADED` 表示基础编辑器通过，但某个外部能力被
阻塞。详见 [`core-health.md`](core-health.md)。

## 致谢

[LazyVim](https://github.com/LazyVim/LazyVim)、
[snacks.nvim](https://github.com/folke/snacks.nvim)、
[clangd](https://clangd.llvm.org/)、
[google/codesearch](https://github.com/google/codesearch)（fork 加了 `-files-from`）。
