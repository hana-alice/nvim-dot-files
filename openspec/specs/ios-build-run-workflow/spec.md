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

MUST：日常 iOS C++ 编译必须继续调用 Build.sh，让 UBT 的当前 target makefile/action graph 判定
C++ compile/link actions；不得用 `-SkipBuild` 代替增量编译。AOT、自动 dSYM、Package Build/Cook 与
clean-stage 只能按各自独立证据跳过，任一证据失效不得污染其他阶段的判定。

#### Scenario: 只修改一个 C++ implementation 文件

- **WHEN** 用户执行 `:UEBuildIOS`，且只有当前 tuple 的部分 C++ action 过期
- **THEN** wrapper 必须调用 Build.sh 并让 UBT 执行过期 action、复用未变化 action
- **AND** 不得向该 build 添加 `-SkipBuild`

#### Scenario: AOT 输入与上次成功输出均可证明未变

- **WHEN** 当前 tuple、SDK/toolchain、全部 AOT 输入与上次成功 framework manifest 匹配
- **THEN** wrapper 可以只为当前 build 子进程设置 `bSkipAOTProcess=true`
- **AND** 只有 path/device/inode/size/mtime/ctime 全部未变化时，才可以复用输入的已记录 content hash
- **AND** 必须继续验证全部记录的 output artifact

#### Scenario: AOT 输入 metadata 变化或证据不完整

- **WHEN** 任一输入 path/size/mtime 变化、cache/manifest 缺失、工具链变化或 output 校验失败
- **THEN** wrapper 必须重新计算对应输入 content hash
- **AND** cache miss 必须清除继承的 skip/disable AOT 环境并执行完整 AOT
- **AND** 只有原生构建成功且 framework 产物完整后才可原子发布新 manifest

#### Scenario: 日常 build 不需要 dSYM

- **WHEN** 用户执行 `:UEBuildIOS`
- **THEN** Build.sh argv 必须稳定关闭自动 dSYM 与 dSYM bundle/ZIP
- **AND** 不得关闭 object file 中的编译调试信息
- **AND** `:UEIOSSymbols` 必须按需生成 dSYM 并验证 binary/dSYM UUID

#### Scenario: 本地增量 package

- **WHEN** 当前 tuple 已有成功 build 与明确可复用的 cooked data
- **THEN** `:UEPackageIOS` 必须使用 `-skipbuild -skipcook -stage -nocleanstage -package -nodebuginfo`
- **AND** 不得执行 Build、Cook、Archive、Deploy 或 Run
- **AND** release/distribution 的 clean pipeline 不得复用该 local-iteration 假设

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

### Requirement: 签名与工具链必须非破坏预检

MUST：系统必须按阶段检查 iOS 工具链，并提供 `:UESetIOSSigningCertificate[!] [identity]` 从当前
macOS keychain 的有效 code-sign identities 中为当前 project 显式选择、直接设置或清除签名证书。
无参数命令在 `PrepareIOSQADebug.sh` 已为当前 workspace 写入 `Saved/IOSQADebug/signing.json` 时，
必须优先导入其中的精确 identity；没有该 manifest 时才显示 picker。
Build 在存在显式选择时必须捕获并复验它；Package/Install/debug 必须要求、捕获并精确复验所选
identity。系统不得仅验证“至少有一张有效证书”，不得静默选择第一张，也不得自动导入证书、读取
私钥密码或修改工程签名配置。

IOS `:UEPrepare` 必须把一次性 Nvim 配置收敛为其 Apple 前置分支：导入 prepared identity、
使用 Nvim 自有临时 Mach-O 实际证明非交互 `/usr/bin/codesign` 能使用对应私钥、选择当前唯一可用设备，
并在 legacy backend 下验证 branch helper 存在。私钥探针不得修改工程、prepared app、keychain 或设备，
且必须无条件清理临时副本。`:UEIOSSetup` MAY 保留为显式重跑/诊断入口，但不得成为正常流程的必需步骤。

#### Scenario: 一次性配置通过后进入日常循环

- **WHEN** 用户已成功运行 `PrepareIOSQADebug.sh` 与 `InstallIOSClient.sh`，设置 project/IOS target、
  完成 `<leader>ub`，随后执行 `:UEPrepare`
- **THEN** 系统必须精确导入 prepared identity，并在只有一台可用设备时自动保存
  device identifier 与 backend
- **AND** 必须通过真实临时签名证明私钥可由非交互 `/usr/bin/codesign` 使用后才报告 ready
- **AND** legacy backend 必须在报告 ready 前验证 branch 对应 `InstallIOSClient.sh` 存在且可执行
- **AND** setup 成功后必须继续生成 Apple semantic CDB 并完成公共 prepare pipeline
- **AND** 正常流程必须收敛为 project/platform 任意顺序 → `<leader>ub` → `:UEPrepare` → `<leader>ui`

