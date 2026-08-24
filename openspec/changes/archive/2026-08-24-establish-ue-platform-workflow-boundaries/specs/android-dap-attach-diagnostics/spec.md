## MODIFIED Requirements

### Requirement: 分层定位 attach 失败

诊断文档 SHALL 把 attach 失败拆成自顶向下的若干层，每层 MUST 给出可执行的验证手段与判定标准，覆盖 host adapter、ADB/forward、设备端 `lldb-server platform`、serial-form platform connect 与 ptrace/进程架构边界。文档 MUST 将 sandbox `gdbserver --attach` 标为已证伪的历史路线，而不得继续把它写成当前前置条件。

#### Scenario: 每层都有验证命令与期望输出

- **WHEN** 读者按文档逐层排查当前 Android attach
- **THEN** host adapter 层 SHALL 确认 `lldb-dap.exe` 为 LLVM 22.1.6+（不得回退 21）并成功 spawn
- **AND** ADB 层 SHALL 确认本次捕获的 serial、`adb -s <serial>` 定向命令与 forward 状态一致
- **AND** 设备端 server 层 SHALL 确认 `lldb-server platform --server --listen 127.0.0.1:<pport>` 正确启动并监听
- **AND** platform connect 层 SHALL 验证 `connect://[<session.serial>]:<port>`，不得使用 localhost route 或 `gdbserver --attach`
- **AND** ptrace 层 SHALL 针对 `Cannot get process architecture` / `lost connection` 核对目标进程 arch（arm64）、server arch、`/proc/<pid>` 可读性、目标是否处于 state T 与 `TracerPid`

#### Scenario: 区分当前路线与历史诊断证据

- **WHEN** 旧诊断文档记录 sandbox gdbserver、单设备假设或已经修复的 F9 short-circuit
- **THEN** 文档 SHALL 明确标记这些内容为 historical/superseded evidence
- **AND** 当前排查步骤 SHALL 指向 `android-dap-attach`、`android-dap-live-breakpoints` 与 `dap-platform-dispatch` 的现行契约

#### Scenario: 区分设备端根因与编辑器侧异常

- **WHEN** 读者看到 dapui `threads.lua` 类报错
- **THEN** 文档 SHALL 说明该报错可能是 attach 失败的下游次生异常，不得仅凭该 UI 报错判定根因
- **AND** SHALL 用当前 session owner 的 live 证据定位 adapter、route、device/server 或 ptrace 层
