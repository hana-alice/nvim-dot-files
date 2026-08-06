## 1. 公共 Android device 模块

- [x] 1.1 新建 `lua/utils/android_device.lua`，实现 `adb devices -l` 解析、ready/filter、名称 + serial 格式化与错误信息。
- [x] 1.2 实现 `get`/`set`、强制 picker 的 `select`、缺值回退 picker 的 `ensure`，以 `vim.g.ue_android_device_serial` 为会话全局真相。
- [x] 1.3 实现统一 `adb_args(adb, serial, args)`，保证设备定向命令的 argv 形状为 `adb -s <serial> ...`。

## 2. 用户入口与 Android 调用点接入

- [x] 2.1 在 `ue.setup()` 注册 `:UESetAndroidDevice`，新增 `<Space>uA`，同步命令冻结清单与 cheatsheet。
- [x] 2.2 修改 `<Space>ui` / `UEInstallAndroid` 与 AI context：未设置时先选择，安装 argv 显式带 `-s`，不再生成危险的裸 `adb install`。
- [x] 2.3 修改 `utils.ue_launch` 与 `utils.ue_logs`，统一使用全局 selected serial，移除“多设备重选/取第一台”的分散策略。
- [x] 2.4 修改 `ue.dap.android` 的 serial 优先级和设备 picker，保持显式程序化 serial 最高优先级、全局 serial 次之，并锁住 K30 URL/ADB serial 一致性。
- [x] 2.5 全仓审计设备定向 ADB 发起点，确认除 `adb devices -l` 外都显式含 `-s <serial>`，运行中流程继续使用捕获的 session serial。

## 3. 回归测试

- [x] 3.1 新建 `tests/cases/android_device_spec.lua`，覆盖列表解析、名称 + serial 展示、只选 ready、全局值写入/取消保留、无设备与 argv 构造。
- [x] 3.2 增加 install/launch/logcat/DAP 行为测试，覆盖全局 serial 路由、未设置 picker、explicit DAP serial 优先与 K30 URL 一致。
- [x] 3.3 更新 `tests/AGENTS.md` 与 `docs/testing-regression.md` 的 change-to-filter map，并运行最小 filters：`android_device`、`commands`、`keymaps`、`dap`、`utils`、`ue_context`、`structure`。
- [x] 3.4 运行全量 `nvim --headless -l tests/run.lua` 并确保全绿。
- [x] 3.5 处置全量回归揭示的 INDEX F1 既存 DI 缺口：补 scope resolver deps 与 forward declaration，使 `ue_project_context` 恢复全绿。

## 4. 文档与收尾

- [x] 4.1 更新 `docs/ue_lazyvim_cheatsheet.md` 与相关用户说明，记录 `<Space>uA`、全局变量和 `<Space>ui` 的 selected-device 语义。
- [x] 4.2 在 `docs/changelog.md` Unreleased 按模板追加记录，Validation 写明实际回归范围与结果。
- [x] 4.3 运行 `openspec validate select-global-android-device --strict`，并把本 tasks checklist 全部标记完成。
