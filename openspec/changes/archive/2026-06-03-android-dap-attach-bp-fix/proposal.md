## Why

诊断（`docs/plans/2026-06-02-android-dap-attach-bp-diagnosis.md`，真机 `ANDROID-SERIAL-A` 验证）定位到 `<space>da` 连不上 + F9 断不上的具体根因，且全部可在 **nvim 配置内**修复：

1. 设备端 server spawn 用 `cd files && ./lldb-server ...`，但 Android 16 `runas_app` SELinux 域下 `cd` 不生效、cwd 卡在 `/`，`./lldb-server` 找不到 → attach 第一步就失败（确定性 bug）。
2. `gdbserver --attach` 用 LLDB 18/19 server 在该 UE 目标上 Segfault；改用 **NDK21 LLDB 9.0.9**（与 libUE4.so 构建 NDK 匹配）后，tracer 稳定存活、不崩（真机已验证）。
3. F9 在 Android 被设计性短路：`setBreakpoints` 被合成成 `verified=false`，且 attachCommands preseed 调用被注释；同时缺 `target modules load --slide` 模块 rebase，断点会解析到错地址。

## What Changes

- **修 spawn 路径（根因 #1）**：`lua/ue/dap/android.lua` `start_lldb_server_gdbserver` 把 `cd files && ./lldb-server ...` 改为相对包数据根的 `files/lldb-server ...`（run-as cwd 已是 `/data/user/0/<pkg>`），消除 SELinux cd 失效。
- **钉死设备 server 为 NDK21（根因 #2）**：`lua/utils/platform/windows.lua` `default_lldb_server_paths()` 把 NDK 21 候选恢复为**首选**，移除 2026-06-02 临时把 Android Studio LLDB19 置顶的 probe override。
- **接通断点（根因 #3）**：
  - `lua/ue/dap/android.lua`：attach 成功后注入 ASLR rebase（`target modules load --file libUE4.so --slide 0x<base>`，base 取自设备 `/proc/<pid>/maps`，hex 用拼接，禁 `string.format("%x")`）。
  - 启用 attachCommands 内的 file:line 断点 preseed（解除 `_finalize_session` 中被注释的 `preseed_breakpoints_into_attach_commands`），并相应放开 `lua/ue/dap.lua` 对 Android `setBreakpoints` 的合成短路，使 `verified` 反映真实 resolved 状态。
- **环境要求记录**：在 `docs/TOOLING.md` 增补 Android 设备 server 必须 NDK21 LLDB 9.0.9 的硬性要求与原因（不改任何 nvim 之外的二进制/系统）。
- **不改 nvim 之外的东西**：不改设备系统、不改 UE 工程、不改 host adapter 版本（维持 22.1.6+）。设备端二进制由现有 push/run-as 暂存逻辑处理，不新增手工部署步骤。

## Capabilities

### New Capabilities
<!-- 无新 capability。-->

### Modified Capabilities
<!-- 无 spec 级既有 capability 需要修改（DAP 行为此前无 spec 化）。本 change 为实现层修复 + 环境文档。-->

## Impact

- **修改的 nvim 配置文件**：
  - `lua/ue/dap/android.lua`：spawn 路径修正 + ASLR rebase 注入 + 启用断点 preseed。
  - `lua/ue/dap.lua`：放开 Android `setBreakpoints` 合成短路，返回真实 verified。
  - `lua/utils/platform/windows.lua`：device lldb-server 候选恢复 NDK21 首选。
- **文档**：`docs/TOOLING.md` 增补 Android device server = NDK21 LLDB 9.0.9 的环境要求；`docs/CONSTRAINTS.md` 若涉及可同步一行。
- **不改**：host adapter 版本策略（22.1.6+ forward-only）、`stopOnEntry=true`、SIGSEGV/SIGBUS 信号处置、postRunCommands 不加 `process continue`。
- **设备验证范围**：仅 `ANDROID-SERIAL-A`（abi arm64-v8a, sdk 36 / Android 16, SELinux Enforcing）。
- **环境要求（记录用）**：
  - host adapter：LLVM 22.1.6 `lldb-dap.exe`（forward-only）。
  - device lldb-server：**NDK 21.4.7075529 LLDB 9.0.9**（`%LOCALAPPDATA%/Android/Sdk/ndk/21.4.7075529/.../aarch64/lldb-server`）。
  - app 必须 DEBUGGABLE，run-as 可用。
  - host 符号 so：`.../Client_Symbols_v*/SampleGame-arm64/libUE4.so`。
