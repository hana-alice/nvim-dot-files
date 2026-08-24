## 1. 受控 probe 脚本

- [ ] 1.1 在 `tools/dap_probe_android.py` 写参数化受控 probe：复刻 `lldb_dap_attach_config` 的命令序（target create → gdb-remote → 信号处置 → ASLR slide），用 `lldb-dap --connection listen://`，支持 MODE=none/handshake/imagelookup/sourcebp/addrbp。
- [ ] 1.2 脚本内置裸 socket gdb 握手探测（正确 checksum + `+` ack），区分"零响应"与"格式错"。

## 2. root cause #1：握手零响应

- [ ] 2.1 端口监听层：设备本地查 gdbserver 是否在端口 listen（`/proc/net/tcp` 或等价），对比 `*:port` vs `127.0.0.1:port`。
- [ ] 2.2 adb forward 链路层：确认 forward 建立、host 能 connect；记录"connect 成功但零响应"以排除链路。
- [ ] 2.3 gdb 协议层：裸发 `$qSupported#<ck>`，记录是否有任何字节/ack。
- [ ] 2.4 server 兼容层：换一个对照 server 二进制（仅定位用，不改默认），看握手是否变通；若变通则 root cause = server 选择。
- [ ] 2.5 目标 ptrace 层：握手期间记录目标 `State`/`TracerPid` 是否异常。
- [ ] 2.6 归纳 root cause #1，并解释上一轮"tracer 稳定"为何与"握手零响应"并存（是否漏测握手）。

## 3. root cause #2：3221226505 崩溃层

- [ ] 3.1 仅在握手通后：单条 evaluate `image lookup --file <f> --line <N>`，记录是否崩。
- [ ] 3.2 单条 `breakpoint set --address 0x<addr>`（地址来自 3.1），记录是否崩。
- [ ] 3.3 单条 `breakpoint set -f <f> -l <N>`，复现 `3221226505`，定位崩溃层。
- [ ] 3.4 归纳 root cause #2 + 给出 address 断点是否"语义正解"的判据结论。

## 4. 诊断报告

- [ ] 4.1 写 `docs/plans/2026-06-03-android-dap-handshake-rootcause.md`：本轮 live 证据、分层结论、复现命令、正解 vs workaround 判据、修复方向建议。

## 5. 核验（仅 ANDROID-SERIAL-A）

- [ ] 5.1 所有设备命令 `-s ANDROID-SERIAL-A`；收尾 `killall lldb-server` + 移除 forward + 目标 `TracerPid=0`。
- [ ] 5.2 `git status` 仅 `docs/`、`tools/`、`openspec/`；无 `lua/` 改动。
- [ ] 5.3 `openspec validate android-dap-attach-handshake-rootcause` 通过。
