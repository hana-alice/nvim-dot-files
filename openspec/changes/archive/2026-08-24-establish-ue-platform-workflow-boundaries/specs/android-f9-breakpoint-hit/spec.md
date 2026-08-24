## MODIFIED Requirements

### Requirement: Android 断点植入职责单一

系统 SHALL 让 Android attach-time preseed 与 active-session live breakpoint 各有唯一运行时 owner；`lua/ue/dap.lua` MUST NOT 重复注入 Android attachCommands，也 MUST NOT 以 reattach 作为会话中断点变更的正常应用路径。

#### Scenario: attachCommands 由 Android 模块生成

- **WHEN** 构建 UE Android attach config
- **THEN** 初始断点 preseed 的收集、命令生成和插入顺序 SHALL 由 Android DAP owner 负责
- **AND** `lua/ue/dap.lua` MUST NOT 另行向 Android attachCommands 注入重复 breakpoint 命令
- **AND** 断点命令 SHALL 位于 symbol target、platform connect、process attach、signal disposition、ASLR rebase 之后

#### Scenario: 会话中 F9 不静默重连

- **WHEN** 用户在已 attach 的 Android 会话中按 F9 新增或删除断点
- **THEN** active-session breakpoint owner SHALL 即时下发并验证真实 LLDB 状态
- **AND** 系统 MUST NOT 提示用户 reattach，也 MUST NOT 静默 detach/reattach

### Requirement: F9 断点端到端命中

系统 SHALL 让 UE Android F9 file:line 断点从编辑器设置到真机运行时命中形成可验证闭环；attach 前断点 SHALL 由 preseed 处理，会话中变更 SHALL 由 live 通道处理，两条路径都 MUST 以真实 LLDB 状态为准且不得要求 reattach。

#### Scenario: attach 前断点命中

- **WHEN** 用户在 attach 前通过 F9 设置 UE C++ file:line 断点并触发 `<space>da`
- **THEN** attach 流程 SHALL 在 LLDB 中植入对应断点
- **AND** LLDB `breakpoint list` SHALL 显示该断点 `resolved>0`
- **AND** 目标运行到该位置时 SHALL 产生 `stopped` event，reason 为 breakpoint 或等价断点停顿
- **AND** Neovim SHALL 定位到对应本地源码行

#### Scenario: attach 后新增断点不假成功

- **WHEN** 用户在 Android DAP 会话已 attach 后新增 F9 断点
- **THEN** 系统 SHALL 通过 live 通道下发并验证该断点的真实 resolved 状态
- **AND** MUST NOT 在未下发或未验证 resolved 时报告误导性的成功状态
- **AND** MUST NOT 要求或触发 reattach

### Requirement: 断点成功判据包含 LLDB 证据

系统 SHALL 用 LLDB 层证据决定 Android F9 断点是否成功，而不是只依赖 UI 状态或合成响应；失败诊断 SHALL 指向 live/preseed、路径、符号、ASLR 或命令层，不得把 reattach 描述为正常修复步骤。

#### Scenario: verified=true 有真实依据

- **WHEN** DAP `setBreakpoints` 响应返回 `verified=true`
- **THEN** 该响应 SHALL 对应已经 preseed 或即时下发的 LLDB breakpoint
- **AND** 最近一次 `breakpoint list` SHALL 显示匹配 file:line 或 address 的 resolved location
- **AND** adapter 进程 SHALL 存活且未出现 `3221226505`

#### Scenario: pending 或未下发时返回可诊断信息

- **WHEN** LLDB breakpoint pending、命令未发出、路径无法匹配或 adapter 风险路径被禁止
- **THEN** DAP/UI 反馈 SHALL 暴露原因
- **AND** SHALL 指明是 live/preseed 未下发、路径未匹配、符号未加载、ASLR 未校正还是 LLDB 命令失败
- **AND** MUST NOT 建议用户通过 reattach 掩盖失败
