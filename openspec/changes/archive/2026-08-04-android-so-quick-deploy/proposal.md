## Why

当前 Android C++ 迭代会在 UBT 编译完成后继续进入 Gradle 组包，且每次通过 APK 安装更新 `libUE4.so`，造成数十秒到数分钟的额外等待。已连接的 userdebug/root 测试设备允许安全替换已安装应用的 native library，因此需要一条不修改引擎或项目代码、可验证且可回滚的 SO-only 快速迭代链路。

## What Changes

- 新增 Android SO-only 构建命令，通过 UBT 导出并执行 outdated action graph，仅完成编译/链接，不进入 Gradle 或生成 APK。
- 新增 root 设备快速部署命令：按当前项目、Target、Configuration 和已选 Android serial 定位 SO，使用与正常 APK 一致的 strip 规则后替换设备端 `libUE4.so`。
- 部署前按已安装 APK 路径保存原始 SO；替换时恢复 owner、mode 和 SELinux context，并在 hash、进程存活或 `/proc/<pid>/maps` 验证失败时自动回滚。
- 新增小写快捷键 `<leader>us` 和 `<leader>uq`，并复用现有 `:UESetAndroidDevice`、包名状态、任务终端与日志设施。
- 补充命令、快捷键、AI context、cheatsheet 与文档回归覆盖。

## Capabilities

### New Capabilities

- `android-so-quick-deploy`: 规定 Android SO-only 构建、配置一致的 strip、root 设备原子替换、自动回滚和运行时加载验证行为。

### Modified Capabilities

无。

## Impact

- 受影响代码：`lua/ue.lua`、`lua/config/keymaps.lua`、`lua/utils/cheatsheet.lua`。
- 新增本地脚本：`scripts/ue_android_so_build.ps1`、`scripts/ue_android_so_deploy.ps1`。
- 受影响测试与文档：命令、快捷键、UE API、AI context、cheatsheet 回归，以及 README、中文文档、快捷表和 changelog。
- 外部边界：不修改 UE 引擎或游戏项目源码；部署要求已安装目标包且设备支持 `su 0`。非 root/正式设备继续使用正常 APK 安装流程。
- 依赖：复用现有 PowerShell、ADB、UBT 和 Android NDK 工具，不新增依赖。
