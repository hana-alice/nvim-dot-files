## 1. 真机验证连接组合（apply 第一步，定方案）

- [ ] 1.1 clean env：`am force-stop` + 重启 app 取新 pid；动态取 device serial（限 a3ad86f3）。
- [ ] 1.2 扩展 `tools/dap_platform_structured.py` 支持组合：device 纯 listen `gdbserver 127.0.0.1:<port>` + host `gdb-remote-port=<port>` + attachCommands `process attach --pid <pid>`。
- [ ] 1.3 真机跑该组合，取 fresh protocol log，判定是否到 `initialized`+`threads`。
- [ ] 1.4 若失败：读 `D:/project/llvm-lldb-sparse` 的 `AttachRequestHandler` 在 gdb-remote-port + attachCommands 并存时的执行序，定位 connect→vAttach 失败点。
- [ ] 1.5 确定 device server 版本（LLDB21 r29 / 其它）与 host 22 兼容。

## 2. 改 attach 实现（方案定型后）

- [ ] 2.1 `lua/ue/dap/android.lua`：server 启动改纯 listen `gdbserver`（或最终方案）；移除 `--attach` 形态。
- [ ] 2.2 `lua/ue/dap/android.lua`：attach 配置用结构化键（`gdb-remote-port`/`gdb-remote-hostname`）+ attachCommands `process attach --pid`，不用 `platform connect` 字符串。
- [ ] 2.3 `lua/ue/dap/android.lua`：ASLR rebase（运行时读 maps，hex 拼接）保留。
- [ ] 2.4 `lua/utils/platform/windows.lua`：server 版本/优先级；serial 不写死。

## 3. 断点 + 入口噪音

- [ ] 3.1 真机测 source-file `breakpoint set`；崩则切 address 断点（`image lookup --line`→`breakpoint set --address`），按"正解"判据确认。
- [ ] 3.2 `lua/ue/dap.lua`：`verified` 反映真实 resolve。
- [ ] 3.3 `lua/ue/dap.lua`：入口合成帧不 jump，消除 `Source missing`。

## 4. 文档与 spec

- [ ] 4.1 `docs/plans/2026-06-03-android-dap-platform-mode.md`：固化 E1–E6 + 最终方案。
- [ ] 4.2 `docs/TOOLING.md` / `docs/CONSTRAINTS.md`：更新 device server 版本、连接方式、getopt URL bug、gdbserver --attach 不绑端口。
- [ ] 4.3 以真机结论 MODIFY 主 spec `android-dap-attach`（纯 listen vs platform server 定稿）。

## 5. 验证（仅 a3ad86f3）

- [ ] 5.1 headless smoke：android.lua / dap.lua / windows.lua / require。
- [ ] 5.2 真机 `<space>da` 端到端：initialized/threads，无 Invalid URL / 超时 / 3221226505。
- [ ] 5.3 真机 F9：verified=true 且 resolved>0；命中停正确源码行。
- [ ] 5.4 连上无 Source missing。
- [ ] 5.5 收尾清理：host lldb-dap + device lldb-server killed、forward 清空、目标 TracerPid=0。
- [ ] 5.6 `git status` 仅 `lua/ue/dap/*.lua`、`lua/utils/platform/windows.lua`、`docs/`、`tools/`、`openspec/`；`openspec validate android-dap-platform-walkthrough` 通过。
