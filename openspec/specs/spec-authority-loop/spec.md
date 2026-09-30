# spec-authority-loop Specification

## Purpose

定义 spec 在本仓开发循环中的**定位与使用方式**：spec 只规定各能力的大方向与不可退让的底线，
并集中记录选型理由、踩坑根因与重要事项；实现细节以代码与回归为准。spec 通过唯一内容源
`AGENTS.md` 对 Claude Code / Codex / pi 三端同时可见，并能从改动目录一步定位。

## Requirements

### Requirement: spec 只规定大方向并记录选型与踩坑

每份 `openspec/specs/<capability>/spec.md` SHALL 只包含：Purpose（能力边界与方向）、2–6 条方向性
Requirement（含安全/隐私/正确性/不静默退化等底线），以及「选型与踩坑」段。spec MUST NOT 退化为
逐字段、逐超时、逐用例的实现契约。

#### Scenario: 日常修复不需要动 spec
- **WHEN** 一次改动只是修复缺陷、调整实现细节或测试，未改变大方向
- **THEN** 不需要更新 spec，也不需要立 openspec change
- **AND** 若产生了值得留底的选型或踩坑，直接追加到对应 spec 的「选型与踩坑」段

### Requirement: 方向变化时先确认再改

当改动与某 spec 的大方向或底线冲突时，开发会话 SHALL 先停下来与用户确认方向，确认后直接更新
spec；MUST NOT 为绕过底线而悄悄改写或删除它。

#### Scenario: 改动触及底线
- **WHEN** 改动会削弱某 spec 声明的底线（例如 SuperUnity 性能保全、隐私门禁）
- **THEN** 会话先向用户说明冲突与取舍，得到明确调整后再改 spec

### Requirement: 按改动范围读取，三端经唯一内容源生效

SESSION START SHALL 要求按改动范围读取对应 spec（经 `memory/project_overview.md` 的「治理 spec」列
定位），MUST NOT 遍历全部 spec。纪律只经根 `AGENTS.md` 层级下发；MUST NOT 为某一 agent 新增并行入口，
目录级 `CLAUDE.md` 保持为 `@AGENTS.md` stub。

#### Scenario: 从改动目录定位 spec
- **WHEN** agent 准备修改某子系统目录（例如 `lua/ue/dap/`）
- **THEN** 子系统速查表给出对应 capability 与必跑 filter，无需遍历 `openspec/specs/`

### Requirement: 回归红灯优先与宿主能力守卫

全量回归存在 FAIL 时 SHALL 先处置（修复 / 记录不处理理由）再推进无关新工作。宿主不具备被断言能力
导致的失败 SHALL 按宿主能力守卫，MUST NOT 伪造可执行文件或宿主让断言碰巧通过。

#### Scenario: 宿主缺少工具
- **WHEN** 某用例因当前宿主缺少对应工具或平台能力而失败
- **THEN** 用例在该宿主上显式 skip 并给出原因，而不是注入假工具

### Requirement: spec 引用不悬空

spec 与关键规则文档中反引号内的仓内路径 SHALL 真实存在，由 `structure` filter 守护；模板/通配路径跳过。

#### Scenario: 引用了已删除文件
- **WHEN** 某 spec 引用的仓内文件已被删除或改名
- **THEN** `structure` 回归 FAIL 并打印悬空路径与所在 spec

## 选型与踩坑

- **踩坑（2026-09-30，用户叫停）**：旧版本把 spec 定为「可观察行为的权威契约」，要求每次改动同步 spec
  或立 change、只改实现不算完成。结果 41 份 spec 膨胀到近万行、50 个归档 change，大量逐超时/逐字段场景
  与实现同频漂移，每次修复都要连带改 spec、跑 sync/archive，严重拖慢开发。已整体瘦身为方向级。
- **选型**：保留 openspec 目录结构与 `openspec validate --strict` 兼容格式（Purpose / Requirement /
  Scenario），因为既有工具与 `structure` 回归依赖它；但不再强制 propose→apply→archive 流程，
  大改动可自愿使用 change。
- **选型**：保留「按改动范围读」「唯一内容源」「红灯优先」「宿主能力守卫」四条纪律——它们成本低、
  防止过真实问题（遍历全部 spec、per-agent 规则分叉、伪造宿主让 CI 碰巧通过）。
- **重要事项**：历史细节并未丢失——瘦身前的完整条款可在 git 历史与
  `openspec/changes/archive/` 中查到；需要追溯某条旧契约时去那里找，不要重新塞回主 spec。
