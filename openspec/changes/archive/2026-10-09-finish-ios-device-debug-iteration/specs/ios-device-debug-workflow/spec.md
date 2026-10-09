## ADDED Requirements

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

## MODIFIED Requirements

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
