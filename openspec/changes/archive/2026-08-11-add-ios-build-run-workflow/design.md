# Design — Unreal iOS 构建与运行

## Context

定制 UE 4.26.2-derived 工具链在 macOS 上提供三个可验证入口：

- `Engine/Build/BatchFiles/Mac/Build.sh`：调用 UnrealBuildTool 编译 target；
- `Engine/Build/BatchFiles/RunUAT.sh`：调用 AutomationTool；
- `BuildCookRun`：按 Build → Cook → Stage → Package → Archive → Deploy → Run 的阶段模型执行应用流水线；具体阶段由参数启用。

iOS AutomationTool 可生成 `Binaries/IOS/*.ipa`、`Binaries/IOS/Payload/*.app`、dSYM 与可选 xcarchive；`Saved/StagedBuilds/IOS` 是随后被复制进 app bundle 的原始 stage tree，不是可直接安装的签名 app。UE 4.26 legacy 设备链路使用 fastlane/ideviceinstaller/instruments，但现代 Xcode 提供 `xcrun devicectl` 的结构化设备、安装与启动接口。本设计让 UAT 停在 Archive，再由外置 devicectl 后端优先安装 packaged `.app`；`.ipa` 作为归档/分发产物，不进入 legacy deploy/run。

探索环境已具备 Xcode、iPhoneOS SDK 与 devicectl，但没有可用 code-sign identity，也没有可连接设备。因此提案与命令规划可以实现和自动测试；真实设备验收必须作为明确的外部 gate，而不能伪装成已通过。

## Goals / Non-Goals

### Goals

- 在 macOS 上用原生 UBT/UAT 构建和打包 Unreal iOS 应用。
- 将所有 IOS target-specific 策略封装在独立 IOS driver，不污染 Mac、Android 或核心调度模块。
- 在执行前准确检查签名、SDK、设备和产物条件。
- 选择精确 tuple 的 `.app`，安装到固定设备并按真实 bundle id 启动。
- 让所有阶段异步、可取消、可观察，并保留可复现的脱敏命令证据。
- 保持 Android 和其他平台行为兼容。

### Non-Goals

- 不生成或维护 clangd CDB，也不触发 Tree-sitter/索引刷新。
- 不自动导入 `.p12`、证书或 provisioning profile，不保存密码/私钥。
- 不上传 TestFlight、App Store Connect 或其他分发服务。
- 不实现远程 Mac 构建、iOS Simulator 或原生 iOS DAP。
- 不新增 macOS→Android 构建、部署或运行能力；Android 仍走既有 Windows 工作流。
- 不调用或适配 UE 4.26 的 fastlane/ideviceinstaller/instruments Deploy/Run 后端。
- 不修改 Unreal Engine 或游戏工程源码来绕过签名/构建失败。

## Decisions

### 0. IOS target driver 独占 IOS 平台策略

本变更遵循 host/target 双层架构：

- `lua/utils/platform/macos.lua` 是 macOS host driver，只提供 `Build.sh`、`RunUAT.sh`、`xcrun`、`security`、`plutil` 等本机 executable/path primitives；
- `lua/ue/targets/ios.lua` 是 IOS target driver，独占 IOS 的 UBT/UAT argv、签名预检、artifact provenance、device discovery、install 与 launch 规则；
- `lua/ue/targets/mac.lua` 只实现 Mac target，不得因为同属 Apple host 而承载 IOS package/device 逻辑；
- `lua/ue/targets/android.lua` 只实现 Android target，不得被 IOS workflow 调用或作为 fallback；
- Android 的既有 PowerShell 兼容代码只允许存在于 Windows 专属适配器，macOS host 不声明该能力；
- registry/core 只按统一 contract dispatch，不出现 `if platform == "IOS"`、devicectl 命令或 iOS artifact 路径。

IOS driver 对外返回纯 plan/result descriptor；通用异步执行器可以执行这些 descriptor，但不解释 IOS 参数。共享 helper 只允许做 schema validation、argv/path normalization、redaction 等无状态工作，不得保存设备、签名、产物或平台默认策略。

### 1. 编译、打包、安装、启动是四个显式阶段

