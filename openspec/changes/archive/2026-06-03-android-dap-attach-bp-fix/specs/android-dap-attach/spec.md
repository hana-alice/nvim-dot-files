## ADDED Requirements

### Requirement: Android DAP attach 在 SELinux runas 域下可启动 lldb-server

系统 SHALL 以在 `runas_app` SELinux 域下确实可执行的形式启动设备端 lldb-server，
MUST NOT 依赖 `cd` 切换工作目录（该域下 `cd` 不生效、cwd 停留在 `/`）。

#### Scenario: 用相对包数据根路径启动 server

- **WHEN** `<space>da` 触发设备端 `lldb-server gdbserver --attach`
- **THEN** spawn 命令使用 `files/lldb-server`（相对 run-as cwd `/data/user/0/<pkg>`）或绝对路径
- **AND** 不再使用 `cd files && ./lldb-server` 形式

### Requirement: 设备端 lldb-server 钉死 NDK21 LLDB 9.0.9

系统 SHALL 优先选择 NDK 21.4.7075529 的 LLDB 9.0.9 `lldb-server` 推送到设备，
因为它与 libUE4.so 的构建 NDK 匹配且在该目标上 `gdbserver --attach` 稳定。

#### Scenario: 候选顺序以 NDK21 为首选

- **WHEN** `default_lldb_server_paths()` 解析候选
- **THEN** NDK 21.* 路径排在 Android Studio bundled / 更高 NDK 之前
- **AND** 移除 2026-06-02 把 Android Studio LLDB19 置顶的临时 probe override

#### Scenario: 不稳定 server 不被默认选用

- **WHEN** 设备同时存在 LLDB 18/19 server
- **THEN** 它们仅作为 fallback，不优先于 NDK21（LLDB18/19 在该 UE 目标 attach 会 Segfault）

### Requirement: attach 后对 libUE4.so 做 ASLR rebase

系统 SHALL 在 attach 成功后、断点 resolve 前，对 libUE4.so 显式下发模块基址重定位。

#### Scenario: 用 /proc/maps 基址 rebase

- **WHEN** attach 完成
- **THEN** 系统读取设备 `/proc/<pid>/maps` 中 libUE4.so 首映射 base
- **AND** 下发 `target modules load --file libUE4.so --slide 0x<base>`
- **AND** base 的 hex 字符串通过拼接构造，MUST NOT 使用 `string.format("%x", addr)`（LuaJIT 64 位截断）

#### Scenario: rebase 失败不阻断 attach

- **WHEN** `/proc/<pid>/maps` 读取或解析失败
- **THEN** 系统提示告警并跳过 rebase
- **AND** attach 流程继续，不抛错

### Requirement: Android F9 断点真实下发并反映 resolved 状态

系统 SHALL 让 Android file:line 断点真正下发到 lldb，并使 DAP `verified` 反映真实
resolve 结果，MUST NOT 永远返回 `verified=false` 的合成响应。

#### Scenario: 断点经 attachCommands preseed 下发

- **WHEN** attach 时存在已设断点
- **THEN** 它们以 `?breakpoint set -f <file> -l <N>` 形式注入 attachCommands（信号处置之后）
- **AND** `_finalize_session` 不再注释掉 preseed 调用

#### Scenario: 接通判定标准

- **WHEN** 验证断点是否接通
- **THEN** DAP 侧响应 `verified=true`
- **AND** lldb 侧 `breakpoint list` 中 `resolved` 计数大于 0

### Requirement: 环境要求记录于 docs/TOOLING.md

仓库 SHALL 在 `docs/TOOLING.md` 记录 Android DAP 的设备端环境要求。

#### Scenario: 记录 device server 版本要求

- **WHEN** 读者查阅 `docs/TOOLING.md`
- **THEN** 其中说明 device lldb-server 必须为 NDK 21.4.7075529 LLDB 9.0.9，并给出 host glob 路径
- **AND** 说明为何不能用 NDK27/Android Studio bundled（attach Segfault，真机 `ANDROID-SERIAL-A` 证据）

### Requirement: 仅改 nvim 配置且不改既有协议边界

本 change SHALL 仅修改 nvim 配置文件与文档，不改设备系统、UE 工程、host adapter 版本，
且保持既有 DAP 协议边界不变。

#### Scenario: 边界保持

- **WHEN** 本 change 被应用
- **THEN** host adapter 维持 LLVM 22.1.6+ forward-only
- **AND** 不改 `stopOnEntry=true`、不加 `process continue`、不动 SIGSEGV/SIGBUS 信号处置
- **AND** 改动文件集仅限 `lua/ue/dap/*.lua`、`lua/utils/platform/windows.lua`、`docs/`
