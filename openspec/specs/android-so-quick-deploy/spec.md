# android-so-quick-deploy Specification

## Purpose

为 UE Android C++ 开发提供不组装 APK 的 SO-only 构建和可回滚快速部署能力，保证
设备产物与正常 APK 的 strip 行为一致，并以实机加载证据验证替换结果。边界：只做
native library 级快速迭代（build → deploy → launch 显式分离），不覆盖需要新
Java/JNI/manifest/Gradle 产物的改动，那类改动仍需要正常 APK 流程。

## Requirements

### Requirement: SO-only 构建不得进入 APK 组装

系统 SHALL 为当前 Android Target 和 Configuration 提供独立的 SO-only 构建入口，
只执行 UBT 需要更新的编译与链接 actions，不执行 Gradle APK 组装；构建失败时
SHALL 报告失败且不得继续部署旧 SO。构建任务 SHALL 在隐藏 buffer 中运行，不因
terminal 输出窗口关闭而被终止。

#### Scenario: 增量构建成功

- **WHEN** 用户在已配置 Android Target 和 Configuration 的项目中执行
  `:UEBuildAndroidSO`
- **THEN** 系统仅更新 UBT receipt 中与当前 Target/Platform/Configuration 匹配的
  Android arm64 SO build product
- **AND** 不生成或更新时间戳变更最终 APK

### Requirement: 快速部署必须精确匹配当前构建配置并保持正常 strip 行为

系统 SHALL 从当前项目、Target 和 Configuration 精确选择源 SO（校验
`<Target>.target` receipt 的 TargetName/Platform/Configuration，不得降级选择其他
配置或按最新时间猜测），并在主机临时文件上执行与当前 Android Gradle 打包链一致
的 `--strip-unneeded`；系统 MUST 保留原始未 strip SO 供符号解析使用，不修改
`Binaries/Android` 下的原始 SO。运行时逻辑 MUST NOT 固定某个项目名或 Target 名。

#### Scenario: 已安装 APK 与 SO 构建基线不匹配

- **WHEN** 源 SO 同目录 `packageInfo.txt` 的 package/versionCode 与设备已安装包
  不一致，且当前 transport 将直接修改已安装 native library
- **THEN** 部署 SHALL 在 strip、push 和设备文件替换前失败
- **WHEN** 当前 transport 为 debuggable app-private startup agent
- **THEN** 部署 MAY 继续只更新 app-private SO，但 SHALL 明确警告版本差异，且不得
  修改、重签或重装现有 APK

### Requirement: 部署必须复用当前 Neovim 进程的 Android 设备

系统 SHALL 使用现有 Android device picker 保存的 serial，并对所有 ADB 操作显式
传递该 serial；未选择设备时 SHALL 打开现有 picker，选择完成后继续同一次部署流程。

#### Scenario: 未选择设备时先打开 picker

- **WHEN** 用户执行 `:UEDeployAndroidSO` 且会话中没有已选 serial
- **THEN** 系统 SHALL 打开现有 Android device picker
- **AND** 选择完成后继续同一次部署流程

### Requirement: 设备部署必须按实测能力选择安全且可回滚的 transport

系统 MUST 先以只读 probe 选择 root 原地替换或 debuggable app-private startup
agent 两条路径之一；核心调度层不得拥有 transport 选择、APK/SO 生命周期、设备
发现或重试策略，这些由 deployment workflow owner 消费 target driver 的
structured plan 与当前 Neovim 进程保存的 serial 后确定。两条路径都必须动态解析
已安装应用的 native library 目录、校验主机/设备 hash，并在失败时恢复各自被修改
的目标。非 root 路径 MUST NOT 修改已安装 APK、签名、`/data/app` 文件或工具目录
之外的既有应用数据。

#### Scenario: Root transport 按实测能力选择

- **WHEN** `adb shell id -u` 返回 `0`
- **THEN** 所有特权命令 SHALL 直接通过 root adbd 执行，不得依赖设备存在 `su`
- **WHEN** 普通 shell 非 root，但 `adb shell su 0 id -u` 返回 `0`
- **THEN** 所有特权命令 SHALL 统一通过已验证的 `su 0` transport 执行

#### Scenario: Production user build 走 debuggable app-private transport

- **WHEN** direct shell UID 非 0、`su 0` 不可用，设备报告 `ro.debuggable=0`，但
  已安装包带 `DEBUGGABLE` flag、`run-as <package> id -u` 返回安装包 appId，且
  ActivityManager 支持 `--attach-agent-bind`
