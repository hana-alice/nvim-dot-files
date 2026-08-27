# ios-device-debug-workflow Specification

## Purpose

定义 macOS 本机 Neovim 通过已验证的 Apple/CoreDevice 或 pre-iOS17
MobileDevice/debugserver 链路调试物理 iOS 设备上 Unreal 应用的契约。

## Requirements

### Requirement: iOS DAP capability 必须由真机 protocol evidence 解锁

MUST：在独立 LLDB CLI 与 raw-DAP probe 证明完整 attach、断点与 cleanup 前，IOS target matrix 必须保持
`dap_attach`/`dap_launch` unavailable；实现不得凭文档或历史命令猜测生产连接协议。

#### Scenario: 只有工具 help 或 headless 测试通过

- **WHEN** Xcode/LLDB 命令存在但尚无真机 attach evidence
- **THEN** `UEDAPAttach ios` 与 `UEDAPLaunch ios` 必须保持 unavailable
- **AND** 不得 fallback 到 Mac PID attach 或 Android transport

#### Scenario: protocol spike 成功

- **WHEN** 同一设备/进程完成 LLDB CLI 与 raw-DAP attach、resolved breakpoint、真实 stop frame 和幂等清理
- **THEN** 系统可以把该 adapter、连接命令与 teardown 顺序写入生产实现
- **AND** evidence 必须脱敏并记录工具版本与未验证边界

#### Scenario: pre-iOS17 设备不进入 CoreDevice tunnel

- **WHEN** 显式设备可由 MobileDevice USB 检测、OS 低于 iOS 17，但 CoreDevice 不报告可连接 tunnel
- **THEN** probe 可以选择 legacy backend，并要求 ProductType/OS/build 精确匹配的 DeviceSupport Symbols
- **AND** 必须验证 development profile 已被设备信任、Xcode DeveloperDiskImage/debugserver bridge 可用
- **AND** partial transport evidence 不得替代 breakpoint/source-frame/detach gate

#### Scenario: backend 失败

- **WHEN** 已冻结的 CoreDevice 或 legacy backend 在当前 session 中失败
- **THEN** 当前 session 必须显式失败
- **AND** 不得切换 backend 或另一份 `lldb-dap` 重试同一 process identity

### Requirement: iOS debug 必须消费不可变且可追溯的 context

MUST：每次 attach/launch 必须在开始时冻结 project tuple、selected signing identity、package artifact、
`.app`/bundle、device、PID/launch token、local binary/debug-map 或 dSYM/UUID、adapter/Xcode 与 source roots。

#### Scenario: session 开始后选择发生变化

- **WHEN** 用户在活跃 session 中切换 project、device 或 signing identity
- **THEN** 当前 session 必须继续使用已捕获 context
- **AND** 新选择只影响后续 session

#### Scenario: context 中存在 stale 或 mismatch identity

- **WHEN** PID 不存活、device/bundle 不匹配、artifact 不属于当前 tuple、local debug artifact 缺失或
  loaded image 不匹配
- **THEN** 系统必须在首次 continue 前失败
- **AND** 不得用磁盘上“最新”文件、历史 PID 或其他设备补齐

### Requirement: iOS 必须使用独立 Apple device adapter

MUST：iOS DAP 必须使用 spike 证明与 selected Xcode/设备兼容的 Apple lldb-dap，并拥有独立 adapter id；
不得按通用候选顺序静默使用 Homebrew LLVM，也不得复用 Mac/Android handler。

#### Scenario: 存在多个 lldb-dap

- **WHEN** 系统同时发现 selected Xcode 与 Homebrew/CLT 的 adapter
- **THEN** 必须使用 debug context 中已验证的绝对路径
- **AND** 该 adapter 失败时必须显式失败，不能切换到另一候选重试同一 session

#### Scenario: Android 专用初始化存在

- **WHEN** iOS session 构造 LLDB 配置
- **THEN** 不得包含 ADB、remote-android、lldb-server、JDWP、`/proc/maps`、手工 ASLR slide、
  Android 信号或 breakpoint planting 逻辑

### Requirement: 已运行应用 attach 必须复验设备进程身份

MUST：`UEDAPAttach ios` 必须 attach 到捕获设备上与捕获 bundle 对应的存活 PID，并使用精确 local
binary/dSYM；不得把普通 launch 曾返回的 PID 直接视为当前真相。

#### Scenario: launch 后 PID 仍有效

- **WHEN** device process probe 确认同一 device/bundle/PID 且 debug gates 满足
- **THEN** handler 可以创建 target、连接设备并 attach
- **AND** breakpoint 必须在首次 continue 前发送

