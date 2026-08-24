## MODIFIED Requirements

### Requirement: 设备部署必须按能力选择安全且可回滚的 transport

系统 MUST 先以只读 probe 选择 root 原地替换或 debuggable app-private startup agent；选择结果必须由 Android deployment workflow owner 消费当前 target driver 产出的 structured plan 与当前 Neovim 进程保存的 Android serial 后确定。两条路径都必须动态解析已安装应用的 native library 目录、校验主机/设备 hash，并在失败时恢复各自被修改的目标；核心调度层不得拥有 transport 选择、APK/SO 生命周期、设备发现或重试策略。非 root 路径 MUST NOT 修改已安装 APK、签名、`/data/app` 文件或工具目录之外的既有应用数据。

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

#### Scenario: workflow owner 消费 live serial 与 plan

- **WHEN** `vim.g.ue_android_device_serial` 已设置且 deployment workflow owner 收到当前 target driver 的部署 plan
- **THEN** workflow owner 必须用该 serial 进行 transport probe 与所有 ADB 操作
- **AND** 核心层不得自己重建 transport、serial 或 SO/APK 生命周期步骤

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
- **AND** ActivityManager 暴露 `--attach-agent-bind`、ABI 列表包含 `arm64-v8a`、installed app `primaryCpuAbi=arm64-v8a`，源 SO 为 ELF64/AArch64 且 `DT_SONAME=libUE4.so`
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

- **WHEN** active target 为 Android，用户执行 `<leader>ui` / `:UEInstall` 或 `:UEInstallAndroid` 且安装成功
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
