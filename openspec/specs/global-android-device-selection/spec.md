# global-android-device-selection Specification

## Purpose

为当前 Neovim 进程提供唯一、显式的 Android device 目标：从 `adb devices -l`
按名称+serial 选择并写入进程内 `vim.g` 变量，让 APK install、launch、logcat 与
DAP 的所有设备定向命令统一使用 `adb -s <serial>`。边界：只管本进程内的显式
serial 选择与传播一致性；不做设备发现算法或跨进程持久化，不同 Neovim 实例
互不影响。

## Requirements

### Requirement: 必须从 ADB ready devices 显式选择，不得静默默认

系统 SHALL 注册 `:UESetAndroidDevice`，枚举 `adb devices -l` 中状态为 `device`
的 ready rows 作为可选项并打开选择 UI；每个选项 MUST 同时显示可读设备名称与
serial。选择成功后 SHALL 把 serial 写入当前进程的 `vim.g.ue_android_device_serial`
（仅该进程内的 Vim global scope，MUST NOT 持久化或传播到其他 Neovim 进程）。
即使只有一台 ready device，也 SHALL 仍打开选择 UI，MUST NOT 未经选择就静默
设置；取消选择时原值保持不变，MUST NOT 自动选中列表第一项。

#### Scenario: 无 ready device 时不修改全局 serial

- **WHEN** ADB 只返回 offline/unauthorized rows 或没有设备
- **THEN** 系统 SHALL 显示包含状态或连接指引的可见错误，MUST NOT 修改全局 serial

### Requirement: 所有设备定向 ADB 命令必须显式带 serial

系统 SHALL 让仓内所有面向某一 Android device 的 ADB 操作在 argv 中显式包含
`-s <serial>`——包括 `<Space>ui`/`:UEInstall`/`:UEInstallAndroid`、Android
`:UELaunch`、Android logcat、DAP attach/launch/reattach 的 shell/push/forward/
pidof/cleanup。`adb devices -l` 作为发现命令是不加 `-s` 的例外。

#### Scenario: launch 和 logcat 使用同一设备

- **WHEN** 全局 serial 为某值，随后执行 Android launch 与 logcat
- **THEN** 两条流程的每个设备定向 ADB argv SHALL 包含该 serial
- **AND** logcat MUST NOT 另取 `adb devices` 的第一台设备

### Requirement: 未设置时复用同一选择器，已设置的离线 serial 不静默改投

交互式 Android 操作在全局 serial 为空时 SHALL 复用 `:UESetAndroidDevice` 的同一
设备选择器，取消或无 ready device 时中止，不得根据"第一台"或"唯一一台"静默
猜测目标。全局 serial 一经显式设置，在用户再次选择之前 SHALL 保持权威目标；
该 serial 离线或断开时系统 SHALL 仍把它传给 `adb -s` 并呈现真实失败，MUST NOT
自动切换到当前列表中的其他 ready device。

#### Scenario: 所选设备断开后仍定向原设备

- **WHEN** 全局 serial 为 `SERIAL-OLD`，该设备已断开，同时另一台 `SERIAL-NEW`
  在线
- **THEN** 安装命令 SHALL 仍包含 `-s SERIAL-OLD`，MUST NOT 静默对 `SERIAL-NEW`
  安装

### Requirement: 已选设备不可用时必须提示重选，仍不得自动改投

设备定向操作失败且 adb 输出表明该 serial 已断开（`device 'X' not found` /
`device offline` / `no devices/emulators found` / `device unauthorized`）时，系统
SHALL 明确说明「所选设备未连接」，并 SHALL 把 `:UESetAndroidDevice` 登记为
一键修复（`<leader>uk`）；MUST NOT 因此清空或改写全局 serial，MUST NOT 自动
切到列表中的其他 ready device。判定只依赖该次操作的 adb 输出（纯函数），
不得为此在失败路径上新增阻塞探测。

#### Scenario: 设备拔掉后安装失败

- **WHEN** 全局 serial 为 `SERIAL-OLD`（已拔出），执行 Android install/launch/deploy/DAP attach
- **THEN** 失败信息 SHALL 指向设备未连接，并登记 `:UESetAndroidDevice` 作为修复
- **AND** 全局 serial SHALL 仍为 `SERIAL-OLD`

### Requirement: 运行中流程必须捕获 serial 并保持设备一致，跨会话不漂移

每个 Android 长流程 SHALL 在启动时捕获目标 serial，后续异步 callback、poller
与 cleanup SHALL 使用该捕获值；流程运行期间更改全局 serial MUST NOT 让同一
流程跨设备执行。

#### Scenario: DAP 会话中切换全局设备不影响已运行会话

- **WHEN** DAP session 已使用 `SERIAL-OLD` 启动，随后用户把全局变量改为
  `SERIAL-NEW`
- **THEN** 该 session 的 liveness probe 与 cleanup SHALL 继续使用 `SERIAL-OLD`
- **AND** 下一次新建的 Android 操作 SHALL 使用 `SERIAL-NEW`

## 选型与踩坑

- **重要事项**：这里的"全局"仅指进程内 Vim global scope，不做跨 Neovim 实例
  持久化——两个实例可以分别选中不同设备且互不影响，这是刻意设计而非缺口。
- **重要事项**：serial 捕获必须在流程启动时一次性完成，而不是让异步 callback/
  poller 每次都重读全局变量，否则运行中途切换全局设备会让同一流程跨设备执行，
  产生难以复现的状态不一致。
