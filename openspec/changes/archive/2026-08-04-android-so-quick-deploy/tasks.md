## 1. SO-only 构建

- [x] 1.1 实现 PowerShell 两阶段 UBT action graph 构建，确保不进入 Android deploy/Gradle
- [x] 1.2 注册 `:UEBuildAndroidSO` 并按当前 Target、Platform、Configuration 构造命令
- [x] 1.3 绑定小写快捷键 `<leader>us`，保持现有 `<leader>ub` 行为不变

## 2. Root 设备快速部署

- [x] 2.1 精确选择当前配置 arm64 SO，并在临时副本执行 `llvm-strip --strip-unneeded`
- [x] 2.2 复用全局 Android serial 和包名，动态解析已安装包的 native library 目录
- [x] 2.3 实现版本化原始 SO 备份、同目录原子替换、owner/mode/SELinux context 恢复和 hash 校验
- [x] 2.4 实现启动、PID、`/proc/<pid>/maps`、稳定性验证以及失败自动回滚
- [x] 2.5 注册 `:UEDeployAndroidSO` 并绑定小写快捷键 `<leader>uq`

## 3. 回归、文档与实机证据

- [x] 3.1 补充 UE API、命令、快捷键、AI context 与 cheatsheet headless tests
- [x] 3.2 更新 README、中文文档、快捷表和 changelog
- [x] 3.3 在真实 USB 设备执行 SO-only 构建，确认 SO 更新且 APK timestamp 不变
- [x] 3.4 实机验证 strip、push、原子替换、运行时 maps 加载和失败回滚
- [x] 3.5 对比 Gradle Debug、Gradle Release 与快速部署副本的大小和 SHA-256，确认三者一致
- [x] 3.6 运行全量 headless 回归并确认 `679/679 passed`
