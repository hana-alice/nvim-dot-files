# Design — macOS 本机 Neovim 的 iOS 真机调试

## Context

当前链路已经提供：

- `targets/ios.lua` 的结构化 device/install/launch plan 与结果解析；
- 成功 launch 后的 `device_id`、`bundle_id`、`process_id`；
- tuple-scoped staged `.app` provenance；
- `:UEIOSSymbols` 生成 dSYM 并比较 host binary/dSYM UUID；
- nvim-dap 的通用 UI、断点持久化、Apple host executable discovery 与 platform registry。

当前链路没有证明：

- selected Xcode 与哪一个 `lldb-dap` 组合可以驱动当前设备；
- CoreDevice 或 pre-iOS17 MobileDevice/debugserver 的真实连接、attach 与 teardown 顺序；
- 普通 launch 后 attach 是否可用，或是否必须 start-stopped；
- 设备已加载 image UUID 是否与本地 binary/dSYM 一致；
- breakpoint 是否 resolved、真实命中且 frame 能映射到当前 checkout。

因此生产实现不能先猜 `platform connect`、端口、debugserver 路径或 Homebrew/Xcode adapter 兼容性。

## Goals / Non-Goals

### Goals

- 以真机 protocol evidence 决定 Apple adapter、CoreDevice 命令与 cleanup 顺序。
- 为现有进程 attach 和 launch-under-debug 建立互不混淆的生命周期。
- 将 project tuple、artifact、signing identity、device、bundle、PID、binary、dSYM 与 UUID 固定为一次
  session 的不可变 debug context。
- 在首次 continue 前下发断点，并以 resolved + breakpoint stop + source frame 作为成功证据。
- 保持 Android 行为不变，并把通用 session lifecycle 与平台私有 transport 分离。

### Non-Goals

- 不实现 Windows controller、SSH executor、远程 stdio bridge 或跨主机 source mapping。
- 不支持 simulator。
- 不自行部署未知版本的 debugserver；legacy backend 只能挂载 Xcode 匹配的 DeveloperDiskImage，并由
  `ios-deploy` 建立 loopback bridge，不能建立 ADB 风格的任意手工转发。
- 不自动导入、创建或选择 provisioning profile，不接触证书私钥和密码。
- 不把普通 `:UELaunch` 改成 debug launch。
- 不在真机 spike 通过前向 matrix 宣称 IOS DAP 可用。

## Decisions

### 1. 先修正签名身份契约

新增 `:UESetIOSSigningCertificate[!] [identity]`：

- 无参数时若当前标准项目或 `workspace/Source/SampleGame` 布局存在由 `PrepareIOSQADebug.sh` 写入的
  `Saved/IOSQADebug/signing.json`，先 fail-closed 验证其 v1/debug/profile/application identity 字段，
  再用其中 SHA-1/显示名精确复验 keychain；没有 manifest 时才显示当前有效 identity picker；
- 参数可以是当前探测结果中的精确显示名或 SHA-1 fingerprint，必须先解析为唯一有效 identity；
- 保存 project-scoped fingerprint 与显示名；bang 清除显式选择并恢复“未配置”，不是选择第一张证书；
- 对 UBT/UAT 使用命令行 INI override 注入
  `[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:SigningCertificate`，不修改工程 ini；
- Build/Package/Install/debug preflight 重新探测 keychain，并要求 fingerprint 与当前选择一致；证书过期、
  消失或歧义均失败；
- 日志、probe 与 changelog 不记录完整显示名、team id 或 fingerprint。

签名 identity 是项目输入，不是设备 runtime 状态；多 Neovim 实例通过现有 project-state 原子更新语义
读取它。长任务在开始时复制一次选择，任务中途重新选择只影响后续任务。

### 2. 增量构建使用阶段矩阵，不使用笼统 fast path

`Build.sh` 必须继续运行，以便 UBT 根据 makefile/action graph 发现 C++、header、Build.cs、Target.cs、
toolchain 与配置变更。`-SkipBuild` 只适合“不执行 compile actions”的语义准备/打包复用，不能加入
`:UEBuildIOS`。

可跳过工作按证据分层：

