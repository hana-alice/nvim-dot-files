# android-dap-attach

## MODIFIED Requirements

### Requirement: F9 断点真实 resolved 并命中

系统 SHALL 让 Android file:line 断点真实下发、resolve 并在目标运行到对应代码时命中，
覆盖 **attach 前已存在**（attach-time preseed）与 **会话中运行时新增/修改**（live 通道）
两类断点；`verified` MUST 反映真实 LLDB 状态，MUST NOT 无条件返回固定成功值，MUST NOT
要求 `:UEDAPReattach` 重连才能应用会话中 F9 变更。

#### Scenario: 断点接通判定

- **WHEN** 验证 F9 断点（无论 attach-time 还是 session-time）
- **THEN** DAP 响应 SHALL 返回与真实植入状态一致的 `verified`
- **AND** lldb `breakpoint list` 中该断点 SHALL `resolved>0`
- **AND** 适配器进程 SHALL 存活（无 `3221226505`）
- **AND** 目标运行到对应位置时 SHALL 触发 breakpoint stop
- **AND** stop frame SHALL 映射到正确本地源码行

#### Scenario: 会话中新增断点即时生效

- **WHEN** DAP 会话已 attach 且进程运行中，用户按 F9 新增断点
- **THEN** 系统 SHALL 经 live 通道即时下发该断点到 LLDB
- **AND** 该断点 SHALL 在不重连会话的前提下 resolve 并在命中位置触发 stop
- **AND** 系统 MUST NOT 提示需要 `:UEDAPReattach`

#### Scenario: 断点未生效时不伪装成功

- **WHEN** 断点未下发、pending、路径匹配失败、符号/ASLR 未就绪或 LLDB 命令失败
- **THEN** 系统 MUST NOT 报告无条件成功
- **AND** 反馈 SHALL 包含可用于定位失败层级的信息
- **AND** 系统 MUST NOT 通过静默 detach+reattach 伪装即时生效
