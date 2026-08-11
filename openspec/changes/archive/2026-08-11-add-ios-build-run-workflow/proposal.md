# Proposal — add-ios-build-run-workflow

## Why

当前配置虽然可选择 `IOS`，但端到端应用流程仍以 Android/Windows 假设为主，无法在 macOS 上可靠完成 Unreal iOS 的编译、Cook、Stage、Package、安装和启动。设备选择、签名预检、产物身份与成功判据也没有 iOS 专用契约。

本变更独立于编辑器语义准备：它交付的是可运行的 iOS 应用，不负责 clangd CDB、Tree-sitter 或索引。

## What Changes

- 让 `:UEBuild` 在当前平台为 `IOS` 时使用 macOS 原生 UBT；提供显式 `:UEBuildIOS` 别名用于只编译目标。
- 所有 IOS-specific BuildCookRun、签名、产物、设备、安装和启动策略只实现在 `lua/ue/targets/ios.lua`；不得放入核心调度层、Mac target driver 或 Android target driver。
- 新增 `:UEPackageIOS`，通过 `RunUAT.sh BuildCookRun` 执行 Build、Cook、Stage、Package 与 Archive，并明确不启用 UAT 的 Deploy/Run。
- 新增 `:UESetIOSDevice`，通过 `xcrun devicectl` 的结构化 JSON 输出选择可用真机，并持久化非秘密设备选择。
- 新增 `:UEInstallIOS`，通过外置 devicectl 后端把当前 tuple 的 staged `.app` 安装到一次任务内固定的设备；不调用 UE 4.26 legacy deploy/run 后端。
- 扩展 `:UELaunch` 的 IOS 分派，使用 app bundle identifier 启动已安装应用；不隐式进入 DAP。
- 新增 Xcode、iPhoneOS SDK、code-sign identity、provisioning、设备与产物预检；不得自动导入证书或保存私钥密码。
- 任务使用异步、可取消生命周期，成功必须由工具退出结果和设备返回证据共同确认。

## Capabilities

### New Capabilities

- `ios-build-run-workflow`：在 macOS 宿主上为 Unreal iOS 工程提供可追溯的编译、打包、安装与启动流程。

### Modified Capabilities

- 无。Android 安装/启动与既有 CDB 能力不在本变更中改写。

## Impact

- 预计修改 UE 命令注册、IOS target driver、macOS host driver、异步任务、产物解析和配置持久化模块；Mac/Android target driver 仅接受 contract 回归验证，不承载 IOS 行为。
- 预计新增 UBT/UAT argv 规划、签名预检、devicectl JSON、staged app 选择、安装和启动测试。
- 预计更新命令帮助、cheatsheet 和 macOS/iOS 使用文档。
- 不引入新依赖，不导入证书，不上传 TestFlight/App Store，不修改 Engine/项目源码，不调用基于 fastlane/ideviceinstaller/instruments 的 UE legacy Deploy/Run，不实现 iOS DAP。