- **THEN** 系统 SHALL 选择 debuggable app-private startup-agent transport，不得
  因设备全局 `ro.debuggable=0` 或缺少 `su` 而拒绝

#### Scenario: 两类 transport 都不满足前置条件

- **WHEN** root transport 不可用且 debuggable app-private transport 也不可用，
  或包未安装、包名缺失、目标 SO 不存在
- **THEN** 系统 SHALL 在替换前失败并给出可操作错误，不修改设备已安装的 SO

#### Scenario: 替换后验证失败必须自动回滚

- **WHEN** metadata 或设备端 hash 验证失败
- **THEN** 系统 MUST 自动恢复备份的原始 SO，并清理 staging 和同目录临时文件

### Requirement: 非 root 启动必须重定向原生 ClassLoader 查找，不得预加载猜测

系统 SHALL 在 bind application 阶段附加 JVMTI agent，在目标 app ClassLoader 的
prepared-class 事件中验证 `findLibrary("UE4")` 原本精确指向安装目录 SO，再把
app-private native directory 对应元素置于 `nativeLibraryPathElements` 首位。
系统 MUST 让应用原有 `System.loadLibrary("UE4")` 继续走 ART `nativeLoad`、原
classloader linker namespace 与 `JNI_OnLoad`；不得自行 `dlopen` 目标 SO 或依赖
SONAME 复用。任一环节不匹配时 SHALL fail closed，不得回落加载安装目录 SO。

#### Scenario: 运行时映射证明

- **WHEN** app-private 启动报告映射成功
- **THEN** host SHALL 在启动前复算 current generation 的 SO/agent SHA-256 并与
  manifest 精确相等
- **AND** maps 校验 SHALL 精确比较 pathname（仅允许内核追加的 ` (deleted)` 后缀），
  MUST NOT 包含安装目录 `libUE4.so`
- **AND** `mapped` 只证明 linker mapping，不得表述为 `JNI_OnLoad` 或引擎初始化
  已经成功返回

#### Scenario: staging 部分损坏时拒绝启动

- **WHEN** 工具目录、`current` pointer、generation、manifest、SO 或 agent 任一
  呈部分状态，文件 hash 不匹配，或已安装 APK 基线不再匹配发布 generation 记录
- **THEN** `<leader>ul` SHALL 在启动前失败并要求重新执行 `<leader>uq`，不得静默
  回落启动 APK 原 SO

### Requirement: 安装、部署与启动必须显式分离

系统 MUST NOT 在 APK 安装或 SO 替换完成后自动启动应用；应用启动 SHALL 只由用户
显式执行 `<leader>ul` / `:UELaunch` 触发。

#### Scenario: SO 替换成功后保持停止

- **WHEN** 用户执行 `<leader>uq` / `:UEDeployAndroidSO` 且 metadata 与 hash 验证
  成功
- **THEN** 系统 SHALL 保持应用停止并结束部署，不得启动应用或读取
  `/proc/<pid>/maps` 作为部署完成条件

### Requirement: 用户入口必须简短且不破坏现有 APK 工作流

系统 SHALL 提供快捷键 `<leader>us`（SO-only 构建）与 `<leader>uq`（快速部署），
并保持现有 `:UEBuild` / `:UEInstallAndroid` 完整构建和 APK 安装行为不变。

#### Scenario: 快捷键调用对应命令

- **WHEN** 用户按下 `<leader>us` 或 `<leader>uq`
- **THEN** 系统 SHALL 分别调用 `:UEBuildAndroidSO` 或 `:UEDeployAndroidSO`
- **AND** 现有 `:UEBuild` / `:UEInstallAndroid` 行为 SHALL 保持不变

## 选型与踩坑

- **选型**：非 root 场景选 JVMTI agent 重定向 ClassLoader 查找路径，而不是
  `dlopen` 目标 SO 或依赖 SONAME 复用——理由是必须让应用原有
  `System.loadLibrary("UE4")` 继续走 ART 原生加载路径（`nativeLoad`/原
  classloader linker namespace/`JNI_OnLoad`），自行 dlopen 无法保证与正常加载
  路径语义等价。
- **重要事项**：该快速部署流程只保证 native-only 迭代；需要新 Java/JNI/manifest/
  Gradle 产物的改动仍不兼容旧 APK，必须走正常 APK 流程。
- **重要事项**：`uq`/`ul` 之间存在操作锁（同一 serial/package），锁由进程持有，
  异常退出后由操作系统释放，不留永久锁文件。