- `:UEBuild` 在 active platform 为 `IOS` 时执行原生 UBT 编译；`:UEBuildIOS` 是显式别名。
- `:UEPackageIOS` 执行 UAT BuildCookRun 的 Build/Cook/Stage/Package/Archive 阶段并发布 tuple-scoped 产物状态；不得启用 UAT Deploy/Run。
- `:UEInstallIOS` 安装已存在的 staged `.app`，不隐式重新打包。
- `:UELaunch` 根据 active platform 分派到 iOS launch，且不隐式安装或进入 DAP。

每个阶段都可以独立失败和重试。系统不得因为找到旧 `.ipa` 就跳过当前 tuple 的校验，也不得把“打包成功”报告成“设备运行成功”。UAT 未启用 Deploy/Run，因此外置 Install/Launch 是唯一设备成功来源。

该能力可以复用语义编译提案引入的 macOS host-driver build entry 和 IOS target driver 的无状态 build planner，但不得调用 `UECompileForNvim` 或 `UEPrepare`，也不读写 CDB/clangd 状态。共享的是 driver contract 与纯命令规划，不是两个 workflow 的生命周期；Mac target 与 Android target 保持独立实现。

### 2. UAT 命令由结构化参数计划生成

macOS 打包计划使用：

```text
<ENGINE_ROOT>/Engine/Build/BatchFiles/RunUAT.sh
  -ScriptsForProject=<UPROJECT>
  BuildCookRun
  -nop4
  -project=<UPROJECT>
  -target=<TARGET>
  -targetplatform=IOS
  -clientconfig=<CONFIGURATION>
  -build -cook -stage -package -archive
  -archivedirectory=<ARCHIVE_DIR>
  -utf8output
```

计划不得启用 `-deploy` 或 `-run`；若当前 UAT 版本支持显式 false 形式，可以使用等价的显式禁用参数，否则通过缺省 false 并对解析后的 ProjectParams 做测试证明。pak、compression、manifest、prerequisite 等可选项来自已有项目配置或显式非秘密选项，不用项目名称或本机路径硬编码。所有参数保持 argv 数组，cwd 和产物目录由纯规划函数返回，便于 headless 测试。

### 3. 签名只做读取和预检

签名配置优先遵循工程 `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]`、UBT/UAT 的 provisioning 推导与 macOS keychain 的现有状态。预检按阶段收紧：Build 只要求可用的 Xcode、SDK、引擎自带 dotnet 与编译入口；进入 Package/Install 前再要求签名身份与 provisioning。完整预检至少确认：

- `xcode-select` 指向可用 Xcode；
- iPhoneOS SDK 可用；
- `Build.sh`、`RunUAT.sh`、AutomationTool 与引擎自带 dotnet 启动链可用；
- 存在有效 code-sign identity；
- 所需 provisioning 信息可由 UBT/UAT 解析；
- bundle identifier 可确定。

Neovim 不导入证书、不解密或复制私钥、不接收/持久化 `.p12` 密码。日志必须遮蔽个人证书名称、团队标识、用户目录与环境秘密。预检失败返回具体缺失项和人工修复方向。

### 4. devicectl JSON 是设备发现的事实来源

`UESetIOSDevice` 使用 `xcrun devicectl list devices --json-output <TEMP_FILE>`，读取完成后解析 JSON 并删除临时文件。不得解析面向人的表格文本。

候选仅包含当前可用的物理 iOS 设备。选择结果保存稳定 device identifier 和非敏感显示名。每次 install/launch 在任务开始时复制一次 device identifier，后续阶段不得因全局选择变化而改投另一设备。

没有设备或设备变为 unavailable 时任务必须失败，不得选择“第一个历史设备”或静默 fallback。

### 5. 产物必须匹配当前 tuple

打包成功后记录 project/target/platform/configuration、UAT 任务标识以及 `.app`、`.ipa`、dSYM、xcarchive 的精确路径与指纹。安装只选择当前成功任务产生的 `Binaries/IOS/Payload/<TARGET>.app`；不得把原始 `Saved/StagedBuilds/IOS` 目录伪装成可安装 app。

