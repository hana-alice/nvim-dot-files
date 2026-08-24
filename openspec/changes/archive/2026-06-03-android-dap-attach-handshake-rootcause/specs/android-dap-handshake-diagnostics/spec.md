## ADDED Requirements

### Requirement: 诊断报告与可复现 probe

仓库 SHALL 产出 `docs/plans/2026-06-03-android-dap-handshake-rootcause.md` 与一个可重复
运行的诊断脚本，把 gdb 握手零响应与 source-file 断点 `3221226505` 两个 root cause 查实。

#### Scenario: 纯诊断、不改运行时

- **WHEN** 本 change 被应用
- **THEN** 仅新增 `docs/plans/...` 与 `tools/` 下的 probe 脚本
- **AND** 不修改任何 `lua/ue/dap/*.lua` 运行时文件

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

- **WHEN** 对比本轮"握手零响应"与上一轮"tracer 稳定"
- **THEN** 诊断说明 tracer 附上不等于 attach 成功，并指出上一轮是否漏测握手层

### Requirement: 定位 source-file 断点崩溃层面

诊断 SHALL 在握手通后用受控单条命令复现并定位 `3221226505` 的崩溃层面。

#### Scenario: 单条命令区分崩溃点

- **WHEN** 握手与 attach 已稳定
- **THEN** 分别单条执行 `image lookup --file <f> --line <N>`、
  `breakpoint set --address 0x<addr>`、`breakpoint set -f <f> -l <N>`
- **AND** 记录哪一条导致 adapter 退出 `3221226505`，定位崩溃层（DWARF / source 映射 / 通用 breakpoint set）

### Requirement: 区分正解与 workaround 的判据

诊断 SHALL 给出明确判据，用于判断后续修复机制是语义正解还是 workaround。

#### Scenario: 正解判定

- **WHEN** 评估某修复机制（如 address 断点 / 换 server / 换命令序）
- **THEN** 仅当它走与崩溃路径不同的 lldb 原生代码路径、且语义等价（同一 PC/同一断点行为）、并能解释为何不触发 root cause 时，才标记为"正解"
- **AND** 若只是"碰巧不崩"而无法解释，标记为 workaround 并不采纳

### Requirement: 设备验证范围限定

诊断 SHALL 仅在 adb serial `ANDROID-SERIAL-A` 上验证，并在报告中标注其它设备需各自取证。

#### Scenario: 单机取证

- **WHEN** 执行任何设备侧 probe
- **THEN** 命令均指定 `-s ANDROID-SERIAL-A`
- **AND** 收尾清理：`killall lldb-server`、移除 adb forward、目标 `TracerPid=0`
