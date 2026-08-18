# ios-build-run-workflow Specification

## Purpose

定义 macOS 宿主构建、打包、安装并启动 Unreal iOS 应用的端到端契约。该能力与 Neovim/clangd 语义准备相互独立。

## Requirements

### Requirement: iOS 应用流水线必须与编辑器语义准备分离

MUST：系统必须把 iOS Build/Package/Install/Launch 作为应用生命周期能力；不得将其作为生成 CDB 或 Tree-sitter 解析的隐式副作用。

#### Scenario: 用户只打包 iOS 应用

- **WHEN** 用户执行 `:UEPackageIOS`
- **THEN** 系统必须执行配置的 UAT 应用流水线
- **AND** 不得生成、切换或刷新 clangd 编译数据库

#### Scenario: 用户只准备语义上下文

- **WHEN** 用户执行 `:UEPrepare`
- **THEN** 系统不得 Cook、Package、Install 或 Launch iOS 应用

### Requirement: IOS 平台策略必须由独立 target driver 实现

MUST：所有 IOS-specific UBT/UAT 参数、签名预检、产物识别、设备发现、安装与启动规则必须由 IOS target-driver 模块拥有；核心调度层及其他 target driver 不得包含这些实现。

#### Scenario: 核心层分派 iOS Package

- **WHEN** 用户执行 `:UEPackageIOS`
- **THEN** 核心层必须通过 target registry 调用 IOS driver 的统一 contract
- **AND** 核心层不得构造 BuildCookRun 参数、iOS artifact 路径或签名策略

#### Scenario: IOS 与 Mac 共享 macOS host tools

- **WHEN** IOS driver 与 Mac driver 都使用 macOS host driver 提供的 executable/path primitive
- **THEN** IOS package/device/install/launch 策略必须只存在于 IOS driver
- **AND** Mac driver 不得调用 IOS driver 或保存 IOS 状态

#### Scenario: IOS 与 Android 都支持设备生命周期

- **WHEN** IOS 与 Android 都实现 device/install/launch capability
- **THEN** 两者必须分别拥有设备状态、命令规划、结果解析和错误语义
- **AND** 任一 driver 不得把另一 driver 作为 fallback

#### Scenario: 多个 driver 使用共享 helper

- **WHEN** target driver 共享 argv/path/schema/redaction helper
- **THEN** helper 必须无状态且不包含 target 选择、默认值、工具选择、设备或产物策略
- **AND** contract 测试必须检查该边界

### Requirement: iOS 编译必须最终使用 macOS 原生 Unreal 入口

MUST：当 active platform 为 `IOS` 时，`UEBuild` 与 `UEBuildIOS` 必须使用 macOS `Build.sh` 规划当前 target/configuration 的 UBT 编译。

#### Scenario: 只编译 IOS target

- **WHEN** 用户执行 `:UEBuildIOS` 且工程上下文有效
- **THEN** 系统必须以 argv 数组通过 Nvim-owned macOS wrapper 最终调用 `Engine/Build/BatchFiles/Mac/Build.sh`
- **AND** 不得包含 Cook、Stage、Package、Archive、Install 或 Run 阶段
- **AND** 不得调用 Windows `.exe`、PowerShell 或 Windows path converter

#### Scenario: Build.sh 对引擎退出码执行兼容映射

- **WHEN** macOS `Build.sh` 按其内部兼容规则返回成功
- **THEN** 调用方必须把包装脚本结果作为 build 进程状态
- **AND** 不得在 Neovim 层重新解释未直接暴露的原始 UBT 状态码

#### Scenario: 通用构建快捷键选择 IOS

- **WHEN** active platform 为 `IOS` 且用户执行 `<leader>ub` / `:UEBuild`
- **THEN** IOS driver 交给 `Build.sh` 的 argv 必须依次包含 target、`IOS`、configuration、
  `-Project=<UPROJECT>`、`-WaitMutex`、`-FromMsBuild` 与 `-disablev8pointercompression`
- **AND** `-disablev8pointercompression` 必须由 IOS target policy 拥有，不得从共享 host/core 层
  泄漏到 Mac、Win64、Linux 或 Android target

### Requirement: iOS C++ 日常编译必须安全复用 AOT 并延后 dSYM

MUST：Nvim 可以通过构建环境复用工程既有的 AOT 产物，但只有输入、SDK/工具链与上次成功产物均可证明未变时才允许跳过 AOT。日常编译必须通过命令行 override 关闭自动 dSYM；符号必须由独立命令按需生成。

#### Scenario: 首次构建或 AOT 输入变化

