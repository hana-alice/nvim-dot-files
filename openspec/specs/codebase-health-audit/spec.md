# codebase-health-audit Specification

## Purpose

定义对本仓代码库执行一次性、只读健康审计的要求：覆盖五个维度（P6 阻塞面、
约束自违反、workaround 存活、并发/生命周期、测试盲区），要求 finding 有
可验证证据、按严重级分类，并把修复动作交给独立的后续 change。边界：本审计
不修改任何运行时代码，不承诺持续更新——它是快照，不是持续监控机制。

## Requirements

### Requirement: 审计必须覆盖五个维度，未完成部分必须显式声明

健康审计 SHALL 覆盖：P6 阻塞面（timer/autocmd/事件回调中的同步 spawn、
`vim.wait`、同步大文件 IO）、约束自违反（文件行数上限、CONSTRAINTS 禁止项
源码复核）、workaround 存活（`lua/workarounds/*/*.lua` 逐个对照 frontmatter
`removal_condition`）、并发/生命周期（timer/job/watcher 的 stop 路径完整性、
有界集合打满时的行为）、测试盲区（`tests/cases/*_spec.lua` 与子系统清单对照，
列出零覆盖/薄覆盖子系统）。任一维度未在时间盒内扫完时，报告 MUST 显式标注
「未覆盖」及原因，不得静默省略。

#### Scenario: 维度超时未完成
- **WHEN** 某一维度在时间盒内未扫完
- **THEN** 报告 MUST 包含该维度的「已覆盖范围 / 未覆盖范围」明细，而非仅给出
  已发现的 finding

### Requirement: finding 必须满足证据标准，无证据观察进附录

每条 finding MUST 包含 `文件:行号` 引用或可复现命令二者至少其一、严重级
（HIGH/MED/LOW）、建议动作（立 change / 记录待观察 / 忽略+理由）。不满足证据
标准的观察 SHALL 不进入 finding 列表，只能进「未证实观察」附录，不计入 finding
统计或触发后续 change 建议。HIGH finding MUST 给出建议的独立 change 名称
（kebab-case）与一句话范围，且该修复 MUST NOT 在本审计 change 内实施。

#### Scenario: 无证据的直觉观察
- **WHEN** 审计者认为某段代码「可能有问题」但无法给出行号级证据或复现命令
- **THEN** 该观察 MUST 落入报告附录「未证实观察」区，MUST NOT 计入 finding
  统计

### Requirement: 审计对代码库只读

审计 SHALL NOT 修改 `lua/` 下任何运行时代码、`tests/` 下任何既有 spec、以及
任何配置行为。允许的写入仅限：审计报告、一次性扫描脚本（`tools/` 新文件）、
openspec change 自身工件。发现看似一行即可修复的缺陷时，MUST 仅记录为
finding，MUST NOT 直接修改运行时代码。

#### Scenario: 发现一行可修的缺陷
- **WHEN** 审计中发现一个看似一行即可修复的缺陷
- **THEN** 审计 MUST 仅将其记录为 finding，MUST NOT 直接修改运行时代码

### Requirement: workaround 复审结论必须是三态之一

每个 workaround 的复审结论 MUST 是三态之一：`可移除`（removal_condition 已
满足，附上游证据链接/版本号）、`保留`（条件未满足，一句话现状）、`条件失效`
（上游变化使原条件无法评估，附改写建议）。判定「可移除」SHALL 仅产出移除
建议，实际移除与禁用验证归后续独立 change，审计自身 MUST NOT 禁用该
workaround 验证行为。

#### Scenario: 上游宣称已修复
- **WHEN** 某 workaround 对应的上游 issue 标记已修复且修复版本 ≤
  lazy-lock.json 锁定版本
- **THEN** 结论 MUST 为「可移除」并附版本证据；审计自身 MUST NOT 禁用该
  workaround 验证行为

### Requirement: 报告是一次性快照，不承诺持续更新

审计完成时 SHALL 产出报告文件，头部 MUST 含快照日期与 HEAD commit hash；
正文 MUST 含五维度分节、finding 总表（按严重级排序）、后续 change 建议清单、
未覆盖区声明。报告为一次性快照，SHALL NOT 承诺持续更新；后续代码演进不
反向要求本审计报告保持同步。

#### Scenario: 审计收尾
- **WHEN** 五维度扫描与判读完成
- **THEN** 报告存在，包含 HEAD hash、finding 总表与 change 建议清单，且全量
  回归（未被审计改动破坏）保持绿

## 选型与踩坑

- **选型**：finding 证据标准强制「文件:行号 或可复现命令」——理由是本仓
  历史上多次「问题都是事后靠 stall_probe / jit.profile / 真机日志抓出来的，
  没有一次主动体检把它们提前找到」；没有该门槛，审计会退化为主观印象罗列，
  无法驱动后续 change。
- **选型**：审计严格只读，修复动作全部拆到独立 change——避免「审计」与
  「修复」两类风险不同的工作混在一次 change 里验收，也避免审计者顺手改动
  未经充分验证。
- **重要事项**：本 capability 的具体审计执行落地于
  `openspec/changes/archive/2026-07-26-codebase-health-check`（首次审计，
  报告见 `docs/health-check-2026-07.md`）；后续若再执行同类审计，应新开
  独立 change 而非复用旧报告文件名。
- **重要事项**：与 `nvim-core-functionality-audit`（`lua/utils/core_health*.lua`
  + `scripts/nvim_core_health.lua`）不同——那是隔离、可机器判定、可重复运行
  的启动/编辑/AST/搜索/clangd/CDB/target plan 证据收集，本 capability 是
  人工判读为主的一次性代码库体检，两者不互相替代。
