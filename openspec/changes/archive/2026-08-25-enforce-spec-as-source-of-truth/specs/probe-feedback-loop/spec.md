## MODIFIED Requirements

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
  空且休眠的 topic 移除）并落盘
- **AND** 反馈一次 INFO 提示，不刷屏
