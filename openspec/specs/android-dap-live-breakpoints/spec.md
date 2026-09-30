# android-dap-live-breakpoints Specification

## Purpose

会话中（attach 完成、`configurationDone` 之后）即时下发/移除 UE Android
file:line 断点并真实命中的行为契约：live 路径成功/失败判据、attach-time
preseed 降级为初始种子、`verified` 真实性、不再依赖 `:UEDAPReattach`。边界：只管
会话建立之后的断点变更通道；attach 建连本身与初始 preseed 由 `android-dap-attach`
管。2026-06-15 真机 `ANDROID-SERIAL-B` 经闸门+端到端验证：lldb-dap evaluate
backtick `breakpoint set -f/-l` 通道在 K30 platform route + 3.5 匹配符号下
`resolved=1` 且命中（`docs/CONSTRAINTS.md` K36）。

## Requirements

### Requirement: 会话中 F9 必须即时下发到 LLDB，不得要求 reattach

系统 SHALL 在活跃 DAP 会话中，将用户运行时新增/修改的 file:line 断点即时下发到
LLDB 并真实 resolve，MUST NOT 要求用户 `:UEDAPReattach` 重连整个会话才能生效。
下发通道为 file:line 命令通道（`breakpoint set -f/-l`）或 address 通道
（`image lookup --line` → `breakpoint set --address`，须证明源行语义等价）之一，
由真机复验结果决定；删除断点同样经 live 通道即时移除。

#### Scenario: attach 后新增断点即时命中

- **WHEN** DAP 会话已 attach 且进程运行中，用户在某源文件按 F9 新增断点
- **THEN** 系统 SHALL 通过 live 通道向 LLDB 下发对应断点
- **AND** lldb `breakpoint list` 中该断点 SHALL `resolved>0`，目标运行到对应
  位置时 SHALL 触发 breakpoint stop 并映射到正确本地源码行
- **AND** 系统 MUST NOT 提示需要 `:UEDAPReattach`

### Requirement: live 下发失败时必须诚实反馈，不得静默 reattach 伪装成功

系统 SHALL 在 live 断点下发失败（命令报错、pending、符号/ASLR 未就绪、适配器
崩溃）时给出诚实反馈，MUST NOT 返回无条件 `verified=true`，也 MUST NOT 静默
detach+reattach 伪装即时生效。若 file:line 命令通道导致 lldb-dap 退出
（`3221226505`/`0xC0000409`），系统 SHALL 改用 address 通道，且仅在
`image lookup --line` 结果与源行语义等价被证明后采用，MUST NOT 把"碰巧不崩"或
"UI 变绿"作为正解。

#### Scenario: live 下发失败不假成功

- **WHEN** live 通道下发断点后 LLDB 未 resolve 或命令失败
- **THEN** DAP 响应的 `verified` SHALL 反映真实植入状态（失败为 false）
- **AND** 反馈 SHALL 包含可定位失败层级的信息（命令未发出/pending/路径不匹配/
  适配器退出）

### Requirement: attach-time preseed 降级为初始种子，不再是唯一路径

系统 SHALL 把 attach-time preseed（写入 `attachCommands` 的 `breakpoint set`）
作为会话开始前的初始断点快照，会话中后续的断点变更走 live 通道；preseed
MUST NOT 再是断点到达 LLDB 的唯一路径。

#### Scenario: 初始断点经 preseed，会话中断点经 live

- **WHEN** attach 时已有 N 个断点，attach 后又新增 M 个
- **THEN** N 个初始断点 SHALL 经 attachCommands preseed 植入，M 个新增断点
  SHALL 经 live 通道植入
- **AND** 两类断点最终都 SHALL 在 `breakpoint list` 中 `resolved>0`

### Requirement: live 通道接通后必须移除过时的 reattach warning

live 通道接通后，系统 SHALL 移除"会话中 F9 变更不会被应用、请
`:UEDAPReattach`"的 warning 及其 `configurationDone` gate；会话中 setBreakpoints
SHALL 经 live 通道处理且不再弹该 warning，诊断日志（`ue-dap-bp-diag.log`）SHALL
仍记录真实 setBreakpoints 响应供排查。

#### Scenario: 会话中 F9 不再弹 reattach warning

- **WHEN** 会话中（`configurationDone` 之后）发生 `setBreakpoints`
- **THEN** 系统 SHALL 经 live 通道处理，不弹"changes during an active session
  are not silently reattached"warning
- **AND** 诊断日志 `ue-dap-bp-diag.log` SHALL 仍记录真实 setBreakpoints 响应
  供排查

## 选型与踩坑

- **选型**：下发通道在 file:line 命令通道与 address 通道之间由真机复验结果
  决定，不是固定选一个——理由是 file:line 命令通道曾在特定符号/路由组合下导致
  adapter 崩溃（`3221226505`/`0xC0000409`），需要 address 通道作为经证明语义
  等价的回退。
- **重要事项**：K36 的 `resolved=1` 且命中结论限定于 `ANDROID-SERIAL-B` 在
  K30 platform route + 3.5 匹配符号下的真机验证，不代表在所有设备/符号组合下
  自动成立。
