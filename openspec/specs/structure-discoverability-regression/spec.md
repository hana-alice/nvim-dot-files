# structure-discoverability-regression Specification

## Purpose

把「规则与知识就地可发现」变成可执行的回归守护项（`tests/cases/structure_spec.lua`，filter `structure`）：
验证本地规则、知识库结构、关键链接与 spec 引用不悬空、capability 覆盖映射不腐烂，以及完成定义类政策
在文件中可被发现。它只守护结构与可发现性，不校验 spec 的具体行为条款。

## Requirements

### Requirement: 本地规则与知识库结构存在

回归 SHALL 断言主要目录清单中每个目录都有 `AGENTS.md` 与 `@AGENTS.md` stub `CLAUDE.md`，
且知识库四区入口文件存在；缺失时 FAIL 并打印缺失项。

#### Scenario: 新增主要目录未补规则
- **WHEN** 主要目录清单中的目录缺少 `AGENTS.md` 或 `CLAUDE.md` 不是 stub
- **THEN** `structure` 回归 FAIL

### Requirement: 链接与仓内路径引用不悬空

回归 SHALL 校验关键导航文档的相对 Markdown 链接，以及 spec 与规则文档中反引号内的仓内路径真实存在；
模板/通配形式（含 `<` `>` `*` `...`）与外部 URL SHALL 被跳过，宁漏不误报。

#### Scenario: spec 引用已归档的 change 路径
- **WHEN** 某 spec 引用的 `openspec/changes/<name>/` 已被移入 archive
- **THEN** 回归 FAIL 并打印悬空路径与所在文件

### Requirement: 覆盖映射与政策入口可解析

速查表中的 capability SHALL 有主规格文件，CHANGE-TO-FILTER MAP 中的 filter SHALL 匹配到 `tests/cases/*_spec.lua`；
每个主要目录 `AGENTS.md` SHALL 含 spec 指针或「无对应 capability」；根 `AGENTS.md` SHALL 含 SESSION START、
Definition of Done、红灯优先、分层契约指针，`docs/CONSTRAINTS.md` SHALL 含 C6–C11 等政策条目。

#### Scenario: 重命名 capability
- **WHEN** capability 被重命名但速查表未同步
- **THEN** 回归 FAIL 并打印不可解析的名称

## 选型与踩坑

- **选型**：只检查反引号内、首段命中仓内顶层目录白名单且带已知扩展名的路径，跳过 `module.function` 形态——
  保守策略避免误报拖慢开发。
- **踩坑**：历史审计发现 spec 仍声称产出已被脱敏移除的 `docs/plans/...`、已归档的 change 路径、已删除的脚本；
  这是引入引用完整性用例的原因。
- **重要事项（2026-09-30）**：spec 瘦身后本回归仍只看结构；不要为了「守护 spec」往这里加行为条款断言。
