# probe-feedback-loop Specification

## Purpose

改动落地后不等用户反馈——代码自己在关键路径埋探针记录证据；下一个开发会话
**第一件事是读探针报告并优先修它揭示的问题**。探针可迭代（re-arm）可休眠
（dormant），证据日志自我精简（TTL + 上限 + 重复压缩），不允许无界增长。

实现：`lua/utils/probe.lua`；报告入口 `:UEProbeReport`；存储
`stdpath('state')/ue_probes.json`。

## Requirements

### Requirement: 读取反馈先于新工作（report-first）
任何进入本仓的开发会话，在开始新改动之前 SHALL 先读取探针证据
（`:UEProbeReport` 或直接读 `ue_probes.json`），且对其中揭示的问题 SHALL
优先于计划中的新工作处理（修复、立 change、或明确记录「不处理+理由」三选一）。
会话启动时若存在未读证据，系统 SHALL 主动提示一次（count 摘要，非刷屏）。

#### Scenario: 会话启动存在证据
- **WHEN** nvim 启动（UIEnter）且探针存储中存在 ≥1 条记录
- **THEN** 显示一次性 INFO 摘要（topic 数 + record 数 + `:UEProbeReport` 指引），
  不重复提示、不使用 ERROR/WARN 级别刷屏

#### Scenario: 证据揭示已落地改动的故障
- **WHEN** 探针报告显示某 topic 存在失败类记录（如 `android-wait-launch` 的
  set-debug-app 失败、`csearch-smart-build` 的 add-fallback-reset）
- **THEN** 开发会话对该记录的处置（修复 / 立 change / 记录不处理理由）
  SHALL 先于新功能开发

### Requirement: 探针可迭代与可休眠
每个探针 topic SHALL 具备生命周期：首次 record 自动 arm（默认 14 天 TTL）；
TTL 过期或 distinct-key 达到上限后自动休眠（dormant），休眠后 record 为
no-op（调用点零成本、零改动）；`:UEProbeArm <topic> [days]` SHALL 可重新
激活以迭代观察，`:UEProbeSleep <topic>` SHALL 可手动休眠。

#### Scenario: TTL 过期自动休眠
- **WHEN** topic 的 armed_until 已过且再次调用 record()
- **THEN** record 返回 false 且不写入任何数据（探针睡眠，调用点无感）

#### Scenario: 洪水自我保护
- **WHEN** 某 topic 的 distinct key 数达到 max_records 上限
- **THEN** topic 自动休眠并留下一条 `_overflow` 聚合记录（含次数），
  不再吸收新 key（同 F2 dirty-set 洪水哲学：打满必须可见且自停）

#### Scenario: 重新激活迭代
- **WHEN** 用户执行 `:UEProbeArm <topic> 7`
- **THEN** 该 topic 恢复记录 7 天，已有历史记录保留

### Requirement: 日志定期精简与重复压缩
探针存储 SHALL 满足：(1) **写时去重**——同 (topic, key) 重复事件压缩为单条
`{count, first, last, data=最近一次}`，一万次重复即一条记录；(2) **定期精简**
——每次 load 与 save 时执行 compaction：超过 30 天未更新的记录删除、
每 topic 记录数超上限时按 last-seen 淘汰最旧、空且休眠的 topic 整体移除；
(3) 存储体积由构造保证有界（cap × topic 数），不存在无界增长路径。

#### Scenario: 重复事件压缩
- **WHEN** 同一 (topic, key) 被 record 1000 次
- **THEN** 存储中恰有一条该 key 的记录，count=1000，first/last 反映时间跨度

#### Scenario: TTL 精简
- **WHEN** 某记录 last-seen 早于 30 天前且触发任一次 load/save/compact
- **THEN** 该记录被删除；其 topic 若因此为空且处于休眠则整体移除

### Requirement: 探针自身不得成为负担
record() SHALL 满足 P6/P5：热路径上仅做内存 upsert + 防抖异步落盘
（一次性 timer，必 stop+close），不做同步 IO 放大；探针 SHALL NOT 主动
notify（会话启动摘要除外）；所有调用点 SHALL 经 pcall 包裹，探针故障
不得影响宿主功能。

#### Scenario: 探针模块损坏
- **WHEN** probe.lua 加载失败或 record 抛错
- **THEN** 调用点（wait_notice / dirty cap / smart_build 等）行为不受影响
