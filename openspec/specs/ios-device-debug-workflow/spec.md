# ios-device-debug-workflow Specification

## Purpose

定义 macOS 本机 Neovim 通过已验证的 Apple CoreDevice 或 pre-iOS17 MobileDevice/debugserver
链路调试物理 iOS 设备上 Unreal 应用的契约。假定 Neovim、lldb-dap、Xcode、device 与 artifact 均在
同一 macOS 主机上；不涉及远程执行、Windows/SSH controller 或跨主机路径映射（那属于独立的
remote-execution capability）。调试与普通运行（`ios-build-run-workflow` 的 `UELaunch`）是分离
的两条路径。

## Requirements

### Requirement: iOS DAP capability 必须由真机 protocol evidence 解锁

MUST：在独立 LLDB CLI 与 raw-DAP probe 证明完整 attach、断点与 cleanup 前，IOS target matrix 必须
保持 `dap_attach`/`dap_launch` unavailable；不得凭文档或历史命令猜测生产连接协议，也不得 fallback
到 Mac PID attach 或 Android transport。iOS 必须使用独立的 Apple lldb-dap adapter（selected Xcode
版本），不得按通用候选顺序静默使用 Homebrew LLVM，也不得复用 Mac/Android handler。

#### Scenario: 只有工具 help 或 headless 测试通过

- **WHEN** Xcode/LLDB 命令存在但尚无真机 attach evidence
- **THEN** `UEDAPAttach ios` 与 `UEDAPLaunch ios` 必须保持 unavailable，不得 fallback

#### Scenario: pre-iOS17 设备不进入 CoreDevice tunnel

- **WHEN** 显式设备可由 MobileDevice USB 检测、OS 低于 iOS 17，但 CoreDevice 不报告可连接 tunnel
- **THEN** probe 可以选择 legacy backend，并要求 ProductType/OS/build 精确匹配的 DeviceSupport
  Symbols、development profile 已被设备信任、debugserver bridge 可用
- **AND** partial transport evidence 不得替代 breakpoint/source-frame/detach gate

### Requirement: 每次 attach/launch 必须冻结不可变且可追溯的 context

MUST：每次 attach/launch 必须在开始时冻结 project tuple、selected signing identity、package
artifact、`.app`/bundle、device、PID/launch token、local binary/debug-map 或 dSYM/UUID、
adapter/Xcode 与 source roots；session 开始后用户切换选择不得影响当前 session。已运行应用 attach
必须复验设备进程身份（存活 PID 与 bundle 对应），不得把普通 launch 曾返回的 PID 直接视为当前真相。

#### Scenario: context 中存在 stale 或 mismatch identity

- **WHEN** PID 不存活、device/bundle 不匹配、artifact 不属于当前 tuple、或 loaded image 不匹配
- **THEN** 系统必须在首次 continue 前失败，不得用磁盘上“最新”文件、历史 PID 或其他设备补齐

#### Scenario: PID 已退出或被复用

- **WHEN** PID 不存在或对应 bundle 与捕获值不同
- **THEN** attach 必须失败并要求重新 launch/select process，不得 attach 到同号的其他进程

### Requirement: iOS 17+ 真机必须使用冻结的 CoreDevice route，且 loaded image 必须与本地一致

MUST：当所选设备 backend 为 `coredevice` 时，iOS DAP 必须冻结同一 macOS host 上的 selected
Xcode、设备、bundle、local debug artifact 与 process identity，按 `target create` → `device
select` → `device process attach -p` 顺序附加；失败后不得切换到 legacy、Mac 或其他 adapter。
attach 必须在首次 continue 前证明 local Mach-O 与 dSYM UUID 一致，且与设备已加载的主 executable
UUID 一致；缺少 dSYM、UUID mismatch 或 DWARF verification 失败时必须失败，不得降级为无 source
proof 的 symbol-only 调试成功。

#### Scenario: CoreDevice debug launch

