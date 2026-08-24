## MODIFIED Requirements

### Requirement: platform 连接使用 K30 serial-form 路线

系统 SHALL 使用已验证的 Android platform-mode serial-form 连接路线建立 attach 会话，不得回退到已证伪的 `gdbserver --attach`。交互式 DAP attach/launch SHALL 优先使用会话全局选择的 `vim.g.ue_android_device_serial`；程序化调用显式传入的 `context.android_serial` / `opts.serial` SHALL 保持最高优先级。选定后，该 serial SHALL 同时用于 `platform connect connect://[<serial>]:<port>` 与本次 session 的全部设备定向 ADB 命令。禁止 localhost / 127.0.0.1 形式与已证伪的 `gdbserver --attach` 路线。

#### Scenario: 用全局 serial-form platform connect 建立连接

- **WHEN** `vim.g.ue_android_device_serial = "SERIAL-002"` 且交互式构建 lldb-dap attach 配置
- **THEN** attachCommands SHALL 包含 `platform select remote-android`
- **AND** attachCommands SHALL 使用 `platform connect connect://[SERIAL-002]:<port>`
- **AND** attachCommands SHALL 随后执行 `process attach --pid <pid>`
- **AND** 本次 bootstrap/cleanup 的设备定向 ADB 命令 SHALL 使用 `adb -s SERIAL-002 ...`
- **AND** attachCommands MUST NOT 使用 `platform connect connect://localhost:<port>` 或 `platform connect connect://127.0.0.1:<port>`

#### Scenario: 程序化显式 serial 保持可复现

- **WHEN** headless/tool 调用显式传入 `context.android_serial = "SERIAL-AUTO"`，同时全局 serial 为其他值
- **THEN** 本次 attach SHALL 使用 `SERIAL-AUTO`
- **AND** K30 connect URL 与全部设备定向 ADB 命令 SHALL 使用同一个 `SERIAL-AUTO`

#### Scenario: 未设置时先选设备

- **WHEN** 交互式 DAP attach/launch 没有显式 serial 且全局 serial 为空
- **THEN** 系统 SHALL 打开同时显示 device 名称与 serial 的统一选择 UI
- **AND** 选择成功后 SHALL 写入全局 serial 并继续 attach
- **AND** 取消时 SHALL 中止 attach，不猜测第一台或唯一一台设备

#### Scenario: 连接建立无旧路径错误

- **WHEN** 连接执行
- **THEN** 不出现 `error: Invalid URL:`
- **AND** 不出现 `Connection shut down ... initial handshake` 超时
- **AND** 不启动 `lldb-server gdbserver --attach <pid>`

### Requirement: 仅改 nvim 配置且保持 host adapter 约束

该 attach 实现 SHALL 保持在本 nvim 配置仓的 Lua/OpenSpec/docs/tests 边界内，MUST NOT
修改或替换 host adapter / device binary；host adapter SHALL 维持 LLVM 22.1.6+
forward-only。每次 session 选定 serial 后，全部设备命令与收尾清理 SHALL 显式使用
`-s <session.serial>`，不得固定某一台设备或在运行中重读 global 改投其他设备。

#### Scenario: 边界与 selected serial 保持

- **WHEN** 该 attach 实现被应用并以 `SERIAL-002` 建立 session
- **THEN** host adapter SHALL 维持 LLVM 22.1.6+
- **AND** 实现 SHALL 不改 host adapter / device binary
- **AND** 全部设备命令与收尾清理 device lldb-server + forward SHALL 指定 `-s SERIAL-002`
