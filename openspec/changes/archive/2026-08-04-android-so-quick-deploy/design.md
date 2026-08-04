## Context

现有 Android 构建入口直接执行定制 UE 引擎的 `Build.bat`。实测证明 `-SkipDeploy` 会被 Android platform reset 覆盖，仍进入 Gradle，因此不能作为可靠的 SO-only 边界。测试设备是同一物理设备的 USB/TCP 两个 ADB serial，已安装目标包并支持 `su 0`；设备上的 `nativeLibraryDir` 位于版本化 `/data/app/...` 路径，APK 重装后可能变化。

正常 Gradle Debug 与 Release 的 `libUE4.so` strip 输出均与 NDK `llvm-strip --strip-unneeded` 结果逐字节一致，而 `Binaries/Android` 原始 SO 保留 DWARF 和静态符号表。完整行为合同见 `specs/android-so-quick-deploy/spec.md`。

## Goals / Non-Goals

**Goals:**

- 在不修改引擎或游戏项目源码的前提下切断 UBT 编译与 Android Deploy/Gradle 组包。
- 复用当前 Neovim 项目、Target、Configuration、设备 serial 和包名状态。
- 使设备 SO 与正常 APK 打包后的 SO 保持一致，同时保留主机完整符号文件。
- 对 root 替换提供备份、原子更新、metadata 恢复、hash 和运行时映射验证。

**Non-Goals:**

- 不支持非 root 正式设备绕过 APK 安装。
- 不热替换正在运行进程已映射的 SO；流程会停止并重启应用。
- 不覆盖 Manifest、Java/Kotlin、资源、Pak、AAR 或其他必须重新打包的变更。
- 不修改或修补 UBT、AutomationTool、Gradle 模板和游戏 Target 文件。

## Decisions

### 使用 UBT action graph 两阶段执行

构建脚本先通过 `-WriteOutdatedActions=<temp-json>` 导出当前过期 actions，再以 `-Mode=Execute -Actions=<temp-json>` 执行。`WriteOutdatedActions` 分支不会进入 deploy loop，Execute mode 只执行已导出的 action graph，从控制流上隔离 Gradle。

拒绝直接依赖 `-SkipDeploy`：该定制引擎在 Android platform reset 中重新启用 `bDeployAfterCompile`，实测仍运行 Gradle 并在 package task 失败。

### 在临时副本上统一执行 `--strip-unneeded`

部署脚本不直接推送带 DWARF 的原始 SO，而是使用项目 NDK 的 `llvm-strip` 生成临时副本。Debug Gradle、Release Gradle 与该副本的大小和 SHA-256 已独立验证一致。原始 SO 不变，可继续供 LLDB、CrashSight 或离线 symbolication 使用；strip 前后 GNU Build ID 保持一致。

拒绝推送未 strip SO：它不符合 APK 实际运行产物，传输和设备占用显著增大。拒绝 `--strip-debug`：它与当前 Gradle 输出不逐字节一致。

### 动态解析安装目录并按已选 serial 路由

通过 `dumpsys package <package>` 读取 `nativeLibraryDir`/`legacyNativeLibraryDir`，再探测 `arm64/libUE4.so` 和 flat fallback。所有操作使用共享 Android device helper 选择的 serial 并拼成 `adb -s <serial>`，避免同一设备 USB/TCP 双连接时出现歧义。

拒绝硬编码 `/data/app/...`：该路径包含安装生成 token，重装 APK 后会变化。

### 备份与同目录原子替换

备份目录以 `pm path` 返回值的 SHA-256 前缀区分安装实例，首次部署保存原始 SO。新文件先进入 `/data/local/tmp`，再由 root 复制到目标同目录的 `.nvim-new`，恢复 `system:system`、`0755` 和 SELinux context 后执行 `mv`。

同目录 rename 避免跨文件系统替换；版本化备份防止 APK 重装后错误恢复上一安装实例的 SO。

### 以运行时映射作为成功标准

文件复制成功不足以证明生效。部署完成后启动包、读取 PID 和 `/proc/<pid>/maps`，要求映射路径等于本次动态解析的目标文件，并在等待后再次检查进程存活。任何替换后失败触发自动回滚和重新启动原始版本。

## Risks / Trade-offs

- [root 直接修改 `/data/app` 不适用于正式设备] → 命令在替换前强制验证 `su 0`，文档明确非 root 继续走 APK。
- [APK 重装改变路径并覆盖 SO] → 每次部署重新解析目录，备份按安装 APK path 分桶。
- [错误配置 SO 可能启动即崩溃] → 精确按当前 Configuration 选文件，替换后检查进程与 maps，失败自动回滚。
- [大型 SO push 仍有传输成本] → 使用与 APK 一致的 stripped 副本，将实测 3.29 GB 原始 SO 降至约 347 MB。
- [并行执行 build 与 deploy 可能部署旧产物] → 保持两个显式原子命令，不将异步任务简单串接；构建失败不会自动进入部署。

## Migration Plan

1. 注册 `:UEBuildAndroidSO`/`:UEDeployAndroidSO` 与 `<leader>us`/`<leader>uq`。
2. 通过 headless tests 锁定命令、argv、快捷键、context 和 cheatsheet 行为。
3. 在 USB serial 上执行真实 SO-only 构建，确认 APK timestamp 不变。
4. 对照 Gradle Debug/Release strip 产物，确认部署副本 hash 一致。
5. 执行实机替换并验证 hash、metadata、PID、maps 和短期稳定性。
6. 如需撤销，重新安装 APK或使用版本化备份恢复原始 SO。
