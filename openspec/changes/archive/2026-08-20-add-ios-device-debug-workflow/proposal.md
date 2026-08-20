# Proposal — add-ios-device-debug-workflow

## Why

现有 iOS 管线已经能在 macOS 上完成 build、package、真机选择、install、普通 launch，并保存
device、bundle、PID 与本地 binary/dSYM UUID 证据；但 `lua/ue/dap/ios.lua` 仍明确 unsupported，
仓库没有证明 CoreDevice 或 pre-iOS17 MobileDevice/debugserver、真机 process attach、iOS 专用 lldb-dap 配置、断点命中或
detach 清理。

同时，现有 build-run 契约有两个会直接影响调试可信度的缺口：签名只验证“至少存在一张证书”，
没有由用户命令固定本工程使用的 identity；“增量构建”也需要明确哪些阶段可以凭证据跳过，不能把
UBT 的 `-SkipBuild` 与安全的 AOT/dSYM/Cook 复用混为一谈。

本变更只处理 macOS 上运行 Neovim 的 iOS 真机调试及其必要前置。Windows/SSH、远程 DAP bridge、
跨主机 source mapping 不在范围内。

## What Changes

- 新增 iOS 签名证书选择契约：由 `:UESetIOSSigningCertificate` 探测当前 keychain、显式选择或设置
  identity，并以 project-scoped 状态固定；Build 在存在显式选择时捕获并复验它，
  Package/Install/debug 必须要求并复验所选 identity，不得静默使用第一张有效证书。
- 收紧 iOS 增量构建契约：UBT 仍负责 C++ dirty action 判定；只有拥有当前 tuple、输入与输出证据的
  AOT、dSYM、Build/Cook 与 clean-stage 工作可以跳过，禁止用 `-SkipBuild` 代替日常 C++ 编译。
- 先增加独立 CLI/raw-DAP protocol spike；backend 必须按显式设备证据固定为 CoreDevice 或
  pre-iOS17 MobileDevice/debugserver，不能在 session 内 fallback。在完整真机证据产生前，IOS matrix 继续不声明
  `dap_attach`/`dap_launch`。
- spike 成功后实现 iOS 专用 Apple lldb-dap adapter、不可变 debug context、attach 与
  launch-under-debug，并保持普通 `:UELaunch` 不进入 DAP。
- 将 `UEDAPStop`、session end 与 Vim 退出清理从 Android-only 分支改为 session-owned platform
  lifecycle；Android 的 ADB/lldb-server/JDWP 语义继续留在 Android handler。
- 成功标准包含设备/进程身份、本地 binary/dSYM/设备 image UUID、resolved breakpoint、真实
  breakpoint stop 与正确源码帧；headless 测试不能替代真机 gate。

## Capabilities

### New Capabilities

- `ios-device-debug-workflow`：在 macOS 本机 Neovim 中，通过已验证的 Apple/CoreDevice 或
  pre-iOS17 MobileDevice/debugserver 链路 attach
  或 debug-launch 物理 iOS 设备上的 Unreal 应用。

### Modified Capabilities

- `ios-build-run-workflow`：增加显式签名 identity 命令与分阶段增量跳过契约，作为 iOS debug 的
  可追溯前置。

## Impact

- 预计修改 `lua/ue/targets/ios.lua`、`lua/ue/dap/ios.lua`、`lua/ue/dap/platforms.lua`、
  `lua/ue/dap.lua`、`lua/ue.lua`、iOS iteration script、命令文档和对应回归。
- 预计新增独立 protocol probe、脱敏 fixture 与真机验收记录；probe 先于生产 DAP 实现。
- 不引入新依赖，不修改 Unreal Engine/工程源码，不导入证书或 provisioning profile，不保存私钥、
  密码或完整设备标识，不复用 Mac PID attach，不实现 Windows/SSH。
