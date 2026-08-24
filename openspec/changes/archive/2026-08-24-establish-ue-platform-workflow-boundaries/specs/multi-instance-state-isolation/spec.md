## ADDED Requirements

### Requirement: live workflow/session owners SHALL freeze across selection changes

当 build、prepare、deploy 或 launch workflow 开始时，系统 SHALL 冻结该 workflow 的 project、target、device serial 与 session owner；后续 live selection 变更 MUST NOT 改投、重绑或重新解释已经开始的 workflow、已持有的 lease，或正在发布的 artifact。新的 owner 只能由后续新 invocation 捕获。

#### Scenario: 运行中的 workflow 遭遇 live selection 变更

- **WHEN** 实例 A 正在执行一个已捕获 project/target/device/session owner 的 workflow，用户随后切换 live selection
- **THEN** 当前 workflow SHALL 继续使用最初捕获的 owner
- **AND** 当前 workflow MUST NOT 因新的 live selection 改投到其他 project、target 或 device

#### Scenario: 新 workflow 允许观察最新选择

- **WHEN** 前一个 workflow 已结束，且用户在此期间更新了 live selection
- **THEN** 下一次新的 workflow invocation SHALL 读取最新 live selection 作为新的 owner 捕获点
- **AND** 旧 workflow 的 owner 冻结状态 SHALL 不被重用到新任务
