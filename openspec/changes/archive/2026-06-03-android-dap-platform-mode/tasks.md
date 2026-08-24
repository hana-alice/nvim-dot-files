## 1. 真机验证 platform 连接途径（apply 第一步，决定方案）

- [ ] 1.1 clean env：`am force-stop` + 重启 app 取新 pid；动态取 device serial；用 `tools/dap_platform_probe.py`（随机端口+必清理）。
- [ ] 1.2 启动 device `lldb-server platform --server --listen 127.0.0.1:<pport>` + `adb forward`。
- [ ] 1.3 验证方案 A：lldb-dap attach 配置 `platformName="remote-android"` + `gdb-remote-port=<pport>` + `gdb-remote-hostname="127.0.0.1"`，取 fresh protocol log，确认无 `Invalid URL`、能到 `initialized`。
- [ ] 1.4 若 A 不通（platform 需先 qLaunchGDBServer 拉子 gdbserver）：验证方案 B —— `platformName=remote-android` 让 lldb-dap 经 platform 自动 spawn gdbserver 子端口并连接；必要时读 `lldb/tools/lldb-dap` attach 实现确认 platform 自动连流程。
- [ ] 1.5 确定 device server 版本（LLDB21 r29 / 其它）与 host 22 platform 协议兼容；记录握手结果。
- [ ] 1.6 连接通后验证 `process attach --pid <pid>` → `threads` 成功。

## 2. 改 attach 实现（按 1 的结论）

- [ ] 2.1 `lua/ue/dap/android.lua`：server 启动改 `platform --server --listen`（替换 gdbserver --attach）。
- [ ] 2.2 `lua/ue/dap/android.lua`：attach 配置改用结构化键（`platformName` + 结构化连接），移除 `platform connect connect://...` 命令字符串。
- [ ] 2.3 `lua/ue/dap/android.lua`：保留 ASLR rebase（运行时读 maps，hex 拼接），在连接+attach 后下发。
- [ ] 2.4 `lua/utils/platform/windows.lua`：device server 候选/优先级按验证结论调整。

## 3. 断点 + 入口噪音

- [ ] 3.1 真机验证 platform 路径下 source-file `breakpoint set` 是否仍崩 `3221226505`；崩则用 address 断点（`image lookup --line` → `breakpoint set --address`）。
- [ ] 3.2 `lua/ue/dap.lua`：`verified` 反映真实 resolve 结果。
- [ ] 3.3 `lua/ue/dap.lua`：入口合成帧不触发 jump，消除 `Source missing`。

## 4. 文档

- [ ] 4.1 `docs/TOOLING.md`：platform 模式正式路径 + device server 版本要求 + 结构化连接键（非 platform connect 字符串）+ getopt URL bug 说明。
- [ ] 4.2 `docs/CONSTRAINTS.md`：增补 gdbserver --attach 不绑端口、platform connect getopt 吞 URL 两条坑。
- [ ] 4.3 `docs/plans/2026-06-03-android-dap-platform-mode.md`：固化 E1–E5 证据链 + 最终方案。

## 5. 验证（仅 ANDROID-SERIAL-A）

- [ ] 5.1 headless smoke：android.lua / dap.lua / windows.lua / require。
- [ ] 5.2 真机 `<space>da`：platform attach 到 `initialized`+`threads`，无 Invalid URL / 握手超时 / 3221226505。
- [ ] 5.3 真机 F9：DAP `verified=true` 且 lldb `breakpoint list` resolved>0；命中停正确源码行。
- [ ] 5.4 连上无 `Source missing`。
- [ ] 5.5 收尾清理：app force-stop（或保留）、device lldb-server killed、forward 清空、host lldb-dap 僵尸清掉、目标 TracerPid=0。
- [ ] 5.6 `git status` 仅 `lua/ue/dap/*.lua`、`lua/utils/platform/windows.lua`、`docs/`、`tools/`、`openspec/`；`openspec validate android-dap-platform-mode` 通过。
