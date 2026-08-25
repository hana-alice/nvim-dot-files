## ADDED Requirements

### Requirement: spec 引用完整性回归

回归套件 SHALL 验证 `openspec/specs/**/spec.md` 与关键规则文档（根 `AGENTS.md`、各目录
`AGENTS.md`、`docs/CONSTRAINTS.md`、`memory/project_overview.md`）中出现的**仓内路径引用**
指向真实存在的文件或目录，把「规则与 spec 不得指向已删除或已归档路径」变成可执行守护项。

#### Scenario: 悬空仓内路径被拦下

- **WHEN** 引用完整性用例运行，且某份 spec 或规则文档引用了一个已不存在的仓内路径
  （如被删除的 `docs/plans/*.md`、已归档到 `openspec/changes/archive/` 后的旧 change 路径、
  被移除的 `scripts/*.lua`）
- **THEN** 该用例 FAIL
- **AND** 输出打印每条悬空路径及引用它的文件

#### Scenario: 占位符与外部引用不误报

- **WHEN** 被检查文本中出现模板/通配形式（含 `<`、`>`、`*` 的路径，如
  `docs/release_vX.Y.Z.md`、`lua/**`、`<engine_root>/...`）或仓外/外部 URL
- **THEN** 校验 SHALL 跳过这些引用
- **AND** 不产生误报 FAIL

### Requirement: capability 覆盖映射回归

回归套件 SHALL 验证 capability 覆盖映射（capability → 代码目录 → 必跑 filter）自身不腐烂：
映射中出现的 filter 名称均有对应用例文件，映射中出现的 capability 均有对应主规格文件。

#### Scenario: 映射中的 filter 与 capability 均可解析

- **WHEN** 覆盖映射校验用例运行
- **THEN** 映射中每个 filter 名称都能匹配到至少一个 `tests/cases/*_spec.lua`
- **AND** 映射中每个 capability 名称都存在 `openspec/specs/<capability>/spec.md`
- **AND** 任一不可解析则 FAIL 并打印该名称

### Requirement: 目录规则声明治理 spec 回归

回归套件 SHALL 验证每个主要目录的 `AGENTS.md` 在「先读」段落显式声明其治理 spec 指针
（指向 `openspec/specs/<capability>/spec.md`），或显式声明该目录无对应 capability。

#### Scenario: 目录规则含 spec 指针或显式无

- **WHEN** 目录规则 spec 指针用例运行
- **THEN** 每个主要目录的 `AGENTS.md` 含至少一个 `openspec/specs/` 路径引用，或含可识别的
  「无对应 capability」声明
- **AND** 任一目录两者皆缺则 FAIL 并打印该目录

## MODIFIED Requirements

### Requirement: 本地规则存在性回归

回归套件 SHALL 验证每个主要目录都存在本地规则内容源 `AGENTS.md` 与同目录 `@AGENTS.md`
导入 stub `CLAUDE.md`，把「规则就地可发现」变成可执行的回归守护项，并保证单一内容源约定
不被回退成双份维护。

#### Scenario: 主要目录规则存在性断言

- **WHEN** 可发现性回归用例运行
- **THEN** 遍历一份「主要目录」清单（`lua`、`lua/ue`、`lua/ue/cdb`、`lua/ue/core`、
  `lua/ue/dap`、`lua/ue/index`、`lua/ue/targets`、`lua/ue/workflows`、`lua/utils`、
  `lua/utils/ue_goto`、`lua/utils/code_search`、`lua/utils/platform`、`lua/config`、
  `lua/plugins`、`lua/workarounds`、`lua/trouble`、`lua/nio`、`tools`、`scripts`、
  `tests`、`docs`）
- **AND** 每个目录均存在 `AGENTS.md`，且同目录 `CLAUDE.md` 为 `@AGENTS.md` 导入 stub，
  缺失或非 stub 则该用例 FAIL 并打印缺失目录

### Requirement: 回归政策可发现性回归

回归套件 SHALL 验证「改动后回归政策」、其分范围映射，以及 spec 权威性纪律在文件中可被
发现，防止政策文档被删或漂移。

#### Scenario: 政策与映射表存在

- **WHEN** 政策可发现性用例运行
- **THEN** `tests/AGENTS.md` 含「改动 → 必跑 spec filter」映射表的可识别标记
- **AND** 根 `AGENTS.md` 含 SESSION-START 协议块与 Definition of Done 的可识别标记
  （强制执行入口），且根 `CLAUDE.md` 为 `@AGENTS.md` stub
- **AND** 根 `AGENTS.md` 的 SESSION-START 含 `openspec/specs` 必读一步，
  Definition of Done 含 spec 一致性硬条件
- **AND** `docs/CONSTRAINTS.md` 含「改动后回归政策」条目（指向 `docs/testing-regression.md`）
- **AND** `docs/CONSTRAINTS.md` 与根 `AGENTS.md` 含「改动记录政策」条目（指向 `docs/changelog.md`）
- **AND** `docs/CONSTRAINTS.md` 与根 `AGENTS.md` 含「milestone 政策」条目（指向
  `docs/changelog.md` 与 release 格式范例）
- **AND** 任一缺失则用例 FAIL

### Requirement: 关键链接可解析回归

回归套件 SHALL 验证知识库与导航文档中的关键内部链接指向真实存在的文件。

#### Scenario: 内部 Markdown 链接不悬空

- **WHEN** 链接校验用例运行
- **THEN** 对一组关键文档（根 `AGENTS.md`、`docs/CONSTRAINTS.md`、
  `memory/project_overview.md`、`docs/architecture/overview.md`）提取其相对路径 Markdown 链接
- **AND** 每个被链接的仓库内文件路径真实存在，悬空链接使用例 FAIL 并打印悬空目标
