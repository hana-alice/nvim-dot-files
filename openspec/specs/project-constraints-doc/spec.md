# project-constraints-doc Specification

## Purpose

在 `docs/CONSTRAINTS.md` 提供一份权威的、统一归纳项目禁止项、踩过的坑与约束的导航文档，
使人类与 AI agent 动代码前能一站式发现承重规则。该文档以索引/链接指向仓库既有出处，而非整段复制原文，
并作为知识库（`memory/`、`decisions/`、`lessons/`、`docs/architecture/`）、目录本地规则与 spec 的导航中枢。

## Requirements

### Requirement: 单一约束导航中枢

仓库 SHALL 在 `docs/CONSTRAINTS.md` 维护「禁止 / 踩过的坑 / 约束」三段，每条附简短理由与出处指针；
该文档 SHALL 被根 `AGENTS.md` 与 `README.md` 链接，并链接到知识库四区与 `openspec/specs/`。

#### Scenario: agent 寻找项目规则
- **WHEN** agent 在 SESSION START 读取 `docs/CONSTRAINTS.md`
- **THEN** 能找到禁止项、按领域分组的坑与版本钉死/约定，并能跳转到原始出处

### Requirement: SuperUnity 性能硬约束不依赖 spec 即可发现

根 `AGENTS.md` SHALL 在 SESSION START 之前直接写出 SuperUnity 性能保全约束（不得静默删除/绕过二次合并、
正确性与性能同时验收、基线不可偷换），`docs/CONSTRAINTS.md` C11 与相关本地规则 SHALL 链接该正文；
MUST NOT 新增 agent 专属平行规则源。

#### Scenario: agent 未使用 OpenSpec 工作流
- **WHEN** agent 只读取根或目录本地规则
- **THEN** 它仍能发现该约束，且功能回归全绿不构成豁免

### Requirement: DAP 归属分层纪律可见

`docs/CONSTRAINTS.md` SHALL 在约束段记录 DAP 五层归属契约（L0–L4）与每层 owner，以及「失败先报层、再给处置」
纪律；新增 DAP 坑 MUST 标注其归属层。权威正文在 `openspec/specs/dap-failure-layering/spec.md`。

#### Scenario: 新增一条 DAP 坑
- **WHEN** 贡献者记录新的 DAP 坑
- **THEN** 条目标注归属层，读者可一步判断是外部契约还是本仓缺陷

### Requirement: 维护契约防腐

新增 workaround 或踩到新坑时 SHALL 记入 `docs/CONSTRAINTS.md` 并附出处；引用的仓内文件被删除或改名时
SHALL 同步更正引用，`tests/cases/structure_spec.lua` 守护引用不悬空与入口指针存在。

#### Scenario: 被引用文件归档
- **WHEN** 某条目引用的仓内文件被移动或删除
- **THEN** `structure` 回归 FAIL，提示同步更正

## 选型与踩坑

- **选型**：索引 + 出处指针，而不是复制原文——避免 CONSTRAINTS、本地规则、spec 形成多份可漂移副本。
- **选型**：`AGENTS.md` 为唯一内容源、各目录 `CLAUDE.md` 为 `@AGENTS.md` stub；目录无本地规则时回落最近祖先。
- **踩坑**：区分「历史 LLVM 22.0–22.1.5 启动崩」与「当前 22.1.6 pin 上裸 `script` 命令崩（`0xC0000409`，
  `launch` 无 response）」两个不同失败；`import lldb` 在当前 pin 上仍不可用（缺 `lldb` python 包），
  不要据「已修」删掉 native `type summary` 兜底。
- **重要事项**：DAP 坑中只有少数属本仓代码，多数是目标 OS 策略与调试引擎等外部契约，这是引入分层的原因。
- **重要事项（2026-09-30）**：C9 已由「spec 是行为权威、改实现必须同步 spec」调整为「spec 只规定大方向、
  记录选型与踩坑」，见 `openspec/specs/spec-authority-loop/spec.md`。
