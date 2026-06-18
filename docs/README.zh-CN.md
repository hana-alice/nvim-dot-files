# hana-alice's Neovim — Unreal Engine 版

> 基于 LazyVim 的 Neovim 配置，用于在 Windows 上编辑超大型 Unreal Engine 5
> C++ 工程——并为长期 AI 辅助开发而设计。

[English](../README.md) · **中文**

## 特性

- **Super-unity 索引**：把 11,593 个翻译单元折叠成约 23 个聚合 TU，在
  Windows/NTFS 上把全量冷索引从**几小时压到约 3 分钟**，且保留 ≥90% 符号。
- **亚 100ms 跳定义**：UE 量级工程上的 5 层解析链
  （treesitter → cache → clangd → csearch → gtags）。
- **亚秒级工程 grep**：对工程文件清单建 trigram 索引（`FRDGBuilder` 约
  365ms，对比 NTFS 目录遍历的约 14s）。
- **CDB 超级流水线**：对 `compile_commands.json` 做 expand / PCH 预编译 / 裁剪
  include（删掉 60–90% 的 `-I`），让 clangd 解析更少。
- **多平台 DAP**：Win64 与 Android（headless attach）调试，断点按工程持久化。
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

**仅支持 Windows 10/11。** macOS 与 Linux 未适配：配置能加载、基础编辑器可用，但
UE 子系统（CDB 流水线、索引、DAP、启动器）是针对 Windows 工具链编写的，其它平台
不受支持。

## 环境要求

| 组件 | 版本 / 说明 |
| --- | --- |
| 操作系统 | Windows 10/11 |
| Neovim | 0.10+ |
| 工具链 | clangd/LLVM 22.1.x —— 钉死；不要使用 mason auto-install |
| Android DAP | LLVM 22.1.6+ `lldb-dap` + NDK 27 `lldb-server` |
| 可选 | Go ≥ 1.22，用于构建 grep 索引工具 |
| 构建前置 | 目标平台可用的 Unreal Build Tool 环境 |

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

确认工程根（含 `.uproject`）与引擎根，两者均持久化保存。若 `.uproject` 不在工程根
直下，使用 `:UESetUprojectRelativePath`。

### 2. 选择平台

```vim
:UESetPlatform
```

选择 `Win64`、`Android`、`Mac`、`IOS` 或 `Linux`。不设则按当前 OS。缓存按
`<Platform>-<Config>` 分别存储，切换平台不会使其它平台缓存失效。

### 3. 先对目标平台编译一次（必需）

```
<leader>ub        " （space u b）→ :UEBuild
```

`:UEPrepare` 的编译参数来自目标平台的一次真实编译。**索引前必须已有一次成功的平台
编译**，否则没有 compile commands 可供处理。Android 用 `:UEBuildAndroid` 编译。

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
| 启动 Editor | `:UELaunch` |
| 增删文件后重建索引 | `:UEPrepareIncremental` |
| Android：安装 / attach / 断点 | `:UEInstallAndroid` / `:UEDAPAttach` / `F9` |
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

## 致谢

[LazyVim](https://github.com/LazyVim/LazyVim)、
[snacks.nvim](https://github.com/folke/snacks.nvim)、
[clangd](https://clangd.llvm.org/)、
[google/codesearch](https://github.com/google/codesearch)（fork 加了 `-files-from`）。
