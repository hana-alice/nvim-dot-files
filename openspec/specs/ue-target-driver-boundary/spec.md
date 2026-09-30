# ue-target-driver-boundary Specification

## Purpose

把 host/target 的正交关系固定成可执行契约：host driver 只回答“当前宿主是什么、有哪些主机级
能力可用”，target driver 只回答“在这个宿主上，某个目标是否可行、应该走哪份计划”。
`host_operations` matrix 是兼容性的唯一真相，任何 host/target 可执行性判断都必须从这里出发，
不能回读 `ue.lua`、当前平台选择或别的 target 的默认值来猜测。这样 Android/iOS/Mac/Win64/Linux
的 target 规则可以独立演进，同时避免通用层把跨平台 fallback 当成“更聪明”的行为。

## Requirements

### Requirement: host/target 兼容性必须只看 `host_operations` matrix

SHALL：系统以 target driver 声明的 `host_operations` matrix 作为 host/target 兼容性的唯一判据；
`ue.lua`、通用 runner、当前平台 UI 状态或任何兄弟 target 的默认值 MUST NOT 参与兼容性推断。若
某个 host/target pair 未在 matrix 中声明，系统 MUST 明确报告该 pair 不兼容，不得隐式选择别的
target 或别的 backend。

#### Scenario: 未声明的 host/target pair 必须显式拒绝

- **WHEN** 当前宿主与请求的 target pair 未出现在 `host_operations` matrix 中
- **THEN** 系统 SHALL 立即拒绝该请求并返回不兼容原因
- **AND** MUST NOT 通过 sibling target、历史默认值或当前平台选择完成“自动修复”

### Requirement: target driver 只能产出纯 policy/plan，严禁跨 target fallback

SHALL：target driver 只负责纯 policy/plan——描述 build/prepare/package/install/launch/debug/
probe 所需的结构化步骤与约束，但 MUST NOT 直接执行异步任务、打开 UI、探测设备、挑选进程、写
进度条、触发 cleanup 或 mutate session state；任何可观察副作用必须由下游 workflow owner 或
runner 执行。系统 SHALL 保证 target driver 的规划结果不会因为“本 target 不可用”而自动跳到另一
个 target；一旦当前 target 的规划或能力缺失，系统 MUST 失败或返回显式不可用状态，任何跨 target
的恢复或降级都必须由上层明确选择，不能由 driver 自行兜底。

#### Scenario: driver 只返回结构化计划

- **WHEN** 上层向 target driver 请求一个可执行动作的规划
- **THEN** driver SHALL 只返回结构化 plan、约束与所需能力
- **AND** SHALL NOT 直接执行安装、启动、连接或设备枚举

#### Scenario: Android driver 缺失时不能改用 iOS driver

- **WHEN** 当前请求的 target 是 Android，但 Android driver 未声明该 host 的可用操作
- **THEN** 系统 SHALL 失败并报告 Android 不可用
- **AND** MUST NOT 复用 iOS driver、Mac driver 或其他 target 的 plan

### Requirement: Android SDK policy 必须经外部配置文件到达编译参数

SHALL：Android build 与 SO-only build 时，driver 在形成每份 plan 时都要重新加载外部 JSON SDK
policy（`ue.config` 的 `android.sdk_policy_file` 选择该文件，默认
`stdpath('state')/ue-android-sdk-policy.json`），其中包含项目相对 INI 路径、字段名与一个 UBT
disable argument。实际项目专属映射必须留在公开 worktree 之外；仓库代码、测试与文档 MUST NOT
编码、拼装或改写私有标识以绕过隐私扫描。显式值 `0` 时才追加该 disable argument；运行时配置本身
不能证明 Target 已排除 SDK 模块。缺失 policy/字段或值为 `1` 时必须保留 Target 既有默认值；
malformed policy 或读取失败（非文件缺失）必须返回不可用 plan 并附原因；元数据只暴露最终
`sdk_disabled` 布尔值，不暴露外部映射或 INI 内容。

#### Scenario: 运行时配置禁用 SDK

- **WHEN** 外部 policy 指出某字段在当前项目配置中的值为 `0`
- **THEN** 普通 build plan 必须包含该 policy 的实际 disable argument 作为一个参数
- **AND** SO-only plan 必须把同一编译决策转发进它的 UBT action-export 阶段

#### Scenario: Project 没有 SDK 专属配置

- **WHEN** 不存在外部 policy，或所选项目没有配置对应 INI 文件或字段
- **THEN** Android build 参数必须保留 Target 既有默认值，不写入任何 SDK 专属设置到项目

## 选型与踩坑

- **选型**：兼容性判据唯一来源是 `host_operations` matrix，不是 `ue.lua` 的隐式判断——这是把
  12,002 行单体中散落的平台分支收口的核心手段
  （出处：`openspec/changes/archive/2026-08-24-establish-ue-platform-workflow-boundaries/proposal.md`）。
- **选型**：Android SDK 私有映射放在公开镜像之外的机器本地 JSON（`android.sdk_policy_file`），
  仓库内只保留占位示例（`Config/SDK/Runtime.ini`、`UseSDK`、`-skip-project-sdk`），避免公开镜像
  泄漏真实工程私有标识。
- **踩坑**：K71（2026 迁移）— 运行时 SDK 设置本身不会让编译器禁用 SDK 模块，Target 在无参数时
  默认启用 SDK；准备脚本写入的文件并非 Target 真正消费者。必须核对实际 Target parser 与最终 UBT
  argv，普通/SO 构建都要把当前项目的禁用意图转成外部策略指定的单个编译参数，不能只以“环境设置
  成功”作为编译产物证据；迁移后的行为与隐私门禁必须重新验收，不能沿用迁移前的绿灯
  （出处：`docs/CONSTRAINTS.md` K71；`docs/release_1.11.2.md`）。