- **WHEN** 用户对已安装且可调试的 iOS 17+ 应用执行 `UEDAPLaunch ios`
- **THEN** 系统必须以 start-stopped 语义启动应用取得正 PID，首次 continue 前必须允许下发 source
  breakpoints

#### Scenario: 本地或设备 image 不匹配

- **WHEN** dSYM 属于另一构建、设备运行另一 binary，或 loaded image identity 无法唯一证明
- **THEN** session 必须在首次 continue 前失败，不得降级为无 source proof 的成功

### Requirement: 调试成功必须由断点和 frame 证据确认

MUST：系统不得以 adapter 启动、attach response 或 UI 出现为成功；必须证明同一 device/bundle/PID、
host binary/dSYM/loaded image UUID 一致、breakpoint resolved、真实 breakpoint stop 与预期源码
frame。headless 真机验收必须运行 production CoreDevice handler 并以这些证据组合判定通过；只有
parser/unit fixtures 通过时，CoreDevice 真机 gate 必须继续报告 blocked/not-run，不能算 passed。

#### Scenario: breakpoint 仅显示但未 resolved

- **WHEN** DAP 接收 setBreakpoints 但返回 `verified=false` 或没有有效 location
- **THEN** session 不得报告 debug-ready，必须保留可诊断的脱敏 adapter/protocol evidence

#### Scenario: 只有 parser/unit fixtures 通过

- **WHEN** headless unit regressions 全绿但未执行满足条件的真机 production handler
- **THEN** CoreDevice 真机 gate 必须继续报告 blocked/not-run，而不是 passed

### Requirement: debug launch 必须与普通 launch 分离，cleanup 必须幂等

MUST：`UEDAPLaunch ios` 必须使用独立 debug-launch plan；普通 `:UELaunch` 永远保持非调试语义，不得
因 DAP 支持而 start-stopped。DAP stop、terminated/exited、adapter error、device disconnect 与
Vim 退出必须按 session platform/owner 分派一次幂等 cleanup，不得按配置名称猜平台，也不得重复
执行有副作用的 teardown。

#### Scenario: debug-launch bootstrap 失败

- **WHEN** 本次命令创建了 suspended process 但 adapter/attach/UUID validation 失败
- **THEN** 系统必须按验证过的顺序 resume 或 terminate 该 launch-owned process，不得遗留冻结 app
  或清理其他 session 的 PID

#### Scenario: cleanup 重复触发

- **WHEN** DAP event、用户 stop 与 Vim 退出先后触发清理
- **THEN** owner cleanup 必须至多执行一次有副作用的 teardown，后续调用只能读取或确认已清理状态

#### Scenario: adapter 退出但没有协议结束事件

- **WHEN** Apple lldb-dap 崩溃或关闭连接，未发送 terminated/exited 事件或 disconnect response
- **THEN** 系统必须通过 session close 回调异步派发同一 frozen owner 的幂等 cleanup
- **AND** attach 保留并复验原进程，debug launch 清理本次创建的进程，不得遗留活跃 owner 状态

#### Scenario: 旧会话回调晚于新会话启动

- **WHEN** 旧 iOS 会话的 UUID failure fallback、退出事件或显式 stop/cleanup 在新会话启动后到达
- **THEN** 系统必须核对该请求与冻结 runtime 的单次会话归属，只处理匹配的 owner
- **AND** 不得清空新会话、断开其他活跃 DAP session 或复用另一 owner 的 cleanup runtime

### Requirement: iOS 调试日志必须属于冻结的真机会话

MUST：iOS 调试日志只读取冻结会话的设备和进程，不得因后来切换 target/device 而改投，
也不得混用 Android 日志状态。日志读取与取消必须独立于 debugger/debuggee，不能恢复、
断开或终止调试进程。系统必须诚实显示缺工具、连接失败与 reader 退出，限制保留历史，
并清理结束会话的 reader；晚到回调不得影响其他会话或重新打开的日志。

#### Scenario: iOS 会话切到日志页

