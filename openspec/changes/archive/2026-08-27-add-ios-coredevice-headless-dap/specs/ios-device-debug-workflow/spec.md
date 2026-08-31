## ADDED Requirements

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
- **THEN** 系统不得启动 adapter或从进程列表猜测替代目标
- **AND** 若本次 launch 已能证明创建了某个 session-owned PID，必须清理并复验该 PID

### Requirement: CoreDevice loaded image 必须与本地 debug artifact 一致

MUST：CoreDevice attach 必须在首次 continue 前证明 local Mach-O 与 dSYM UUID 一致，并证明设备已加载
的主 executable UUID 与该本地 UUID 一致。缺少 dSYM、UUID mismatch 或无法找到唯一主 image 时必须失败。

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

## MODIFIED Requirements

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
