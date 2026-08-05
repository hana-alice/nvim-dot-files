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
- **THEN** 部署 SHALL 在 strip、push 和设备文件替换前失败
- **AND** 错误 SHALL 指引用户先安装一次匹配 APK，再继续 SO-only 迭代
- **AND** 不得把需要新 Java/JNI 接口的 SO 注入旧 APK

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

### Requirement: 设备替换必须安全且可回滚

系统 MUST 要求目标设备支持 root，动态解析已安装应用的 native library 目录，备份原始 `libUE4.so`，并通过同目录临时文件原子替换目标文件。

#### Scenario: 安全替换成功

- **WHEN** 包已安装、设备支持 `su 0` 且目标 `libUE4.so` 存在
- **THEN** 系统 SHALL 将部署副本先推送到 `/data/local/tmp`
- **AND** 在目标目录恢复 owner、mode 和 SELinux context 后原子替换 `libUE4.so`
- **AND** 校验设备端 SHA-256 与主机部署副本一致

#### Scenario: 不满足部署前置条件

- **WHEN** 设备无 root、包未安装、包名缺失或目标 SO 不存在
- **THEN** 系统 SHALL 在替换前失败并给出可操作错误
- **AND** 不修改设备已安装的 SO

#### Scenario: 替换后验证失败

- **WHEN** hash、应用启动、进程存活或运行时映射验证失败
- **THEN** 系统 MUST 自动恢复备份的原始 SO
- **AND** 清理 staging 和同目录临时文件

### Requirement: 部署成功必须有运行时加载证据

系统 SHALL 在替换后重新启动应用，并验证运行进程确实映射了动态解析目标路径中的新 `libUE4.so`。

#### Scenario: 新 SO 已加载

- **WHEN** 应用启动后保持运行
- **THEN** 系统 SHALL 从 `/proc/<pid>/maps` 找到目标 `libUE4.so` 路径
- **AND** 在短暂稳定性等待后再次确认进程仍然存活

### Requirement: 用户入口必须简短且不破坏现有工作流

系统 SHALL 提供小写快捷键 `<leader>us` 执行 SO-only 构建、`<leader>uq` 执行快速部署，并保持现有 APK 构建、安装和设备选择命令行为不变。

#### Scenario: 快捷键调用

- **WHEN** 用户按下 `<leader>us` 或 `<leader>uq`
- **THEN** 系统 SHALL 分别调用 `:UEBuildAndroidSO` 或 `:UEDeployAndroidSO`

#### Scenario: 继续使用正常 APK 流程

- **WHEN** 用户执行现有 `:UEBuild` 或 `:UEInstallAndroid`
- **THEN** 系统 SHALL 保持原有完整构建和 APK 安装行为
