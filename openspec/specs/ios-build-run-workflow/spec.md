# ios-build-run-workflow Specification

## Purpose

定义 macOS 宿主构建、打包、安装并启动 Unreal iOS 应用的端到端契约：Build → Package →
Install → Launch 的应用生命周期。该能力与 Neovim/clangd 语义准备（`macos-ios-cdb-semantic-prepare`）
相互独立——打包不生成 CDB，准备语义不打包/安装/启动应用。IOS 平台专属策略（签名、设备发现、
安装/启动规则）归 IOS target driver/workflow owner 独立所有，不归核心调度层。

## Requirements

### Requirement: iOS 应用生命周期必须与编辑器语义准备分离

MUST：iOS Build/Package/Install/Launch 必须是独立的应用生命周期能力，不得作为生成 CDB 或
Tree-sitter 解析的隐式副作用；反之 `:UEPrepare` 不得 Cook/Package/Install/Launch。

#### Scenario: 用户只打包 iOS 应用

- **WHEN** 用户执行 `:UEPackageIOS`
- **THEN** 系统必须执行配置的 UAT 应用流水线
- **AND** 不得生成、切换或刷新 clangd 编译数据库

### Requirement: IOS 平台策略必须由独立 target driver 拥有

MUST：所有 IOS-specific UBT/UAT 参数、签名预检、产物识别、设备发现、安装与启动规则必须由
IOS target/workflow owner 拥有；IOS target driver 只产出结构化 plan，generic runner 负责执行。
核心调度层与其他 target driver 不得包含这些实现；验收必须基于 contract/behavior/plan output，
不得以 `lua/ue.lua` 的源码位置、行号或函数名作为归属或验收锚点。

#### Scenario: 核心层分派 iOS Package

- **WHEN** 用户执行 `:UEPackageIOS`
- **THEN** 核心层必须通过 target registry 取得 IOS owner 的 structured plan 并交给 generic runner 执行
- **AND** 核心层不得构造 BuildCookRun 参数、iOS artifact 路径或签名策略

### Requirement: iOS 编译与本地打包必须复用宿主原生 UBT/UAT 产物

MUST：iOS 编译最终必须使用 macOS `Engine/Build/BatchFiles/Mac/Build.sh` 规划当前 tuple 的
UBT 增量编译，不得调用 Windows `.exe`、PowerShell 或 Windows path converter。日常编译不得用
`-SkipBuild` 代替增量编译；AOT 复用、自动 dSYM 跳过与本地打包（复用已有 cooked 数据）各自只能
按独立证据判定，任一证据失效不得污染其他阶段。

#### Scenario: 只编译 IOS target

- **WHEN** 用户执行 `:UEBuildIOS` 且工程上下文有效
- **THEN** 系统必须以 argv 数组通过 Nvim-owned macOS wrapper 调用 `Build.sh`
- **AND** 不得包含 Cook、Stage、Package、Archive、Install 或 Run 阶段

#### Scenario: 本地增量 package

- **WHEN** 当前 tuple 已有成功 build 与明确可复用的 cooked data
- **THEN** `:UEPackageIOS` 必须使用 `-skipbuild -skipcook -stage -nocleanstage -package -nodebuginfo`
- **AND** release/distribution 的 clean pipeline 不得复用该 local-iteration 假设

### Requirement: 签名与设备识别必须非破坏且精确匹配当前身份

MUST：签名身份选择（`:UESetIOSSigningCertificate[!]`）必须精确匹配单一 identity，并通过 Nvim
自有临时 Mach-O 证明该私钥可被非交互 `/usr/bin/codesign` 使用；不得仅验证“至少有一张有效证书”、
静默选择第一张、自动导入证书或读取私钥密码。设备选择（`:UESetIOSDevice`）必须合并 devicectl
CoreDevice 与 `idevice_id` 的实时 MobileDevice（USB/Wi-Fi）结果；已保存设备离线时必须进入
picker 而不能自动改选另一台。单次 Install/Launch 任务必须在开始时冻结 selected device，安装的
`.app` 必须与当前 tuple 一致，且必须由外置 `devicectl` 的退出码与结构化结果共同确认成功。

