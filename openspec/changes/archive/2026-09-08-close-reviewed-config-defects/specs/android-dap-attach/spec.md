## RENAMED Requirements

- FROM: `### Requirement: Android 项目和符号包发现不得固定项目名`
- TO: `### Requirement: Android 项目、Target、Configuration 与符号源发现不得靠名字或时间猜测`

## MODIFIED Requirements

### Requirement: attach 后 ASLR rebase

系统 SHALL 在连接 + attach 成功后，对 host 符号模块显式下发
`target modules load --file <host-symbol-basename> --slide 0x<base>`，base 运行时从设备
`/proc/<pid>/maps` 读取。当 host 符号文件名与 APK runtime module 名不同，系统 SHALL
以 ELF `DT_SONAME` 作为两者的已验证映射：maps 查 runtime SONAME，LLDB load 命令仍指向
`target create` 创建的 host 符号模块。MUST NOT 直接拿 host artifact basename 去查设备 maps。

#### Scenario: 用运行时 base rebase

- **WHEN** attach 完成
- **THEN** 读 `/proc/<pid>/maps` 取 runtime module 首映射 base（每次冷启会变，不缓存跨会话）
- **AND** 下发 `target modules load --file <host-symbol-basename> --slide 0x<base>`
- **AND** host 文件名不等于 runtime module 名时 SHALL 由 `DT_SONAME` 关联，普通 attach 与
  wait-mode late rebase SHALL 使用同一关联
- **AND** hex 字符串用拼接构造，MUST NOT 用 `string.format("%x", addr)`

### Requirement: Android 项目、Target、Configuration 与符号源发现不得靠名字或时间猜测

系统 SHALL 从显式 `.uproject` 或唯一的 `Source/<Project>/*.uproject` 派生 Android 输出目录，
并与构建层共用同一 Target/Configuration resolver。`UE_TARGET_CONFIGURATION` 的显式环境覆盖
SHALL 与 build 一样优先于 engine cache；项目名与 Target 名 SHALL 保持独立，MUST NOT 从
`.uproject` basename 反推 Target。命令 façade 与注册到 nvim-dap 的 configuration SHALL 进入
同一 resolver，MUST NOT 有绕过 identity enrichment 的第二入口。

自动符号源优先级 SHALL 是：显式 context/config override → 当前 Target/Configuration 的
未 strip UBT 产物 → 同 versionCode 且 build-id 与该配置产物一致的唯一符号包。当前配置产物
只有在 ELF64 little-endian section table 真实声明非空 `.debug_info`（或 `.zdebug_info`），且
`DT_SONAME` 提供 APK runtime module identity 时，才可直接作为符号源；字符串表中未被 section
引用的残留名字 MUST NOT 算作 DWARF 证据。

build-id 已知但候选无命中或多命中时系统 SHALL 拒绝猜测；build-id 不可得时，versionCode
最多构成弱匹配且只接受唯一候选。已有 packageInfo/versionCode 但没有唯一同版本候选时，MUST NOT
回退到另一个版本的 mtime winner。普通 attach/launch MUST NOT 回放 `_last_session.symbol_lib`
绕过上述选择；只有显式 reattach 可冻结并复用上一会话符号源。

#### Scenario: 非 Client 项目的 nested layout

- **WHEN** 项目位于 `<repo>/Source/<Project>/<Project>.uproject` 且 Android 输出位于该项目的 `Binaries/Android`
- **THEN** packageInfo 与符号库发现 SHALL 使用该项目目录
- **AND** 符号包发现 SHALL 接受任意 `<Target>_Symbols_v<code>/<Target>-arm64` 目录
- **AND** 多个 nested 项目同时具有 Android 输出且没有显式 `.uproject` 时 SHALL 不猜测项目

#### Scenario: build 的环境配置覆盖 cache

- **WHEN** engine cache 为 `Test Client`，但 `UE_TARGET_CONFIGURATION=Shipping Server`
- **THEN** build 与 DAP SHALL 同时解析为 Shipping + Server target identity
- **AND** DAP MUST NOT 继续选择 Test/Client 符号

#### Scenario: Development 通用文件名

- **WHEN** 当前 Configuration 为 Development、matching receipt 不存在且只有
  `<Target>-arm64.so` 存在
