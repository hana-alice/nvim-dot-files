# android-dap-attach

## Purpose

UE Android DAP attach、断点与设备路由的目标行为契约。当前以 host
LLVM 22.1.6+ `lldb-dap`、device `lldb-server platform`、K30 serial-form URL 为准；
交互式流程消费会话全局选择的 Android serial，程序化显式 serial 保持最高优先级。
## Requirements
### Requirement: device 端用 lldb-server platform 模式

系统 SHALL 用 `lldb-server platform --server --listen 127.0.0.1:<pport>` 启动设备端
platform server（替代已证伪的 `gdbserver --attach`，后者从不绑定监听端口），并
`adb forward` 该端口。

#### Scenario: platform server 正常监听

- **WHEN** `<space>da` 触发 Android attach
- **THEN** 设备端以 `platform --server --listen` 启动并进入 LISTEN 状态
- **AND** 不再使用 `gdbserver --attach <pid>`

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

### Requirement: attach 后 ASLR rebase

系统 SHALL 在连接 + attach 成功后，对 libUE4.so 显式
`target modules load --file libUE4.so --slide 0x<base>`，base 运行时从设备
`/proc/<pid>/maps` 读取。

#### Scenario: 用运行时 base rebase

- **WHEN** attach 完成
- **THEN** 读 `/proc/<pid>/maps` 取 libUE4.so 首映射 base（每次冷启会变，不缓存跨会话）
- **AND** 下发 `target modules load --file libUE4.so --slide 0x<base>`
- **AND** hex 字符串用拼接构造，MUST NOT 用 `string.format("%x", addr)`

### Requirement: Android 项目和符号包发现不得固定项目名

系统 SHALL 从显式 `.uproject` 或唯一的 `Source/<Project>/*.uproject` 派生 Android 输出目录，并从符号包实际目录发现 `<Target>-arm64`，不得假设项目或 Target 名为固定字符串。

#### Scenario: 非 Client 项目的 nested layout

- **WHEN** 项目位于 `<repo>/Source/<Project>/<Project>.uproject` 且 Android 输出位于该项目的 `Binaries/Android`
- **THEN** packageInfo 与符号库发现 SHALL 使用该项目目录
- **AND** versionCode 精确匹配 SHALL 接受任意 `<Target>_Symbols_v<code>/<Target>-arm64` 目录
- **AND** 多个 nested 项目同时具有 Android 输出且没有显式 `.uproject` 时 SHALL 不猜测项目

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

### Requirement: 入口停顿不报 Source missing

系统 SHALL 在 UE Android 入口 stopOnEntry 合成帧时不触发源码跳转。

#### Scenario: 入口合成帧不 jump

- **WHEN** attach 入口停在 PC-only 合成帧
- **THEN** 不调用 jump，不出现 `Source missing, cannot jump to ...`

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
