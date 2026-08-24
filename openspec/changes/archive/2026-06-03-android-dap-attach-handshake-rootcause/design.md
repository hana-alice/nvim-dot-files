## Context

用户要求"be sure 这不是 workaround"。本轮 live probe（ANDROID-SERIAL-A，未改运行时代码）发现
attach 比之前以为的更不稳——这改变了优先级：先查 root cause，再谈修复。

本轮 live 证据（受控 DAP probe + 裸 socket 握手）：
- `files/lldb-server gdbserver --attach <pid> *:<port>`：进程存活、`TracerPid` 非 0、
  11s 不崩。
- host→`$qSupported#37`：**零字节响应**。
- lldb-dap attach：`Running attachCommands` 后立刻
  `error: Connection shut down by remote side while waiting for reply to initial
  handshake packet` → attach 超时。
- 换 pushservice 小进程、换 `127.0.0.1:<port>` 绑定、等 10s 再握手：**全零响应**。
- 设备 NDK21 LLDB 9.0.9 server `version` 正常；上一轮同一 server 曾观察到 tracer 稳定，
  但**当时未验证 gdb 握手层**——这是本轮新发现的缺口。

历史（changelog 2026-06-02）：source-file `breakpoint set -f <file> -l <line>` 在
lldb-dap 22.1.6 直连 gdb-remote 路径下崩溃 `3221226505`；这是第二个待查 root cause。

约束（`docs/CONSTRAINTS.md`）：host adapter 22.1.6+ forward-only、`stopOnEntry` 不动、
无 `process continue`、SIGSEGV/SIGBUS 不动、改协议需 fresh protocol proof、hex 拼接
禁 `string.format("%x")`、设备验证仅 ANDROID-SERIAL-A。

## Goals / Non-Goals

**Goals:**
- 查实 root cause #1：gdb-remote 初始握手为何零响应 / connection shut down。
- 查实 root cause #2：source-file `breakpoint set` 的 `3221226505` 崩在哪一层。
- 每个结论可复现、可解释，并据此给出"后续修复是否语义正解"的判据。
- 产出诊断报告 + 可重复 probe 脚本（纯诊断）。

**Non-Goals:**
- 不改运行时 `.lua`、不改 attach 协议、不改 server/adapter 版本。
- 不在 root cause 未定前写任何修复（含 address 断点）。

## Decisions

**D1 — 诊断先行，零运行时改动。** "be sure 不是 workaround" 的唯一办法是先有 root
cause。备选（直接上 address 断点）被否：在握手都没通的情况下，任何断点机制都无从验证，
且可能掩盖真因。

**D2 — root cause #1 分层 probe（握手零响应）。**
1. **gdbserver 绑定层**：`gdbserver --attach` 是否真的 listen 在端口？用设备本地
   `cat /proc/net/tcp` / `netstat` 查端口监听状态；对比 `*:port` vs `127.0.0.1:port`。
2. **adb forward 链路**：`adb forward` 是否真正转发；host `telnet`/socket 能否建连
   （能 connect 但零响应 vs 连不上，区分链路 vs 协议）。
3. **gdb 协议层**：裸发 `+$qSupported#<ck>` 看是否有 ack/响应；区分"server 没说话"
   与"我们的握手包格式不对"（用正确 checksum + `+` ack 序列）。
4. **lldb-server 版本/目标兼容**：NDK21 LLDB9 vs 该 UE 目标的 gdbremote 协议是否匹配；
   必要时换 server 二进制对照握手层（不是换默认，只为定位）。
5. **目标 ptrace 状态**：握手期间目标 `State`/`TracerPid` 是否进入异常态。

**D3 — root cause #2 分层 probe（3221226505）。**
仅在握手通后才可测；用受控 DAP evaluate 单条下发：
- `image lookup --file <f> --line <N>`（只读，看是否也崩）；
- `breakpoint set --address 0x<addr>`（地址断点，看是否崩）；
- `breakpoint set -f <f> -l <N>`（source 断点，复现崩溃点）；
逐条记录"哪条让 adapter 退出 3221226505"，定位崩溃层（DWARF 解析 / source 映射 /
通用 breakpoint set）。

**D4 — 区分正解 vs workaround 的判据写进 spec。**
- 若 root cause 是"source-file 解析路径在该 adapter 有 bug"，而 address 断点走**不同的
  lldb 原生代码路径**且语义等价（同一 PC 地址）→ address 断点是**正解**。
- 若只是"碰巧不崩"但无法解释为何→ 标记为 workaround，不采纳。

**D5 — probe 脚本入库 `tools/`，可重复。** 纯诊断、不被运行时引用，便于他人复现。

## Risks / Trace-offs

- [握手零响应可能是 server↔目标根本不兼容] → D2.4 换 server 对照；若换 server 握手通，
  则 root cause = server 选择（这本身是 attach 修复的真因，而非断点问题）。
- [3221226505 在握手不通时测不了] → 先解 root cause #1；#2 排在其后。
- [probe 与真实 nvim 路径有差异] → probe 复刻 `lldb_dap_attach_config` 的命令序，
  结论需在真实 `<space>da` 复验。
- [仅单机] → 明确 ANDROID-SERIAL-A。

## Migration Plan

1. 写 `tools/dap_probe_android.py`（受控 attach + 分层 probe，参数化 MODE）。
2. 在 ANDROID-SERIAL-A 跑 D2/D3 各层，收集 protocol log。
3. 写 `docs/plans/2026-06-03-android-dap-handshake-rootcause.md`（证据 + 结论 + 正解判据）。
4. `git status` 仅 `docs/`、`tools/`、`openspec/`；无 `lua/` 改动。
5. 回滚：删两个新文件。

## Open Questions

- 握手零响应的真因：gdbserver 没 listen？adb forward 没通？协议不匹配？server 不兼容？
  —— 由 D2 逐层排除得出。
- 上一轮"tracer 稳定"为何与本轮"握手零响应"并存：是否上一轮根本没测握手层、把
  tracer 附上误当 attach 成功？—— 诊断需明确回答。
