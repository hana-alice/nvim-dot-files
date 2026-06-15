## ADDED Requirements

### Requirement: 真机验证收窄的连接组合

系统 SHALL 在 a3ad86f3 上验证 "纯 listen gdbserver + 结构化 `gdb-remote-port` +
attachCommands `process attach --pid`" 组合能否端到端到 `threads`，并据此定最终连接方案。

#### Scenario: 收窄组合到 threads

- **WHEN** device 跑 `lldb-server gdbserver 127.0.0.1:<port>`（无 --attach）且 host attach 配置含 `gdb-remote-port=<port>` 与 attachCommands `process attach --pid <pid>`
- **THEN** lldb-dap 到达 `initialized` 且 `threads` 成功
- **AND** 全程无 `Invalid URL` / 握手超时 / `3221226505`

#### Scenario: 失败时回退诊断

- **WHEN** 该组合 connect 后 attach/threads 失败
- **THEN** 读 `AttachRequestHandler` 的 gdb-remote-port + attachCommands 执行序定位原因
- **AND** 不盲改协议，按 fresh protocol log 决策

### Requirement: attach 端到端跑通

系统 SHALL 让 `<space>da` 端到端建立 attach 会话。

#### Scenario: 端到端成功判据

- **WHEN** 用户触发 `<space>da` 并完成 attach
- **THEN** 会话到达 `initialized` + `threads`
- **AND** 对 libUE4.so 完成 `target modules load --slide 0x<base>`（base 运行时读 maps，hex 拼接）

### Requirement: F9 断点真实 resolved

系统 SHALL 让 file:line 断点真实下发并 resolve。

#### Scenario: 断点接通判据

- **WHEN** 验证 F9
- **THEN** DAP `verified=true` 且 lldb `breakpoint list` `resolved>0` 且适配器存活（无 `3221226505`）
- **AND** 若 source-file `breakpoint set` 崩，则用 address 断点并满足"正解"判据（不同 lldb 代码路径、语义等价）

### Requirement: 消除入口噪音

系统 SHALL 在 UE Android 入口 stopOnEntry 合成帧时不触发源码跳转。

#### Scenario: 无 Source missing

- **WHEN** attach 入口停在 PC-only 合成帧
- **THEN** 不出现 `Source missing, cannot jump to ...`

### Requirement: 环境与设备约束

系统 SHALL 仅在 a3ad86f3 验证，host adapter 维持 22.1.6+，且不把 device serial 写死进
probe/运行时逻辑（测试机重连后 serial 会变）。

#### Scenario: clean env + 动态 serial

- **WHEN** 执行任何真机 probe
- **THEN** 先 `am force-stop` + 重启 app 取新 pid，用随机 host 端口，结束必清理 host lldb-dap + device lldb-server + forward
- **AND** serial 动态取当前在线设备，不硬编码字面量到逻辑（验证范围仍限 a3ad86f3）

### Requirement: 最终方案文档化

系统 SHALL 把最终连接方案与剩余增强项固化进文档，并更新主 spec。

#### Scenario: 文档与 spec 同步

- **WHEN** attach 真机跑通
- **THEN** `docs/plans/`、`docs/TOOLING.md`、`docs/CONSTRAINTS.md` 记录最终方案与 E1–E6 结论
- **AND** 主 spec `android-dap-attach` 以真机结论更新（纯 listen vs platform server 定稿）
