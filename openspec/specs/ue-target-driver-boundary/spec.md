# ue-target-driver-boundary Specification

## Purpose
这个 capability 把 host/target 的正交关系固定成可执行契约：host driver 只回答“当前宿主是什么、有哪些主机级能力可用”，target driver 只回答“在这个宿主上，某个目标是否可行、应该走哪份计划”。`host_operations` matrix 由此成为兼容性的唯一真相，任何 host/target 可执行性判断都必须从这里出发，而不能再回读 `ue.lua`、当前平台选择、或别的 target 的默认值来猜测。这样一来，Android、iOS、Mac、Win64、Linux 的 target 规则可以独立演进，同时避免通用层把跨平台 fallback 当成“更聪明”的行为。

## Requirements

### Requirement: host/target 兼容性必须只看 `host_operations` matrix

系统 SHALL 以 target driver 声明的 `host_operations` matrix 作为 host/target 兼容性的唯一判据；`ue.lua`、通用 runner、当前平台 UI 状态或任何兄弟 target 的默认值 MUST NOT 参与兼容性推断。若某个 host/target pair 未在 matrix 中声明，系统 MUST 明确报告该 pair 不兼容，而不是隐式选择别的 target 或别的 backend。

#### Scenario: 已声明的 host/target pair 可以进入规划

- **WHEN** 当前宿主与请求的 target pair 出现在该 target driver 的 `host_operations` matrix 中
- **THEN** 系统 SHALL 允许继续进入该 target driver 的规划阶段
- **AND** 所得结果 SHALL 仅反映该 matrix 允许的 operation 集合

#### Scenario: 未声明的 host/target pair 必须显式拒绝

- **WHEN** 当前宿主与请求的 target pair 未出现在 `host_operations` matrix 中
- **THEN** 系统 SHALL 立即拒绝该请求并返回不兼容原因
- **AND** MUST NOT 通过 sibling target、历史默认值或当前平台选择完成“自动修复”

### Requirement: target driver 只能产出纯 policy/plan

系统 SHALL 让 target driver 只负责纯 policy/plan：它可以描述 build、prepare、package、install、launch、debug 或 probe 所需的结构化步骤与约束，但 MUST NOT 直接执行异步任务、打开 UI、探测设备、挑选进程、写进度条、触发 cleanup 或 mutate session state。任何可观察副作用都必须由下游 workflow owner 或 runner 执行。

#### Scenario: driver 只返回结构化计划

- **WHEN** 上层向 target driver 请求一个可执行动作的规划
- **THEN** driver SHALL 只返回结构化 plan、约束与所需能力
- **AND** SHALL NOT 直接执行安装、启动、连接或设备枚举

#### Scenario: driver 不能借通用层偷偷做副作用

- **WHEN** target driver 的实现需要读取文件、路径或候选工具信息
- **THEN** 这些读取 SHALL 只用于生成 plan 或 capability 结果
- **AND** driver MUST NOT 通过通用层启动异步 job、更新状态栏或修改当前会话

### Requirement: target driver 严禁跨 target fallback

系统 SHALL 保证 target driver 的规划结果不会因为“本 target 不可用”而自动跳到另一个 target；一旦当前 target 的规划或能力缺失，系统 MUST 失败或返回显式不可用状态。任何跨 target 的恢复、降级或兼容实现都必须由上层明确选择，不能由 driver 自行兜底。

#### Scenario: Android driver 缺失时不能改用 iOS driver

- **WHEN** 当前请求的 target 是 Android，但 Android driver 未声明该 host 的可用操作
- **THEN** 系统 SHALL 失败并报告 Android 不可用
- **AND** MUST NOT 复用 iOS driver、Mac driver 或其他 target 的 plan

#### Scenario: 同一请求不能因为平台切换而换 driver

- **WHEN** 一个请求已经绑定到某个 target driver
- **THEN** 该请求后续步骤 SHALL 继续使用同一个 driver 的规划结果
- **AND** MUST NOT 因当前平台选择变化而切换到另一个 driver
