# android-so-quick-deploy Specification

## Purpose

为 UE Android C++ 开发提供不组装 APK 的 SO-only 构建和可回滚快速部署能力，同时保证设备产物与正常 APK 的 strip 行为一致，并以实机加载证据验证替换结果。

## Requirements

### Requirement: SO-only 构建不得进入 APK 组包

系统 SHALL 为当前 Android Target 和 Configuration 提供独立的 SO-only 构建入口，只执行 UBT 需要更新的编译与链接 actions，不执行 Gradle APK 组装。

#### Scenario: 增量构建成功

- **WHEN** 用户在已配置 Android Target 和 Configuration 的项目中执行 `:UEBuildAndroidSO`
- **THEN** 系统仅更新 UBT receipt 中与当前 Target/Platform/Configuration 匹配的 Android arm64 SO build product
- **AND** 不生成或更新时间戳变更最终 APK

#### Scenario: 构建失败

- **WHEN** action graph 导出或执行返回非零退出码
- **THEN** 系统 SHALL 报告失败并且不得继续部署旧 SO

### Requirement: 快速部署必须匹配当前构建配置和正常 APK strip 行为

系统 SHALL 从当前项目、Target 和 Configuration 精确选择源 SO，并在主机临时文件上执行与当前 Android Gradle 打包链一致的 native library strip；系统 MUST 保留原始未 strip SO 供符号解析使用。

#### Scenario: 项目名和 Target 名不是固定值

- **WHEN** `.uproject` 位于 `<project-root>/Source/<Project>/` 且当前 Target 不是 `Client`
- **THEN** 构建与部署 SHALL 从当前 `.uproject`、Target 选择和 `<Target>.target` receipt 派生全部路径
- **AND** 运行时逻辑 MUST NOT 固定某个项目名或 Target 名

#### Scenario: 当前配置产物存在

- **WHEN** 当前配置为 Development、Test 或 Shipping 且对应 arm64 SO 已生成
- **THEN** `:UEDeployAndroidSO` SHALL 校验 `<Target>.target` receipt 的 TargetName、Platform、Configuration
- **AND** 使用 receipt 声明的实际 SO build product（包括 UE4 的 `<Target>-arm64.so` 通用文件名）
- **AND** 不得降级选择其他配置或仅按最新时间猜测

#### Scenario: receipt 同时声明插件 SO

- **WHEN** matching receipt 的 BuildProducts 同时包含插件动态库和当前 Target 主产物
- **THEN** 部署 SHALL 仅接受文件名匹配当前 Target 且类型为 Executable 的主产物
- **AND** 多个主产物候选仍然有效时 SHALL 拒绝部署，不得按列表顺序猜测

#### Scenario: 已安装 APK 与 SO 构建基线不匹配

- **WHEN** 源 SO 同目录 `packageInfo.txt` 的 package/versionCode 与设备已安装包不一致
- **AND** 当前 transport 将直接修改已安装 native library
- **THEN** 部署 SHALL 在 strip、push 和设备文件替换前失败
- **WHEN** 当前 transport 为 debuggable app-private startup agent
- **THEN** 部署 SHALL 明确警告版本差异但 MAY 继续只更新 app-private SO
- **AND** 不得修改、重签或重装现有 APK
- **AND** 该流程只保证 native-only 迭代；需要新 Java/JNI/manifest/Gradle 产物的改动仍不兼容旧 APK

#### Scenario: 生成部署副本

- **WHEN** 用户执行快速部署
- **THEN** 系统 SHALL 使用 `--strip-unneeded` 生成临时部署副本
- **AND** 不修改 `Binaries/Android` 下的原始 SO

### Requirement: 部署必须复用会话全局 Android 设备

系统 SHALL 使用现有 Android device picker 保存的 serial，并对所有 ADB 操作显式传递该 serial。

#### Scenario: 已选择设备

- **WHEN** `vim.g.ue_android_device_serial` 已设置
- **THEN** 部署 SHALL 只操作该 serial 对应的设备

#### Scenario: 尚未选择设备

- **WHEN** 用户执行 `:UEDeployAndroidSO` 且会话中没有已选 serial
- **THEN** 系统 SHALL 打开现有 Android device picker
- **AND** 选择完成后继续同一次部署流程

### Requirement: 设备部署必须按能力选择安全且可回滚的 transport

系统 MUST 先以只读 probe 选择 root 原地替换或 debuggable app-private startup agent。两条路径都必须动态解析已安装应用的 native library 目录、校验主机/设备 hash，并在失败时恢复各自被修改的目标；非 root 路径 MUST NOT 修改已安装 APK、签名、`/data/app` 文件或工具目录之外的既有应用数据。

#### Scenario: 安全替换成功

