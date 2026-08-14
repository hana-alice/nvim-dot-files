## Status

**DRAFT — exploration archive only. NOT approved for implementation.**

捕获自 `/opsx:explore` 一次探索（对照《AI 长期软件工程手册》找本仓提升点）。
落地前必须先回答 `design.md` 的三个决策点（甲/乙/丙）。在此之前不得实现。

## Why

《AI 长期软件工程手册》§7.2 / §8.6 反复强调一条：架构边界应「**用工具执行**」
（import rules / dependency-cruiser / ArchUnit / package boundary tests），并把
「import 违规」列为模块健康指标。

本仓 `docs/CONSTRAINTS.md` 已经写了一批「禁止 import / 边界归属」承诺，但它们
**全靠人/AI 读文档 + code review 执行**，没有任何回归会在违规时变红：

- P3  不做全局 `vim.lsp.handlers[...]` 覆盖（只走 lsp_fallback / workarounds/clangd）
- R1  OS 分支只在 `lua/utils/platform/`（overview §5 ownership）
- R5  `lua/ue/core/**` 纯函数、无副作用、不反依赖上层（overview §1）
- DI seam：`ue/config`、`ue/cdb/pipeline`、`ue/dap/platforms` 通过
  literal defaults / `set_runtime` 注入 / `register_*` 注册表与中枢解耦，
  契约是「不在 load 时 `require("ue")`」

对一个 **AI 频繁改代码**的仓库，这正是手册说的「边界可执行 ❌」缺口：某个
agent 完全可能在 core 里反向 `require("ue")`、或在 ue_goto 外把 csearch 当主路，
文档拦不住、review 可能漏。本 change 把这些承诺升级为回归红线，与
`structure-discoverability-regression`（把「规则可发现」变回归）同血统。

## What Changes

新增一个 **treesitter AST 源码扫描型** 回归用例，锁住已声明的边界：

- **新增** `tests/cases/boundaries_spec.lua`：用 `vim.treesitter` 解析
  `lua/**/*.lua`，按规则表检测违规。**必须 AST，不得正则/grep**（见下文铁律）。
- **新增** `openspec/specs/architecture-boundary-regression/spec.md`（本 change
  的 specs/ 目录内已含 delta 草案）。
- **改** `tests/CLAUDE.md`：CHANGE-TO-FILTER MAP 加一行
  `lua/** 运行时模块的 require/边界 → boundaries`。
- **改** `docs/CONSTRAINTS.md`：§三加 `C9 架构边界回归`，指向 spec + spec 文件。
- **改** `docs/changelog.md`：Unreleased 追加一条（DoD 要求）。

## 铁律（A1 实读教训，落地必须遵守）

扫描器**必须用 treesitter AST**，不得用正则/grep。理由有实证：

> A1 阶段用 `grep -o 'require(...)'` 扫描，把 `ue/config.lua:17`、
> `ue/cdb/pipeline.lua:12`、`ue/dap/platforms.lua:5` **文件头注释里**出现的
> `require("ue")` 字符串误判为「反向依赖违规」。实读后这三处恰恰是模范 DI
> 解耦的文档说明——三个文件都在文件头明确写了「no `require("ue")` at load
> time」。文本搜索分不清注释/字符串/代码，正是 CONSTRAINTS P11/P12 反复讲的
> 「文本没有语义」。门禁若重蹈此覆辙，会把模范文件报成违规，比没有更糟。

此铁律本身即仓库约定 C4「AST/treesitter 优先于 regex」。

## 存量违规盘点（A2 勘察实测）

| 规则 | 存量违规 | 说明 |
|---|---|---|
| P3 LSP handler 覆盖 | **0** | 全仓无全局 handler 赋值 |
| R5 core 零上层依赖 | **0** | `ue/core/fs,proc` 仅 require 同层 + `bit` |
| DI seam 不反依赖 | **0** | 三处均为注入/注册表，无 load-time `require("ue")` |
| R1 OS 分支收口 | **1** | `ue/cdb/pipeline.lua` 的 `python_exe()`/`copy_file()` 用 `vim.fn.has("win32")`（决策甲） |

**结论：除 1 条待决策外存量违规为 0。** 本 change 价值是**防回归哨兵**，
不是清存量——与 structure/commands_spec 锁住「已达成的干净状态」同理。

## Capabilities

### Added Capabilities

- `architecture-boundary-regression`：把 CONSTRAINTS 的 P3/R1/R5/DI-seam 边界
  承诺，变为 treesitter AST 驱动的可执行回归红线。

## Impact

- 测试：新增 `tests/cases/boundaries_spec.lua`（仓内**首个**扫描自身源码的
  AST 用例）；新 filter `boundaries`，挂全量。
- 文档：`tests/CLAUDE.md`、`docs/CONSTRAINTS.md`、`docs/changelog.md`。
- 运行时代码：仅当采纳决策甲「收口」时才动 `lua/ue/cdb/pipeline.lua` 与
  `lua/utils/platform/**`；否则零运行时改动。
- 不引入新依赖（treesitter 已在仓内）。

## 阻塞：落地前必答的三个决策

见 `design.md`「Open decisions」。甲/乙/丙未定之前本 change 停留 draft。