- **THEN** target owner SHALL 可把该 short-name 产物提供给 build/DAP
- **WHEN** 当前 `<Target>.target` 明确描述另一 Configuration
- **THEN** DAP MUST NOT 把 generic short-name 文件猜成 Development 产物

#### Scenario: 当前配置产物自带 DWARF

- **WHEN** build planner 解析出的 Target 为 `Client`、cache Configuration 为 `Test`
- **AND** target owner 定位到 `Client-Android-Test-arm64.so`，其真实 section 含非空
  `.debug_info` 且 `DT_SONAME=libUE4.so`
- **THEN** 系统 SHALL 直接选择该未 strip 产物作为 host 符号源
- **AND** 即使现有 `*_Symbols_v*` 只属于其他配置，也 MUST NOT 选择其他配置的符号包
- **AND** maps/ASLR lookup SHALL 使用 `libUE4.so`，而 `target create`/module rebase SHALL 指向
  `Client-Android-Test-arm64.so`

#### Scenario: 当前 receipt 描述另一配置

- **WHEN** `<Target>.target` 当前描述 Shipping，但 cache 选择 Test，且
  `<Target>-Android-Test-arm64.so` 存在
- **THEN** 部署路径仍 SHALL 以 receipt mismatch fail closed
- **AND** DAP 符号解析 MAY 消费配置限定的 Test 产物，因为文件名本身携带完整 Target/Platform/Configuration tuple

#### Scenario: 符号候选不一致时拒绝绕过

- **WHEN** 当前配置产物 build-id 已知但同 versionCode 符号包无命中或多命中
- **THEN** 系统 SHALL 拒绝自动选择，MUST NOT 以 mtime 或目录顺序挑一个
- **WHEN** 当前配置产物 build-id 不可得
- **THEN** versionCode 相同只能标为弱匹配，且只有唯一候选可被接受

#### Scenario: 切配置后的普通 attach 不复用旧符号

- **WHEN** 上一成功会话使用 Shipping 符号，随后 cache 切换为 Test 并执行普通 attach/launch
- **THEN** 系统 SHALL 重新按 Test 选择符号源
- **AND** MUST NOT 通过 `_last_session` 把 Shipping 符号作为显式 override

#### Scenario: 捕获到 PID 但 attach 失败不写 reattach 快照

- **WHEN** 系统已捕获目标 PID，但随后 L2 gate 拒绝或 DAP `attach` response 失败
- **THEN** `_last_session` SHALL 保持为上一份成功会话或空
- **AND** PID、`initialized` event、listener 启动或 liveness poller 本身 MUST NOT 被当作成功证明
- **WHEN** DAP `attach` response 明确成功
- **THEN** 系统 MAY 写入本次 frozen package/serial/symbol/runtime identity 供显式 reattach

### Requirement: 真实致命信号必须可停

系统 SHALL 让 UE 的真实致命信号在调试器中产生**真实 stop**，同时保持 K3 对 ART 良性
陷阱的 `--stop false` 处置不回退。

事实基础：ART 通过 `libsigchain.so` 把 SIGSEGV/SIGBUS 用作 JIT read barrier /
压缩 GC card-table / heap poisoning 的常规机制，故按**信号号**无法区分良性与致命；但按
**符号**可以——NDK 27 `llvm-nm` 实测出货 symbol `libUE4.so` 中存在
`FFatalSignalHandler::OnTargetSignal(int, siginfo*, void*)`，它在故障线程上运行。

#### Scenario: 符号断点在 attach 命令序列中的位置

- **WHEN** 构造 Android attach 命令序列
- **THEN** 序列 SHALL 在 `process attach` 与 ASLR `target modules load --slide` 之后
  下发一条限定当前 host 符号模块的 `FFatalSignalHandler::OnTargetSignal` 符号断点
- **AND** 该命令 SHALL 以 `?` 前缀标记为非致命：符号不匹配的构建 MUST NOT 中断整个 attach
- **AND** SIGSEGV/SIGBUS 处置 SHALL 仍为 `--pass true --stop false`（K3 不回退）
- **AND** 系统 SHALL 提供 `UE_DAP_NO_FATAL_BP=1` 逃生开关以还原旧行为