#### Scenario: 证书可枚举但私钥不能用于非交互签名

- **WHEN** `security find-identity` 能精确找到 prepared identity，但临时 Mach-O 的真实签名返回
  `errSecInternalComponent`、interaction-not-allowed 或其他私钥访问错误
- **THEN** `:UEIOSSetup`、显式签名选择及后续已配置 build/install 必须在重签工程 artifact 前失败
- **AND** 不得保存新的已验证选择、修改 app 或触碰设备
- **AND** 错误必须指向 login keychain 与 `/usr/bin/codesign` 的持久访问权限，不得把它误报成 device/artifact 问题

#### Scenario: Setup 缺少 prepared 清单

- **WHEN** 用户执行 `:UEIOSSetup`，但当前 workspace 没有有效的 prepared signing manifest
- **THEN** setup 必须 fail closed 并指向 `PrepareIOSQADebug.sh`
- **AND** 不得退回通用 signing picker；通用 `:UESetIOSSigningCertificate` 仍可保留 picker 行为

#### Scenario: Setup 异步期间上下文或状态失效

- **WHEN** signing/device 探测期间 active project 发生切换，或 project-scoped runtime state 无法原子落盘
- **THEN** setup 必须中止且不得把结果写入另一个 project
- **AND** device/package/install/launch 不得在状态写入失败后报告 selected、ready、installed 或 launched

#### Scenario: 无参数复用 PrepareIOSQADebug 签名

- **WHEN** 用户执行 `:UESetIOSSigningCertificate`
- **AND** 当前 project 或 `workspace/Source/SampleGame` 布局的 workspace 已存在
  `Saved/IOSQADebug/signing.json`
- **THEN** 系统必须验证 manifest version、完整 identity、仍存在的 profile、Bundle/Team 字段与
  `get-task-allow=true`
- **AND** 必须在当前 keychain 中精确复验 manifest 的 SHA-1 与显示名后保存为 project-scoped identity
- **AND** 必须先用自有临时 Mach-O 证明该 identity 的私钥可被非交互 `/usr/bin/codesign` 使用
- **AND** manifest 损坏、歧义或 stale 时必须失败，不得退回 picker 或选择另一张证书

#### Scenario: 无 Prepare manifest 时从 picker 选择

- **WHEN** 用户执行 `:UESetIOSSigningCertificate`
- **AND** 当前 project 及其受支持 workspace 布局中没有 prepared signing manifest
- **THEN** 系统必须异步探测当前有效 code-sign identities 并显示 picker
- **AND** 选择结果必须保存为 project-scoped fingerprint 与显示名
- **AND** 不得读取、复制或保存私钥、密码或 `.p12`

#### Scenario: 通过参数设置签名证书

- **WHEN** 用户传入精确显示名或 SHA-1 fingerprint
- **THEN** 系统必须把它解析为当前 keychain 中唯一有效 identity 后再保存
- **AND** 空匹配、重复匹配或过期 identity 必须失败且不覆盖原选择

#### Scenario: 清除显式签名选择

- **WHEN** 用户执行 `:UESetIOSSigningCertificate!`
- **THEN** 系统必须清除当前 project 的显式 identity
- **AND** 后续 Package/Install/debug 必须报告未配置，不能退回 keychain 第一张证书

#### Scenario: 规划 iOS build 或 package

- **WHEN** 当前 project 已选择有效 identity
- **THEN** IOS driver 必须通过 argv 中的 Engine ini override 设置
  `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:SigningCertificate`
- **AND** 不得修改工程或 Engine ini 文件
- **AND** 日志不得暴露完整证书名称、team id 或 fingerprint

#### Scenario: 没有显式签名身份但只执行编译

- **WHEN** Xcode 与 SDK 可用、当前 project 没有选择 identity，且用户只执行 `:UEBuildIOS`
- **THEN** 系统必须允许不依赖签名的 compile/link 阶段继续
- **AND** 必须把 Package/Install/debug 的签名 gate 标记为未满足

#### Scenario: 没有显式签名身份且准备打包或调试

- **WHEN** 用户执行 Package/Install/debug 且当前 project 没有选择 identity
- **THEN** 系统必须在该阶段前失败并提示执行 `:UESetIOSSigningCertificate`
- **AND** 不得因为 keychain 中存在其他有效 identity 而继续

#### Scenario: 长任务开始后证书选择改变

- **WHEN** build/package/install/debug 已捕获 identity 后用户修改全局选择
- **THEN** 当前任务必须继续使用开始时捕获的 identity
- **AND** 新选择只影响后续任务

#### Scenario: 所选证书失效或消失

- **WHEN** preflight 重新探测时无法精确匹配已捕获 identity
- **THEN** 需要该 identity 的阶段必须在执行前失败
- **AND** 不得自动选择另一张有效证书

