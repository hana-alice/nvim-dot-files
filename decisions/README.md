# Decisions · 架构决策记录（ADR）导航

> **decisions/** 区：记录「为什么这样设计」的架构决策。
> 出处优先：本仓 ADR 的**权威正文仍在 `docs/plans/`**（成熟体系 + 交叉链接），
> 本文件是**分类导航**，不复制原文、不搬家（遵守 refra「minimize disruptive moves」）。
> 已归档的 openspec change（`openspec/changes/archive/`）亦是决策出处。

## 什么属于这里 / 不属于这里

- **属于**：影响子系统形状的设计抉择（为什么用 X 不用 Y）、架构权衡、被否决的方案及理由。
- **不属于**：一次性任务清单（→ openspec change tasks）、踩坑记录（→ `lessons/`）、
  日常改动流水（→ `docs/changelog.md`）。

## ADR 索引（权威在 docs/plans/）

### 多平台基础系列（2026-05）

| ADR | 主题 | 出处 |
|---|---|---|
| 多平台基础 A·B·C·D | 平台驱动 / `ue/core/` / `ue/config` / headless 测试 gate | `docs/plans/2026-05-06-multi-platform-foundation.md` |
| CDB 流水线拆分 E | 把 compile_commands 流水线拆出 `ue.lua` → `ue/cdb/*` | `docs/plans/2026-05-07-cdb-pipeline-split.md` |
| DAP 多平台 F | 平台中立 `UEDAP*` 命令 + dispatch registry | `docs/plans/2026-05-07-dap-multiplatform.md` |
| DAP 真实平台 H | Win64/macOS/Linux/iOS attach/launch | `docs/plans/2026-05-07-dap-real-platforms.md` |
| 配置 schema 扩展 I | `clangd.*`/`dap.*`/`cdb.*` 进 `ue.config` | `docs/plans/2026-05-07-config-schema-expansion.md` |
| Android 配置接线 J | Android prompts 走 `ue.config` | `docs/plans/2026-05-07-android-config-wire.md` |
| UEPrepare csearch 流水线 | 一键增量 `:UEPrepare` | `docs/plans/2026-05-07-ueprepare-csearch-pipeline.md` |
| .h CDB inject | `.h` 反查 + 双 donor，34/34 0 ERROR | `docs/plans/2026-05-08-h-inject-cdb.md` |

### 早期 ADR（2026-04）

| ADR | 主题 | 出处 |
|---|---|---|
| 即时 goto 架构 | 5 层 fallback 解析栈 | `docs/plans/2026-04-17-instant-goto-architecture.md` |
| 语法重载消歧 | 同名重载的语法过滤 | `docs/plans/2026-04-20-syntax-overload-disambiguation.md` |

### 迭代日志（先读这个看「改了什么 + 为什么」）

| 日志 | 出处 |
|---|---|
| multi-platform-foundation 16 commit 全景 | `docs/plans/2026-05-07-iteration-log.md` |

### 归档 change 中的决策出处

| 主题 | 出处 |
|---|---|
| Android DAP attach platform 模式（宪法级 K30） | `openspec/changes/archive/2026-06-03-android-dap-platform-mode/` |
| Android DAP attach handshake 根因 | `openspec/changes/archive/2026-06-03-android-dap-attach-handshake-rootcause/` |
| Android DAP session-time live 断点（K36/K37，evaluate 通道正解） | ADR `docs/plans/2026-06-15-android-dap-live-breakpoints.md`；归档 `openspec/changes/archive/2026-06-15-android-dap-live-breakpoints/` |

## 新增一条决策

1. 在 `docs/plans/` 写 ADR 正文（沿用既有 ADR 格式）。
2. 在本文件对应分类加一行（标题 + 出处指针）。
3. 若该决策动了架构边界，同步 `docs/architecture/overview.md` 与 `memory/project_overview.md`。

相关区：踩坑 → `../lessons/README.md`；总览 → `../docs/architecture/overview.md`；约束 → `../docs/CONSTRAINTS.md`。