#### Scenario: PID 已退出或被复用

- **WHEN** PID 不存在或对应 bundle 与捕获值不同
- **THEN** attach 必须失败并要求重新 launch/select process
- **AND** 不得 attach 到同号的其他进程

### Requirement: iOS 17+ 真机必须使用冻结的 CoreDevice debug route

MUST：当所选设备 backend 为 `coredevice` 时，iOS DAP 必须冻结同一 macOS host 上的 selected Xcode、
设备、bundle、local debug artifact 与 process identity，并使用 Apple CoreDevice LLDB 命令完成附加。
当前 session 不得启动 legacy `ios-deploy` bridge，也不得在失败后切换到 legacy、Mac 或其他 adapter。

#### Scenario: CoreDevice debug launch

- **WHEN** 用户对已安装且可调试的 iOS 17+ 应用执行 `UEDAPLaunch ios`
- **THEN** 系统必须在显式选择的设备上以 start-stopped 语义启动应用并取得正 PID
- **AND** Apple `lldb-dap` 必须按 `target create` → `device select` → `device process attach -p` 顺序附加
- **AND** 首次 continue 前必须允许 DAP 下发 source breakpoints

#### Scenario: CoreDevice ordinary attach

- **WHEN** 用户执行 `UEDAPAttach ios` 且设备上存在唯一匹配捕获 bundle 的运行进程
- **THEN** 系统必须通过结构化 CoreDevice process evidence 复验正 PID 与 bundle identity 后附加
- **AND** 不得使用普通 launch 返回的历史 PID、进程名猜测或另一台设备的同名进程

#### Scenario: CoreDevice session 失败

- **WHEN** selected Xcode、CoreDevice tunnel、app identity、PID 或 adapter attach 任一 gate 失败
- **THEN** 当前 session 必须显式失败并保留 backend-specific 诊断
- **AND** 不得在同一 process identity 上尝试 legacy、Mac 或另一份 `lldb-dap`

### Requirement: CoreDevice debug launch 必须复验 suspended process identity

MUST：debug launch 必须消费 `devicectl` 的结构化输出，并在进入 DAP 前确认 device、bundle 与正 PID
都与冻结 context 一致。若 launch 已创建 suspended process 但后续 bootstrap 失败，cleanup 只能操作该
session 捕获的 device/PID，并必须复查该 PID 已不存在。

#### Scenario: launch 结果完整且一致

- **WHEN** start-stopped launch 返回与冻结 device/bundle 一致的正 PID
- **THEN** 该 PID 必须成为 session owner metadata 的 process identity
- **AND** 后续 attach、status、stop 与 cleanup 必须继续使用同一快照

#### Scenario: launch 输出缺失或 identity mismatch

- **WHEN** launch 输出缺少正 PID，或返回的 device/bundle 与冻结值不同
- **THEN** 系统不得启动 adapter 或从进程列表猜测替代目标
- **AND** 若本次 launch 已能证明创建了某个 session-owned PID，必须清理并复验该 PID

### Requirement: CoreDevice loaded image 必须与本地 debug artifact 一致

MUST：CoreDevice attach 必须在首次 continue 前证明 local Mach-O 与 dSYM UUID 一致，并证明设备已加载
的主 executable UUID 与该本地 UUID 一致。缺少 dSYM、UUID mismatch、DWARF verification 失败或无法找到
唯一主 image 时必须失败。

#### Scenario: 三方 UUID 一致

- **WHEN** local Mach-O、dSYM 与设备 loaded image 给出同一 UUID 集合
- **THEN** session 可以继续进入 breakpoint gate
- **AND** source frame 仍必须指向冻结的当前 checkout

#### Scenario: 本地或设备 image 不匹配

- **WHEN** dSYM 属于另一构建、设备运行另一 binary，或 loaded image identity 无法唯一证明
- **THEN** session 必须在首次 continue 前失败
- **AND** 不得降级为无 source proof 的 symbol-only 调试成功

### Requirement: headless 真机验收必须运行 production CoreDevice handler

MUST：iOS headless smoke 必须通过显式 project/device/bundle/binary/dSYM/source/line 输入调用 production
handler，并以 verified breakpoint、真实 breakpoint stop、精确 source frame、LLDB expression 与幂等
cleanup 的组合结果判定通过。证据输出必须脱敏，不得写入真实设备 ID、bundle、PID 或个人绝对路径。

#### Scenario: headless smoke 全链通过

