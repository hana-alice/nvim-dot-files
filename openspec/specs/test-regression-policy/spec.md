# test-regression-policy Specification

## Purpose

提供一套权威的开发完成定义类政策——改动后回归测试、分范围回归映射、改动记录与 milestone——并把强制力收口于根 `CLAUDE.md`（每个新 context 自动注入的强制执行入口），使人类与 AI agent 都能从文件发现流程，而非依赖 chat 历史。

## Requirements

### Requirement: 根 CLAUDE.md 强制执行入口

根 `CLAUDE.md` SHALL 作为开发政策的**强制执行入口**——它是每个新 context 自动注入的文件，因此本仓所有「完成定义」类政策（回归 / changelog / milestone）的强制力 MUST 收口于此，使新 context 的 AI agent 无需主动查找即被告知流程。根 `CLAUDE.md` MUST 含一个 SESSION-START 协议块与一份 Definition of Done。

#### Scenario: SESSION-START 协议块存在

- **WHEN** 一个新 context 的 AI agent 进入仓库准备改动
- **THEN** 根 `CLAUDE.md` 顶部含可识别的「SESSION START」协议块，规定动代码前的第一动作为依次阅读：`docs/CONSTRAINTS.md` → `memory/project_overview.md` → 当前改动目录的 `CLAUDE.md`（无则回落最近祖先）
- **AND** 该块表述为强制前置步骤而非建议

#### Scenario: Definition of Done 列出完成硬条件

- **WHEN** AI agent 判断一次改动是否「完成」
- **THEN** 根 `CLAUDE.md` 含 Definition of Done，明确「缺一不算完成」的三条硬条件：
  - 按改动范围跑对应 filter 回归并全绿（映射表见 `tests/CLAUDE.md`）
  - 在 `docs/changelog.md` 追加记录（Validation 字段写所跑回归范围与结果）
  - 收尾版本时执行 milestone 政策（semver 触发 + 四件套产出）
- **AND** 其余文档（`docs/CONSTRAINTS.md`、`tests/CLAUDE.md`、`docs/testing-regression.md`、`docs/changelog.md`）为出处/细节，强制入口是根 `CLAUDE.md`

#### Scenario: 强制入口可被回归发现

- **WHEN** 可发现性回归运行
- **THEN** 校验根 `CLAUDE.md` 含 SESSION-START 协议块与 Definition of Done 的可识别标记
- **AND** 任一缺失则用例 FAIL

### Requirement: 改动后回归测试政策

仓库 SHALL 提供一条权威的「改动后回归测试」政策，规定任何代码或测试改动在视为完成前 MUST 运行回归测试并全绿；该政策 MUST 被文档化在 `docs/CONSTRAINTS.md`、根 `CLAUDE.md` 与 `tests/CLAUDE.md`，使人类与 AI agent 都能从文件发现，而非依赖 chat 历史。其强制力以根 `CLAUDE.md` 的 Definition of Done 为入口（见「根 CLAUDE.md 强制执行入口」）。

#### Scenario: 政策可被发现

- **WHEN** 贡献者或 AI agent 改动了 `.lua` 运行时代码或 `tests/` 用例
- **THEN** `docs/CONSTRAINTS.md`、根 `CLAUDE.md`、`tests/CLAUDE.md` 中存在「改动后必须跑对应范围回归并全绿才算完成」的明确条目
- **AND** 该条目指向权威操作出处 `docs/testing-regression.md`

#### Scenario: 新增功能必须补测试

- **WHEN** 新增一个功能域、用户命令、快捷键或公共 API
- **THEN** 政策要求同步新增或更新对应的 `tests/cases/*_spec.lua`
- **AND** 冻结清单类用例（如 `commands_spec.lua` 的 `UE_COMMANDS`）在相关命令变化时必须同步

### Requirement: 分范围回归映射

回归政策 SHALL 按改动类型界定**最小必跑范围**，避免「改一行跑全量」的浪费，同时保证合并/提交前至少跑过一次全量。该映射 MUST 文档化于 `docs/testing-regression.md` 并在 `tests/CLAUDE.md` 给出速查。

#### Scenario: 按改动类型选择 filter 范围

- **WHEN** 贡献者完成一次局部改动
- **THEN** 政策给出改动类型 → 必跑 spec 范围的映射，至少覆盖：
  - 改 keymap/命令注册（`lua/config/keymaps.lua`、命令定义）→ `keymaps`、`commands`
  - 改 `ue.config` schema → `ue_config`、`smoke`
  - 改 `ue.cdb.*` → `ue_cdb`
  - 改 DAP / 平台（`lua/ue/dap/**`、`lua/utils/platform/**`）→ `dap`、`platform`
  - 改 `ue_goto` / `code_search` / `ue_paths` → `ue_goto_behavior`、`ue_paths`、`utils`
  - 改 options/autocmd（`lua/config/options.lua`、`autocmds.lua`）→ `options`、`autocmds`
  - 改 workarounds → `workarounds`、`smoke`
  - 改文档/规则/知识库结构 → `structure`
