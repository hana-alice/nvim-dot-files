# hana-alice's Neovim — Unreal Engine 版

> 基于 LazyVim 的 Neovim 配置，用于在 Windows 与 macOS 上编辑超大型 Unreal Engine
> C++ 工程——并为长期 AI 辅助开发而设计。

[English](../README.md) · **中文**

## 特性

- **Super-unity 索引**：把 11,593 个翻译单元折叠成约 23 个聚合 TU，在
  Windows/NTFS 上把全量冷索引从**几小时压到约 3 分钟**，且保留 ≥90% 符号。
- **上下文感知 C++ 跳定义**：source 用 clangd exact-cursor identity；header 在
  compiler-emitted evidence 证明的真实 origin TU 中由异步 libclang sidecar 解析重载。
- **亚秒级工程 grep**：对工程文件清单建 trigram 索引（`FRDGBuilder` 约
  365ms，对比 NTFS 目录遍历的约 14s）。
- **CDB 超级流水线**：对 `compile_commands.json` 做 expand / PCH 预编译 / 裁剪
  include（删掉 60–90% 的 `-I`），让 clangd 解析更少。
- **多平台 DAP**：Win64 与 Android（headless attach）调试，断点按工程持久化。
- **Host/target 双层构建驱动**：Windows/macOS/Linux 宿主执行与
  Win64/Android/Mac/IOS/Linux target 策略分离。
- **macOS/iOS 原生流程**：UBT 编译、UAT 打包归档、物理设备选择、安装与启动。
- **基于文件的 AI 知识库**：逐目录规则、SESSION START 协议、回归门禁的
  Definition of Done。

编辑器本体仍是通用编辑器；没有 UE 工程时所有 UE 功能 no-op。

## 性能数据

实测于 UEProj：**11,593 个 `.cpp` 文件**、每条 CDB 757 个 `-D` 宏、运行在
Windows/NTFS 上——目录递归与逐 TU 索引才是真正的瓶颈。

### Super-unity 索引——核心亮点

朴素的「一 TU 一索引」冷构建跑下来是**几小时**起步。super-unity 流水线把这
11,593 个翻译单元折叠成**约 23 个聚合 TU** 再索引——全量冷索引**约 3 分钟**，
保留 ≥90% 符号。

```
全量冷索引（11,593 TU）
  朴素逐 TU        ████████████████████████████████████████  几小时
  super-unity      ██▏ ~3 min     （11,593 TU 折叠成 ~23）
```

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
  打包/安装/启动；尚未实现 iOS 真机 DAP。
- **Linux**：基础编辑器与原生 UBT build planner 可用；设备与 DAP 能力取决于 target。

## 环境要求

| 组件 | 版本 / 说明 |
| --- | --- |
| 操作系统 | Windows 10/11，或安装完整 Xcode 的 macOS |
| Neovim | 0.10+ |
| 工具链 | clangd/LLVM 22.1.x —— 钉死；不要使用 mason auto-install |
| Android DAP | LLVM 22.1.6+ `lldb-dap` + NDK 27 `lldb-server` |
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

在 UE 工程内打开一个 C++ 文件，按顺序操作。

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

### 3. 为编辑器语义编译

```
<leader>ub        " （space u b）→ :UEBuild
```

推荐直接执行 `:UECompileForNvim`：先验证仓库钉死的 clangd 22.1.x，再编译当前 target，
最后准备 CDB 与索引。IOS 编译不会保留 C++ response file，因此 build 成功后会在同一个构建
终端继续执行 tuple-scoped UBT `GenerateClangDatabase` action-graph 阶段；它不执行编译、Cook 或
Package。Tree-sitter 语法高亮不依赖这一步；clangd 导航、诊断和编译器语义需要 CDB。

`:UEBuild` 仍然只构建；已有新鲜 response file 或已验证的 tuple-scoped semantic source 时可单独
执行 `:UEPrepare`。

### 4. 构建索引

```vim
:UEPrepare
```

全程异步并带进度 UI：生成 `compile_commands.json`、运行 CDB 流水线
（expand → PCH → resolve → unify → prune）、构建 csearch 索引、重启 clangd。完成
后跳定义、工程 grep 与 clangd 均就绪。

变体：`:UEPrepareIncremental`（仅脏文件）、`:UEPrepareReindex`（重建索引）、
`:UEPrepareSync`（阻塞）。

### 常用命令

| 操作 | 键 / 命令 |
| --- | --- |
| 跳定义 / 找引用 | `gd` / `gr` |
| 工程级 grep | `<leader>/` |
| 文件 picker | `<leader><leader>` |
| 编译（当前平台） | `<leader>ub` / `:UEBuild` |
| 编译并准备 Neovim 编译器语义 | `:UECompileForNvim` |
| 只编译 IOS C++（安全复用 AOT，默认不生成 dSYM） | `:UEBuildIOS` |
| 为当前工程导入 prepared identity 或选择 / 清除 IOS 签名证书 | `:UESetIOSSigningCertificate` / `:UESetIOSSigningCertificate!` |
| 复用已有 cooked 数据组 IOS 包 | `:UEPackageIOS` |
| 按需生成并校验 IOS dSYM | `:UEIOSSymbols` |
| IOS 选设备 / 安装 / 启动 | `:UESetIOSDevice` / `:UEInstallIOS` / `:UELaunch` |
| 仅编译 Android SO（跳过 APK） | `<leader>us` / `:UEBuildAndroidSO` |
| Android SO 快速部署（root 设备；替换后不启动） | `<leader>uq` / `:UEDeployAndroidSO` |
| 启动当前 target 应用 | `:UELaunch` |
| 增删文件后重建索引 | `:UEPrepareIncremental` |
| Android：选择设备（名称 + serial，仅当前 Neovim 进程） | `<leader>uA` / `:UESetAndroidDevice` |
| Android：安装（不启动）/ attach / 断点 | `<leader>ui` / `:UEDAPAttach` / `F9` |
| 后台任务：列出 / 停止 | `<leader>X` / `:Tasks` / `:TaskStopAll` |
| 全部命令速查 | `<leader>?` / `:UECheatsheet` |

完整键位与工作流手册见
[`ue_lazyvim_cheatsheet.md`](ue_lazyvim_cheatsheet.md)。

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
| 逐目录 `CLAUDE.md` 规则 | 19 | 本地子系统规则；子级只写增量 |
| 记录在案的踩坑（`K1…`） | 39 | 每个调试陷阱都留有 症状 → 解决 → 出处 |
| 隔离的 workaround 文件 | 9 | 每个上游 bug 补丁带 frontmatter 契约 |
| headless 回归 spec | 21 | 锁定行为，保证重构与迁移安全 |
| OpenSpec spec / 已归档 change | 14 / 12 | 决策与变更可规格化、可追溯 |

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
  utils/ue_goto/          5 层跳定义
  utils/code_search/      csearch 亚秒 grep
  utils/platform/         唯一允许做 OS 分支的地方
  workarounds/            隔离的上游 bug 补丁与注册表
tools/                    cindex-uefilter（Go）与 Python CDB/PCH/索引工具
docs/                     架构、约束、工具链、速查表
tests/                    headless 回归套件
```

## 文档

| 主题 | 位置 |
| --- | --- |
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
