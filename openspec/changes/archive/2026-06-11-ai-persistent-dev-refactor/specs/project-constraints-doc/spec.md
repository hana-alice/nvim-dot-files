## MODIFIED Requirements

### Requirement: Consolidated constraints reference document

仓库 SHALL 在 `docs/CONSTRAINTS.md` 提供一份权威文档，统一归纳项目的禁止项、
踩过的坑与约束。该文档 MUST 来源于仓库既有出处，并且 MUST 通过索引/链接指向
这些出处，而非整段复制其原文。此外，该文档 MUST 作为导航中枢，链接到持久化
知识库（`memory/`、`decisions/`、`lessons/`、`docs/architecture/`）与递归本地
规则（各目录 `CLAUDE.md`），使 AI agent 能从此入口发现就地规则。

#### Scenario: Document exists and is discoverable

- **WHEN** 贡献者或 AI agent 寻找项目规则
- **THEN** `docs/CONSTRAINTS.md` 存在，并被 `README.md`、
  `docs/architecture-vs-lazyvim.md` 和 `CLAUDE.md` 链接到

#### Scenario: Navigates to knowledge base and local rules

- **WHEN** AI agent 从 `docs/CONSTRAINTS.md` 出发寻找子系统级规则或持久知识
- **THEN** 文档含指向 `memory/`、`decisions/`、`lessons/`、`docs/architecture/overview.md`
  的链接
- **AND** 文档说明「目录无本地 `CLAUDE.md` 时回落最近祖先目录规则」的继承语义

#### Scenario: Change is documentation-only

- **WHEN** 该变更被应用
- **THEN** 没有任何 `.lua`、`.py` 或 `.go` 运行时模块被修改，没有 plugin spec 或
  运行时行为变化（允许新增纯文档 `CLAUDE.md`/README/知识库文件，以及新增只读的
  headless 回归用例 `tests/cases/structure_spec.lua`；不触碰既有模块行为）

### Requirement: Maintenance contract

文档 SHALL 声明它如何保持常新，以免腐烂；该契约 MUST 覆盖知识库与本地规则层。

#### Scenario: Update contract is stated

- **WHEN** 贡献者新增一个 workaround 或踩到一个新坑
- **THEN** 维护小节指示他们将其记入 `docs/CONSTRAINTS.md`，附出处引用，并
  （对坑而言）附症状与解决约束

#### Scenario: Knowledge base and local rules stay coherent

- **WHEN** 贡献者新增一个子系统目录，或新增/迁移一份知识到 `memory/` `decisions/` `lessons/`
- **THEN** 维护契约要求为新目录补一份本地 `CLAUDE.md`（声明继承父级），并在对应
  知识区域 README 登记新条目
- **AND** 可发现性回归（`tests/cases/structure_spec.lua`）守护这些不变量不被破坏
