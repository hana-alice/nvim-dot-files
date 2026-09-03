# android-dap-attach-diagnostics

## Purpose

诊断契约：UE Android DAP attach 失败与 F9 断点失效的分层定位、判定标准与出处。

## Requirements

### Requirement: 诊断文档存在且可发现

仓库 SHALL 在 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 提供一份
Android DAP attach 失败与 F9 断点失效的诊断文档，记录当前代码事实、已知证据、
分层假设与排查顺序。

#### Scenario: 文档产出且为纯文档变更

- **WHEN** 本 change 被应用
- **THEN** `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 存在
- **AND** 没有任何 `lua/ue/dap/*.lua` 运行时文件被修改（`git status` 仅显示 `docs/`、`openspec/`）

### Requirement: 分层定位 attach 失败

诊断文档 SHALL 把 attach 失败拆成自顶向下的若干层，每层 MUST 给出可执行的验证手段与判定标准，覆盖 host adapter、ADB/forward、设备端 `lldb-server platform`、serial-form platform connect 与 ptrace/进程架构边界。文档 MUST 将 sandbox `gdbserver --attach` 标为已证伪的历史路线，而不得继续把它写成当前前置条件。

#### Scenario: 每层都有验证命令与期望输出

- **WHEN** 读者按文档逐层排查当前 Android attach
- **THEN** host adapter 层 SHALL 确认 `lldb-dap.exe` 为 LLVM 22.1.6+（不得回退 21）并成功 spawn
- **AND** ADB 层 SHALL 确认本次捕获的 serial、`adb -s <serial>` 定向命令与 forward 状态一致
- **AND** 设备端 server 层 SHALL 确认 platform server 以 **app uid**（`run-as <package>`）
  从 `/data/data/<package>/lldb-server` 启动并监听 `--listen "*:<port>"`；shell uid +
  `/data/local/tmp` 启动形式与 `--listen 127.0.0.1:<port>` 形式均为已证伪的历史写法
  （`android-dap-attach` app-uid Requirement，`docs/CONSTRAINTS.md` K56）
- **AND** platform connect 层 SHALL 验证 `connect://[<session.serial>]:<port>`，不得使用 localhost route 或 `gdbserver --attach`
- **AND** ptrace 层 SHALL 针对 `Cannot get process architecture` / `lost connection` 核对目标进程 arch（arm64）、server arch、`/proc/<pid>` 可读性、目标是否处于 state T 与 `TracerPid`
- **AND** 遇到 `lost connection` 时 ptrace 层 SHALL **首先**核对 platform server 的运行 uid
  （K56：shell uid 在 `ro.debuggable=0` 的 user build 上无权 ptrace app，LLDB 把该拒绝暴露成
  子进程 SIGSEGV，host 只看到 `lost connection`），MUST NOT 把 device server 版本当作首要变量

#### Scenario: 区分当前路线与历史诊断证据

- **WHEN** 旧诊断文档记录 sandbox gdbserver、单设备假设或已经修复的 F9 short-circuit
- **THEN** 文档 SHALL 明确标记这些内容为 historical/superseded evidence
- **AND** 当前排查步骤 SHALL 指向 `android-dap-attach`、`android-dap-live-breakpoints` 与 `dap-platform-dispatch` 的现行契约

#### Scenario: 区分设备端根因与编辑器侧异常

- **WHEN** 读者看到 dapui `threads.lua` 类报错
- **THEN** 文档 SHALL 说明该报错可能是 attach 失败的下游次生异常，不得仅凭该 UI 报错判定根因
- **AND** SHALL 用当前 session owner 的 live 证据定位 adapter、route、device/server 或 ptrace 层

### Requirement: 暴露 F9 断点当前被设计性短路

诊断文档 SHALL 明确指出现有代码中导致 Android F9 断点必然不生效的两处事实，避免被
误判为环境问题。

#### Scenario: 标注合成 setBreakpoints 与注释掉的 preseed

- **WHEN** 读者排查"F9 断不上"
- **THEN** 文档指出 `lua/ue/dap.lua` 将 Android 会话的 `setBreakpoints` 拦截为合成响应（`ue_android_synthetic_breakpoint_response`）
- **AND** 指出 `lua/ue/dap/android.lua` 的 `preseed_breakpoints_into_attach_commands(cfg)` 调用曾被注释，未把断点作为 attachCommands 下发
- **AND** 说明这是"先保 attach 稳定"的取舍，接通断点需要在 attach 稳定后另行选择 preseed 或安全的 post-attach 路径

#### Scenario: 断点接通的判定标准

- **WHEN** 后续验证断点是否真正接通
- **THEN** 文档要求同时满足 DAP 侧 `verified=true` 与 lldb 侧 `breakpoint list` 中 `resolved` 计数大于 0
- **AND** 仅 UI 上出现断点标记不算接通

### Requirement: 记录 ASLR slide 缺失风险

诊断文档 SHALL 记录 `android.lua` 缺少 `target modules load --slide` 模块 rebase 的风险，
并将其列为断点解析到错地址的潜在原因（对应 `docs/CONSTRAINTS.md` K2/K11）。

#### Scenario: 给出 ASLR 验证手段

- **WHEN** attach 成功后验证模块基址
- **THEN** 文档要求比对 `image list libUE4.so` 的 base 与设备 `/proc/<pid>/maps` 首映射地址
- **AND** 若不一致，列出补 `--slide` rebase 为修复前置条件

### Requirement: 不改运行时行为

该诊断 change SHALL 仅产出诊断文档，不改变 DAP 运行时行为。

#### Scenario: 保持既有边界不变

- **WHEN** 该诊断 change 被应用
- **THEN** 不修改 host adapter 版本策略（22.1.6+ forward-only）
- **AND** 不修改 `stopOnEntry=true`、不在 attachCommands/postRunCommands 加 `process continue`、不动 SIGSEGV/SIGBUS 信号处置
