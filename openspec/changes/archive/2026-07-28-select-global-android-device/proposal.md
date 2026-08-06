## Why

当前 APK 安装、Android launch、logcat 与 DAP 各自选择或猜测设备，`UEInstallAndroid` 甚至使用未带 `-s` 的裸 `adb install`；多设备连接时可能操作错设备，切换设备也没有统一入口。需要把用户显式选择的 Android device serial 提升为当前 Neovim 会话的全局唯一目标，并让所有设备定向 ADB 操作复用它。

## What Changes

- 新增 `:UESetAndroidDevice`：从 `adb devices -l` 的 ready devices 中打开选择 UI，每项同时显示 device 名称与 serial。
- 选择结果写入会话全局变量 `vim.g.ue_android_device_serial`；再次执行命令可切换目标设备。
- `<Space>ui` 的 APK 安装、Android launch、Android logcat、Android DAP attach/launch/reattach 等设备定向 ADB 流程统一读取该 serial，并在 ADB argv 中显式使用 `-s <serial>`；仅 `adb devices -l` 这类发现命令不加 `-s`。
- 尚未设置目标设备时，交互式 Android 操作先复用同一选择器；已设置但设备离线时不静默改投其他设备，由 ADB 返回针对所选 serial 的真实错误。
- 增加 `<Space>uA` 快捷键与 cheatsheet 条目，便于发现设备选择入口。
- 新增 headless test cases，覆盖设备列表解析、picker 展示、全局变量、serial 优先级以及 install/launch/logcat/DAP 的 `-s` 路由。

## Capabilities

### New Capabilities

- `global-android-device-selection`: Android device 的会话级选择、全局 serial 状态、统一 ADB 定向与交互回退契约。

### Modified Capabilities

- `android-dap-attach`: Android DAP 必须优先使用会话全局选择的 serial，并保持 K30 serial-form attach 与所有设备命令的 `-s` 一致。

## Impact

- 新增：`lua/utils/android_device.lua`、`tests/cases/android_device_spec.lua`。
- 修改：`lua/ue.lua`、`lua/utils/ue_launch.lua`、`lua/utils/ue_logs.lua`、`lua/ue/dap/android.lua`、`lua/config/keymaps.lua`、命令/cheatsheet/回归映射文档。
- OpenSpec：新增 capability spec，并为 `android-dap-attach` 写 delta spec。
- 不引入新依赖；全局选择只在当前 Neovim 会话生效，不写项目 state 或磁盘配置。
