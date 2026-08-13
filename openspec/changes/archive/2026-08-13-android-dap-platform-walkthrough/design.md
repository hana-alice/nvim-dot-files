## Context

UE Android DAP attach 路线已通过本次会话的真机 + LLVM 22.1.6 源码诊断收窄到一个精确
组合，但未端到端跑通。本设计承接归档 change 的全部结论（E1–E6，见 proposal），把"继续
攻坚"结构化，避免重复发现。

关键约束（用户给定 + `docs/CONSTRAINTS.md`）：host adapter LLDB **22.1.6+ forward-only**
是唯一硬约束；其余原则本任务内可放宽以跑通路线。设备仅 `<test-device>`。host lldb-dap 是
nopython 构建（E3），任何 host python 方案排除。

源码与证据脚本已在仓：`<local-llvm-source>`（tag llvmorg-22.1.6，sparse 含
Platform/Android、Interpreter、Host/common、tools/lldb-dap）；
`tools/dap_probe_android.py` / `dap_platform_probe.py` / `dap_platform_structured.py`。

## Goals / Non-Goals

**Goals**
- 真机端到端跑通 attach：到 `initialized` + `threads`，无 `Invalid URL` / 握手超时 / `3221226505`。
- F9 file:line 断点真实 resolved。
- 消除 `Source missing` 入口噪音。
- 把最终连接方案固化进代码 + 文档，并以真机结论更新主 spec `android-dap-attach`。

**Non-Goals**
- 不回退 gdbserver `--attach`（E1 证伪）、不依赖 host python（E3）。
- 不改 device 系统 / UE 工程。

## Decisions

**D1 — 先验证收窄组合，再改代码（apply 第一步）**
按概率先验 "纯 listen gdbserver + `gdb-remote-port` 结构化键 + attachCommands
`process attach --pid`"（同时绕 E1+E4）。用 `tools/dap_platform_structured.py` 扩展支持
该组合，取 fresh protocol log 判定能否到 `threads`。

**D2 — platform server 作为可选增强，不阻塞主目标**
用户要 platform 模式是为 IDE 级扩展（file transfer 等）。但 lldb-dap 22.1.6 结构化键
只连纯 gdb stub（E6）。决策：**主目标先用 D1 的纯 listen + vAttach 跑通**（功能等价、
支持后续 attach/断点/step/变量）；platform server 的额外能力作为后续增强，若需要再评估
nvim-dap 层绕 E4 或上游补丁。先有可用的 attach，再谈锦上添花。

**D3 — 断点：先 source-file，崩则 address**
连接通后真机测 source-file `breakpoint set`；若复现 `3221226505` 则切 address 断点
（`image lookup --line`→`breakpoint set --address`），并按
`android-dap-handshake-diagnostics` 的判据确认是正解（走不同 lldb 代码路径、语义等价）。

**D4 — clean-env 协议固化**
每轮 probe：`am force-stop` + 重启 app 取新 pid；动态取当前 device serial（不写死
`<test-device>` 字面量到 probe 逻辑，但验证仍限这台）；random host port；结束必 kill host
lldb-dap + device lldb-server + 清 forward。

## Risks / Trade-offs

- [D1 组合 connect 后 vAttach 仍失败] → 回退到逐层 probe（gdb 协议手动 vAttach 已验
  E2 回 `+`，说明 stub 支持 vAttach；问题可能在 lldb-dap 连接后的 pid 互斥处理）→ 读
  `AttachRequestHandler` 在 gdb-remote-port + attachCommands 并存时的执行序。
- [用户坚持必须 platform server] → 升级到 D2 的 nvim-dap 层绕 E4（更曲折），单独评估。
- [device server 版本不兼容 host 22] → 逐版本真机验证握手层。
- [仅单机] → 明确 `<test-device>`。

## Migration Plan

1. 扩展 `tools/dap_platform_structured.py` 支持 "纯 listen + gdb-remote-port +
   process attach pid" 组合；真机验证到 `threads`。
2. 方案定型 → 改 `lua/ue/dap/android.lua`（server 启动 + 结构化 attach 配置 + ASLR）。
3. 改 `lua/ue/dap.lua`（verified 真实化、入口不 jump）。
4. 改 `lua/utils/platform/windows.lua`（server 版本/优先级 + serial 不写死）。
5. 文档 `docs/plans/` + `docs/TOOLING.md` + `docs/CONSTRAINTS.md`。
6. 真机端到端 `<space>da` + F9 验证；clean-env 收尾。
7. 以真机结论 MODIFY 主 spec `android-dap-attach`（纯 listen vs platform server 定稿）。

## Open Questions

- `gdb-remote-port` + attachCommands `process attach --pid` 的执行序：lldb-dap 是先
  ConnectRemote 再跑 attachCommands 吗？（决定 vAttach 能否成功）——读源码 + 真机定。
- platform server 的 IDE 增强能力是否本期就要？还是先要可用 attach？——按 D2 默认先要可用。
