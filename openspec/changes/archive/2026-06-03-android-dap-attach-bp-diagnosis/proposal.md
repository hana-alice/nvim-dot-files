## Why

当前 `<space>da`（`:UEDAPAttach android`）连真机后存在两个叠加问题：(1) attach 在设备/服务端边界失败（`process attach --pid` 报 `Cannot get process architecture` / `lost connection`，bare `lldb-server gdbserver --attach` 在设置 `TracerPid` 之前就返回/崩溃）；(2) 即使 attach 成功，F9 断点也断不上——当前代码把 Android 会话的 `setBreakpoints` 拦截成 `verified=false` 的合成响应，且 attachCommands 预置断点被注释掉了。需要先**系统化定位潜在问题**，产出可执行的诊断清单和证据，再谈修复。

本 change 是**诊断/调研先行**：不盲目改 attach 协议、不动 `stopOnEntry`/`process continue`/SIGSEGV 策略，而是先把"哪里可能出问题"落成可验证的排查项。

## What Changes

- 新增一个**诊断 capability** `android-dap-attach-diagnostics`：把 attach 失败与 F9 断不上的潜在原因拆成分层假设（host adapter / adb 转发 / 设备端 lldb-server / ptrace 边界 / 模块与 ASLR slide / 断点注入路径），每条配可执行的验证命令与期望输出。
- 新增一份诊断文档 `docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md`：记录当前代码事实、已知证据（来自 `docs/changelog.md`）、分层假设、排查顺序，以及"先 attach 稳定、再接通断点"的修复路线建议。
- **本阶段不改运行时代码**：不动 `lua/ue/dap/*.lua` 的 attach 协议、断点拦截、信号处置；只产出诊断产出物。后续修复另开 change 或在 apply 阶段按诊断结论最小改动。

## Capabilities

### New Capabilities
- `android-dap-attach-diagnostics`: 一套关于 UE Android DAP attach 失败与断点失效的诊断契约——分层定位潜在问题、给出每层的验证手段与判定标准、并指明现有代码里已知的"断点被合成短路"事实，避免把已解决问题重新引入或误判 attach 成功。

### Modified Capabilities
<!-- 无。修复运行时行为留待诊断结论确定后单独提出。 -->

## Impact

- **新增文件**：`docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md`（诊断报告）。
- **不改代码**：`lua/ue/dap.lua`、`lua/ue/dap/android.lua`、`lua/ue/dap/_common.lua`、`lua/ue/dap/_persist_bp.lua` 均不在本阶段修改。
- **涉及（只读分析）的现有事实**：
  - attach 走 `gdb-remote 127.0.0.1:<port>`（gdbserver 模式），见 `android.lua` `attach_commands` / `_finalize_session`。
  - `setBreakpoints` 被 `session_mod.request` 包装拦截，返回 `ue_android_synthetic_breakpoint_response`（`verified=false`），见 `lua/ue/dap.lua` ~1958。
  - `preseed_breakpoints_into_attach_commands(cfg)` 在 `_finalize_session` 中被注释（`android.lua` ~1225）。
  - 当前 `android.lua` **没有** ASLR `target modules load --slide` rebase，与 MEMORY/历史教训（断点须先 rebase 模块基址）不一致。
  - host adapter 锁定 LLVM 22.1.6+ forward-only；device `lldb-server` 为独立 live-probe 变量（见 `docs/changelog.md` 2026-06-02 多条）。
- **受众**：后续修复的实现者（人或 agent），用于在动协议前先验证假设。
- **设备范围**：验证限定当前连接的 adb serial（如 `ANDROID-SERIAL-A`）。
