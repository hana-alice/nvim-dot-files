# android-dap-attach Specification

## Purpose

UE Android DAP attach、断点与设备路由的目标行为契约。当前以 host LLVM 22.1.6+
`lldb-dap`、device `lldb-server platform`、K30 serial-form URL 为准；交互式流程
消费当前 Neovim 进程内选择的 Android serial，程序化显式 serial 保持最高优先级。
边界：只管 attach 建连、符号/ASLR 关联、F9 断点接通与会话结束报告；不管 host
adapter 本体或 device binary 的替换。

## Requirements

### Requirement: device 端必须用 lldb-server platform 模式，且以 app uid 从 sandbox 运行

系统 SHALL 用 `lldb-server platform --server` 启动设备端 platform server（`adb
forward` 该端口），MUST NOT 使用已证伪的 `gdbserver --attach <pid>`。系统 SHALL
以 app uid（经 `run-as <package>`）从 `/data/data/<package>/lldb-server` 启动它，
MUST NOT 以 shell uid 从 `/data/local/tmp` 启动；该形态的可行性 SHALL 由针对当前
设备的能力探测确认，探测失败时 SHALL 以 L2 归属报告，MUST NOT 静默回退到 shell
uid 形态。收尾清理 SHALL 同时 kill 两个 uid 下的残留 server。

#### Scenario: 以 app uid 启动 platform server

- **WHEN** `<space>da` 触发 Android attach
- **THEN** 系统 SHALL 先 `adb push` 到 `/data/local/tmp/lldb-server` 中转，再经
  `run-as <package>` 复制进 sandbox 并校验可执行
- **AND** 启动命令 SHALL 经 `run-as <package>` 执行 `/data/data/<package>/lldb-server`，
  listen 参数双引号保护为 `--listen "*:<port>"`
- **AND** MUST NOT 采用 `cd /data/local/tmp && ./lldb-server …` 的 shell-uid 形式

### Requirement: platform 连接必须使用 K30 serial-form 路线并遵循 serial 优先级

系统 SHALL 使用已验证的 Android platform-mode serial-form 连接路线（`platform
connect connect://[<serial>]:<port>`）建立 attach 会话，禁止 localhost/127.0.0.1
形式与已证伪的 `gdbserver --attach` 路线。交互式 DAP attach/launch SHALL 优先使用
当前 Neovim 进程选择的 `vim.g.ue_android_device_serial`；程序化调用显式传入的
`context.android_serial` / `opts.serial` SHALL 保持最高优先级。选定后，该 serial
SHALL 同时用于 platform connect 与本次 session 的全部设备定向 ADB 命令。

#### Scenario: 未设置时先选设备

- **WHEN** 交互式 DAP attach/launch 没有显式 serial 且全局 serial 为空
- **THEN** 系统 SHALL 打开同时显示 device 名称与 serial 的统一选择 UI
- **AND** 取消时 SHALL 中止 attach，不猜测第一台或唯一一台设备

### Requirement: attach 后必须做 ASLR rebase 且不得靠名字或时间猜符号源

系统 SHALL 在连接+attach 成功后，对 host 符号模块显式下发 `target modules load
--slide 0x<base>`，base 从设备 `/proc/<pid>/maps` 运行时读取；host 符号文件名与
APK runtime module 名不同时，SHALL 以 ELF `DT_SONAME` 作为已验证映射。项目/Target/
Configuration 发现 SHALL 从显式 `.uproject` 或唯一候选派生，与构建层共用同一
resolver，MUST NOT 从 `.uproject` basename 反推 Target。自动符号源优先级为：显式
override → 当前配置未 strip UBT 产物（须真实声明非空 `.debug_info`）→ 同
versionCode 且 build-id 一致的唯一符号包；build-id 已知但候选无命中/多命中时
SHALL 拒绝猜测，MUST NOT 以 mtime 或目录顺序挑一个。普通 attach/launch MUST NOT
回放 `_last_session.symbol_lib` 绕过上述选择；只有显式 reattach 可冻结复用上一
会话符号源，且仅在 DAP `attach` response 明确成功后才允许写入该快照。

