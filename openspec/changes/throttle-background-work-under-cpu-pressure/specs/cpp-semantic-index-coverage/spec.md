## ADDED Requirements

### Requirement: Background index work SHALL yield to host CPU pressure

后台受控索引构建 SHALL 在**启动前**评估宿主整体 CPU 负载，并在负载超过高水位时推迟启动，
而不是无条件加压。静态并发预算（`-j` / 保留核数）只能防止"我们自己占满"，无法防止"在别人
（外部编译器、其他工具链）已占满时我们继续加压"——共享机器上必须有动态准入。

负载采样 MUST NOT 通过 spawn 子进程实现（周期性同步子进程往返会阻塞主循环，见 K40）。
采样 SHALL 使用进程内可用的宿主统计信息，其开销 SHALL 可忽略。

系统 MUST NOT 声称能保证宿主总体 CPU 低于任何阈值，也 MUST NOT 尝试挂起、降级或终止外部进程；
契约仅限于**我们自己不在高负载期间主动启动新的重活**。

#### Scenario: Host is under heavy external load when a phase becomes due
- **WHEN** 某索引阶段的 deadline 到达，而宿主 CPU 使用率高于高水位
- **THEN** 系统 SHALL 推迟该阶段启动，MUST NOT 启动新的构建子进程
- **AND** 推迟原因 SHALL 可观测（进度/日志），MUST NOT 静默无响应

#### Scenario: Load falls back after a deferral
- **WHEN** 先前因高负载被推迟的阶段，其后宿主 CPU 回落到低水位以下
- **THEN** 系统 SHALL 恢复该阶段的启动
- **AND** 判定 SHALL 使用高/低双水位（滞回），MUST NOT 在单一阈值附近抖动式反复启停

#### Scenario: A build is already running when load spikes
- **WHEN** 构建已在进行中，随后宿主负载超过高水位
- **THEN** 系统 SHALL 允许该构建继续完成，MUST NOT 杀掉它以致已完成的工作被浪费
- **AND** 系统 SHALL NOT 在此期间启动额外阶段

#### Scenario: Host stays busy for a long time
- **WHEN** 宿主 CPU 长期高于高水位
- **THEN** 推迟 SHALL 有上限，超过上限后 SHALL 允许交付推进
- **AND** 系统 MUST NOT 因外部负载而无限期饿死索引交付

#### Scenario: Load sampling is unavailable
- **WHEN** 宿主 CPU 统计不可读（平台不支持或采样失败）
- **THEN** 系统 SHALL 视为无压力并按既有 deadline 正常启动
- **AND** MUST NOT 因无法测量而永久阻塞交付

#### Scenario: Throttling is disabled by configuration
- **WHEN** 用户在配置中关闭 CPU 准入控制
- **THEN** 系统 SHALL 完全按既有 deadline 行为启动，不做负载判定
- **AND** 阈值与开关 SHALL 可通过既有配置机制调整
