# local-subsystem-rules Specification

## Purpose

让仓库的每个承担独立功能的目录都携带一份就地可发现的本地规则内容源 `AGENTS.md`（同目录一份 `@AGENTS.md` 导入 stub `CLAUDE.md`），使 AI agent 进入目录即可发现规则，无需依赖 chat 历史。本地规则采用继承模型、保持短小聚焦，并与 `docs/CONSTRAINTS.md` 的权威约束及 `openspec/specs/` 的 requirement 保持一致。
## Requirements
### Requirement: 每个主要目录存在本地规则文件

仓库的每个承担独立功能的目录（递归到子级）SHALL 包含一份本地规则内容源 `AGENTS.md`，以及
同目录一份内容为 `@AGENTS.md` 导入 stub 的 `CLAUDE.md`，使 AI agent 进入该目录即可就地发现
规则，无需依赖 chat 历史或仅靠顶层规则。规则只维护 `AGENTS.md` 一份内容源：Codex 与 pi
原生读取 `AGENTS.md`，Claude 读 `CLAUDE.md` 并由其 `@import` 展开同一内容，改一次三端同步。

#### Scenario: 主要目录均有本地规则

- **WHEN** AI agent 进入任一主要目录（如 `lua/ue/`、`lua/ue/index/`、`lua/ue/targets/`、
  `lua/ue/workflows/`、`lua/utils/ue_goto/`、`lua/workarounds/`、`tools/`、`scripts/`、
  `tests/`、`docs/`）
- **THEN** 该目录存在 `AGENTS.md` 内容源，且存在为 `@AGENTS.md` stub 的 `CLAUDE.md`
- **AND** 该文件描述：用途、归属、属于/不属于该目录的文件类型、子系统专属约定、
  平台/性能考量、常见坑、应先读的相关文档

#### Scenario: 本地规则文件短小聚焦

- **WHEN** 编写任一目录的 `AGENTS.md`
- **THEN** 内容保持简短聚焦（约 20–80 行）
- **AND** 不复制其它出处的原文，只给摘要 + 出处指针

#### Scenario: 目录规则声明其治理 spec

- **WHEN** 某目录的行为受一个或多个 `openspec/specs/<capability>/spec.md` 治理
- **THEN** 该目录 `AGENTS.md` 的「先读」段落列出这些 spec 的路径指针
- **AND** 该目录无对应 capability 时，显式声明「无对应 capability」而非留空

### Requirement: 子级规则继承父级

本地规则内容源 SHALL 采用继承模型：子目录规则只声明与父级不同的增量，与父级一致的约束
不重复，默认继承上一层。

#### Scenario: 子目录声明继承来源

- **WHEN** 某子目录存在 `AGENTS.md` 且其父目录也存在 `AGENTS.md`
- **THEN** 子目录文件顶部明确声明「继承自 `../AGENTS.md`」（或等效表述）
- **AND** 仅记录相对父级的差异/补充约束

#### Scenario: 无本地规则时回落父级

- **WHEN** 某目录没有自己的 `AGENTS.md`
- **THEN** 适用规则为最近祖先目录的 `AGENTS.md`
- **AND** 这一回落语义在根 `AGENTS.md` 或 `docs/CONSTRAINTS.md` 中被说明

### Requirement: 本地规则与既有约束一致

本地规则内容源 SHALL 与 `docs/CONSTRAINTS.md` 的禁止项/坑/约束以及 `openspec/specs/` 的
requirement 保持一致，并指向权威出处，不得引入与之冲突的新规则。

#### Scenario: 子系统规则指向权威出处

- **WHEN** 某目录 `AGENTS.md` 涉及一条已存在于 CONSTRAINTS 的禁止/坑/约束
- **THEN** 它以摘要 + 指针形式引用该出处（如 `→ docs/CONSTRAINTS.md §一 P3`）
- **AND** 不在本地文件中重新表述与权威出处冲突的内容

#### Scenario: 本地规则不与 spec 冲突

- **WHEN** 某目录 `AGENTS.md` 描述的约定与治理该目录的 capability spec 的 requirement 冲突
- **THEN** 以 spec 为权威，本地规则 MUST 被更正
- **AND** 若冲突源于 spec 陈旧，则 MUST 先更正 spec 再对齐本地规则

### Requirement: 高踩坑密度目录的本地规则 SHALL 声明其归属分层契约

当某目录的失败按**归属层**分类（例如 DAP 的宿主工具链 / 传输 / 目标 OS 策略 / 调试引擎 /
符号语义五层）时，该目录 `AGENTS.md` SHALL 声明这套分层与每层 owner，并 SHALL 声明
「失败必须先报层再给处置」的纪律。

该声明 SHALL 位于本地规则内容源（`AGENTS.md`）中，使进入该目录的 agent 就地发现，
MUST NOT 只存在于源码注释或 changelog。

#### Scenario: DAP 目录规则声明五层契约

- **WHEN** agent 进入 `lua/ue/dap/` 并读取其 `AGENTS.md`
- **THEN** 该文件 SHALL 列出五层归属契约与每层 owner
- **AND** SHALL 声明失败先报层的纪律
- **AND** SHALL 指向治理该契约的 capability spec