- **WHEN** 用户在已暂停的 iOS 会话按 `<leader>d4` 或执行 `:UEDAPTab logcat`
- **THEN** 同一底部窗口必须显示 `iOS Logs` 与冻结设备/PID 的日志，调试进程仍保持暂停
- **AND** 切回 REPL 再打开日志必须保留历史；Android 会话仍显示 `Logcat`

#### Scenario: 旧日志查询在会话结束后返回

- **WHEN** 日志 reader 的设备查询、输出或退出回调晚于对应会话清理
- **THEN** 不得创建新的 reader 或写入后来会话的 buffer，且不得清理新会话的日志

### Requirement: 外部真机 gate 必须诚实报告，且本能力不得暗含远程主机语义

MUST：签名、Developer Mode、debug entitlement、设备连接或兼容 Xcode 缺失时，真机验证必须报告
blocked/not-run；headless fixtures 只能证明 planner/parser/lifecycle contract，不能替代 E2E。
本能力假定单一 macOS 主机；Windows/SSH controller 调试 Mac 上的 iOS 设备必须视为独立的
remote-execution capability，不得把远程 Mac 冒充本地 host driver。

#### Scenario: CI 没有物理设备

- **WHEN** 所有 headless regressions 通过但不存在满足条件的物理设备
- **THEN** 可以报告自动测试通过，但必须单独把真机 breakpoint/cleanup gate 标记为 blocked/not-run

#### Scenario: adapter 在断点命中后崩溃

- **WHEN** headless 真机验收已获得 UUID、断点与源码 frame 证据，但 adapter 在求值完成前关闭
- **THEN** 验收必须保留已获得的脱敏证据、执行 owner cleanup，并及时报告失败
- **AND** 不得因已有断点证据而将未完成的求值或完整 E2E 判定为 passed

## 选型与踩坑

- **选型**：第四页统一为 `:UEDAPTab log`，保留 `logcat` 别名；iOS 使用已有
  `idevicesyslog` 按 PID 过滤。CoreDevice UUID 与 hardware UDID 不同，必须以匹配捕获设备的
  结构化 details 结果映射，不能把 CoreDevice UUID 直接交给日志 relay。
- **踩坑**：启动停止点的初始 process/image 查询各曾需约 20 秒；LLDB 默认 5 秒 packet timeout
  会先断开，空镜像并不证明 device 拒绝读内存。连接前使用有限 packet timeout 解决该构建的
  真机问题，仍保留首次 continue 前 UUID 与源码断点证明；具体值和顺序由实现与回归维护。
- **踩坑**：adapter EOF 不保证发出协议结束事件；session close 与 owner token 必须共同约束
  cleanup，避免旧退出回调清理新的设备进程或日志 reader。
- **选型**：iOS 必须使用独立 Apple lldb-dap adapter 与独立 adapter id，不复用 Mac/Android
  handler——设备协议、cleanup 顺序与失败语义都不同，混用会掩盖真实的平台差异。
- **踩坑**：K55（2026-08-26 真机）— CoreDevice start-stopped、PID identity 与 Mach-O/dSYM UUID
  都一致，但 LLDB source breakpoint 永远 pending；`dwarfdump --statistics` 报 0 functions/0 line
  entries。根因：超过 4 GiB 的 monolithic UE DWARF 可能生成 UUID 正确但结构损坏的 dSYM，只跑
  `--uuid` 会把不可调试工件误判为可用。约束：CoreDevice DAP 必须在启动 adapter 或创建 suspended
  process 前异步执行 `dwarfdump --verify --quiet`，失败即报告 external artifact blocker，不允许
  降级成 symbol-only 成功；loaded UUID 检查必须在 post-run `process status` 之后消费唯一
  OK/MISMATCH marker（提前 assert 会过早执行，且 lldb-dap 可能忽略其错误）
  （出处：`docs/CONSTRAINTS.md` K55；`lua/ue/dap/_ios_coredevice.lua`）。
- **重要事项**：真机 evidence 只能记录摘要/digest，不得落真实 device、bundle、PID 或个人路径。
  归属分层契约见 `openspec/specs/dap-failure-layering/spec.md`（失败先报层再处置）。
