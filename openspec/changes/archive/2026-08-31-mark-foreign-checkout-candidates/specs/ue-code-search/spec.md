## ADDED Requirements

### Requirement: File picker candidates SHALL make checkout ownership recognizable

同一台机器上常并存多个**同构 checkout**（相同的 `Source/<Proj>/Plugins/...` 层级、相同文件名），
它们仅在路径前缀的少数字符上不同。当 `shada` 的 oldfiles 等历史来源把其他 checkout 的路径混入
候选时，用户 MUST 能在候选列表里辨认出该候选不属于当前 pin 的项目。

已 pin 项目时，来自 pin 项目根与 engine 根**之外**的候选 SHALL 携带可见标记。归属判定 SHALL
复用系统既有的"是否属于当前项目"谓词，MUST NOT 另行实现一套可能漂移的判据。

默认 SHALL 保留这些候选（跨 checkout 查阅代码是正当用途）；系统 SHALL 提供配置将其降权或过滤，
但 MUST NOT 在未经配置的情况下静默丢弃候选。

未 pin 项目时不存在"外部"概念，系统 SHALL NOT 添加标记或改变候选顺序。

候选装饰位于 picker 热路径，其计算 SHALL 是廉价的字符串判定，MUST NOT 执行文件系统访问、
子进程或其他可能阻塞 UI 的操作（P6）。

#### Scenario: Sibling checkout appears in picker candidates
- **WHEN** 已 pin 某项目，且候选中包含另一个同构 checkout 的同名文件
- **THEN** 该候选 SHALL 带有可见标记，表明它不属于当前 pin 的项目
- **AND** 用户 SHALL 能在不逐字比对完整路径的情况下区分二者

#### Scenario: Candidate belongs to the pinned project or its engine
- **WHEN** 候选位于 pin 项目根或 engine 根之内
- **THEN** 该候选 SHALL NOT 被标记
- **AND** 其展示与排序 SHALL 保持不变

#### Scenario: No project is pinned
- **WHEN** 当前没有 pin 任何项目
- **THEN** 系统 SHALL NOT 标记任何候选，也 SHALL NOT 改变候选顺序

#### Scenario: User configures foreign candidates to be filtered
- **WHEN** 用户配置将 foreign 候选降权或过滤
- **THEN** 系统 SHALL 按配置降至列表末尾或排除
- **AND** 默认配置下 MUST NOT 丢弃任何候选
