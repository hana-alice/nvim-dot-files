## MODIFIED Requirements

### Requirement: IOS 平台策略必须由独立 target driver 实现

MUST：所有 IOS-specific UBT/UAT 参数、签名预检、产物识别、设备发现、安装与启动规则必须由 IOS target workflow owner 拥有；IOS target driver 只负责产出可验证的 structured plan 和 policy contract，generic runner 负责执行该 plan。核心调度层及其他 target driver 不得包含这些实现，也不得以 `lua/ue.lua` 的源码位置、行号、函数名或局部实现片段作为归属或验收锚点。

#### Scenario: 核心层分派 iOS Package

- **WHEN** 用户执行 `:UEPackageIOS`
- **THEN** 核心层必须通过 target registry 取得 IOS workflow owner 的 structured plan，并交给 generic runner 执行
- **AND** 核心层不得构造 BuildCookRun 参数、iOS artifact 路径或签名策略

#### Scenario: IOS 与 Mac 共享 macOS host tools

- **WHEN** IOS workflow owner 与 Mac driver 都使用 macOS host driver 提供的 executable/path primitive
- **THEN** IOS package/device/install/launch 策略必须只存在于 IOS workflow owner
- **AND** Mac driver 不得调用 IOS workflow owner 或保存 IOS 状态

#### Scenario: IOS 与 Android 都支持设备生命周期

- **WHEN** IOS 与 Android 都实现 device/install/launch capability
- **THEN** 两者必须分别拥有各自的 workflow owner、设备状态、命令规划、结果解析和错误语义
- **AND** 任一 owner 不得把另一 owner 作为 fallback

#### Scenario: 验收不得绑定源码位置

- **WHEN** 回归或评审验证 IOS workflow ownership
- **THEN** 断言必须基于 contract / behavior / plan output，而不是 `lua/ue.lua` 的行号、函数名或源码片段
- **AND** workflow controller 在不同文件间移动时，只要 contract 不变，结果必须保持一致

#### Scenario: 多个 driver 使用共享 helper

- **WHEN** target driver 共享 argv/path/schema/redaction helper
- **THEN** helper 必须无状态且不包含 target 选择、默认值、工具选择、设备或产物策略
- **AND** contract 测试必须检查该边界