- **WHEN** `nvim --headless` 在满足条件的 CoreDevice 真机上执行 production debug-launch 或 attach
- **THEN** 结果必须同时记录 attach、verified breakpoint、breakpoint stop、source frame、expression 与 cleanup 成功
- **AND** 只有全部 gate 通过时 status 才能为 passed

#### Scenario: 只有 parser/unit fixtures 通过

- **WHEN** headless unit regressions 全绿但未执行满足条件的真机 production handler
- **THEN** 自动化测试只能证明 planner/parser/lifecycle contract
- **AND** CoreDevice 真机 gate 必须继续报告 blocked/not-run，而不是 passed

### Requirement: debug launch 必须与普通 launch 分离

MUST：`UEDAPLaunch ios` 必须使用独立 debug-launch plan；普通 `:UELaunch` 永远保持可运行应用的非调试
语义，不得因为 DAP 支持而 start-stopped。

#### Scenario: 用户执行普通 launch

- **WHEN** 用户执行 `:UELaunch` 且当前 target 为 IOS
- **THEN** 应用必须正常运行
- **AND** 不得启动 adapter、等待 debugger 或注入 debug-launch 参数

#### Scenario: debug-launch bootstrap 失败

- **WHEN** 本次命令创建了 suspended process 但 adapter/attach/UUID validation 失败
- **THEN** 系统必须按 spike 验证的顺序 resume 或 terminate 该 launch-owned process
- **AND** 不得遗留冻结 app 或清理其他 session 的 PID

### Requirement: iOS 调试成功必须由断点和 frame 证据确认

MUST：系统不得以 adapter 启动、attach response 或 UI 出现为成功；必须证明同一 device/bundle/PID、
host binary/dSYM/loaded image UUID 一致、breakpoint resolved、真实 breakpoint stop 与预期源码 frame。

#### Scenario: breakpoint 仅显示但未 resolved

- **WHEN** DAP 接收 setBreakpoints 但返回 `verified=false` 或没有有效 location
- **THEN** session 不得报告 debug-ready
- **AND** 必须保留可诊断的脱敏 adapter/protocol evidence

#### Scenario: breakpoint 命中

- **WHEN** `stopped.reason=breakpoint` 且 stack frame 指向当前 checkout 的预期文件/行
- **THEN** session 可以标记真机 debug gate 通过
- **AND** loaded image UUID 必须与捕获的 binary/dSYM UUID 一致

### Requirement: cleanup 必须由 session owner 幂等执行

MUST：DAP stop、terminated/exited、adapter error、device disconnect 与 Vim 退出必须按 session platform/owner
分派一次幂等 cleanup；不得按配置名称猜平台。

#### Scenario: attach 到既有进程后停止

- **WHEN** 用户停止 attach-owned iOS session
- **THEN** 系统必须 disconnect 且 `terminateDebuggee=false`
- **AND** detach 完成后必须按冻结 device/app/PID 复验既有进程仍存活，且不得发送 terminate

#### Scenario: debug-launch session 停止

- **WHEN** 用户停止由本次 CoreDevice debug-launch 创建的 session-owned frozen PID
- **THEN** 系统必须先 non-terminating disconnect，再终止该精确 PID 并复验 absence
- **AND** 不得按当前 UI selection 或同名进程猜测清理目标

#### Scenario: cleanup 重复触发

- **WHEN** DAP event、用户 stop 与 Vim 退出先后触发清理
- **THEN** owner cleanup 必须至多执行一次有副作用的 teardown
- **AND** 后续调用只能读取或确认已清理状态

### Requirement: 外部真机 gate 必须诚实报告

MUST：签名、Developer Mode、debug entitlement、设备连接或兼容 Xcode 缺失时，真机验证必须报告
blocked/not-run；headless fixtures 只能证明 planner/parser/lifecycle contract，不能替代 E2E。

#### Scenario: CI 没有物理设备

- **WHEN** 所有 headless regressions 通过但不存在满足条件的物理设备
- **THEN** change 可以报告自动测试通过
- **AND** 必须单独把真机 breakpoint/cleanup gate 标记为 blocked/not-run，而不是 passed

### Requirement: 本变更不得引入远程主机语义

MUST：本能力假定 Neovim、lldb-dap、Xcode、device 与 artifact 均在同一 macOS 主机；不得暗含
Windows/SSH executor、远程 temp、DAP byte-stream bridge 或跨主机路径映射。

#### Scenario: controller 位于 Windows

- **WHEN** 用户需要 Windows Neovim 通过 SSH 控制 Mac 上的 iOS debug
- **THEN** 系统必须将其视为独立 remote-execution capability
- **AND** 本变更不得把远程 Mac 冒充本地 macOS host driver
