# local-subsystem-rules Specification

## Purpose

让每个承担独立功能的目录都携带一份就地可发现的本地规则内容源 `AGENTS.md`（同目录 `CLAUDE.md`
仅为 `@AGENTS.md` 导入 stub），使 AI agent 进入目录即可发现该子系统的约定、常见坑与应先读的文档，
而不依赖 chat 历史或只靠顶层规则。本地规则只写相对父级的增量。

## Requirements

### Requirement: 主要目录有短小的本地规则

每个主要目录 SHALL 有 `AGENTS.md`（约 20–80 行，摘要 + 出处指针，不复制原文）与 `@AGENTS.md` stub
`CLAUDE.md`；「先读」段 SHALL 列出治理该目录的 spec 指针，或显式写「无对应 capability」。

#### Scenario: agent 进入 `lua/ue/index/`
- **WHEN** agent 进入该目录
- **THEN** 就地读到用途、归属、子系统约定、常见坑与治理 spec 指针

### Requirement: 继承与回落

子目录规则 SHALL 声明继承自 `../AGENTS.md` 且只记增量；目录无本地规则时 SHALL 适用最近祖先目录规则。

#### Scenario: 无本地规则的目录
- **WHEN** 某目录没有 `AGENTS.md`
- **THEN** 适用最近祖先目录的规则

### Requirement: 与约束和 spec 方向一致

本地规则 SHALL 以指针引用 `docs/CONSTRAINTS.md` 的既有条目，MUST NOT 引入与 CONSTRAINTS 或 spec 大方向
冲突的规则；高踩坑密度目录（如 `lua/ue/dap/`）SHALL 就地声明其归属分层契约与每层 owner。

#### Scenario: DAP 目录
- **WHEN** agent 读取 `lua/ue/dap/AGENTS.md`
- **THEN** 看到 L0–L4 五层、每层 owner 与「失败先报层」纪律，并指向 `openspec/specs/dap-failure-layering/spec.md`

## 选型与踩坑

- **选型**：`AGENTS.md` 单一内容源 + `CLAUDE.md` stub——Codex 与 pi 原生读 `AGENTS.md`，Claude 经 `@import`
  展开同一内容，改一次三端同步；禁止为某一 agent 新增第四份并行入口。
- **踩坑**：分层纪律若只存在于源码注释或 changelog，agent 进入目录时看不到，会反复现场取证；因此必须写在本地规则里。
