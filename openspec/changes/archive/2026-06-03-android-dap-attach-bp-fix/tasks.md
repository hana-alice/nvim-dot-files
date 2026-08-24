## 1. 修 attach 启动（根因 #1 + #2）

- [x] 1.1 `lua/ue/dap/android.lua` `start_lldb_server_gdbserver`：把 `cd files && ./lldb-server gdbserver ...` 改为 `files/lldb-server gdbserver ...`（用 `remote_server` 相对路径），消除 runas_app 域 `cd` 失效。
- [x] 1.2 `lua/utils/platform/windows.lua` `default_lldb_server_paths()`：移除 2026-06-02 Android Studio LLDB19 置顶 probe override，恢复 NDK 21.* 为首选（commit 144c28d 契约）。
- [x] 1.3 headless smoke：`nvim --headless -u NONE -c "luafile lua/ue/dap/android.lua" -c qa` 与 `luafile lua/utils/platform/windows.lua` 通过。

## 2. ASLR rebase（根因 #3a）

- [x] 2.1 `lua/ue/dap/android.lua`：新增 `read_so_base_hex`，attach 前读设备 `/proc/<pid>/maps` 取 libUE4.so 首映射 base（run-as `cat`，已验证可读）。
- [x] 2.2 `module_rebase_command` 拼接 hex base（禁 `string.format("%x")`），经 `session._module_rebase_cmd` 注入 attachCommands，在信号处置之后、断点之前下发 `target modules load --file libUE4.so --slide 0x<base>`。
- [x] 2.3 读取/解析失败时 `log.notify(... WARN)` 告警并跳过 rebase，不阻断 attach。

## 3. 接通断点（根因 #3b）

- [x] 3.1 `lua/ue/dap/android.lua` `_finalize_session`：解除 `preseed_breakpoints_into_attach_commands(cfg)` 注释；preseed 插入点改为在 ASLR rebase（`target modules load`）之后。
- [x] 3.2 `lua/ue/dap.lua` `ue_android_synthetic_breakpoint_response`：保留 basename 路径重写与合成响应（规避 lldb-dap 22 setBreakpoints 崩溃），但 `verified` 改为 `true`（反映断点已 preseed），去掉旧的硬编码 false + 误导 message。
- [x] 3.3 回退方案已写入 design（若真机重现 lldb-dap 22 崩溃，保持 preseed-only + verified=true，按 protocol log 决定）。

## 4. 环境要求记录

- [x] 4.1 `docs/TOOLING.md`：device server 段改为 NDK 21.4.7075529 LLDB 9.0.9 首选 + host glob + 为何不用 NDK27/AS bundled（真机 Segfault 证据）+ spawn 路径禁 `cd && ./` + 新增"Environment requirements (Android DAP)"表。
- [x] 4.2 `docs/CONSTRAINTS.md`：C1 表 device server 行更新为 NDK21，指向 TOOLING.md。

## 5. 验证（仅 ANDROID-SERIAL-A）

- [x] 5.1 headless 加载 smoke 全过（android.lua / dap.lua / windows.lua / require ue.dap + ue.dap.android）。
- [x] 5.2 真机分步验证：NDK21 `files/lldb-server gdbserver --attach 22232` tracer 稳定存活 6s、无 Segfault dump、`lldb-server` 进程数=1；新 spawn 路径形式可执行（旧 `cd && ./` 形式已确认失败）。
- [x] 5.3 ASLR 单元校验：maps 行解析得 base `0x6c9fe21000`，slide 命令未被 LuaJIT 32 位截断（`UNIT_OK`）。device libUE4.so base 与诊断一致。
- [x] 5.4 收尾清理设备：`killall lldb-server`、移除 adb forward、目标 `TracerPid=0`；沙箱 `files/lldb-server` 现为 NDK21（与代码默认一致，保留供复用）。
- [x] 5.5 `git status` 仅显示 `lua/ue/dap/*.lua`、`lua/utils/platform/windows.lua`、`docs/`、`openspec/`（外加前序 CONSTRAINTS change 的 doc）；无 nvim 配置外改动。
- [x] 5.6 `openspec validate android-dap-attach-bp-fix` 通过。

> 备注：完整 `<space>da` UI 端到端（DAP `initialized`/`threads` + F9 命中后源码定位）需在运行中的 Neovide 里跑一次最终确认；headless + bare-server 探针已覆盖设备/server/ASLR/断点拼装各层，但 UI 路径的 lldb-dap 协议交互建议用户在 Neovide 重载配置后实测一次。