- **WHEN** AOT cache manifest 不存在、任一输入指纹变化、工具链/SDK 变化或记录的 framework 缺失
- **THEN** wrapper 必须清除继承的 skip/disable AOT 环境并执行完整 AOT
- **AND** 只有原生构建成功且 framework 产物存在后才可原子发布新 manifest

#### Scenario: AOT 输入与产物均可证明未变

- **WHEN** 当前指纹与上次成功 manifest 一致，且全部记录产物的路径与内容 hash 均匹配
- **THEN** wrapper 可以仅为当前 build 子进程设置 `bSkipAOTProcess=true`
- **AND** cache 状态必须写在 engine `.cache/nvim-ue`，不得修改工程或引擎代码

#### Scenario: 日常 C++ 编译

- **WHEN** 用户执行 `:UEBuildIOS`
- **THEN** Build.sh argv 必须稳定关闭 `bGeneratedSYMFile` 与 `bGeneratedSYMBundle`
- **AND** 不得关闭对象文件中的编译调试信息

#### Scenario: 用户需要符号化

- **WHEN** 用户执行 `:UEIOSSymbols`
- **THEN** 系统必须对当前 tuple 的 IOS binary 运行 `dsymutil`，且不生成 ZIP
- **AND** 必须用 `dwarfdump --uuid` 验证 binary 与 dSYM UUID 集合一致

### Requirement: iOS 本地组包必须使用既有 cooked 数据

MUST：`UEPackageIOS` 必须通过 macOS `RunUAT.sh BuildCookRun` 复用已存在的 cooked 数据，只执行 Stage 与 Package。该本地 C++ 迭代入口不得触发 Build、Cook、Archive、Deploy 或 Run。

#### Scenario: 规划 Development 包

- **WHEN** 当前 target、IOS platform、Development configuration 与既有 cooked 数据均有效
- **THEN** 计划必须包含 `-project`、`-target`、`-targetplatform=IOS`、`-clientconfig=Development`、`-skipbuild`、`-skipcook`、`-stage`、`-nocleanstage`、`-package` 与 `-nodebuginfo`
- **AND** 必须使用 argv 数组而非 shell 拼接
- **AND** 工程身份和路径不得硬编码在实现中
- **AND** 不得包含 `-build`、`-cook`、`-archive`、`-deploy` 或 `-run`

#### Scenario: UAT 打包失败

- **WHEN** UAT 返回非零退出码或所需 staged app 未产生
- **THEN** 系统必须将 package 标记为 failed 并显示失败阶段
- **AND** 不得自动继续安装或启动

### Requirement: 签名与工具链必须只读预检

MUST：系统必须按阶段检查 iOS 工具链：Build 前检查 Xcode、iPhoneOS SDK、引擎自带 dotnet 与原生编译入口；Package/Install 前额外检查 code-sign identity、工程 iOS settings 与 UBT/UAT provisioning 推导可解析性。

#### Scenario: 没有有效签名身份但只执行编译

- **WHEN** Xcode 与 SDK 可用、没有有效 code-sign identity，且用户只执行 `:UEBuildIOS`
- **THEN** 系统必须允许不依赖签名的编译阶段继续
- **AND** 必须将 Package/Install 的签名 gate 标记为未满足

#### Scenario: 没有有效签名身份且准备打包

- **WHEN** keychain 中没有有效 code-sign identity 且用户执行需要签名的 Package/Install 阶段
- **THEN** 系统必须在需要签名的阶段前失败并列出缺失条件和人工修复方向
- **AND** 不得自动导入证书、读取私钥密码或修改工程签名配置

#### Scenario: SDK 或 Xcode 不可用

- **WHEN** developer directory 或 iPhoneOS SDK 探测失败
- **THEN** 系统必须停止当前任务并报告探测结果
- **AND** 不得回退到 Windows 或未知工具链

### Requirement: 设备发现必须使用结构化 devicectl 输出

MUST：`UESetIOSDevice` 必须从 devicectl JSON 文件输出中选择可用物理 iOS 设备，不得解析面向人的表格文本，也不得调用 UE legacy fastlane 设备发现。

#### Scenario: 存在多个可用设备

- **WHEN** JSON 结果包含多个可用物理 iOS 设备
- **THEN** 系统必须允许用户按非敏感显示信息选择
- **AND** 必须保存稳定 device identifier，而不是依赖名称匹配

#### Scenario: 没有可用设备

- **WHEN** 结果为空或所有设备均 unavailable
- **THEN** 系统必须阻止 install/launch 并报告 no available iOS device
- **AND** 不得选择历史设备或自动 fallback

