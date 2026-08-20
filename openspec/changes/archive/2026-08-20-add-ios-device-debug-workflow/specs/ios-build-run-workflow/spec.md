## MODIFIED Requirements

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
- **AND** 当前 project 或 `workspace/Source/Client` 布局的 workspace 已存在
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

### Requirement: 设备选择必须区分 CoreDevice 与 pre-iOS17 MobileDevice

MUST：`:UESetIOSDevice` 必须先使用 devicectl 结构化 JSON 选择已连接的 CoreDevice；当且仅当没有
可用 CoreDevice 时，可以使用 `xcdevice` 结构化 JSON 发现 `available=true`、物理、USB 连接且
系统版本低于 iOS 17 的设备。选择结果必须保存稳定 identifier 和 backend，不能解析人类表格文本、
选择 unavailable 历史设备或把 legacy identity 冒充 CoreDevice identity。

#### Scenario: iOS 15 USB 设备只有 MobileDevice 可见

- **WHEN** devicectl 没有 connected tunnel，但 xcdevice 报告同一台物理 USB iOS 15 设备 available
- **THEN** picker 必须列出该设备并保存其 UDID 与 `legacy-mobiledevice` backend
- **AND** 不得要求设备支持不存在的 CoreDevice tunnel

#### Scenario: xcdevice 只包含 simulator、unavailable 或现代历史设备

- **WHEN** fallback 输出没有 available physical USB pre-iOS17 设备
- **THEN** 系统必须继续报告 no available device
- **AND** 不得选择 simulator、网络设备、iOS 17+ CoreDevice-unavailable 历史记录

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

- **WHEN** 当前选择的 backend 是 `legacy-mobiledevice` 且用户执行 `UELaunch`
- **THEN** CoreDevice-only launch planner 必须明确 fail closed
- **AND** 不得静默引入未经验证的普通启动 fallback