若只能从磁盘恢复产物，必须证明其属于当前 tuple，并读取 `.app/Info.plist` 获得实际 `CFBundleIdentifier`。不得以“修改时间最新”为唯一条件跨 target/configuration 选择产物，也不得硬编码 bundle id。

### 6. 安装和启动使用独立的现代 Xcode 设备后端

安装计划：

```text
xcrun devicectl device install app
  --device <CAPTURED_DEVICE_ID>
  <STAGED_APP>
```

启动计划：

```text
xcrun devicectl device process launch
  --device <CAPTURED_DEVICE_ID>
  <BUNDLE_IDENTIFIER>
```

如需机器可读结果，应使用 devicectl 支持的 JSON 文件输出并在完成后解析，不能依赖本地化控制台文本。`.ipa` 留作 archive/distribution；不引入新的第三方安装依赖。UE legacy fastlane/ideviceinstaller/instruments 后端可作为未来显式兼容模式评估，但本变更不调用或静默 fallback 到该后端。

### 7. 成功判据逐阶段收紧

- Build：macOS `Build.sh` 包装脚本按其兼容映射返回成功，且目标产物与 tuple 一致；调用方不得重新解释脚本内部的原始 UBT 状态码。
- Package：UAT 退出码为 0，且当前任务记录所需 `.app`/`.ipa` 产物。
- Install：devicectl 退出码为 0，结构化结果确认目标设备和应用安装。
- Launch：devicectl 退出码为 0，结构化结果确认 bundle id 已启动并返回进程证据。因为不使用 UAT Run，成功判据不读取 legacy instruments 的后处理状态。

任何阶段都不得只因文件存在或进程曾启动就宣称成功。失败保留此前成功产物，但将其标记为非本次任务结果。

### 8. 运行不等于调试

`UELaunch` 只启动应用。它不调用 `UEDAPAttach`，也不把现有 macOS PID attach 伪装成 iOS 真机调试。iOS DAP/LLDB 远程调试需要独立提案处理 device support、debugserver、符号和生命周期。

### 9. 任务共享异步、取消与可观察性契约

Build、Package、Install、Launch 分别进入既有异步任务 surface；同一工程的冲突写阶段必须串行。取消 UAT 后不得继续安装，取消安装后不得继续启动。日志展示脱敏 argv、cwd、设备显示名、阶段、退出码和 artifact identity，高频进度不使用通知刷屏。

## Risks / Trade-offs

- UE 4.26 派生版本与新 Xcode/iOS SDK 可能存在兼容性问题。预检和真实构建日志必须把版本不兼容与 Neovim 编排错误区分开。
- `devicectl` JSON schema 可能随 Xcode 变化。解析器只依赖验证过的最小字段，并为未知 schema 返回显式错误与 fixtures。
- 使用 staged `.app` 安装比直接安装 `.ipa` 更符合 devicectl，但要求保留 stage 目录。清理策略必须避免在 install 前删除该目录。
- IOS driver 的职责较多，但按技术层再拆成跨平台“通用 package/device abstraction”会重新混合策略。优先在 `ios.lua` 内用局部纯函数分区，只有被第二个 target 以完全相同语义复用后才提取 policy-free helper。
- 真机测试依赖外部签名与设备状态，CI 只能覆盖规划、解析和失败路径；真实 gate 必须诚实记录。

## Migration Plan

1. 锁定 Android/Mac/Win64/Linux target driver 与 Windows/macOS/Linux host driver 的既有行为。
2. 在 IOS target driver 内引入纯 UBT/UAT/设备/产物规划器及 fixtures；核心层只接 contract。
3. 接入 iOS build 与 package 命令，完成无证书失败路径验证，并证明 Mac/Android driver 未承载 IOS 逻辑。
4. 在 IOS driver 内接入 devicectl JSON 设备选择、`.app` 安装和 bundle-id 启动。
5. 补齐任务取消、并发互斥、日志脱敏与 IOS-scoped 状态展示。
6. 更新 target-driver 架构文档与 cheatsheet，运行 headless/full suite 及平台隔离检查。
7. 在具备有效签名身份和可用真机后执行人工 E2E gate，并保存脱敏证据。

回滚时可删除 iOS 专用命令与分派；已生成的 Unreal 产物不由 Neovim 自动删除。
