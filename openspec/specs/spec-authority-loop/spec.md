# spec-authority-loop Specification

## Purpose

定义 spec 在本仓开发循环中的**权威地位与生效机制**：spec 不是写完就躺着的文档，而是每个
开发会话在动代码之前必须读到、改完之后必须与实现保持一致的契约。本 capability 规定 spec
如何被三个 agent（Claude Code / Codex / pi）通过唯一内容源自动读到、如何从改动位置一步
定位到治理它的 spec、以及 spec 与实现分叉时如何被可执行回归拦下。

## Requirements

### Requirement: spec 是 SESSION START 的强制前置

任何进入本仓的开发会话，在动代码之前 SHALL 读取其改动范围所对应的
`openspec/specs/<capability>/spec.md`。该要求 MUST 写在根 `AGENTS.md` 的 SESSION START
协议块内，与 `docs/CONSTRAINTS.md`、`memory/project_overview.md`、目录本地规则并列为
强制前置步骤，而非建议。SESSION START MUST 同时说明「按改动范围读，不遍历全部 spec」的
读取边界，避免把强制前置变成 37 份 spec 的全量扫描。

#### Scenario: SESSION START 含 spec 一步

- **WHEN** 一个新 context 的 agent 读取根 `AGENTS.md`
- **THEN** SESSION START 协议块含一条明确要求：动代码前读取改动范围对应的
  `openspec/specs/<capability>/spec.md`
- **AND** 该条目表述为强制前置步骤，并指向 capability 覆盖映射作为定位入口

#### Scenario: 读取范围被界定为按改动范围

- **WHEN** agent 依据 SESSION START 决定读哪些 spec
- **THEN** 协议要求只读改动目录所对应的 capability spec
- **AND** 明确禁止把「读 spec」执行成遍历 `openspec/specs/` 全目录

### Requirement: 三个 agent 通过唯一内容源同时生效

spec 权威性的强制力 SHALL 只通过既有唯一内容源 `AGENTS.md` 层级下发，使 Claude Code、
Codex 与 pi 三个 agent 在无需 per-agent 配置的情况下同时读到同一份纪律。系统 MUST NOT
为让某一个 agent 生效而新增第四份并行维护的入口文件（如 agent 专属规则文件或重复的
spec 索引副本）；`CLAUDE.md` MUST 保持为 `@AGENTS.md` 导入 stub。

#### Scenario: 三端读到同一内容

- **WHEN** 分别以 Claude Code、Codex、pi 在仓库根启动一个新会话
- **THEN** 三者自动加载的项目上下文均包含根 `AGENTS.md` 的内容（Claude 经
  `CLAUDE.md` 的 `@AGENTS.md` 展开，Codex 与 pi 原生读取 `AGENTS.md`）
- **AND** 三者读到的 SESSION START 与 Definition of Done 文本一致，不存在 per-agent 分叉

#### Scenario: 拒绝新增并行入口

- **WHEN** 有改动试图为某个 agent 单独添加一份规则或 spec 索引文件
- **THEN** 该做法 SHALL 被拒绝，内容 MUST 收敛回 `AGENTS.md` 层级
- **AND** 目录级 `CLAUDE.md` 仍 MUST 仅含 `@AGENTS.md` 导入，不承载独立内容

### Requirement: capability 覆盖导航

仓库 SHALL 提供一张 capability → 代码目录 → 必跑回归 filter 的覆盖映射，使 agent 能从
「我要改哪个目录」一步定位到治理该目录的 spec，而不必遍历全部 capability。该映射 MUST
与 `tests/AGENTS.md` 的 CHANGE-TO-FILTER MAP 同源对齐，并 MUST 可从 `docs/CONSTRAINTS.md`
与 `memory/project_overview.md` 导航到。

#### Scenario: 从改动目录定位 spec

- **WHEN** agent 准备修改某个子系统目录（例如 `lua/ue/dap/`）
- **THEN** 覆盖映射给出该目录对应的 capability spec 路径与必跑 filter
- **AND** agent 无需遍历 `openspec/specs/` 即可确定应读哪几份 spec

#### Scenario: 目录级规则声明治理 spec

- **WHEN** agent 进入任一主要目录并读取其 `AGENTS.md`
- **THEN** 该文件的「先读」段落列出治理该目录行为的
  `openspec/specs/<capability>/spec.md` 指针（该目录无对应 capability 时明确写「无」）
