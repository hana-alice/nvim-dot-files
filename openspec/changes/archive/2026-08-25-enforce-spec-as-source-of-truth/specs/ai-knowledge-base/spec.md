## MODIFIED Requirements

### Requirement: 既有知识迁移与索引

现有散落知识 SHALL 被索引或迁移进知识库，且不丢失既有出处的权威性。

#### Scenario: 决策与教训可从知识库导航

- **WHEN** AI agent 从 `decisions/README.md` 或 `lessons/README.md` 出发
- **THEN** 能导航到 `docs/plans/` 的 ADR 与 `docs/CONSTRAINTS.md §二` 的踩坑条目
- **AND** 迁移采用「索引指回原位」或 `git mv` 保留历史，二者择一且不破坏既有链接

#### Scenario: memory 入口指引先读顺序

- **WHEN** AI agent 首次进入仓库
- **THEN** `memory/project_overview.md` 给出「先读什么」的顺序（探针反馈 → CONSTRAINTS →
  architecture/overview → 对应子系统 `AGENTS.md` → 改动范围对应的
  `openspec/specs/<capability>/spec.md`）
- **AND** 指向各子系统本地规则、知识区域与 capability 覆盖映射

### Requirement: 知识库互链与维护契约

知识库各根 SHALL 互链，并纳入「出处优先、索引不复制原文」的维护契约。

#### Scenario: 根入口互链

- **WHEN** 从 `README.md` 或根 `AGENTS.md` 查找规则
- **THEN** 能链接到 `docs/CONSTRAINTS.md`、`memory/`、`decisions/`、`lessons/`、
  `docs/architecture/`、`openspec/specs/`
- **AND** `docs/CONSTRAINTS.md` 维护契约扩展为覆盖知识库腐烂防护与 spec 引用完整性

## ADDED Requirements

### Requirement: capability 覆盖映射登记于知识库

`memory/` 知识库 SHALL 承载一张 capability → 代码目录 → 必跑回归 filter 的覆盖映射，使
agent 从子系统速查表一步定位治理该目录的 spec，而不必遍历 `openspec/specs/`。该映射 MUST
与 `tests/AGENTS.md` 的 CHANGE-TO-FILTER MAP 同源对齐。

#### Scenario: 子系统速查表含 spec 列

- **WHEN** AI agent 阅读 `memory/project_overview.md` 的子系统速查表
- **THEN** 每个子系统条目除代码路径与本地规则外，还给出治理它的
  `openspec/specs/<capability>/spec.md`（无对应 capability 时显式写「无」）
- **AND** 该列与 `tests/AGENTS.md` 的 filter 映射指向同一改动分类

#### Scenario: 映射不腐烂

- **WHEN** 新增或重命名一个 capability，或新增一个子系统目录
- **THEN** 维护契约要求同步更新该覆盖映射
- **AND** capability 覆盖映射回归守护映射中的 capability 与 filter 均可解析