#### Scenario: 证书可枚举但私钥不能用于非交互签名

- **WHEN** `security find-identity` 能找到 identity，但临时 Mach-O 真实签名返回
  `errSecInternalComponent` 或其他私钥访问错误
- **THEN** 后续 build/install 必须在重签工程 artifact 前失败，且必须指向 login keychain 与
  `/usr/bin/codesign` 的持久访问权限，不得误报成 device/artifact 问题

#### Scenario: 已保存设备离线但存在其他实时设备

- **WHEN** Install/Launch 保存的 UDID 不在实时 USB/Wi-Fi/CoreDevice 结果中
- **THEN** picker 必须同时展示实时候选与带 `saved, offline` 标记的保存设备
- **AND** 系统不得自动切换到唯一的其他设备

### Requirement: 启动必须使用真实 bundle identifier 且不得进入 DAP

MUST：`UELaunch` 必须使用捕获设备和已安装 app 的真实 bundle identifier；CoreDevice 与
pre-iOS17 legacy backend 均不得调用 UE legacy Run 后端或自动进入 DAP。

#### Scenario: 普通启动与真机调试均可用

- **WHEN** 用户执行 `:UELaunch`，且当前宿主同时支持原生 iOS DAP
- **THEN** 系统必须只报告 run 结果，不得自动 start-stopped 或进入 DAP
- **AND** 真机调试必须通过独立 `:UEDAPLaunch ios` / `:UEDAPAttach ios` 入口执行

#### Scenario: 只存在 macOS PID attach 能力

- **WHEN** 当前宿主没有满足条件的原生 iOS 真机调试能力
- **THEN** 普通启动必须只报告 run 结果，不得把 macOS PID attach 伪装成 iOS 真机调试

### Requirement: 长任务必须异步、可取消、不误报成功，且日志脱敏

MUST：Build/Package/Install/Launch 必须使用非阻塞任务生命周期，按依赖顺序阻止失败后的下游
阶段；日志可记录脱敏 argv、阶段、退出码与设备显示名，不得记录私钥、密码或完整个人证书身份。

#### Scenario: 外部真机 gate 尚未满足

- **WHEN** 自动测试通过但没有有效签名身份或可用设备
- **THEN** 系统必须把真实 E2E 标记为 blocked/not-run，不得宣称端到端已通过

## 选型与踩坑

- **选型**：IOS package/device/install/launch policy 归 IOS target/workflow owner 独立所有，
  不绑定 `lua/ue.lua` 源码位置——防止 workflow controller 移动文件后回归失效
  （出处：`openspec/changes/archive/2026-08-24-establish-ue-platform-workflow-boundaries/proposal.md`）。
- **选型**：本地增量 package 复用已有 cooked data（`-skipbuild -skipcook`），不是 clean release
  流水线的替代——两者假设不可互换。
- **踩坑**：pre-iOS17 USB 设备在 devicectl 无 CoreDevice tunnel 时仍必须用 MobileDevice 实时结果
  构造 picker，不能要求设备支持不存在的 CoreDevice tunnel。
- **踩坑**：签名身份校验不能止步于“keychain 里有一张有效证书”，必须用临时 Mach-O 证明私钥可被
  非交互 `codesign` 使用；`errSecInternalComponent` 等错误的根因通常是 keychain 访问权限，不是
  设备或产物问题。
- **重要事项**：`UELaunch` 保持普通 run 语义；已实现的原生 iOS DAP 使用独立入口，相关调试能力见
  `ios-device-debug-workflow`。真机 E2E 需要有效签名身份和可用设备，CI 无真机时必须报告
  blocked/not-run，不能靠 headless fixture 冒充通过。
