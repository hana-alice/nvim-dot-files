## ADDED Requirements

### Requirement: 每个主要目录存在本地规则文件

仓库的每个承担独立功能的目录（递归到子级）SHALL 包含一份本地规则文件 `CLAUDE.md`，使 AI agent 进入该目录即可就地发现规则，无需依赖 chat 历史或仅靠顶层规则。

#### Scenario: 主要目录均有 CLAUDE.md

- **WHEN** AI agent 进入任一主要目录（如 `lua/ue/`、`lua/utils/ue_goto/`、`lua/workarounds/`、`tools/`、`scripts/`、`tests/`、`docs/`）
- **THEN** 该目录存在 `CLAUDE.md`
- **AND** 该文件描述：用途、归属、属于/不属于该目录的文件类型、子系统专属约定、平台/性能考量、常见坑、应先读的相关文档

#### Scenario: 本地规则文件短小聚焦

- **WHEN** 编写任一目录的 `CLAUDE.md`
- **THEN** 内容保持简短聚焦（约 20–80 行）
- **AND** 不复制其它出处的原文，只给摘要 + 出处指针

### Requirement: 子级规则继承父级

本地规则文件 SHALL 采用继承模型：子目录规则只声明与父级不同的增量，与父级一致的约束不重复，默认继承上一层。

#### Scenario: 子目录声明继承来源

- **WHEN** 某子目录存在 `CLAUDE.md` 且其父目录也存在 `CLAUDE.md`
- **THEN** 子目录文件顶部明确声明「继承自 `../CLAUDE.md`」（或等效表述）
- **AND** 仅记录相对父级的差异/补充约束

#### Scenario: 无本地规则时回落父级

- **WHEN** 某目录没有自己的 `CLAUDE.md`
- **THEN** 适用规则为最近祖先目录的 `CLAUDE.md`
- **AND** 这一回落语义在根 `CLAUDE.md` 或 `docs/CONSTRAINTS.md` 中被说明

### Requirement: 本地规则与既有约束一致

本地规则文件 SHALL 与 `docs/CONSTRAINTS.md` 的禁止项/坑/约束保持一致，并指向权威出处，不得引入与之冲突的新规则。

#### Scenario: 子系统规则指向权威出处

- **WHEN** 某目录 `CLAUDE.md` 涉及一条已存在于 CONSTRAINTS 的禁止/坑/约束
- **THEN** 它以摘要 + 指针形式引用该出处（如 `→ docs/CONSTRAINTS.md §一 P3`）
- **AND** 不在本地文件中重新表述与权威出处冲突的内容
