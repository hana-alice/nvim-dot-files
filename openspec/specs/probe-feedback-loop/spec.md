# probe-feedback-loop Specification

## Purpose

改动落地后不等用户反馈——代码自己在关键路径埋探针记录证据；下一个开发会话第一件事是读探针
报告并优先处置它揭示的问题。探针可迭代（re-arm）可休眠（dormant），证据日志自我精简（TTL +
上限 + 重复压缩），不允许无界增长。实现：`lua/utils/probe.lua`（生命周期、统计与报告）、
`lua/utils/probe_store.lua`（持久化）；报告入口 `:UEProbeReport`；存储
`stdpath('state')/ue_probes.json`。

## Requirements

### Requirement: 读取反馈先于新工作（report-first）

任何进入本仓的开发会话，在开始新改动之前 SHALL 先读取探针证据（`:UEProbeReport` 或直接读
`ue_probes.json`），且对其中揭示的问题 SHALL 优先于计划中的新工作处理（修复、立 change、或
明确记录「不处理+理由」三选一）。会话启动时若存在未读证据，系统 SHALL 主动提示一次（count
摘要，非刷屏）。

#### Scenario: 证据揭示已落地改动的故障

- **WHEN** 探针报告显示某 topic 存在失败类记录
- **THEN** 开发会话对该记录的处置（修复 / 立 change / 记录不处理理由）SHALL 先于新功能开发

### Requirement: 探针可迭代、可休眠，日志自我精简且体积有界

每个探针 topic SHALL 具备生命周期：首次 record 自动 arm（默认 TTL）；TTL 过期或 distinct-key
达到上限后自动休眠，休眠后 record 为无成本 no-op；命令可重新激活（re-arm）、手动休眠或立即
精简。存储 SHALL 写时去重（同 (topic, key) 重复事件压缩为一条 `{count, first, last}`）、
定期精简（TTL 过期删除、超上限按 last-seen 淘汰、无观察标识的空休眠 topic 移除），体积由构造
保证有界，不存在无界增长路径。

#### Scenario: 洪水自我保护与重复压缩

- **WHEN** 某 topic 的 distinct key 数达到上限，或同一 (topic, key) 被 record 上千次
- **THEN** topic 自动休眠并留下一条聚合 `_overflow` 记录，不再吸收新 key
- **AND** 重复事件在存储中压缩为一条计数记录，不随事件次数线性增长

### Requirement: 探针自身不得成为负担

`record()` SHALL 满足性能与可靠性底线：热路径仅做内存 upsert + 防抖异步落盘（一次性 timer，
必 stop+close），不做同步 IO 放大；探针 SHALL NOT 主动 notify（会话启动摘要除外）；所有调用点
SHALL 经 pcall 包裹，探针故障不得影响宿主功能。

#### Scenario: 探针模块损坏

- **WHEN** `probe.lua` 加载失败或 `record` 抛错
- **THEN** 调用点（wait_notice / dirty cap / smart_build 等）行为不受影响

### Requirement: Repair revisions SHALL open bounded observation windows

能力 owner SHALL 用稳定修复 revision 调用 `observe(topic, revision)`；已有探针能力的行为修复
SHALL 使用新的 revision 并在验收记录中核对该 revision 的采集状态。新 revision 的存在 MUST NOT
被表述为该修复已通过真实环境验证；同 revision 过期或被手动休眠时不得自动续期。

#### Scenario: A repaired semantic capability was dormant

- **WHEN** 新修复 revision 首次在启动或导航记录路径被观察
- **THEN** 该能力的 topic SHALL 恢复采集并标明观察 revision
- **AND** 新观察期的存在不构成「已通过真实验证」的证明

### Requirement: Reading, disposition and recurrence SHALL remain distinct

`UEProbeReport` 展示记录后 SHALL 标记为已读，不得自动标记问题已解决；`Resolve`/`Defer` 类命令
SHALL 保存有界处置说明与当时失败计数，不删除历史。已处置记录出现新失败事件时 SHALL 重新计入
未读/未解决统计，且并发 writer 的合并 SHALL 保留新失败，不被旧处置隐藏。

#### Scenario: A resolved failure recurs

- **WHEN** 已处置记录出现新的失败事件
- **THEN** 未读和未解决统计 SHALL 重新包含它，后续成功采样不被计为新失败

## 选型与踩坑

- **选型**：探针默认 arm 一个有限 TTL 而非永久开启，兼顾「新修复需要观察窗口验证」与「不让
  证据存储无界增长」两个目标。
- **踩坑**：若不区分「读取/已读」与「处置/已解决」，`UEProbeReport` 的展示动作会被误当作问题
  已修复；处置为读取仅标记已读，解决/推迟需要显式命令并留底说明。
- **重要事项**：`observe(topic, revision)` 打开的新观察期只是「开始采集」，MUST NOT 被下游
  报告或文档表述为该修复已经过真实环境验证——这是防止误报「已验证」的强约束。
- **重要事项**：正常退出时的防抖落盘与写锁冲突下的 recovery journal 机制存在，用于避免退出
  前的最后一批证据丢失；原子发布失败（encode/write/flush/close/rename 任一步）时 SHALL 保留
  旧主文件与未提交增量，不得把无法读取的既有文件当空库覆盖。
