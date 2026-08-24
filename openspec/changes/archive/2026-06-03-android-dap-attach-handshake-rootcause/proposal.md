## Why

`<space>da` 连真机后两层问题，上一轮"修复"未解决且踩回已知崩溃坑。本轮 live probe
（ANDROID-SERIAL-A，未改代码）暴露出一个**比断点更前置**的事实：attach 本身没稳。

证据（受控 DAP probe + 裸 gdb 握手）：
- `lldb-server gdbserver --attach <pid>` 起来了、`TracerPid` 附上了、进程存活 11s 不崩；
- 但 host 发 `$qSupported#37` gdb 握手包**零响应**；
- lldb-dap attach 报 `Connection shut down by remote side while waiting for reply to
  initial handshake packet` → attach 超时；
- 换小进程（pushservice pid）、换 `127.0.0.1:port` 绑定、等 10s 再握手——**全零响应**。

因此"tracer 附上 = attach 成功"是误判；source-file 断点 `3221226505` 崩溃是更下游现象。
在动任何修复（包括 address 断点）之前，必须先把**两个 root cause 查实**：
1. gdb-remote 初始握手为何零响应 / connection shut down；
2. source-file `breakpoint set` 的 `3221226505` 到底崩在哪一层。

这正回应"be sure 这不是 workaround"：只有定位了 root cause，才能判断后续机制（address
断点 / 别的 server / 别的 attach 命令序）是语义正解还是绕坑。

## What Changes

- 新增诊断 capability `android-dap-handshake-diagnostics`：用**受控、可复现**的分层 probe
  把两个 root cause 查到底，每层给命令 + 期望 + 判定。
- 产出诊断报告 `docs/plans/2026-06-03-android-dap-handshake-rootcause.md`：记录 live 证据、
  分层假设（gdbserver 绑定/握手、lldb-server 版本与 UE 目标兼容性、adb forward 链路、
  目标 ptrace 状态、source-file 断点崩溃层面）、复现脚本、结论与"正解 vs workaround"判据。
- **本阶段不改运行时代码**：只产出诊断 + probe 脚本（放 `tools/` 下，纯诊断用途）。
  修复另开 change，按 root cause 决定。

## Capabilities

### New Capabilities
- `android-dap-handshake-diagnostics`: 关于 UE Android DAP "gdb 握手零响应" 与
  "source-file 断点 3221226505" 两个 root cause 的诊断契约——分层复现、判定标准、
  以及区分"语义正解"与"workaround"的判据。

### Modified Capabilities
<!-- 无。 -->

## Impact

- **新增文件**：`docs/plans/2026-06-03-android-dap-handshake-rootcause.md`（诊断报告）；
  可选 `tools/dap_probe_android.py`（受控 DAP probe，纯诊断、可重复运行）。
- **不改**：`lua/ue/dap/*.lua` 运行时；host adapter / device server 版本策略；设备系统；UE 工程。
- **设备范围**：仅 `ANDROID-SERIAL-A`（arm64-v8a / Android 16；目标 `<android-package>`）。
- **关键 live 证据（本轮）**：gdbserver 存活但 gdb 握手零响应；`Connection shut down by
  remote side while waiting for reply to initial handshake`；小进程同样零响应；libUE4.so
  base 每次冷启变（本轮 `0x6ca9e1d000`）。
- **判定标准**：root cause 必须可复现、可解释、并能据此判断后续修复是否为语义正解。
