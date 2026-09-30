# test-regression-policy Specification

## Purpose

提供本仓「完成定义」类开发政策——改动后回归、分范围回归映射、changelog 记录与 milestone——并把强制力
收口于根 `AGENTS.md`（Claude Code / Codex / pi 每个新 context 自动注入的唯一内容源），使人类与 AI agent
都能从文件发现流程，而不是依赖 chat 历史。操作细则在 `docs/testing-regression.md`，速查在 `tests/AGENTS.md`。

## Requirements

### Requirement: 根 AGENTS.md 是强制执行入口

根 `AGENTS.md` SHALL 含 SESSION START 协议块（探针反馈 → `docs/CONSTRAINTS.md` → `memory/project_overview.md`
→ 目录本地规则 → 改动范围对应 spec）与 Definition of Done；根 `CLAUDE.md` MUST 保持为 `@AGENTS.md` stub。

#### Scenario: 新 context 进入仓库
- **WHEN** 新 agent 准备改动
- **THEN** 从根 `AGENTS.md` 即可得知前置阅读顺序与完成硬条件，`structure` 回归守护这些标记存在

### Requirement: 改动后必须跑对应范围回归并全绿

代码或测试改动 SHALL 按 CHANGE-TO-FILTER MAP 跑对应 filter 并全绿；提交/合并前 MUST 跑全量
`nvim --headless -l tests/run.lua`；影响面不确定时 MUST 升级到全量而非猜窄 filter。新增功能域、命令、快捷键、
公共 API 时 SHALL 补对应用例。

#### Scenario: 跨子系统改动
- **WHEN** 改动跨多个子系统或无法判定影响面
- **THEN** 以全量回归为验证，不以单一 filter 通过视为完成

### Requirement: 原生验收不以跳过代替通过

语义导航/编译器契约的最终验收 SHALL 使用 `NVIM_TEST_REQUIRE_NATIVE=1`，缺少真实工具不得以 skip 充当 pass；
CI SHALL 至少有一个必需原生验收 lane，其余宿主的能力跳过 SHALL 独立可见。

#### Scenario: 本地缺少真实 clangd
- **WHEN** 必需原生模式下缺少所需真实工具
- **THEN** 用例失败并报出缺失能力，而非静默跳过

### Requirement: 每次落地改动记 changelog，版本收尾走 milestone

每次落地改动 SHALL 在 `docs/changelog.md` Unreleased 追加一条（既有模板，Validation 写所跑回归范围与结果）。
版本收尾 SHALL 按 semver 执行 milestone：release 文档 + changelog 切片归档 + 全量回归门禁 + git tag（须用户确认）
+ 架构变更同步知识库。

#### Scenario: 连贯工作收尾
- **WHEN** Unreleased 累积 8–12 条或一项连贯工作收尾
- **THEN** 切片到 `docs/release_vX.Y.Z.md`，Released 段留交叉链接

## 选型与踩坑

- **选型**：分范围 filter + 提交前全量，而不是「改一行跑全量」——全量含原生用例，本机一次约 10+ 分钟。
- **选型**：强制力只收口在根 `AGENTS.md`，其余文档只做出处，避免多份可漂移的政策副本。
- **踩坑**：全量回归在本机曾出现时限波动（同一 watcher helper 默认 Python 3.12 启动到 ready 约 9 s、
  Python 3.14 约 125 ms）；复测通过不等于波动已修复，需在 changelog 如实记录首次失败。
- **重要事项（2026-09-30）**：Definition of Done 的 spec 条件已降为方向级——仅改变大方向或产生值得留底的
  选型/踩坑时才动 spec，changelog 不再要求逐条声明「spec 一致性处置」。
