## REMOVED Requirements

### Requirement: host OS 与 Unreal target platform 必须分层

**Reason**: 这条全局 host/target 分层契约已经由新的 `host-platform-driver` 与 `ue-target-driver-boundary` capability 接管；继续在本 spec 里重复会造成双真相与边界漂移。

**Migration**: 任何需要 host/target 分层的实现与测试都应改读新 capability specs；本 spec 只保留对 `UEPrepare`/semantic CDB 的用户行为契约，不再代管该边界。

### Requirement: 每个 Unreal target 的平台策略必须独立实现

**Reason**: target 专属平台策略、脚本归属与生命周期边界现在由新的 target driver / workflow capability 统一定义；将此约束继续挂在 semantic prepare spec 下会让 iOS/Mac/Android 的归属再次回流到单一文档。

**Migration**: 平台策略 ownership 迁移到新的 capability specs；本 spec 仅消费这些能力，不再声明各 target 的通用平台归属。

### Requirement: 核心调度层不得包含 target-specific 实现

**Reason**: `lua/ue.lua` 的 core/workflow 边界已由新的 `ue-target-workflow-boundary` 与相关 dispatch capability 承接；这条约束不应继续在 semantic prepare spec 中单独统管 core 归属。

**Migration**: 核心调度层与 target-specific workflow 的边界应由新 capability specs 和对应 contract tests 共同约束；本 spec 只关注 `UEPrepare` 的用户可见语义。

## MODIFIED Requirements

### Requirement: UEPrepare 不得触发编译但必须拥有 Apple semantic source 生成

MUST：`UEPrepare` 不得触发 compile、Cook、Package、Deploy 或 Run。对保留 response files 的 target，它必须继续只读转换已有证据；对 macOS 主机上声明 `semantic_cdb` capability 的 IOS target，它必须在确认当前 tuple 已有成功 build evidence 后，显式委托 iOS readiness workflow 完成 prepared signing、私钥访问与设备 route setup，再执行不包含 compile action 的 UBT `GenerateClangDatabase`，然后进入公共 CDB/index pipeline。该委托必须保持现有 `:UEPrepare` / `<leader>up` 的用户行为不变，不得改变 build/package/install/launch 语义。

#### Scenario: Apple target 缺少当前 tuple build evidence

- **WHEN** 当前 IOS tuple 没有成功 build evidence
- **THEN** `UEPrepare` 必须失败并建议先运行 `<leader>ub`
- **AND** 不得自动执行编译、Cook、Package、Deploy 或 Run

#### Scenario: 状态 marker 上线前已经成功构建

- **WHEN** project bucket 没有 Nvim build marker，但当前 tuple 存在精确匹配的 UBT `.target` receipt
- **AND** receipt 声明的 launch product 仍存在
- **THEN** `UEPrepare` 必须把该 receipt 迁移为 project-scoped build evidence 并继续
- **AND** 不得要求用户为补写 marker 重复执行相同构建

#### Scenario: 编译证据已存在

- **WHEN** 当前 tuple 存在有效 response files 或已验证的 tuple-scoped CDB source
- **THEN** `UEPrepare` 必须直接生成或复用 CDB
- **AND** 非 Apple target 不得仅为准备语义而触发 UBT

#### Scenario: 重复 prepare 复用当前 build 的 Apple semantic source

- **WHEN** project/uproject/target/platform/configuration 与 build completion evidence 均精确匹配
- **AND** 已验证的 tuple-scoped CDB source 路径、大小与纳秒 mtime 均未变化
- **THEN** `UEPrepare` 必须直接复用该 semantic source
- **AND** 不得再次启动 `Build.sh` 或 UnrealBuildTool
- **AND** 新 build evidence 或 source 文件签名变化后必须重新生成并验证

#### Scenario: IOS 首次 prepare 显式委托 readiness workflow

- **WHEN** 当前 IOS tuple 已有成功 build evidence，但 prepared signing、私钥访问或 device route setup 尚未完成
- **THEN** `UEPrepare` 必须先显式委托 iOS readiness workflow 完成这些前置条件
- **AND** readiness workflow 成功后才可继续 semantic source 生成
- **AND** 用户观察到的 `:UEPrepare` / `<leader>up` 行为必须与现有流程一致

#### Scenario: 其他平台执行 prepare

- **WHEN** 当前 target 不声明 `semantic_cdb` capability
- **THEN** `UEPrepare` 必须保持原有 response-file 路径
- **AND** 不得执行 IOS setup、Apple clangd prelude 或 `GenerateClangDatabase`
