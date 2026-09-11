# probe-feedback-loop Specification

## Purpose

改动落地后不等用户反馈——代码自己在关键路径埋探针记录证据；下一个开发会话
**第一件事是读探针报告并优先修它揭示的问题**。探针可迭代（re-arm）可休眠
（dormant），证据日志自我精简（TTL + 上限 + 重复压缩），不允许无界增长。

实现：`lua/utils/probe.lua`（生命周期、统计与报告）、`lua/utils/probe_store.lua`（持久化）；报告入口 `:UEProbeReport`；存储
`stdpath('state')/ue_probes.json`。

## Requirements

### Requirement: 读取反馈先于新工作（report-first）
任何进入本仓的开发会话，在开始新改动之前 SHALL 先读取探针证据
（`:UEProbeReport` 或直接读 `ue_probes.json`），且对其中揭示的问题 SHALL
优先于计划中的新工作处理（修复、立 change、或明确记录「不处理+理由」三选一）。
会话启动时若存在未读证据，系统 SHALL 主动提示一次（count 摘要，非刷屏）。

#### Scenario: 会话启动存在证据
- **WHEN** nvim 启动（UIEnter）且存在未读记录或已休眠的版本观察 topic
- **THEN** 显示一次性 INFO 摘要（未读数、未处置失败数、休眠观察数与 `:UEProbeReport` 指引），
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
激活以迭代观察，`:UEProbeSleep <topic>` SHALL 可手动休眠，
`:UEProbeCompact` SHALL 可立即执行一次精简（删除 TTL 过期与超上限记录），
使证据存储无需等到下一次 load/save 即可手动收敛。

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

#### Scenario: 手动立即精简
- **WHEN** 用户执行 `:UEProbeCompact`
- **THEN** 系统立即对存储执行一次精简（TTL 过期记录删除、超上限记录按 last-seen 淘汰、
  没有版本观察标识的空且休眠 topic 移除）并落盘
- **AND** 反馈一次 INFO 提示，不刷屏

### Requirement: 日志定期精简与重复压缩
探针存储 SHALL 满足：(1) **写时去重**——同 (topic, key) 重复事件压缩为单条
`{count, first, last, data=最近一次}`，一万次重复即一条记录；(2) **定期精简**
——每次 load 与 save 时执行 compaction：超过 30 天未更新的记录删除、
每 topic 记录数超上限时按 last-seen 淘汰最旧、无版本观察标识的空且休眠 topic 整体移除；
(3) 存储体积由构造保证有界（cap × topic 数），不存在无界增长路径。

#### Scenario: 重复事件压缩
- **WHEN** 同一 (topic, key) 被 record 1000 次
- **THEN** 存储中恰有一条该 key 的记录，count=1000，first/last 反映时间跨度

#### Scenario: TTL 精简
- **WHEN** 某记录 last-seen 早于 30 天前且触发任一次 load/save/compact
- **THEN** 该记录被删除；其 topic 若因此为空、处于休眠且无版本观察标识则整体移除

### Requirement: 探针自身不得成为负担
record() SHALL 满足 P6/P5：热路径上仅做内存 upsert + 防抖异步落盘
（一次性 timer，必 stop+close），不做同步 IO 放大；探针 SHALL NOT 主动
notify（会话启动摘要除外）；所有调用点 SHALL 经 pcall 包裹，探针故障
不得影响宿主功能。

#### Scenario: 探针模块损坏
- **WHEN** probe.lua 加载失败或 record 抛错
- **THEN** 调用点（wait_notice / dirty cap / smart_build 等）行为不受影响

### Requirement: Repair revisions SHALL open bounded observation windows

能力 owner SHALL 用稳定修复 revision 调用 `observe(topic, revision)`；新 revision SHALL 开启默认 14 天观察。
已有探针能力的行为修复 SHALL 使用新的 revision，并在验收记录中核对该 revision 的采集状态。
同 revision 已过期或被手动休眠时，重复启动/记录 MUST NOT 自动续期。
topic SHALL 保留当前 revision 标识，即使历史记录已被 TTL 清理，防止遗忘后错误续期。
新 revision 的 distinct-key 采样预算 SHALL 不被旧 revision 的历史记录占满；总存储仍遵守 cap，
精简时优先保留当前 revision 及其 overflow 证据。

#### Scenario: A repaired semantic capability was dormant
- **WHEN** 新修复 revision 首次在启动或导航记录路径被观察
- **THEN** 该能力的 topic SHALL 恢复采集，并在状态/报告中标明观察 revision
- **AND** 新观察期的存在 MUST NOT 被表述为该修复已通过真实 UE 验证

### Requirement: Reading, disposition and recurrence SHALL remain distinct

`UEProbeReport` 展示记录后 SHALL 标记当前记录为已读，不得自动标记问题已解决。
`UEProbeResolve <topic> <key> <evidence>` 与 `UEProbeDefer <topic> <key> <reason>` SHALL
保存有界处置说明、观察 revision 和当时的失败计数，不删除历史。

#### Scenario: A resolved failure recurs
- **WHEN** 已处置记录出现新的失败事件
- **THEN** 未读和未解决统计 SHALL 重新包含它
- **AND** 后续成功采样 SHALL 不被计为新失败，也不单独重开已解决失败

#### Scenario: Another process records a failure after an older reader reviewed the topic
- **WHEN** 旧进程提交较早计数的已读/已解决状态
- **THEN** 文件锁内的合并 SHALL 保留新失败，旧处置不得隐藏它

### Requirement: Pending evidence and bounded aggregates SHALL survive normal operation

记录 SHALL 保留计数和固定大小的 outcome/latency 聚合，不保存无界事件列表。
同 revision 的并发 writer SHALL 以增量合并计数、总耗时和桶计数，避免覆盖其他 writer 的采样。
防抖 SHALL 有最大 10 秒延迟；正常退出时 SHALL 在 VimLeavePre 尝试立即落盘尚未保存的证据。

#### Scenario: The editor exits before the debounce interval
- **WHEN** 记录后立即正常退出，存储可写且写锁可用
- **THEN** 新事件 SHALL 在退出前保存，不因两秒防抖尚未到期而丢失

#### Scenario: Normal exit encounters another writer's lock
- **WHEN** 正常退出时主存储写锁不可用，但同目录仍可写
- **THEN** 系统 SHALL 将本进程尚未交付的增量保存到独立 recovery journal
- **AND** 后续读取/保存 SHALL 恢复该增量；主文件提交后、journal 删除前退出也不得重复累计

#### Scenario: Atomic publication fails
- **WHEN** encode、write、flush、close 或 rename 任一步失败
- **THEN** 系统 SHALL 保留旧主文件和未提交增量，记录存储错误，并在进程仍运行时有界退避重试
- **AND** 无法读取的既有文件 MUST NOT 被当作空数据库覆盖
- **AND** 只有真正不存在的文件才可作为空库初始化

#### Scenario: A thousand latency samples share a key
- **WHEN** 同 key 记录 1000 次耗时与结果
- **THEN** 存储 SHALL 保留样本数、总耗时、最小/最大、固定桶与各 outcome 计数
- **AND** 记录大小 SHALL 不随事件次数线性增长
