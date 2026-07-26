# Spec Delta: codebase-health-audit

## ADDED Requirements

### Requirement: 五维度覆盖
健康审计 SHALL 覆盖以下五个维度，任一维度未完成时 MUST 在报告中显式标注
「未覆盖」及原因，不得静默省略：

1. P6 阻塞面：timer 回调 / autocmd / 事件回调中的同步 spawn（`vim.fn.system` /
   `vim.fn.systemlist` / `io.popen`）、`vim.wait`、同步大文件 IO。
2. 约束自违反：文件行数上限、CONSTRAINTS P1–P17 禁止项源码复核、C4 六约定抽查。
3. workaround 存活：`lua/workarounds/*/*.lua` 逐个对照 frontmatter
   `removal_condition` 与 lazy-lock.json 锁定版本。
4. 并发/生命周期：所有 `new_timer`/`jobstart`/`fs_event` 的 stop/close 路径完整性；
   有界集合（如 persistent_dirty cap）打满时的行为与可见性。
5. 测试盲区：`tests/cases/*_spec.lua` 与子系统清单（memory/project_overview.md
   子系统速查表）对照，列出零覆盖/薄覆盖子系统。

#### Scenario: 维度超时未完成
- **WHEN** 某一维度在时间盒内未扫完（如 ue.lua 逐段判读未完成）
- **THEN** 报告 MUST 包含该维度的「已覆盖范围 / 未覆盖范围」明细，而非仅给出
  已发现的 finding

### Requirement: finding 证据标准
每条 finding MUST 满足：包含 `文件:行号` 引用或可复现命令二者至少其一；包含
严重级（HIGH/MED/LOW）；包含建议动作（立 change / 记录待观察 / 忽略+理由）。
不满足证据标准的观察 SHALL 不进入 finding 列表（可进「未证实观察」附录）。

#### Scenario: 无证据的直觉观察
- **WHEN** 审计者认为某段代码「可能有问题」但无法给出行号级证据或复现命令
- **THEN** 该观察 MUST 落入报告附录「未证实观察」区，MUST NOT 计入 finding
  统计或触发后续 change 建议

#### Scenario: HIGH finding 的后续交接
- **WHEN** 一条 finding 定级 HIGH
- **THEN** 报告 MUST 为其给出建议的独立 change 名称（kebab-case）与一句话范围，
  且该修复 MUST NOT 在本审计 change 内实施

### Requirement: 只读约束
审计 SHALL NOT 修改 `lua/` 下任何运行时代码、`tests/` 下任何既有 spec、以及
任何配置行为。允许的写入仅限：审计报告（`docs/health-check-2026-07.md`）、
一次性扫描脚本（`tools/` 新文件）、openspec change 自身工件。

#### Scenario: 发现一行可修的缺陷
- **WHEN** 审计中发现一个看似一行即可修复的缺陷
- **THEN** 审计 MUST 仅将其记录为 finding（含建议 change），MUST NOT 直接修改
  运行时代码

### Requirement: workaround 存活判定三态
每个 workaround 的复审结论 MUST 是三态之一：`可移除`（removal_condition 已满足，
附上游证据链接/版本号）、`保留`（条件未满足，一句话现状）、`条件失效`（上游变化
使原条件无法评估，附改写建议）。判定「可移除」SHALL 仅产出移除建议，实际移除
与禁用验证归后续独立 change。

#### Scenario: 上游宣称已修复
- **WHEN** 某 workaround 对应的上游 issue 标记已修复且修复版本 ≤ lazy-lock.json
  锁定版本
- **THEN** 结论 MUST 为「可移除」并附版本证据；审计自身 MUST NOT 禁用该
  workaround 验证行为

### Requirement: 报告产出与存档
审计完成时 SHALL 产出 `docs/health-check-2026-07.md`，头部 MUST 含快照日期与
HEAD commit hash；正文 MUST 含五维度分节、finding 总表（按严重级排序）、
后续 change 建议清单、未覆盖区声明。报告为一次性快照，SHALL NOT 承诺持续更新。

#### Scenario: 审计收尾
- **WHEN** 五维度扫描与判读完成
- **THEN** 报告存在于 `docs/health-check-2026-07.md`，包含 HEAD hash、finding
  总表与 change 建议清单，且全量回归（未被审计改动破坏）保持绿
