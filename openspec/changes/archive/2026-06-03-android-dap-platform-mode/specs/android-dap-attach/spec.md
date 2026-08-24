## ADDED Requirements

### Requirement: device 端用 lldb-server platform 模式

系统 SHALL 用 `lldb-server platform --server --listen 127.0.0.1:<pport>` 启动设备端
platform server（替代已证伪的 `gdbserver --attach`），并 `adb forward` 该端口。

#### Scenario: platform server 正常监听

- **WHEN** `<space>da` 触发 Android attach
- **THEN** 设备端以 `platform --server --listen` 启动并进入 LISTEN 状态
- **AND** 不再使用 `gdbserver --attach <pid>`（该形态从不绑定端口）

### Requirement: platform 连接不经 getopt 命令字符串

系统 SHALL 通过 lldb-dap 的结构化连接路径建立 platform 连接，MUST NOT 把
`platform connect connect://...` 作为 attachCommands 命令字符串执行（在 LLDB 22.1.6 下
该命令经 getopt permute 会丢失 URL，报 `Invalid URL`）。

#### Scenario: 用结构化键选 platform 并连接

- **WHEN** 构建 lldb-dap attach 配置
- **THEN** 用 `platformName="remote-android"` 让 lldb-dap 经 SBAPI 选 platform
- **AND** 用结构化连接（`gdb-remote-port`/`gdb-remote-hostname` 或等价 SBAPI 路径）建立连接
- **AND** attachCommands 不含 `platform connect connect://...` 字符串

#### Scenario: 连接建立无 Invalid URL

- **WHEN** platform 连接执行
- **THEN** 不出现 `error: Invalid URL:`
- **AND** 不出现 `Connection shut down ... initial handshake` 超时

### Requirement: attach 后 ASLR rebase

系统 SHALL 在 platform 连接 + `process attach --pid` 成功后，对 libUE4.so 显式
`target modules load --file libUE4.so --slide 0x<base>`，base 运行时从设备
`/proc/<pid>/maps` 读取。

#### Scenario: 用运行时 base rebase

- **WHEN** attach 完成
- **THEN** 读 `/proc/<pid>/maps` 取 libUE4.so 首映射 base（每次冷启会变，不缓存跨会话）
- **AND** 下发 `target modules load --file libUE4.so --slide 0x<base>`
- **AND** hex 字符串用拼接构造，MUST NOT 用 `string.format("%x", addr)`

### Requirement: F9 断点真实 resolved

系统 SHALL 让 Android file:line 断点在 platform 路径下真实下发并 resolve，`verified`
反映真实结果，MUST NOT 无条件返回固定值。

#### Scenario: 断点接通判定

- **WHEN** 验证 F9 断点
- **THEN** DAP 响应 `verified=true`
- **AND** lldb `breakpoint list` 中该断点 `resolved>0`
- **AND** 适配器进程存活（无 `3221226505`）

### Requirement: 入口停顿不报 Source missing

系统 SHALL 在 UE Android 入口 stopOnEntry 合成帧时不触发源码跳转。

#### Scenario: 入口合成帧不 jump

- **WHEN** attach 入口停在 PC-only 合成帧
- **THEN** 不调用 jump，不出现 `Source missing, cannot jump to ...`

### Requirement: 仅改 nvim 配置且保持 host adapter 约束

本 change SHALL 仅改 nvim 配置与文档，host adapter 维持 LLDB 22.1.6+ forward-only，
设备验证仅在 ANDROID-SERIAL-A。

#### Scenario: 边界保持

- **WHEN** 本 change 被应用
- **THEN** host adapter 维持 LLVM 22.1.6+
- **AND** 改动文件集限于 `lua/ue/dap/*.lua`、`lua/utils/platform/windows.lua`、`docs/`、`tools/`（诊断脚本）
- **AND** 所有设备命令指定 `-s ANDROID-SERIAL-A`，收尾清理 device lldb-server + forward