- **WHEN** 包已安装、设备通过 root adbd 或经 `id -u` 验证的 `su 0` 提供 root，且目标 `libUE4.so` 存在
- **THEN** 系统 SHALL 将部署副本先推送到 `/data/local/tmp`
- **AND** 在目标目录恢复 owner、mode 和 SELinux context 后原子替换 `libUE4.so`
- **AND** 校验设备端 SHA-256 与主机部署副本一致

#### Scenario: Root transport 按实测能力选择

- **WHEN** `adb shell id -u` 返回 `0`
- **THEN** 所有特权命令 SHALL 直接通过 root adbd 执行且不得依赖设备存在 `su`
- **WHEN** 普通 shell 非 root，但 `adb shell su 0 id -u` 返回 `0`
- **THEN** 所有特权命令 SHALL 统一通过已验证的 `su 0` transport 执行
- **AND** 特权命令 MUST NOT 在 capability probe 之外各自写死 root transport

#### Scenario: 两类 transport 都不满足前置条件

- **WHEN** root transport 不可用且 debuggable app-private transport 也不可用，或包未安装、包名缺失、目标 SO 不存在
- **THEN** 系统 SHALL 在替换前失败并给出可操作错误
- **AND** 不修改设备已安装的 SO

#### Scenario: Production user build 没有 root transport

- **WHEN** direct shell UID 非 0、`su 0` 不可用，且设备报告 `build_type=user` / `ro.debuggable=0`
- **AND** 已安装包带 `DEBUGGABLE` flag、`run-as <package> id -u` 返回安装包 appId，且 ActivityManager 支持 `--attach-agent-bind`
- **THEN** 系统 SHALL 选择 debuggable app-private startup-agent transport
- **AND** 不得因为设备全局 `ro.debuggable=0` 或缺少 `su` 而拒绝

#### Scenario: 非 root app-private staging 成功

- **WHEN** 选择 debuggable app-private startup-agent transport
- **AND** 设备 API 为 34、ABI 列表包含 `arm64-v8a`、installed app `primaryCpuAbi=arm64-v8a`，源 SO 为 ELF64/AArch64 且 `DT_SONAME=libUE4.so`
- **THEN** 系统 SHALL 将 stripped `libUE4.so`、nvim 自带的 arm64 JVMTI agent 与 hash manifest 写入唯一 generation 目录
- **AND** 两个文件 SHALL 以 app UID 校验 SHA-256
- **AND** 仅在 generation 完整后以原子 `current` pointer 发布，启动流程不得观察到 SO/agent 半更新组合
- **AND** manifest SHALL 记录 installed versionCode 及由 lastUpdateTime、APK path/stat 组成的安装文件系统摘要
- **AND** 已安装 `/data/app` 下的 `libUE4.so`、APK signer 与 `code_cache/nvim-ue-so` 之外的既有应用数据 SHALL 保持不变

#### Scenario: 部署与启动并发

- **WHEN** 同一 serial/package 已有 `uq` 或 `ul` 进程持有操作锁
- **THEN** 后续 `uq` / `ul` SHALL 在任何设备变更或启动前明确拒绝
- **AND** 进程异常退出后锁 SHALL 由操作系统释放，不得留下永久锁文件

#### Scenario: 非 root 且包不可调试

- **WHEN** root adbd 与 verified `su 0` 都不可用，且已安装包没有 `DEBUGGABLE` flag，或 `run-as` / `--attach-agent-bind` 任一能力不可用
- **THEN** 系统 SHALL 在 force-stop、push 或 app-private 写入前失败
- **AND** 错误 SHALL 报告缺失的实测能力，不得建议脚本自行替换签名

#### Scenario: 替换后验证失败

- **WHEN** metadata 或设备端 hash 验证失败
- **THEN** 系统 MUST 自动恢复备份的原始 SO
- **AND** 清理 staging 和同目录临时文件

#### Scenario: app-private staging 验证失败

- **WHEN** app-private SO 或 startup agent 写入、权限或 hash 验证失败
- **THEN** 系统 MUST 恢复先前的 app-private SO；首次部署则删除不完整目标
- **AND** 已安装 APK 与 `/data/app` 原 SO MUST NOT 被修改

### Requirement: 非 root 启动必须重定向原生 ClassLoader 查找而非预加载猜测

系统 SHALL 在 bind application 阶段附加 JVMTI agent，在目标 app ClassLoader 的 prepared-class 事件中验证 `findLibrary("UE4")` 原本精确指向安装目录 SO，再把 app-private native directory 对应元素置于 `nativeLibraryPathElements` 首位。系统 MUST 让应用原有 `System.loadLibrary("UE4")` 继续走 ART `nativeLoad`、原 classloader linker namespace 与 `JNI_OnLoad`；不得自行 `dlopen` 目标 SO或依赖 SONAME 复用。

