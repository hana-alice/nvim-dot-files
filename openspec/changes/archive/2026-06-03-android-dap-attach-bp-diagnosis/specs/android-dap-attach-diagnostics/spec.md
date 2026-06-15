## ADDED Requirements

### Requirement: 诊断文档存在且可发现

仓库 SHALL 在 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 提供一份
Android DAP attach 失败与 F9 断点失效的诊断文档，记录当前代码事实、已知证据、
分层假设与排查顺序。

#### Scenario: 文档产出且为纯文档变更

- **WHEN** 本 change 被应用
- **THEN** `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md` 存在
- **AND** 没有任何 `lua/ue/dap/*.lua` 运行时文件被修改（`git status` 仅显示 `docs/`、`openspec/`）

### Requirement: 分层定位 attach 失败

诊断文档 SHALL 把 attach 失败拆成自顶向下的若干层，每层 MUST 给出可执行的验证手段
与判定标准，覆盖 host adapter、adb/forward、设备端 lldb-server、ptrace/进程架构边界。

#### Scenario: 每层都有验证命令与期望输出

- **WHEN** 读者按文档逐层排查
- **THEN** host adapter 层要求确认 `lldb-dap.exe` 为 LLVM 22.1.6+（不得回退 21）并成功 spawn
- **AND** adb 层要求确认 `adb forward tcp:<port>` 已建立且设备唯一就绪
- **AND** 设备端 server 层要求确认沙箱 `files/lldb-server version` 可执行、`run-as` 正确启动 gdbserver
- **AND** ptrace 层要求针对 `Cannot get process architecture` / `lost connection` 核对目标进程 arch（arm64）、server arch、`/proc/<pid>` 可读性、目标是否处于 state T 与 `TracerPid`

#### Scenario: 区分设备端根因与编辑器侧异常

- **WHEN** 读者看到 dapui `threads.lua` 类报错
- **THEN** 文档说明该报错是 attach 失败的下游次生异常，不是 attach 失败本身
- **AND** 指明真正失败边界在设备/server/ptrace 层，需 live 命令复现

### Requirement: 暴露 F9 断点当前被设计性短路

诊断文档 SHALL 明确指出现有代码中导致 Android F9 断点必然不生效的两处事实，避免被
误判为环境问题。

#### Scenario: 标注合成 setBreakpoints 与注释掉的 preseed

- **WHEN** 读者排查"F9 断不上"
- **THEN** 文档指出 `lua/ue/dap.lua` 将 Android 会话的 `setBreakpoints` 拦截为 `verified=false` 的合成响应（`ue_android_synthetic_breakpoint_response`）
- **AND** 指出 `lua/ue/dap/android.lua` 的 `preseed_breakpoints_into_attach_commands(cfg)` 调用被注释，未把断点作为 attachCommands 下发
- **AND** 说明这是"先保 attach 稳定"的取舍，接通断点需要在 attach 稳定后另行选择 preseed 或安全的 post-attach 路径

#### Scenario: 断点接通的判定标准

- **WHEN** 后续验证断点是否真正接通
- **THEN** 文档要求同时满足 DAP 侧 `verified=true` 与 lldb 侧 `breakpoint list` 中 `resolved` 计数大于 0
- **AND** 仅 UI 上出现断点标记不算接通

### Requirement: 记录 ASLR slide 缺失风险

诊断文档 SHALL 记录当前 `android.lua` 缺少 `target modules load --slide` 模块 rebase，
并将其列为断点解析到错地址的潜在原因（对应 `docs/CONSTRAINTS.md` K2/K11）。

#### Scenario: 给出 ASLR 验证手段

- **WHEN** attach 成功后验证模块基址
- **THEN** 文档要求比对 `image list libUE4.so` 的 base 与设备 `/proc/<pid>/maps` 首映射地址
- **AND** 若不一致，列出补 `--slide` rebase 为修复前置条件

### Requirement: 不改运行时行为

本 change SHALL 仅产出诊断文档，不改变 DAP 运行时行为。

#### Scenario: 保持既有边界不变

- **WHEN** 本 change 被应用
- **THEN** 不修改 host adapter 版本策略（22.1.6+ forward-only）
- **AND** 不修改 `stopOnEntry=true`、不在 attachCommands/postRunCommands 加 `process continue`、不动 SIGSEGV/SIGBUS 信号处置
