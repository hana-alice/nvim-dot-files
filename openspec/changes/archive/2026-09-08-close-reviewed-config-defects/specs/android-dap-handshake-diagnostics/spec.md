## MODIFIED Requirements

### Requirement: 定位 gdb 握手零响应 root cause

诊断 SHALL 分层复现并定位 "gdbserver 存活但 gdb 初始握手零响应 / Connection shut down"
的真因，覆盖端口监听、adb forward 链路、gdb 协议、server↔目标兼容、目标 ptrace 状态。

#### Scenario: 每层有判定

- **WHEN** 逐层排查握手零响应
- **THEN** 确认 gdbserver 是否在端口 listen（设备本地 `/proc/net/tcp` 或等价）
- **AND** 确认 adb forward 能建连（connect 成功但零响应 → 排除链路，指向协议/server）
- **AND** 用正确 checksum + ack 的 `$qSupported#<ck>` 区分"server 不说话"与"握手包格式错"
- **AND** 必要时换 server 二进制对照握手层，判断是否 server↔UE 目标不兼容

#### Scenario: 解释上一轮误判

- **WHEN** 对比"握手零响应"与上一轮"tracer 稳定"
- **THEN** 诊断说明 tracer 附上不等于 attach 成功，并指出上一轮是否漏测握手层

#### Scenario: app uid listener 与 shell control 的同 binary A/B

- **WHEN** app-uid `lldb-server platform` 进程存活且端口 LISTEN，但正确 checksum 的
  forwarded GDB packet 超时
- **THEN** 诊断 SHALL 在同一捕获 serial、同一 device binary 上以 shell uid server 仅作
  handshake control（不得拿它执行 app attach）
- **AND** 若 shell control 立即 ACK、app uid server 仍超时，结论 SHALL 限定为该设备
  `runas_app` 身份/策略差异证据，MUST NOT 泛化为所有设备
- **AND** MUST NOT 把 shell handshake 成功当作可回退 attach 路线（K56 已证明 shell uid
  可能无权 ptrace app）
- **AND** 若 control 也失败，层 SHALL 保持未判定并继续检查 binary/packet/forward，MUST NOT
  仅凭通用 handshake timeout 猜目标 OS 层