#### Scenario: 用运行时 base rebase

- **WHEN** attach 完成
- **THEN** 读 `/proc/<pid>/maps` 取 runtime module 首映射 base（不缓存跨会话）
- **AND** 下发 `target modules load --file <host-symbol-basename> --slide 0x<base>`

#### Scenario: 符号候选不一致时拒绝绕过

- **WHEN** 当前配置产物 build-id 已知但同 versionCode 符号包无命中或多命中
- **THEN** 系统 SHALL 拒绝自动选择，MUST NOT 以 mtime 或目录顺序挑一个

### Requirement: F9 断点必须真实 resolved 并命中，覆盖 preseed 与会话中 live 两条路径

系统 SHALL 让 Android file:line 断点真实下发、resolve 并在目标运行到对应代码时
命中，覆盖 attach 前已存在（preseed）与会话中新增/修改（live 通道）两类断点；
`verified` MUST 反映真实 LLDB 状态，MUST NOT 无条件返回固定成功值，MUST NOT
要求 `:UEDAPReattach` 重连才能应用会话中变更。

#### Scenario: 断点接通判定

- **WHEN** 验证 F9 断点（无论 attach-time 还是 session-time）
- **THEN** DAP 响应 SHALL 返回与真实植入状态一致的 `verified`
- **AND** lldb `breakpoint list` 中该断点 SHALL `resolved>0`
- **AND** 目标运行到对应位置时 SHALL 触发 breakpoint stop 并映射到正确本地源码行

### Requirement: 会话结束原因必须讲事实，MUST NOT 给无信息量的死亡报告

会话中 app 死亡时，系统 SHALL 报告可核验的死亡原因，MUST NOT 只给出无信息量的
"App … exited. Detaching."。设备侧唯一能指认「谁杀的」的权威是 `dumpsys activity
exit-info <package>` 的 `ApplicationExitInfo` 记录。真实致命信号（如 UE
`FFatalSignalHandler::OnTargetSignal`）SHALL 在调试器中产生真实 stop，同时 ART
对 SIGSEGV/SIGBUS 的良性陷阱仍保持 `--pass true --stop false` 处置不回退。

#### Scenario: 外部 force-stop（不可捕获）

- **WHEN** 会话中 app 死亡，DAP 报 exit status 9，且设备记录为
  `reason=10 (USER REQUESTED) subreason=21 (FORCE STOP)`
- **THEN** 反馈 SHALL 指明该状态对应 SIGKILL 且无法被任何调试器捕获
- **AND** 反馈 SHALL 显式否掉「调试器漏掉了崩溃」这一错误印象

#### Scenario: 取不到设备记录时不编造

- **WHEN** 设备不可达或该 pid 无 `ApplicationExitInfo` 记录
- **THEN** 系统 SHALL 仍报告 lldb 侧状态，并告知用户自行取证的命令
- **AND** 措辞 SHALL 为「匹配某信号」而非断言「被某信号杀死」

### Requirement: attach SHALL 先过 L2 能力门禁再连接调试引擎

Android attach SHALL 在发起 `platform connect` 之前判定 L2（目标 OS 策略）能力：
staged 二进制能否被将要运行它的身份执行、该身份能否 ptrace 目标进程、沙箱运行
路径是否就绪。任一失败时 attach SHALL 以 L2 归属的错误终止并给出确切拒绝命令与
其输出，MUST NOT 把 L2 失败推迟到 L3 表现为 handshake 失败或
`attach failed: lost connection`/`The parameter is incorrect` 这类不指向根因的
下游症状。设备能力 SHALL 针对当前设备探测得出，MUST NOT 沿用某一台已验证设备的
既定前提；判定某身份能力时 SHALL 以该身份探测，MUST NOT 用更高权限身份的探测
结果代替。

#### Scenario: 执行权限缺失在连接前被拦下

