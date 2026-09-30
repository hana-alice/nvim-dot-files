# android-dap-handshake-diagnostics Specification

## Purpose

诊断契约：UE Android DAP "gdb 握手零响应" 与 "source-file 断点 3221226505" 两个
root cause 的分层定位、判定标准，以及区分"语义正解"与"workaround"的判据。边界：
纯诊断，不改运行时；产出物是结论本身（保留在本 spec 与 `docs/CONSTRAINTS.md`），
不要求某个已从工作树移除的报告文件继续存在。

## Requirements

### Requirement: 诊断结论必须以可发现的形式存在，且只引用真实存在的文件

诊断结论 SHALL 以可发现的形式存在于仓库；原始诊断报告已随公开镜像的历史脱敏被
移除，因此结论与判据 SHALL 保留在 `docs/CONSTRAINTS.md` 的踩坑条目与本 spec 中，
MUST NOT 继续要求一个已不存在于工作树的报告文件。任何声称已产出的诊断文件 MUST
真实存在于仓库，否则该引用 MUST 被移除或改指现存出处。每次新的握手层诊断仅新增
诊断记录与 `tools/` 下的 probe 脚本，不修改任何 `lua/ue/dap/*.lua` 运行时文件。

#### Scenario: 结论出处真实存在

- **WHEN** AI agent 或贡献者查阅 Android DAP 握手 root cause 结论
- **THEN** 结论可从本 spec 的 requirement 与 `docs/CONSTRAINTS.md` 的踩坑条目
  读到
- **AND** 本 spec 不引用任何已从工作树移除的报告文件路径

### Requirement: 必须分层定位 gdb 握手零响应的真因

诊断 SHALL 分层复现并定位"gdbserver 存活但 gdb 初始握手零响应 / Connection shut
down"的真因，覆盖端口监听、adb forward 链路、gdb 协议、server↔目标兼容、目标
ptrace 状态。

#### Scenario: app uid listener 与 shell control 的同 binary A/B 判据

- **WHEN** app-uid `lldb-server platform` 进程存活且端口 LISTEN，但正确 checksum
  的 forwarded GDB packet 超时
- **THEN** 诊断 SHALL 在同一捕获 serial、同一 device binary 上以 shell uid
  server 仅作 handshake control（不得拿它执行 app attach）
- **AND** 若 shell control 立即 ACK、app uid server 仍超时，结论 SHALL 限定为
  该设备 `runas_app` 身份/策略差异证据，MUST NOT 泛化为所有设备
- **AND** MUST NOT 把 shell handshake 成功当作可回退 attach 路线（K56 已证明
  shell uid 可能无权 ptrace app）

### Requirement: 必须分层定位 source-file 断点崩溃层面

诊断 SHALL 在握手通后用受控单条命令复现并定位 `3221226505` 的崩溃层面：分别
单条执行 `image lookup --file <f> --line <N>`、`breakpoint set --address
0x<addr>`、`breakpoint set -f <f> -l <N>`，记录哪一条导致 adapter 退出
`3221226505`，定位崩溃层（DWARF / source 映射 / 通用 breakpoint set）。

#### Scenario: 单条命令区分崩溃点

- **WHEN** 握手与 attach 已稳定
- **THEN** 分别单条执行 `image lookup --file <f> --line <N>`、
  `breakpoint set --address 0x<addr>`、`breakpoint set -f <f> -l <N>`
- **AND** 记录哪一条导致 adapter 退出 `3221226505`，定位崩溃层

### Requirement: 区分正解与 workaround 必须有明确判据

诊断 SHALL 给出明确判据：仅当某修复机制走与崩溃路径不同的 lldb 原生代码路径、
且语义等价（同一 PC/同一断点行为）、并能解释为何不触发 root cause 时，才标记为
"正解"；若只是"碰巧不崩"而无法解释，标记为 workaround 并不采纳。

#### Scenario: 正解判定

- **WHEN** 评估某修复机制（如 address 断点 / 换 server / 换命令序）
- **THEN** 仅当它走与崩溃路径不同的 lldb 原生代码路径、且语义等价、并能解释
  为何不触发 root cause 时，才标记为"正解"
- **AND** 若只是"碰巧不崩"而无法解释，标记为 workaround 并不采纳

### Requirement: 每次诊断必须显式限定验证范围到单一捕获 serial

每次诊断 SHALL 显式接收并捕获一个 probe serial，并在报告中记录该 serial 的取证
范围；所有设备命令、forward 与收尾清理 MUST 使用同一个捕获值。规范与脚本 MUST
NOT 固定某台历史设备，也不得在 probe 运行中重读 live selection 后改投其他设备。

#### Scenario: 单机取证收尾清理

- **WHEN** 以某个 probe serial 执行任何设备侧 probe
- **THEN** 所有设备命令 SHALL 指定该 serial，报告 SHALL 标明结论仅覆盖该设备
- **AND** 收尾清理 SHALL 对同一 serial 执行 lldb-server 清理、移除本次 adb
  forward，并确认目标 `TracerPid=0`

## 选型与踩坑

- **踩坑**：曾把"tracer 附上"误判为"attach 成功"，漏测了握手层——tracer 稳定
  不等于 gdb 协议握手真正完成。处置：诊断必须显式区分 tracer 附上与握手完成
  两个独立判据。
- **重要事项**：判定"server 不说话"与"握手包格式错"需要用正确 checksum + ack
  的 `$qSupported#<ck>` 区分，不能只看超时与否就归因。