#### Scenario: ClassLoader 重定向成功

- **WHEN** 用户在已有 app-private staging 后显式执行 `<leader>ul`
- **THEN** 启动脚本 SHALL 使用 `am start --attach-agent-bind` 创建 fresh process
- **AND** agent SHALL 只接受重排前 `findLibrary("UE4")` 等于动态解析的安装目录 SO、重排后等于 app-private SO 的 ClassLoader
- **AND** API/layout、路径或 JNI/JVMTI 操作任一不匹配时 SHALL fail closed，不得回落加载安装目录 SO

#### Scenario: 运行时映射证明

- **WHEN** app-private 启动报告映射成功
- **THEN** host SHALL 在启动前复算 current generation 的 SO/agent SHA-256 并与 manifest 精确相等
- **AND** agent 与 host SHALL 验证 fresh process maps 包含精确 app-private `libUE4.so`
- **AND** maps MUST NOT 包含安装目录 `libUE4.so`
- **AND** maps pathname MUST 精确比较，仅允许内核追加的 ` (deleted)` 后缀，不得使用 substring
- **AND** agent SHALL 在私有 SO 映射后继续监控；installed SO 一旦被观察到映射，agent SHALL 记录错误并立即终止该错误进程
- **AND** `mapped` 只证明 linker mapping，不得表述为 `JNI_OnLoad` 或引擎初始化已经成功返回

#### Scenario: 启动或验证失败

- **WHEN** attach、状态等待、maps 校验或稳定性复查任一步失败
- **THEN** host SHALL 立即 force-stop 本次错误进程并有界确认其已停止
- **AND** 不得把加载原 SO、双映射或无法验证的进程留在运行状态

#### Scenario: 未 staging 时正常启动

- **WHEN** `code_cache/nvim-ue-so` 及其所有托管工件均不存在
- **THEN** `<leader>ul` SHALL 使用既有普通 APK 启动路径
- **AND** 不得附加半成品 agent

#### Scenario: staging 部分损坏

- **WHEN** 工具目录、`current` pointer、generation、manifest、SO 或 agent 任一呈部分状态，文件 hash 不匹配，或已安装 APK versionCode / 安装文件系统摘要不再等于发布 generation 记录的设备基线
- **THEN** `<leader>ul` SHALL 在启动前失败并要求重新执行 `<leader>uq`
- **AND** 不得静默回落启动 APK 原 SO

### Requirement: 安装、部署与启动必须显式分离

系统 MUST NOT 在 APK 安装或 SO 替换完成后自动启动应用；应用启动 SHALL 只由用户显式执行 `<leader>ul` / `:UELaunch` 触发。

#### Scenario: APK 安装成功后保持停止

- **WHEN** 用户执行 `<leader>ui` / `:UEInstallAndroid` 且安装成功
- **THEN** 系统 SHALL 在 `adb install -r` 完成后结束操作
- **AND** 系统 MUST NOT 调用 `monkey`、`am start` 或其他应用启动命令

#### Scenario: SO 替换成功后保持停止

- **WHEN** 用户执行 `<leader>uq` / `:UEDeployAndroidSO` 且 metadata 与 hash 验证成功
- **THEN** 系统 SHALL 保持应用停止并结束部署
- **AND** 系统 MUST NOT 启动应用或读取 `/proc/<pid>/maps` 作为部署完成条件
- **AND** 用户随后可显式执行 `<leader>ul` / `:UELaunch` 启动应用

#### Scenario: app-private SO staging 后保持停止

- **WHEN** 非 root transport 完成 SO/agent staging 与 hash 校验
- **THEN** `<leader>uq` SHALL 保持应用停止且不得调用 `am start` / `monkey`
- **AND** ClassLoader 重定向及 maps 验证 SHALL 只在用户随后显式执行 `<leader>ul` 时发生

### Requirement: 用户入口必须简短且不破坏现有工作流

系统 SHALL 提供小写快捷键 `<leader>us` 执行 SO-only 构建、`<leader>uq` 执行快速部署，并保持现有 APK 构建、安装和设备选择命令行为不变。

#### Scenario: 快捷键调用

- **WHEN** 用户按下 `<leader>us` 或 `<leader>uq`
- **THEN** 系统 SHALL 分别调用 `:UEBuildAndroidSO` 或 `:UEDeployAndroidSO`

#### Scenario: 继续使用正常 APK 流程

- **WHEN** 用户执行现有 `:UEBuild` 或 `:UEInstallAndroid`
- **THEN** 系统 SHALL 保持原有完整构建和 APK 安装行为
