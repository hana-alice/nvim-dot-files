# Tasks — Unreal iOS 构建与运行

## 1. 锁定既有平台行为

- [x] 1.1 为 `UEBuild`、`UELaunch`、Android 安装/设备选择和平台驱动接口补回归测试。
- [ ] 1.2 建立无证书、无设备、设备 unavailable、过期产物和错误 tuple 的失败 fixtures。
- [x] 1.3 记录支持的 UE/Xcode/SDK 探测输出形状，不把特定本机路径或身份写入 fixture。

## 2. IOS target-driver 边界

- [x] 2.1 将所有 IOS UBT/UAT、签名、产物、设备、安装和启动策略放入 `lua/ue/targets/ios.lua`。
- [x] 2.2 让 macOS host driver 只提供本机 executable/path primitives，不包含 IOS target 参数、设备状态或产物选择。
- [x] 2.3 确保 Mac、Android、Win64、Linux target driver 不包含 IOS 脚本、devicectl、签名或 artifact 逻辑。
- [x] 2.4 让核心命令层只通过 target registry/contract dispatch，不包含 IOS 条件分支或命令字符串。
- [x] 2.5 为 target module ownership、禁止跨 driver 调用、policy-free helper 和 structured unavailable 补结构/契约测试。

## 3. iOS 构建与打包规划

- [x] 3.1 在 IOS driver 中实现 macOS 原生 IOS UBT argv/cwd 纯规划器，并让 `:UEBuild` 正确按 active target 分派。
- [x] 3.2 增加 `:UEBuildIOS` 显式别名，确保只编译而不 Cook/Package/Install/Run。
- [x] 3.3 在 IOS driver 中实现 `RunUAT.sh BuildCookRun` argv/cwd/artifact-root 纯规划器。
- [ ] 3.4 增加 `:UEPackageIOS` 异步任务，覆盖 build/cook/stage/package/archive 成功、失败和取消，并证明 UAT ProjectParams 未启用 Deploy/Run。
- [x] 3.5 确保项目、target、configuration、archive directory 均来自解析后的上下文或显式配置，不硬编码私有标识。

## 4. 工具链与签名预检

- [ ] 4.1 探测 Xcode developer directory、iPhoneOS SDK、引擎自带 dotnet、AutomationTool、UBT/UAT 入口与 devicectl。
- [ ] 4.2 按阶段执行只读预检：Build 不要求签名；Package/Install 检查有效 code-sign identity、工程 iOS settings 与 provisioning 可解析性。
- [ ] 4.3 对缺失、不兼容和不可解析状态给出分项错误；不得导入证书或请求/持久化私钥密码。
- [ ] 4.4 对命令、日志和状态中的用户路径、team/certificate identity 与环境秘密执行脱敏。

## 5. 设备选择

- [x] 5.1 在 IOS driver 中用 `devicectl list devices --json-output` 临时文件实现结构化设备发现并确保清理。
- [x] 5.2 增加 `:UESetIOSDevice`，只列出可用物理 iOS 设备，并保存 IOS-scoped 稳定 identifier 与非秘密显示名。
- [x] 5.3 在 install/launch 任务开始时捕获一次 device identifier，禁止中途切换。
- [ ] 5.4 覆盖空列表、unavailable、重复名称、JSON schema 缺失和命令失败测试。

## 6. 产物、安装与启动

- [ ] 6.1 在 IOS driver 中记录 package 任务的 tuple-scoped `.app`、`.ipa`、dSYM 与 xcarchive provenance。
- [x] 6.2 从当前 staged `.app/Info.plist` 读取真实 bundle identifier，拒绝跨 target/configuration 的 newest-file 猜测。
- [x] 6.3 增加 `:UEInstallIOS`，通过 IOS driver/devicectl 把当前 `.app` 安装到捕获设备。
- [x] 6.4 扩展 `:UELaunch` 的 target dispatch，通过 IOS driver 启动真实 bundle id，且不调用 DAP。
- [x] 6.5 解析结构化安装/启动结果，以退出码、设备、bundle id 和进程证据共同判定成功。
- [x] 6.6 证明外置设备流程不调用或静默回退到 UE legacy fastlane/ideviceinstaller/instruments 后端。

## 7. 任务生命周期与 UX

- [ ] 7.1 为 Build、Package、Install、Launch 定义 IOS-scoped 独立异步状态、取消传播与冲突任务互斥。
- [ ] 7.2 失败时保留此前产物但标记为 stale/non-current，不继续下游阶段。
- [ ] 7.3 更新状态、quickfix/log surface、命令帮助和 cheatsheet，避免高频通知。
- [x] 7.4 对无证书、无设备等外部 gate 显示可行动下一步，不伪报完成。

## 8. 验证与交付

- [x] 8.1 运行 target-driver、host-platform、commands、UE API、keymaps、异步执行器及新增 ios build/device/artifact 测试。
- [ ] 8.2 在 macOS headless 环境验证所有 argv、cwd、JSON、脱敏、失败和取消路径，并检查核心/Mac/Android 模块没有 IOS 策略。
- [x] 8.3 运行 lint、静态检查与完整测试套件，修复本变更造成或暴露的跨平台失败。
- [ ] 8.4 在有效 code-sign identity、provisioning 和可用真机齐备后执行 Build → Package → Install → Launch 人工 E2E。
- [ ] 8.5 保存脱敏的 UBT/UAT/devicectl 退出证据；未通过真实设备 gate 前不得宣称端到端完成。
- [x] 8.6 在实现完成后更新 changelog/milestone，并记录 UE/Xcode 版本兼容风险。
