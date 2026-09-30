# ue-target-workflow-boundary Specification

## Purpose

定义 target-specific 工作流的合法归属：涉及异步执行、设备状态机、UI 反馈、进度展示、失败清理、
会话冻结或 launch/install/debug 运行时逻辑的部分，都必须有明确的 workflow owner，不能散落在
`ue.lua`、通用 runner 或 target driver 里。target driver 负责“怎么计划”，workflow owner 负责
“怎么把计划安全地跑完”，通用 runner 负责“按计划执行”，三者边界必须清晰可验证，避免入口文件
同时承担命令 façade、平台政策和所有异步状态。

## Requirements

### Requirement: target-specific 异步与 UI 必须有明确 workflow owner

SHALL：任何 target-specific 的异步任务都必须建立明确的 workflow owner；只要操作需要设备 serial、
PID、签名身份、bundle、adapter、进度文本、错误清理或完成后的状态收束，就 MUST 由该 owner 负责。
`ue.lua`、target driver 或 generic runner MUST NOT 直接承担这些 target-specific 状态机职责。

#### Scenario: iOS install 需要设备与进度状态

- **WHEN** 某个 iOS 安装或启动流程需要冻结 device、PID、bundle 与进度信息
- **THEN** 系统 SHALL 通过 iOS workflow owner 维护这些状态，该 owner 负责进度更新与失败清理

### Requirement: generic runner 只能执行结构化计划，`ue.lua` 不能拥有 target policy

SHALL：generic runner 仅消费已形成的结构化 plan 并按顺序执行；runner MUST NOT 自行决定平台
工具、设备后端、错误策略、候选路径或跨 target fallback，plan 不完整或前置条件不满足时 MUST
显式失败并把控制权交回 workflow owner 或上层调用者。`ue.lua` 限定为公共 API façade、命令注册、
registry lookup 与通用 dispatch；它可以路由请求到 target driver/workflow owner/runner，但
MUST NOT 内嵌 target-specific policy、设备状态机、路径选择、进度策略或 cleanup 策略；对应
workflow 不存在时 MUST 明确报错，不得合成隐式 fallback 流程。

#### Scenario: plan 缺失时必须显式失败

- **WHEN** workflow owner 提供的 plan 缺少必要步骤或能力
- **THEN** runner SHALL 明确失败并返回原因，MUST NOT 用当前平台默认值补齐缺失步骤

#### Scenario: 缺少 workflow 时不得隐式降级

- **WHEN** 某个 target 的 workflow owner 未定义或不可用
- **THEN** `ue.lua` SHALL 显式失败，MUST NOT 用通用 runner 伪造完整 target workflow

### Requirement: 活动工作流必须冻结其初始上下文

SHALL：workflow 启动时冻结该次任务的 target、host、device、session owner、adapter 与其他必要
上下文；随后即便用户切换当前平台、设备或其它 live selection，当前异步任务 MUST 继续使用已冻结的
上下文，新的选择只影响后续新工作流，不能回写当前任务。

#### Scenario: 活动任务不被新选择抢占

- **WHEN** 一个 workflow 已经开始，而用户随后切换了当前 platform 或 device
- **THEN** 该 workflow SHALL 继续使用启动时捕获的上下文，MUST NOT 被重新路由到新的选择

### Requirement: 外部分布式构建必须捕获当前实例并保护敏感配置

SHALL：opt-in 的 `UEBuildDistributed [Android] [Development]` 通过既有 build planner 捕获当前
实例的 engine/project workspace/uproject/target/configuration；省略参数使用当前选择，覆盖只
应用于本次调用。外部脚本路径通过 `vim.g.ue_builddispatch_script`、`NVIM_UE_BUILDDISPATCH` 或
机器本地 JSON（`stdpath('data')/ue-builddispatch.json`）配置，私有路径与 worker 地址 MUST NOT
嵌入公开配置；三者优先级为编辑器 global > 环境变量 > 本地 JSON，新编辑器实例 MUST NOT 仅依赖
继承的环境变量。Android workflow owner 通过 stdin 发送不可变 JSON snapshot 给外部 Python
runner；环境捕获限于 Android toolchain roots 与非敏感 P4 client/config 标识，tickets 与
passwords MUST NOT 被导出。

#### Scenario: 一个新编辑器继承了过期的环境变量

- **WHEN** 编辑器没有配置的 script global 或环境变量，但其机器本地 JSON 包含脚本位置
- **THEN** invocation SHALL 解析持久化的脚本位置，不改变公开仓库

#### Scenario: 查看计划但不改变构建产物

- **WHEN** 用户执行 `UEBuildDistributedPlan`
- **THEN** workflow SHALL 用同一份已捕获上下文附加 `--dry-run`
- **AND** SHALL NOT 执行 build preflight、导出 UBT actions、同步文件或编译

## 选型与踩坑

- **选型**：target driver 只产出 policy/plan，workflow owner 负责运行时状态机，generic runner
  只负责按计划执行——三层分离是为了阻止 `lua/ue.lua` 继续膨胀成同时承担命令 façade、平台策略和
  全部异步状态的单体
  （出处：`openspec/changes/archive/2026-08-24-establish-ue-platform-workflow-boundaries/proposal.md`）。
- **选型**：分布式构建的 worker 地址与私有路径放在机器本地 JSON
  （`stdpath('data')/ue-builddispatch.json`）而非仓库配置，避免公开镜像泄漏内网 worker 信息；
  新编辑器实例通过该文件而不是继承的环境变量拿到脚本位置。
- **重要事项**：验收测试已从“源码位置型”（按 `ue.lua` 行号/函数名锁定）迁移为 driver/workflow
  contract 与行为测试，并新增 AST/结构化架构回归，阻止通用层出现直接 OS probe、target literal
  executable branch、target-specific script/path/backend/error policy 或跨 target fallback；
  `ue.lua` 引入只减不增的存量行数 ratchet，新 workflow 模块仍遵守既有 800 行上限。
