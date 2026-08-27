# global-android-device-selection Specification

## Purpose

为当前 Neovim **进程**提供唯一、显式的 Android device 目标：从 `adb devices -l`
按名称 + serial 选择并写入进程内 `vim.g` 变量，让 APK install、launch、logcat 与 DAP 的所有
设备定向命令统一使用 `adb -s <serial>`，同时保证运行中流程不会因重选而跨设备；
不同 Neovim 实例互不影响。
## Requirements
### Requirement: 从 ADB ready devices 显式选择全局 Android device

系统 SHALL 注册 `:UESetAndroidDevice`，执行时 SHALL 调用 `adb devices -l` 枚举设备，只把状态为 `device` 的 ready rows 作为可选项，并 SHALL 打开选择 UI；每个可选项 MUST 同时显示可读 device 名称与 serial。选择成功后系统 SHALL 把 serial 写入当前 Neovim 进程的 `vim.g.ue_android_device_serial`；这里的“全局”只表示该进程内的 Vim global scope，MUST NOT 持久化或传播到其他 Neovim 进程。

#### Scenario: 多设备候选显示名称和 serial

- **WHEN** `adb devices -l` 返回两台 ready devices，分别含 `model:Pixel_8` / `model:Quest_3` 与不同 serial
- **THEN** `:UESetAndroidDevice` 打开的选择 UI SHALL 包含 `Pixel 8`、`Quest 3` 及各自 serial
- **AND** 系统 MUST NOT 仅显示名称或仅显示 serial

#### Scenario: 单设备也显式选择

- **WHEN** 执行 `:UESetAndroidDevice` 且只有一台 ready device
- **THEN** 系统 SHALL 仍打开包含该设备名称和 serial 的选择 UI
- **AND** 系统 MUST NOT 未经选择就静默设置

#### Scenario: 选择写入全局变量

- **WHEN** 用户在选择 UI 中选择 serial `SERIAL-002`
- **THEN** `vim.g.ue_android_device_serial` SHALL 等于 `SERIAL-002`
- **AND** 后续新的 Android 操作 SHALL 读取该值

#### Scenario: 取消选择保留原值

- **WHEN** 已设置全局 serial，用户再次执行命令后取消选择
- **THEN** 原 `vim.g.ue_android_device_serial` SHALL 保持不变
- **AND** 系统 MUST NOT 自动选中列表第一项

#### Scenario: 两个 Neovim 实例选择不同设备

- **WHEN** 实例 A 设置 serial `SERIAL-A`，实例 B 设置 serial `SERIAL-B`
- **THEN** 实例 A 后续读取仍 SHALL 为 `SERIAL-A`
- **AND** 实例 B 的 `vim.g` 写入 MUST NOT 改变实例 A

#### Scenario: 无 ready device

- **WHEN** ADB 只返回 offline/unauthorized rows 或没有设备
- **THEN** 系统 SHALL 显示包含状态或连接指引的可见错误
- **AND** MUST NOT 修改全局 serial

### Requirement: 所有设备定向 ADB 命令显式使用全局 serial

系统 SHALL 让仓内所有面向某一 Android device 的 ADB 操作在 argv 中显式包含 `-s <serial>`；这包括 active target 为 Android 时的 `<Space>ui` / `:UEInstall`、`:UEInstallAndroid`、Android `:UELaunch`、Android logcat、DAP attach/launch/reattach 的 shell/push/forward/pidof/cleanup。`adb devices -l` 作为发现命令 SHALL 是不加 `-s` 的例外。

#### Scenario: Space ui 安装到所选设备

- **WHEN** `vim.g.ue_android_device_serial = "SERIAL-002"` 且用户执行 `<Space>ui`
- **THEN** APK 安装 argv SHALL 形如 `adb -s SERIAL-002 install -r <apk>`
- **AND** MUST NOT 执行未带 `-s` 的 `adb install`

#### Scenario: launch 和 logcat 使用同一设备

- **WHEN** 全局 serial 为 `SERIAL-002`，随后执行 Android launch 与 logcat
- **THEN** 两条流程的每个设备定向 ADB argv SHALL 包含 `-s SERIAL-002`
- **AND** logcat MUST NOT 另取 `adb devices` 的第一台设备

#### Scenario: 发现命令不加 serial

- **WHEN** 系统需要展示设备选择 UI
- **THEN** 枚举 argv SHALL 为 `adb devices -l`
- **AND** MUST NOT 在发现目标之前构造 `adb -s <unknown> devices -l`

### Requirement: 未设置时复用选择器且不猜设备

交互式 Android 操作在 `vim.g.ue_android_device_serial` 为空时 SHALL 复用 `:UESetAndroidDevice` 的同一设备选择器，选择成功后继续原操作；取消或没有 ready device 时 SHALL 中止，不得根据“第一台”或“唯一一台”静默猜测目标。

#### Scenario: 首次安装先选择再执行

- **WHEN** 全局 serial 未设置且用户执行 `<Space>ui`
- **THEN** 系统 SHALL 先显示名称 + serial 的 device picker
- **AND** 选择成功后 SHALL 保存全局 serial，并用 `-s <serial>` 执行安装

#### Scenario: 首次操作取消

- **WHEN** 全局 serial 未设置，Android 操作唤起 picker 后用户取消
- **THEN** 原操作 SHALL 中止
- **AND** MUST NOT spawn 任意设备定向 ADB 命令

### Requirement: 已设置的离线 serial 不静默改投其他设备

全局 serial 一经显式设置，在用户再次选择之前 SHALL 保持 Android 操作的权威目标。若该 serial 已 offline 或断开，系统 SHALL 仍把它传给 `adb -s` 并呈现真实失败，MUST NOT 自动切换到当前列表中的其他 ready device。

#### Scenario: 所选设备断开后安装

- **WHEN** 全局 serial 为 `SERIAL-OLD`，该设备已断开，同时另一台 `SERIAL-NEW` 在线
- **THEN** 安装命令 SHALL 仍包含 `-s SERIAL-OLD`
- **AND** 系统 MUST NOT 静默对 `SERIAL-NEW` 安装

### Requirement: 运行中流程捕获 serial 并保持设备一致

每个 Android 长流程 SHALL 在启动时捕获目标 serial，后续异步 callback、poller 与 cleanup SHALL 使用该捕获值；流程运行期间更改全局 serial MUST NOT 让同一流程跨设备执行。

#### Scenario: DAP 会话中切换全局设备

- **WHEN** DAP session 已使用 `SERIAL-OLD` 启动，随后用户把全局变量改为 `SERIAL-NEW`
- **THEN** 该 session 的 liveness probe 与 cleanup SHALL 继续使用 `SERIAL-OLD`
- **AND** 下一次新建的 Android 操作 SHALL 使用 `SERIAL-NEW`