| 工作 | 允许跳过的证据 | miss 行为 |
|---|---|---|
| 未变化 C++ compile/link action | UBT 自己的当前 target makefile/action graph | 交给 UBT 重建 |
| AOT | 当前 tuple、SDK/toolchain、全部 AOT 输入与上次成功输出 manifest 匹配 | 清除继承 skip 变量并完整 AOT |
| 自动 dSYM/ZIP | 日常 build 固定关闭；需要时显式 `:UEIOSSymbols` | 独立生成并验 UUID |
| Package 中的 Build/Cook | 成功 build 与既有 cooked data 明确属于当前 tuple | package 使用 `-skipbuild -skipcook` |
| clean stage | 当前 local-iteration package 使用 `-nocleanstage` | release/distribution 走独立 clean pipeline |

AOT fingerprint 计算本身可以缓存每个输入的 `path + device + inode + size + mtime + ctime + content hash`。metadata 未变时可复用
上次 content hash；metadata 变化时必须重新 hash，output artifact 仍需逐个验证。缓存只减少重复校验 I/O，
不得改变 fail-closed 语义。若未来要按 assembly 局部 AOT，必须先由工程 AOT adapter 提供原生的分片
输入/输出契约；Nvim wrapper 不复制或猜测工程编译逻辑。

### 3. Protocol spike 是 matrix capability 的门禁

Backend 选择属于 debug context，必须在 session 开始前显式固定，失败后不能换另一 backend 重试同一
session：

- CoreDevice 只用于 `devicectl` 能报告为已配对、physical、tunnel connected 的设备；
- 对 CoreDevice 不可达但 MobileDevice USB 明确检测到的 pre-iOS17 设备，允许使用
  `ios-deploy`/Xcode DeveloperDiskImage/debugserver loopback bridge；必须先具备与 ProductType、OS、build
  精确匹配的 DeviceSupport `Symbols`，并验证设备已显式信任当前 development profile；
- iOS 17+ 不得走 legacy backend，legacy 失败也不得静默退回 CoreDevice 或其他 `lldb-dap`。

当前实机证据已证明 pre-iOS17 USB 设备、精确 DeviceSupport、DeveloperDiskImage、debugserver listener、
LLDB `remote-ios` 与 target create；设备端明确以 `Needs Explicit User Trust` 拒绝 launch，且现有重签包
没有 source DWARF。因此该结果只能标记为 partial/blocked，不能解锁 matrix。

新增独立、参数化 probe，先做“已运行 app attach”，不依赖 Neovim UI。probe 顺序：

1. 记录 selected Xcode、devicectl、LLDB 与每个候选 lldb-dap 的绝对路径和版本；
2. 以显式 device identity 选择 CoreDevice 或 legacy backend，并捕获同一 bundle 的存活 PID；
3. 验证 Developer Mode、debug entitlement、所选签名身份、binary/dSYM UUID；
4. 用 Apple LLDB CLI 证明 target create、设备选择/连接、process attach、threads、loaded image UUID、
   breakpoint resolve/hit 与 detach；
5. 再用 raw DAP 执行 `initialize → attach → initialized → setBreakpoints → configurationDone →
   threads → continue → stopped → stackTrace → disconnect`；
6. `disconnect` 使用 `terminateDebuggee=false`，并证明 app 存活且没有本次 probe 的残留 helper。

所有具体 LLDB/CoreDevice/MobileDevice 命令、adapter 选择与 teardown 顺序由该证据固化。在此之前，
`targets/ios.lua` 不增加 `dap_attach`/`dap_launch` capability，`ue.dap.ios` 继续返回 unavailable。

### 4. debug context 在 session 开始时冻结

一次 session 至少捕获：

```text
project/target/IOS/configuration
signing identity fingerprint (redacted in logs)
package task/artifact identity
exact .app + CFBundleIdentifier
device identifier
process identifier or launch token
local Mach-O + dSYM
host binary UUID + dSYM UUID + loaded image UUID
adapter absolute path + selected Xcode identity
source roots/source-map evidence
```

任何 identity mismatch、stale PID、缺失 dSYM、UUID mismatch 或 device disconnect 都必须在 continue 前
失败。全局项目、设备或签名选择在 session 期间改变，不得改变已捕获 context。