### Requirement: 单次设备任务必须固定目标设备

MUST：Install 或 Launch 必须在任务开始时捕获一次 selected device identifier，并在整个任务中保持不变。

#### Scenario: 全局设备选择在安装期间改变

- **WHEN** install 已开始后用户选择另一设备
- **THEN** 当前 install 必须继续使用开始时捕获的 identifier
- **AND** 新选择只影响后续任务

### Requirement: 安装产物必须与当前 tuple 一致

MUST：系统必须安装当前 project/target/IOS/configuration 对应的 staged `.app`，并从其 `Info.plist` 读取真实 bundle identifier。

#### Scenario: 磁盘存在多个配置的 app

- **WHEN** Development 与 Shipping stage 目录都存在
- **THEN** 系统必须选择当前 configuration 且 provenance 可证明的 `.app`
- **AND** 不得仅按修改时间选择最新文件

#### Scenario: 只有 IPA 没有 staged app

- **WHEN** 当前 tuple 只有 `.ipa` 而没有可验证的 staged `.app`
- **THEN** 默认 devicectl 安装后端必须拒绝安装并建议重新 stage/package
- **AND** 不得静默切换到第三方 IPA 安装器

### Requirement: 安装必须由设备结果确认

MUST：`UEInstallIOS` 以及 active target 为 IOS 时的 `<Space>ui` / `UEInstall` 必须使用外置 `xcrun devicectl device install app --device <CAPTURED_ID> <APP>` 后端，并以退出码和结构化结果共同判定成功；不得调用或静默回退到 UE legacy ideviceinstaller 后端。

#### Scenario: 通用安装键在 IOS target 下原地更新

- **WHEN** active target 为 IOS 且用户执行 `<Space>ui` / `UEInstall`
- **THEN** 系统必须把操作分派到 IOS target driver，并安装当前 tuple 已签名的 staged `.app`
- **AND** 安装计划不得先执行 uninstall、delete 或 remove；不得重签名或清除既有应用数据
- **AND** 系统不得把该操作分派到 Android APK 安装链

#### Scenario: devicectl 报告安装成功

- **WHEN** devicectl 返回零退出码且结构化结果确认目标设备和 bundle
- **THEN** 系统必须把 install 标记为 succeeded 并记录脱敏证据

#### Scenario: 命令退出零但结果身份不匹配

- **WHEN** devicectl 退出码为零但返回设备或应用身份与任务不一致
- **THEN** 系统必须把 install 标记为 failed
- **AND** 不得继续 launch

### Requirement: 启动必须使用真实 bundle identifier 且不进入 DAP

MUST：IOS `UELaunch` 必须使用捕获设备和 staged app 的实际 bundle identifier 调用 devicectl process launch；不得调用 UE legacy instruments Run 后端。

#### Scenario: 应用成功启动

- **WHEN** devicectl 返回零退出码且结构化结果确认 bundle 已启动并提供进程证据
- **THEN** 系统必须把 launch 标记为 succeeded
- **AND** 不得自动调用 `UEDAPAttach`

#### Scenario: 只存在 macOS PID attach 能力

- **WHEN** 用户启动 IOS 应用但原生 iOS DAP 尚未实现
- **THEN** 系统必须只报告 run 结果
- **AND** 不得把 macOS PID attach 伪装成 iOS 真机调试

### Requirement: iOS 长任务必须异步、可取消且不误报成功

MUST：Build、Package、Install 与 Launch 必须使用非阻塞任务生命周期，并按依赖顺序阻止失败后的下游阶段。

#### Scenario: 用户取消 Package

- **WHEN** UAT 任务被取消
- **THEN** 系统必须标记 cancelled 并终止后续 Install/Launch
- **AND** 不得将磁盘上的旧产物标记为本次成功结果

#### Scenario: 外部真机 gate 尚未满足

- **WHEN** 自动测试通过但没有有效签名身份或可用设备
- **THEN** 系统必须把真实 E2E 标记为 blocked/not-run
- **AND** 不得宣称 Build → Package → Install → Launch 已端到端通过

### Requirement: iOS 状态与日志必须保护秘密

MUST：系统可以记录脱敏 argv、阶段、退出码、设备显示名与 artifact identity，但不得记录私钥、密码、完整个人证书身份或未脱敏用户路径。

#### Scenario: 预检读取签名配置

- **WHEN** 系统生成诊断或日志
- **THEN** 必须仅展示判断所需的脱敏字段
- **AND** 不得持久化密码、私钥内容或敏感环境变量