- **WHEN** 将要运行 platform server 的身份对 staged 二进制没有执行权限
- **THEN** attach SHALL 在启动 device server 与 `platform connect` 之前终止
- **AND** 错误 SHALL 归入 L2 并附带该身份下的探测命令与其退出码

### Requirement: 仅改 nvim 配置，且不得固定设备或替换 host adapter

该 attach 实现 SHALL 保持在本 nvim 配置仓的 Lua/OpenSpec/docs/tests 边界内，
MUST NOT 修改或替换 host adapter / device binary；host adapter SHALL 维持
LLVM 22.1.6+ forward-only。每次 session 选定 serial 后，全部设备命令与收尾清理
SHALL 显式使用该 serial，不得固定某一台设备或在运行中重读 global 改投其他设备。

#### Scenario: 边界与 selected serial 保持

- **WHEN** 该 attach 实现被应用并以某 serial 建立 session
- **THEN** host adapter SHALL 维持 LLVM 22.1.6+，实现 SHALL 不改 host adapter /
  device binary
- **AND** 全部设备命令与收尾清理 device lldb-server + forward SHALL 指定同一
  serial

## 选型与踩坑

- **选型**：device 端选 `lldb-server platform` 模式而不是 `gdbserver --attach`
  —— 后者在真机上从不绑定监听端口（已证伪的历史路线）。
- **踩坑**（K56，2026-09-03 真机）：`ro.debuggable=0` 的 `user` build 上 shell
  uid 无法 ptrace app 进程，NDK 27 LLDB 18 的 lldb-server 不把该拒绝报成错误——
  其 fork 的 per-target gdbserver 子进程在 `vAttach` 里 SIGSEGV，host 仅看到
  `error: attach failed: lost connection`。同一目标 A/B：shell uid 3/3 失败，
  app uid 3/3 成功；device server 版本不是变量（LLDB 9/14/18 在 shell uid 下
  同样失败）。处置：platform server 必须以 app uid 从 sandbox 运行，MUST NOT
  通过降级 device server 版本来"修"它。
- **踩坑**（K58，2026-09-03 真机实测）：公共中转路径 `/data/local/tmp` 的
  SELinux 标签是 `shell_data_file`（app 域可读不可执行），sandbox 副本标签为
  `app_data_file`。早期实现的 run path 复用判定用 shell uid 对公共路径做
  `test -x` 就判定"可运行"，实际启动命令变成 126 退出、设备端无监听，host 侧
  表现为 handshake shutdown。处置：run path 复用判定必须以 app uid 在 sandbox
  副本上同时校验尺寸与 `test -x`。
- **重要事项**：符号发现要求当前配置产物"真实声明非空 `.debug_info`"，字符串表
  中未被 section 引用的残留名字不算 DWARF 证据（避免 strip 后残留符号名误判为
  可用调试信息）。
- **选型（2026-09-30）**：attach/launch 路径上的 adb 往返（查 pid、读
  `/proc/<pid>/maps` 求 slide、`set-debug-app`/启动、JDWP forward）一律异步，
  不再用 `vim.fn.system`。K53 实测 Windows 同步 spawn 仅启动即 ≥87 ms，加上
  adb 往返会在每次 attach/rebase 时冻结界面。
- **重要事项（2026-09-30，引擎源码核对，未真机复验）**：致命信号断点停在
  `FFatalSignalHandler::OnTargetSignal` 时不会触发 UE 的 `exit(0)` 自杀超时——
  该超时只在 `ForwardSignal` 之后的轮询里按 10 ms 迭代累计（非墙钟），且 LLDB
  all-stop 会冻结全部线程；只有 `continue` 之后的运行时间才计入
  `android.SignalTimeout`（默认 20 s）。
- **重要事项**：包名缺省时不再弹空白输入框，改为从设备
  `pm list packages -3` 与项目 cook 产物中选择并持久化；崩溃符号化
  （`:UEAndroidCrash`）复用同一 build-id 权威的符号库选择链（K64/K65/K66）。
