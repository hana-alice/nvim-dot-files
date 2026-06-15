# structure-discoverability-regression Specification

## Purpose

把「规则与知识就地可发现」变成可执行的回归守护项。回归套件验证主要目录的本地规则文件、知识库结构完整性、关键内部链接不悬空，以及回归/changelog/milestone 政策与映射在文件中可被发现，防止文档腐烂或漂移。

## Requirements

### Requirement: 本地规则存在性回归

回归套件 SHALL 验证每个主要目录都存在本地规则文件 `CLAUDE.md`，把「规则就地可发现」变成可执行的回归守护项。

#### Scenario: 主要目录规则存在性断言

- **WHEN** 可发现性回归用例运行
- **THEN** 遍历一份「主要目录」清单（如 `lua`、`lua/ue`、`lua/ue/cdb`、`lua/ue/core`、`lua/ue/dap`、`lua/utils`、`lua/utils/ue_goto`、`lua/utils/code_search`、`lua/utils/platform`、`lua/config`、`lua/plugins`、`lua/workarounds`、`tools`、`scripts`、`tests`、`docs`）
- **AND** 每个目录均存在 `CLAUDE.md`，缺失则该用例 FAIL 并打印缺失目录

### Requirement: 知识库结构完整性回归

回归套件 SHALL 验证知识库四个区域的 README/总览文件存在。

#### Scenario: 知识库根文件存在

- **WHEN** 结构完整性用例运行
- **THEN** `memory/project_overview.md`、`decisions/README.md`、`lessons/README.md`、`docs/architecture/overview.md` 均存在
- **AND** 任一缺失则用例 FAIL 并打印缺失文件

### Requirement: 关键链接可解析回归

回归套件 SHALL 验证知识库与导航文档中的关键内部链接指向真实存在的文件。

#### Scenario: 内部 Markdown 链接不悬空

- **WHEN** 链接校验用例运行
- **THEN** 对一组关键文档（根 `CLAUDE.md`、`docs/CONSTRAINTS.md`、`memory/project_overview.md`、`docs/architecture/overview.md`）提取其相对路径 Markdown 链接
- **AND** 每个被链接的仓库内文件路径真实存在，悬空链接使用例 FAIL 并打印悬空目标

### Requirement: 回归政策可发现性回归

回归套件 SHALL 验证「改动后回归政策」与其分范围映射在文件中可被发现，防止政策文档被删或漂移。

#### Scenario: 政策与映射表存在

- **WHEN** 政策可发现性用例运行
- **THEN** `tests/CLAUDE.md` 含「改动 → 必跑 spec filter」映射表的可识别标记
- **AND** 根 `CLAUDE.md` 含 SESSION-START 协议块与 Definition of Done 的可识别标记（强制执行入口）
- **AND** `docs/CONSTRAINTS.md` 含「改动后回归政策」条目（指向 `docs/testing-regression.md`）
- **AND** `docs/CONSTRAINTS.md` 与根 `CLAUDE.md` 含「改动记录政策」条目（指向 `docs/changelog.md`）
- **AND** `docs/CONSTRAINTS.md` 与根 `CLAUDE.md` 含「milestone 政策」条目（指向 `docs/changelog.md` 与 release 格式范例）
- **AND** 任一缺失则用例 FAIL
