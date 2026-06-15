## MODIFIED Requirements

### Requirement: platform 连接使用 K30 serial-form 路线
系统 SHALL 使用已验证的 Android platform-mode serial-form 连接路线建立 attach 会话，不得回退到
已证伪的 `gdbserver --attach`。该路线允许使用 `platform connect connect://[<serial>]:<port>`
命令字符串，因为 serial-form URL 是当前 `docs/CONSTRAINTS.md` K30 记录的工作路径；禁止的是
localhost / 127.0.0.1 形式与已证伪的 `gdbserver --attach` 路线。

#### Scenario: 用 serial-form platform connect 建立连接
- **WHEN** 构建 lldb-dap attach 配置
- **THEN** attachCommands SHALL 包含 `platform select remote-android`
- **AND** attachCommands SHALL 使用 `platform connect connect://[<serial>]:<port>`
- **AND** attachCommands SHALL 随后执行 `process attach --pid <pid>`
- **AND** attachCommands MUST NOT 使用 `platform connect connect://localhost:<port>` 或
  `platform connect connect://127.0.0.1:<port>`

#### Scenario: 连接建立无旧路径错误
- **WHEN** 连接执行
- **THEN** 不出现 `error: Invalid URL:`
- **AND** 不出现 `Connection shut down ... initial handshake` 超时
- **AND** 不启动 `lldb-server gdbserver --attach <pid>`

### Requirement: F9 断点真实 resolved 并命中
系统 SHALL 让 Android file:line 断点真实下发、resolve 并在目标运行到对应代码时命中，
`verified` MUST 反映真实 LLDB 状态，MUST NOT 无条件返回固定成功值。

#### Scenario: 断点接通判定
- **WHEN** 验证 F9 断点
- **THEN** DAP 响应 SHALL 返回与真实植入状态一致的 `verified`
- **AND** lldb `breakpoint list` 中该断点 SHALL `resolved>0`
- **AND** 适配器进程 SHALL 存活（无 `3221226505`）
- **AND** 目标运行到对应位置时 SHALL 触发 breakpoint stop
- **AND** stop frame SHALL 映射到正确本地源码行

#### Scenario: 断点未生效时不伪装成功
- **WHEN** 断点未下发、pending、路径匹配失败、符号/ASLR 未就绪或 LLDB 命令失败
- **THEN** 系统 MUST NOT 报告无条件成功
- **AND** 反馈 SHALL 包含可用于定位失败层级的信息
