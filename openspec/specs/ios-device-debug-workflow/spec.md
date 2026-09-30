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

### Requirement: 外部真机 gate 必须诚实报告，且本能力不得暗含远程主机语义

MUST：签名、Developer Mode、debug entitlement、设备连接或兼容 Xcode 缺失时，真机验证必须报告
blocked/not-run；headless fixtures 只能证明 planner/parser/lifecycle contract，不能替代 E2E。
本能力假定单一 macOS 主机；Windows/SSH controller 调试 Mac 上的 iOS 设备必须视为独立的
remote-execution capability，不得把远程 Mac 冒充本地 host driver。

#### Scenario: CI 没有物理设备

- **WHEN** 所有 headless regressions 通过但不存在满足条件的物理设备
- **THEN** 可以报告自动测试通过，但必须单独把真机 breakpoint/cleanup gate 标记为 blocked/not-run

## 选型与踩坑

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
