# ai-knowledge-base Specification

## Purpose

提供持久化的 AI 项目知识库，作为跨会话项目记忆的稳定来源。知识库分 `memory/`（总览与速查）、
`decisions/`（ADR 导航）、`lessons/`（平台怪癖与调试硬知识）和 `docs/architecture/`（架构总览）四区，
遵循「出处优先、索引不复制原文」，不替代 `docs/CONSTRAINTS.md` 与 spec。

## Requirements

### Requirement: 四区知识库自描述且职责不重叠

仓库 SHALL 维护四个知识区域，各有一份入口文档（`memory/project_overview.md`、`decisions/README.md`、
`lessons/README.md`、`docs/architecture/overview.md`）说明「什么属于这里 / 不属于这里」。

#### Scenario: 判断知识应放哪里
- **WHEN** 需要沉淀一条设计抉择或一个踩坑
- **THEN** 设计抉择进 decisions（ADR 正文在 `docs/plans/`），踩坑进 CONSTRAINTS §二 并在 lessons 导航

### Requirement: 子系统速查表可一步定位治理 spec 与 filter

`memory/project_overview.md` SHALL 维护子系统速查表，每行给出代码位置、本地规则、治理 spec（无则写「无」）
与必跑 filter，并 MUST 与 `tests/AGENTS.md` 的 CHANGE-TO-FILTER MAP 同源对齐；`structure` 回归守护其可解析。

#### Scenario: 新增 capability 或子系统目录
- **WHEN** 新增或重命名 capability / 子系统目录
- **THEN** 同步速查表，否则 `structure` 回归 FAIL

### Requirement: 根入口互链

`README.md` 与根 `AGENTS.md` SHALL 能链接到 `docs/CONSTRAINTS.md`、四个知识区域与 `openspec/specs/`。

#### Scenario: 首次进入仓库
- **WHEN** agent 首次进入仓库
- **THEN** 能从根入口导航到先读顺序与各知识区域

## 选型与踩坑

- **选型**：索引指回原位（或 `git mv` 保留历史），不搬家、不复制原文——避免多份副本漂移与既有链接失效。
- **选型**：架构总览以指针链接既有深度文档（`docs/architecture-symbol-resolution.md`、
  `docs/architecture-vs-lazyvim.md`、`docs/TOOLING.md`），不复制正文。