- **AND** 指针以路径形式给出，不复制 spec 原文

### Requirement: spec 与实现一致性属于完成定义

一次改动 SHALL 只有在 spec 与实现一致时才算完成：若改动改变了 spec 已声明的可观察行为，
则 MUST 同步更新对应 spec（或立一个 change 承载该 spec 变更）；若发现 spec 落后于既有
正确实现，则 MUST 更正 spec。该条件 MUST 作为根 `AGENTS.md` Definition of Done 的一条
硬条件存在，且 changelog 记录的 Validation 字段 MUST 写明本次 spec 一致性的处置结果
（同步 / 立 change / 判定无 spec 影响）。

#### Scenario: 行为改动必须落到 spec

- **WHEN** 一次改动新增、修改或移除了某 capability spec 已声明的可观察行为
- **THEN** 完成定义要求同步该 spec 的 requirement/scenario，或立一个承载该变更的 change
- **AND** 仅改实现而不动 spec 的收尾 SHALL 视为未完成

#### Scenario: spec 落后于实现时反向更正

- **WHEN** 审计发现 spec 描述与已验证正确的实现不符（spec 陈旧而非实现错误）
- **THEN** 完成定义要求更正 spec 使其与实现一致
- **AND** 该更正 MUST 在 changelog 中留痕，说明是 spec 落后而非行为变更

#### Scenario: DoD 与 changelog 可被发现

- **WHEN** agent 判断一次改动是否完成
- **THEN** 根 `AGENTS.md` 的 Definition of Done 含「spec 与实现一致」硬条件
- **AND** `docs/changelog.md` 的 Validation 约定要求记录 spec 一致性处置

### Requirement: 回归红灯时不得推进新工作

当全量回归存在失败用例时，开发会话 SHALL 先处置这些失败（修复 / 立 change / 明确记录
「不处理 + 理由」三选一），MUST NOT 在红灯状态下推进无关新功能。宿主能力缺失导致的
失败 SHALL 由用例按宿主能力守卫（与 fail-closed 语义一致），MUST NOT 通过在测试中伪造
宿主具备该工具来掩盖。

#### Scenario: 红灯优先于新工作

- **WHEN** 会话开始时或改动过程中全量回归存在 ≥1 条 FAIL
- **THEN** 该 FAIL 的处置 SHALL 先于计划中的新功能开发
- **AND** 选择「不处理」时 MUST 在 changelog 或 change 中留下理由

#### Scenario: 宿主相关失败按能力守卫

- **WHEN** 某用例在当前宿主上失败，原因是该宿主不具备被断言的工具或平台能力
- **THEN** 用例 SHALL 按宿主能力守卫其断言（在不具备该能力的宿主上不执行该断言）
- **AND** MUST NOT 在测试中注入假可执行文件或假宿主使断言「碰巧通过」

### Requirement: spec 引用完整性可被回归发现

回归套件 SHALL 验证 `openspec/specs/**/spec.md` 与关键规则文档中出现的**仓内路径引用**
指向真实存在的文件或目录，把「spec 不得指向已删除/已归档路径」变成可执行守护项。校验
SHALL 跳过占位符（含 `<`/`>`/`*` 的模板路径）与仓外/外部路径，任一悬空引用 MUST 使用例
FAIL 并打印悬空目标及其所在 spec。

#### Scenario: spec 内悬空路径被拦下

- **WHEN** 某份 spec 引用一个仓内路径（如 `docs/plans/....md`、`lua/**` 模块、
  `openspec/changes/<name>/...`）而该路径已不存在
- **THEN** spec 引用完整性用例 FAIL
- **AND** 输出打印该悬空路径与引用它的 spec 文件

#### Scenario: 占位符与外部引用不误报

- **WHEN** spec 中出现 `docs/release_vX.Y.Z.md`、`<engine_root>/...`、`lua/**` 等
  模板或通配形式，或指向仓外/外部 URL
- **THEN** 校验 SHALL 跳过这些引用
- **AND** 不产生误报 FAIL

#### Scenario: 覆盖映射与 filter 表同源

- **WHEN** spec 覆盖映射校验用例运行
- **THEN** 校验 capability 覆盖映射中出现的 filter 名称均对应真实存在的
  `tests/cases/*_spec.lua`
- **AND** 任一 filter 无对应用例文件则 FAIL 并打印该 filter
