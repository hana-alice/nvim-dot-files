# Project Overview · AI 持久化开发入口

> 受众：在本仓持续开发的 AI agent 与人类贡献者。
> 这是 **memory/** 区的入口：稳定项目知识 + 「先读什么」导航。
> 出处优先：本文件只做导航与速查，权威细节在各出处。

## 这是什么

hana-alice 的 Neovim 配置（公开镜像 `hana-alice/nvim`），定位为
**专为 Unreal Engine 5 大型 C++ 工程优化的开发环境**：3 分钟全量索引、
亚 100ms goto-definition、一键 Android headless DAP attach、错误全落盘。

LazyVim 作为**库**而非成品；真正引擎是 `lua/ue.lua`（单文件巨模块）+
`lua/ue/`、`lua/utils/`、`lua/workarounds/`。

## 先读什么（SESSION START 顺序）

新 context 进来、动代码前**按序读**：

1. **根 `CLAUDE.md`** — SESSION START 协议 + Definition of Done（完成的硬标准）。
2. **`docs/CONSTRAINTS.md`** — 禁止 / 踩过的坑 / 约束（权威索引）。
3. **本文件** — 项目总览 + 子系统速查。
4. **当前改动目录的 `CLAUDE.md`** — 子系统本地规则（无则回落最近祖先目录）。

## 子系统速查

| 子系统 | 位置 | 本地规则 | 一句话 |
|---|---|---|---|
| UE 引擎中枢 | `lua/ue.lua` + `lua/ue/` | `lua/ue/CLAUDE.md` | 索引 / CDB / DAP / 命令注册的中枢 |
| CDB 流水线 | `lua/ue/cdb/` | `lua/ue/cdb/CLAUDE.md` | compile_commands.json 生成/裁剪/注入 |
| DAP 调试 | `lua/ue/dap/` | `lua/ue/dap/CLAUDE.md` | codelldb + Android platform 模式 |
| goto 解析栈 | `lua/utils/ue_goto/` | `lua/utils/ue_goto/CLAUDE.md` | 5 层 fallback：TS→cache→clangd→csearch→gtags |
| 代码搜索 | `lua/utils/code_search/` | `lua/utils/code_search/CLAUDE.md` | csearch 亚秒级 grep（兜底，非主路） |
| 平台驱动 | `lua/utils/platform/` | `lua/utils/platform/CLAUDE.md` | 唯一允许做 OS 分支的地方 |
| workaround 注册表 | `lua/workarounds/` | `lua/workarounds/CLAUDE.md` | 上游 bug 补丁，带 frontmatter |
| 配置层 | `lua/config/` | `lua/config/CLAUDE.md` | keymaps / options / autocmds / lazy |
| 插件层 | `lua/plugins/` | `lua/plugins/CLAUDE.md` | per-plugin setup（snacks-only） |
| 回归测试 | `tests/` | `tests/CLAUDE.md` | headless 套件 + 分范围回归映射 |

详见 `docs/architecture/overview.md`（数据流 / 平台层 / 构建流水线 / 归属边界）。

## 知识库各区

| 区 | 入口 | 放什么 |
|---|---|---|
| memory | 本文件 | 稳定速查 / 项目总览 / 先读顺序 |
| decisions | `decisions/README.md` | 架构决策记录（ADR）导航 |
| lessons | `lessons/README.md` | 平台怪癖 / 调试硬知识 |
| architecture | `docs/architecture/overview.md` | 架构总览 |

## 开发纪律（完成的硬标准）

权威在根 `CLAUDE.md` 的 Definition of Done；摘要：

1. **改完跑回归**：按改动范围跑对应 filter（映射见 `tests/CLAUDE.md`），提交前全量。
2. **改完记 changelog**：`docs/changelog.md` 追加一条，Validation 写所跑回归范围。
3. **收尾走 milestone**：semver 触发 + 四件套（见 `docs/CONSTRAINTS.md` §三 C8）。

