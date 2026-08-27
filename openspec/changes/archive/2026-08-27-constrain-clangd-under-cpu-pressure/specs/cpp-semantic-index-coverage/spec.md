## ADDED Requirements

### Requirement: The clangd process SHALL be constrained under host CPU pressure

clangd 的资源占用 MUST NOT 仅由启动参数决定。`-j`、`--pch-storage` 与
`--background-index-priority` 都是进程启动时固定的静态预算，无法反映宿主上其他工具链
（外部编译器、其他编辑器、构建系统）的实时负载；`--background-index-priority` 的效果按 clangd
自身文档为 OS-specific，SHALL NOT 被当作已验证的防线。

当宿主整体 CPU 高于高水位时，系统 SHALL 对 clangd 进程施加 OS 级资源约束（降低进程优先级或
等价手段），使交互式 UI 与前台工具链优先获得调度。负载回落到低水位以下时 SHALL 恢复正常优先级。
判定 SHALL 复用系统既有的宿主负载采样与双水位滞回判据，MUST NOT 另行实现一套可能漂移的阈值。

系统 MUST NOT 终止或暂停 clangd 以降低负载：clangd 是长驻交互式服务，终止会丢弃已构建的
preamble，使下一次导航重新付出分钟级代价。约束 SHALL 限于优先级/亲和性等可逆的降级手段。

无法获取 clangd 进程句柄时，系统 SHALL 跳过约束并记录，MUST NOT 因此报错或阻塞 clangd 启动。

系统 MUST NOT 声称能保证宿主 CPU 低于任何阈值，也 MUST NOT 约束非自身启动的外部进程；
Windows 上 owned clangd 的发现 SHALL 同时匹配当前 Neovim parent PID 与 executable name，MUST NOT
仅按进程名枚举全机。发现后 SHALL 持有绑定原 process object 的原生 HANDLE；每次调整前只在该 HANDLE
仍为 `STILL_ACTIVE` 时写入。MUST NOT 仅凭数字 PID 重开进程，避免 PID reuse 误伤。
契约仅限于降低 owned clangd 抢占 UI 调度的能力。

#### Scenario: Host CPU exceeds the high watermark while clangd is indexing
- **WHEN** 宿主整体 CPU 高于高水位，且 clangd 正在后台索引
- **THEN** 系统 SHALL 降低 clangd 进程优先级
- **AND** 系统 MUST NOT 终止或暂停 clangd

#### Scenario: Host load falls back
- **WHEN** 宿主 CPU 回落到低水位以下
- **THEN** 系统 SHALL 恢复 clangd 的正常优先级
- **AND** 判定 SHALL 使用双水位滞回，MUST NOT 在单一阈值附近反复升降

#### Scenario: clangd process handle is unavailable
- **WHEN** 系统无法获得 clangd 的进程句柄或平台不支持优先级调整
- **THEN** 系统 SHALL 跳过约束并记录该事实
- **AND** clangd 启动与后续导航 MUST NOT 因此失败

#### Scenario: A stale PID has been reused
- **WHEN** 已登记 clangd 的原生 process HANDLE 不再为 `STILL_ACTIVE`
- **THEN** 系统 SHALL 关闭 HANDLE 并从控制集合移除该 PID
- **AND** MUST NOT 按数字 PID 重新打开并写入复用该 PID 的进程

#### Scenario: Static flags are not treated as sufficient
- **WHEN** 评估 clangd 的资源防线
- **THEN** `--background-index-priority` SHALL 被视为效果未在本平台验证
- **AND** OS 级约束 SHALL 独立于该旗标成立
