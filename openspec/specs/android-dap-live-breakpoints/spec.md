# android-dap-live-breakpoints

## Purpose

会话中（attach 完成、`configurationDone` 之后）即时下发/移除 UE Android file:line
断点并真实命中的行为契约：live 路径成功/失败判据、attach-time preseed 降级为初始种子、
`verified` 真实性、不再依赖 `:UEDAPReattach`。2026-06-15 真机 `ANDROID-SERIAL-B` 经闸门 +
端到端验证：lldb-dap evaluate backtick `breakpoint set -f/-l` 通道在 K30 platform route +
3.5 匹配符号下 `resolved=1` 且命中（详见 `docs/CONSTRAINTS.md` K36、change
`android-dap-live-breakpoints`）。

## Requirements

### Requirement: 会话中 F9 即时下发断点到 LLDB

系统 SHALL 在活跃 DAP 会话中，将用户运行时新增/修改的 file:line 断点即时下发到
LLDB 并真实 resolve，**MUST NOT** 要求用户 `:UEDAPReattach` 重连整个会话才能生效。
下发通道为以下之一，由真机复验结果决定：file:line 命令通道（`breakpoint set -f/-l`）
或 address 通道（`image lookup --line` → `breakpoint set --address`，须证明源行语义等价）。

#### Scenario: attach 后新增断点即时命中

- **WHEN** DAP 会话已 attach 且进程运行中，用户在某源文件按 F9 新增断点
- **THEN** 系统 SHALL 通过 live 通道向 LLDB 下发对应断点
- **AND** lldb `breakpoint list` 中该断点 SHALL `resolved>0`
- **AND** 目标运行到对应位置时 SHALL 触发 breakpoint stop，stop frame 映射到正确本地源码行
- **AND** 系统 MUST NOT 提示需要 `:UEDAPReattach`

#### Scenario: 会话中删除断点即时移除

- **WHEN** DAP 会话进行中，用户对一个已生效断点按 F9 取消
- **THEN** 系统 SHALL 通过 live 通道在 LLDB 中移除该断点
- **AND** 目标后续运行到原位置 SHALL NOT 再触发 stop

### Requirement: live 下发失败时诚实反馈

系统 SHALL 在 live 断点下发失败（命令报错、pending、符号/ASLR 未就绪、适配器崩溃）时
给出诚实反馈，**MUST NOT** 返回无条件 `verified=true`，也 **MUST NOT** 静默 detach+reattach
伪装即时生效。

#### Scenario: live 下发失败不假成功

- **WHEN** live 通道下发断点后 LLDB 未 resolve 或命令失败
- **THEN** DAP 响应的 `verified` SHALL 反映真实植入状态（失败为 false）
- **AND** 反馈 SHALL 包含可定位失败层级的信息（命令未发出 / pending / 路径不匹配 / 适配器退出）
- **AND** 系统 MUST NOT 通过 detach+reattach 隐藏失败

#### Scenario: 适配器在 live 下发时崩溃则回退通道

- **WHEN** file:line 命令通道导致 lldb-dap 退出（`3221226505` / `0xC0000409`）
- **THEN** 系统 SHALL 改用 address 通道，且仅在 `image lookup --line` 结果与源行语义等价被证明后采用
- **AND** MUST NOT 把"碰巧不崩"或"UI 变绿"作为正解

### Requirement: attach-time preseed 降级为初始种子

系统 SHALL 把 attach-time preseed（写入 `attachCommands` 的 `breakpoint set`）作为**会话
开始前的初始断点快照**，会话中后续的断点变更走 live 通道。preseed **MUST NOT** 再是
断点到达 LLDB 的唯一路径。

#### Scenario: 初始断点经 preseed、会话中断点经 live

- **WHEN** attach 时已有 N 个断点，attach 后又新增 M 个
- **THEN** N 个初始断点 SHALL 经 attachCommands preseed 植入
- **AND** M 个新增断点 SHALL 经 live 通道植入
- **AND** 两类断点最终都 SHALL 在 `breakpoint list` 中 `resolved>0`

### Requirement: 移除 active-session F9 warning 与 configurationDone gate

live 通道接通后，系统 SHALL 移除"会话中 F9 变更不会被应用、请 `:UEDAPReattach`"的
warning 及其 `configurationDone` gate（`ue_android_bp_config_done` /
`ue_android_bp_local_response` 的 warning 分支）。

#### Scenario: 会话中 F9 不再弹 reattach warning

- **WHEN** 会话中（`configurationDone` 之后）发生 `setBreakpoints`
- **THEN** 系统 SHALL 经 live 通道处理，不弹"changes during an active session are not silently reattached"warning
- **AND** 诊断日志 `ue-dap-bp-diag.log` SHALL 仍记录真实 setBreakpoints 响应供排查