- **AND** 使用 `nvim --headless -l tests/run.lua <filter>` 或 `scripts/run_regression.ps1 -Filter <filter>` 运行该范围

#### Scenario: 提交/合并前跑全量

- **WHEN** 准备 commit 或 PR（跨子系统改动、重构、或无法判定影响面时）
- **THEN** 政策要求运行不带 filter 的全量 `nvim --headless -l tests/run.lua` 并全绿（退出码 0）
- **AND** 跨多个子系统的改动不得仅凭单一 filter 范围即视为验证通过

#### Scenario: 拿不准影响面就升级范围

- **WHEN** 改动的影响面无法明确归入上述某一类（如改动公共 helper、跨子系统重构）
- **THEN** 政策要求向上升级到全量回归，而非猜测一个窄 filter
- **AND** 该「不确定即升级」原则在 `tests/CLAUDE.md` 明确写出

### Requirement: 改动记录政策

仓库 SHALL 提供一条权威的「改动记录」政策：每次落地的改动（即便一行补丁）在视为完成前 MUST 在 `docs/changelog.md` 的 Unreleased 段追加一条记录；该政策 MUST 被文档化在 `docs/CONSTRAINTS.md` 与根 `CLAUDE.md`，使其可从文件发现，而非仅存在于 `docs/changelog.md` 自身头部。

#### Scenario: 改动记录政策可被发现

- **WHEN** 贡献者或 AI agent 落地任意改动
- **THEN** `docs/CONSTRAINTS.md` 与根 `CLAUDE.md` 中存在「每次改动必须在 `docs/changelog.md` 追加记录」的明确条目
- **AND** 该条目指向权威格式出处 `docs/changelog.md`（其 Entry template / How to use 段）

#### Scenario: 改动记录遵循既有模板

- **WHEN** 追加一条 changelog 记录
- **THEN** 记录使用 `docs/changelog.md` 既有模板（`### YYYY-MM-DD — 标题` + Task / Implemented / Pitfalls / Validation / Follow-ups）
- **AND** Implemented 条目包含具体文件路径与函数/模块名
- **AND** Validation 条目记录所跑的回归范围（filter 或全量）与结果，与「改动后回归测试政策」呼应

#### Scenario: changelog 滚动与归档

- **WHEN** Unreleased 段累积 8–12 条或一项连贯的多步工作收尾
- **THEN** 政策指示将其切片到 `docs/release_vX.Y.Z.md` 并在 changelog 的 Released 段留一行交叉链接
- **AND** changelog 继续作为 rolling Unreleased 段前进

### Requirement: milestone（版本里程碑）政策

仓库 SHALL 提供一条权威的「milestone 政策」，规定 milestone 何时产出（按 semver 语义）以及产出物清单；该政策 MUST 文档化在 `docs/CONSTRAINTS.md` 与根 `CLAUDE.md`，并指向 `docs/changelog.md` 与既有 `docs/release_vX.Y.Z.md` 格式范例。

#### Scenario: milestone 按 semver 触发

- **WHEN** 判断是否应产出一个 milestone
- **THEN** 政策按 semver 语义界定版本号递增：含 BREAKING 变更 → major、引入新能力 → minor、仅修复/小改 → patch
- **AND** 版本号与既有序列（`v1.0.0`…`v1.0.3`）连续，不跳号、不倒退

#### Scenario: milestone 产出物清单完整

- **WHEN** 一个 milestone 收尾
- **THEN** 政策要求产出以下全部：
  - 生成 `docs/release_vX.Y.Z.md`（沿用 `release_1.0.0.md` 格式），并把 changelog Unreleased 段切片归档、在 Released 段加交叉链接、清空 Unreleased
  - 在 milestone 标记前运行不带 filter 的**全量回归** `nvim --headless -l tests/run.lua` 并全绿（与「分范围回归映射」的「提交前全量」联动，作为 milestone 门禁）
  - 打 git tag `vX.Y.Z`（**tag/commit 动作须经用户确认**，遵循仓库 git 政策，不自动执行）
  - 若该 milestone 改动了架构或子系统边界，则同步更新 `memory/` 知识库与 `docs/architecture/overview.md`

#### Scenario: milestone 政策可被发现

- **WHEN** 贡献者或 AI agent 准备收尾一个版本
- **THEN** `docs/CONSTRAINTS.md` 与根 `CLAUDE.md` 含「milestone 触发条件 + 产出物清单」条目
- **AND** 条目指向 `docs/changelog.md`（Released/归档约定）与 `docs/release_vX.Y.Z.md`（格式范例）
