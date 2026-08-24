# ue-target-workflow-boundary Specification

## Purpose

这个 capability 定义 target-specific 工作流的合法归属：凡是涉及异步执行、设备状态机、UI 反馈、进度展示、失败清理、会话冻结或 launch/install/debug 的运行时逻辑，都必须有明确的 workflow owner，而不能散落在 `ue.lua`、通用 runner 或 target driver 里。target driver 负责“怎么计划”，workflow owner 负责“怎么把计划安全地跑完”，通用 runner 负责“按计划执行”，三者之间的边界必须清晰可验证。这样可以避免一个入口文件同时承担命令 façade、平台政策和所有异步状态，从根上减少“端了这边忘了那边”的回流风险。

## ADDED Requirements

### Requirement: target-specific 异步与 UI 必须有 workflow owner

系统 SHALL 为任何 target-specific 的异步任务建立明确的 workflow owner；只要操作需要设备 serial、PID、签名身份、bundle、adapter、进度文本、错误清理或完成后的状态收束，就 MUST 由该 owner 负责。`ue.lua`、target driver 或 generic runner MUST NOT 直接承担这些 target-specific 状态机职责。

#### Scenario: iOS install 需要设备与进度状态

- **WHEN** 某个 iOS 安装或启动流程需要冻结 device、PID、bundle 与进度信息
- **THEN** 系统 SHALL 通过 iOS workflow owner 维护这些状态
- **AND** 该 owner SHALL 负责进度更新与失败清理

#### Scenario: Android launch 需要会话内设备锁定

- **WHEN** 某个 Android launch 流程开始并捕获了 device serial
- **THEN** 后续异步步骤 SHALL 继续使用同一个 workflow owner
- **AND** MUST NOT 把设备选择、UI 更新或清理逻辑分散到通用入口

### Requirement: generic runner 只能执行结构化计划

系统 SHALL 让 generic runner 仅消费已经形成的结构化 plan，并按顺序执行这些步骤；runner MUST NOT 自行决定平台工具、设备后端、错误策略、候选路径或跨 target fallback。若 plan 不完整、能力不支持或前置条件不满足，runner MUST 失败并把控制权交回 workflow owner 或上层调用者。

#### Scenario: runner 执行计划但不改计划

- **WHEN** generic runner 接收到一个已经完成的 structured plan
- **THEN** runner SHALL 仅按 plan 执行
- **AND** MUST NOT 在执行时擅自插入平台判断、工具重选或 backend 切换

#### Scenario: plan 缺失时必须显式失败

- **WHEN** workflow owner 提供的 plan 缺少必要步骤或能力
- **THEN** runner SHALL 明确失败并返回原因
- **AND** MUST NOT 用当前平台默认值补齐缺失步骤

### Requirement: `ue.lua` façade 不能拥有 target policy

系统 SHALL 把 `ue.lua` 限定为公共 API façade、命令注册、registry lookup 与通用 dispatch；它可以把用户请求路由到 target driver、workflow owner 或 runner，但 MUST NOT 内嵌 target-specific policy、设备状态机、路径选择、进度策略或 cleanup 策略。若对应 workflow 不存在，`ue.lua` MUST 明确报错，而不是合成一个隐式 fallback 流程。

#### Scenario: 命令入口只做路由

- **WHEN** 用户通过 `ue.lua` 暴露的命令触发某个 target 流程
- **THEN** `ue.lua` SHALL 只完成上下文解析与路由
- **AND** MUST NOT 自行决定设备、后端或安装/启动策略

#### Scenario: 缺少 workflow 时不得隐式降级

- **WHEN** 某个 target 的 workflow owner 未定义或不可用
- **THEN** `ue.lua` SHALL 显式失败
- **AND** MUST NOT 用通用 runner 伪造完整 target workflow

### Requirement: 活动工作流必须冻结其初始上下文

系统 SHALL 在 workflow 启动时冻结该次任务的 target、host、device、session owner、adapter 与其他必要上下文；随后即便用户切换当前平台、设备或其它 live selection，当前异步任务 MUST 继续使用已冻结的上下文。新的选择只影响后续新工作流，不能回写当前任务。

#### Scenario: 活动任务不被新选择抢占

- **WHEN** 一个 workflow 已经开始，而用户随后切换了当前 platform 或 device
- **THEN** 该 workflow SHALL 继续使用启动时捕获的上下文
- **AND** MUST NOT 被重新路由到新的选择

#### Scenario: 后续任务可以使用新上下文

- **WHEN** 前一个 workflow 已结束，用户又发起新的 target 流程
- **THEN** 新 workflow SHALL 读取新的当前选择作为起点
- **AND** 不得继承已结束工作流的冻结上下文