#### Scenario: SDK 或 Xcode 不可用

- **WHEN** developer directory 或 iPhoneOS SDK 探测失败
- **THEN** 系统必须停止当前任务并报告探测结果
- **AND** 不得回退到 Windows 或未知工具链

### Requirement: 设备选择必须区分 CoreDevice 与 MobileDevice transport

MUST：`:UESetIOSDevice` 必须合并 devicectl 的 connected CoreDevice、`idevice_id -l` 的实时 USB
MobileDevice 与 `idevice_id --network` 的实时 Wi-Fi MobileDevice。选择结果必须保存稳定 identifier、
backend 与 transport；已保存设备不在实时结果中时必须进入 picker，不能自动改选另一台设备。

#### Scenario: iOS 15 USB 设备只有 MobileDevice 可见

- **WHEN** devicectl 没有 connected tunnel，但 xcdevice 报告同一台物理 USB iOS 15 设备 available
- **THEN** picker 必须列出该设备并保存其 UDID 与 `legacy-mobiledevice` backend
- **AND** 不得要求设备支持不存在的 CoreDevice tunnel

#### Scenario: xcdevice 只包含 simulator、unavailable 或现代历史设备

- **WHEN** xcdevice fallback 没有 available physical USB pre-iOS17 设备
- **THEN** 系统仍必须使用 MobileDevice 实时 USB/Wi-Fi 结果构造 picker
- **AND** 不得把 simulator 或 CoreDevice-unavailable 历史记录伪装成实时设备

#### Scenario: 已保存设备离线但存在其他实时设备

- **WHEN** Install/Launch 保存的 UDID 不在实时 USB、Wi-Fi 或 connected CoreDevice 结果中
- **THEN** picker 必须同时展示实时候选与带 `saved, offline` 标记的保存设备
- **AND** 系统不得自动切换到唯一的其他设备；用户选择实时候选后才更新 backend/transport
- **AND** 用户选择保存的 offline USB 设备时，系统必须以该精确 UDID 刷新 USB/MobileDevice 路由并重新探测
- **AND** 刷新不得改选其他设备；物理恢复失败必须保留 warning 证据，单次重新探测后仍离线必须结束当前操作
- **AND** 系统不得重复打开相同 picker；只有用户下一次显式 Launch/设备选择才可开始新一轮选择

#### Scenario: legacy 设备安装当前 tuple app

- **WHEN** 当前选择的 backend 是 `legacy-mobiledevice`，当前 tuple app 存在，且
  `Saved/IOSQADebug/signing.json` 与 branch 对应 `InstallIOSClient.sh` 均通过验证
- **THEN** `UEInstallIOS` / active IOS `<Space>ui` 必须把稳定 UDID、源 app 和精确 identity/profile/bundle
  作为独立 argv 交给 helper 的 legacy backend
- **AND** helper 必须克隆并重签临时副本、封装临时 IPA、执行 container-preserving update，禁止修改源 app、
  uninstall、launch 或把 legacy identity 传给 devicectl

#### Scenario: legacy 安装证据不完整

- **WHEN** 当前 tuple app、prepared signing metadata、精确 identity/profile 或 helper 任一缺失/不匹配
- **THEN** 安装必须 fail closed 并报告缺失证据
- **AND** 不得把磁盘上的任意 `.app` 伪装成 package provenance

#### Scenario: legacy 设备被普通 launch 消费

- **WHEN** 当前选择的 backend 是 `legacy-mobiledevice`、持久化 runtime 仍有安装成功的精确 device/bundle，
  且用户在当前或重启后的 Nvim 执行 `UELaunch`
- **THEN** planner 必须验证 `Saved/IOSQADebug/signing.json` 的 prepared signed app 与 bundle，随后通过
  host-owned `ios-deploy` 在用户选择的 USB 或 Wi-Fi transport 执行 `--noinstall --justlaunch`
- **AND** USB transport 必须固定 `--no-wifi`；Wi-Fi transport 不得注入 `--no-wifi`
- **AND** launch helper 必须再次查询精确 bundle PID 并发布结构化 device/bundle/process evidence
- **AND** 不得要求当前进程仍持有 package artifact、重新安装、卸载、进入 DAP 或调用 UE legacy Run 后端

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

MUST：IOS `UELaunch` 必须使用捕获设备和已安装 app 的实际 bundle identifier。CoreDevice backend 调用
`devicectl device process launch`；pre-iOS17 legacy backend 使用 prepared signed app 驱动
`ios-deploy --noinstall --justlaunch`，并在返回前复查 PID。两者都不得调用 UE legacy Run 后端或进入 DAP。

#### Scenario: 应用成功启动

- **WHEN** 对应 backend 的 launch transport 返回成功且结构化结果确认 device、bundle 与 PID
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