### 5. iOS 使用独立 Apple adapter 和 handler

`ue.dap.ios` 拥有 Apple device policy；`targets/ios.lua` 拥有 device/app/debug-launch plan；macOS host
driver 只提供 executable primitive。iOS adapter 使用独立 id，不覆盖 Mac/Android adapter，也不按通用
候选顺序静默选 Homebrew LLVM。

生产 attach config 由 spike 决定。允许复用 `_common` 的 DAP 加载、环境与 UI helper，但不得复用：

- Mac 本机 PID picker/attach；
- Android ADB serial、lldb-server staging/forward、JDWP、ASLR slide、`/proc/maps`、信号策略、
  breakpoint preseed/live-plant 或 logcat cleanup。

### 6. attach 与 debug launch 分离

- `UEDAPAttach ios` 只连接已运行且身份复验通过的进程；stop 默认 detach，不终止 app。
- `UEDAPLaunch ios` 使用单独的 `dap_launch_plan`。若 spike 证明需要 start-stopped，则该 plan 可以使用
  devicectl 的相应参数；普通 `launch_plan` 永远不带该参数。
- debug-launch 创建的 suspended process 若 bootstrap 失败，必须按 spike 证明的顺序 resume 或 terminate，
  不能遗留冻结进程。

### 7. lifecycle 由 session owner 分派

`UEDAPStop`、DAP terminated/exited、adapter error 与 `VimLeavePre` 根据 session metadata 调用所属平台的
幂等 cleanup。公共层只管理一次性调用和 UI 状态；iOS/Android handler 各自清理 transport 资源。

attach-owned app 使用 `disconnect(terminateDebuggee=false)`；debug-launch-owned app 的 stop policy 由
配置 metadata 明确表达。清理不得依赖配置名称字符串，也不得清理另一 session 的设备/PID/temp 文件。

### 8. 成功与日志必须可验证且脱敏

“DAP started”不是成功。真机验收必须同时证明 adapter alive、同一 device/bundle/PID、三方 UUID 一致、
breakpoint `verified=true`、`stopped.reason=breakpoint` 与 stack frame 指向预期本地源码行。

probe/log 只保存工具版本、阶段、脱敏 identity digest、退出码、UUID 比较结果、断点与 cleanup 结果；不保存
完整 device id、证书、bundle、个人绝对路径或环境秘密。无真机/签名时结果是 blocked/not-run，不能被
headless 全绿替代。

## Risks / Trade-offs

- Xcode、设备 OS 与 CoreDevice/MobileDevice/LLDB 命令会变化，所以 adapter 与连接命令必须来自当前环境 spike，不能
  依赖历史命令记忆。
- 普通 launch 后 attach 可能错过早期断点；先交付 attach 可缩小协议未知面，launch-under-debug 是第二切片。
- 强制 loaded image UUID 校验会拒绝“看似能 attach”的旧包，但可避免错误符号导致的假断点。
- metadata-assisted AOT hash cache 理论上不能对抗同时伪造 inode/size/mtime/ctime 的离线篡改；输出仍逐个
  hash，输入在 metadata 变化时复算。若威胁模型要求对抗主动篡改，应保持每次全 hash。

## Migration Plan

1. 先交付签名 identity 命令和增量 skip evidence，保持 IOS DAP unavailable。
2. 运行独立 LLDB CLI/raw-DAP 真机 spike并保存脱敏 evidence。
3. 依据 evidence 增加纯 debug-launch planner、context validator 与 iOS DAP config 测试。
4. 实现 attach，完成真实 breakpoint-stop gate 后才在 matrix 声明 `dap_attach`。
5. 实现 launch-under-debug 与失败清理，完成 gate 后再声明 `dap_launch`。
6. 泛化 session-owned lifecycle，锁住 Android/Mac/Win/Linux 回归。
7. 更新文档、changelog、命令 freeze 与全量回归；真机 gate 单独记录。

回滚时先从 matrix 撤销 IOS DAP capability，再删除 handler；普通 iOS build/run 和既有产物不受影响。
