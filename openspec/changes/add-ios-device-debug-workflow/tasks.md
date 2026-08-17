# Tasks — add-ios-device-debug-workflow

## 1. 前置契约修正

- [x] 1.1 在 IOS driver 中解析有效 code-sign identities，拒绝空、重复、过期或不唯一匹配。
- [x] 1.2 增加 `:UESetIOSSigningCertificate[!] [identity]`，异步 picker/direct-set/clear，并保存
  project-scoped fingerprint + display name。
- [ ] 1.3 将所选 identity 以命令行 INI override 传给 iOS Build/Package，并让 Package/Install/debug
  preflight 精确复验同一 identity；补多实例与日志脱敏测试。
- [x] 1.4 为 iOS iteration wrapper 增加 path/device/inode/size/mtime/ctime hash metadata cache，证明未变输入不重复 hash、metadata
  变化重新 hash、输出仍逐个校验，且 miss 始终完整 AOT。
- [x] 1.5 用 driver/script 测试冻结增量 skip matrix：Build.sh 始终执行；不得给 `:UEBuildIOS` 使用
  `-SkipBuild`；AOT/dSYM/Package Build/Cook/clean-stage 只按各自证据跳过。
## 2. 真机 protocol spike

- [x] 2.1 新增参数化 LLDB CLI/raw-DAP probe；不得包含现场 device、bundle、证书或绝对工程路径。
- [x] 2.2 探测并记录 selected Xcode、devicectl、LLDB、候选 lldb-dap 绝对路径与版本，逐个失败而非
  静默 fallback。
- [x] 2.2a 证明 pre-iOS17/CoreDevice 不可达设备的显式 legacy preflight：MobileDevice USB、
  `ios-deploy`、精确 ProductType/OS/build DeviceSupport、DeveloperDiskImage、debugserver listener 与
  LLDB `remote-ios` 可用；记录设备 profile 未信任与 source DWARF 缺失 blocker，保持 matrix unavailable。
- [ ] 2.3 在已运行 app 上证明 device/bundle/PID、Developer Mode、debug entitlement、
  binary/dSYM/loaded-image UUID、threads、resolved breakpoint、真实 stop frame。
- [ ] 2.4 证明 `disconnect(terminateDebuggee=false)` 后 app 存活且无残留 helper；覆盖 adapter crash、
  device disconnect 与初始化失败清理。
- [x] 2.5 保存脱敏 evidence；未完成 2.3–2.4 前不得修改 IOS DAP matrix。

## 3. 纯 planner、parser 与 debug context

- [ ] 3.1 在 IOS driver 中增加独立 `dap_launch_plan`；普通 `launch_plan` 明确不带 debug/start-stopped
  参数。
- [ ] 3.2 增加不可变 debug context builder，捕获 tuple、signing、artifact、device、bundle、PID、
  binary/dSYM/UUID、adapter/Xcode 与 source roots。
- [ ] 3.3 增加 stale PID、device/bundle mismatch、missing dSYM、host UUID mismatch、loaded image UUID
  mismatch、malformed CoreDevice result 的 fail-closed fixtures。
- [ ] 3.4 基于 spike 固化 Apple adapter 与 attach command/config；不得复用 Mac PID handler 或 Android
  transport。

## 4. iOS attach

- [ ] 4.1 在 `ue.dap.ios` 实现已运行 app attach，断点在首次 continue 前下发。
- [ ] 4.2 仅在 headless contract 与真机 breakpoint-stop gate 均通过后声明 macOS→IOS
  `dap_attach=true`。
- [ ] 4.3 覆盖 session 捕获后全局 project/device/signing 变化不改变当前 attach 目标。

## 5. iOS launch-under-debug

- [ ] 5.1 按 spike 证据实现独立 debug launch、结构化 PID 解析与同一 attach pipeline。
- [ ] 5.2 bootstrap 失败时按已验证顺序 resume/terminate 本次 launch-owned suspended process。
- [ ] 5.3 仅在早期断点、stop policy 与失败清理真机 gate 均通过后声明 `dap_launch=true`。

## 6. 跨平台 lifecycle 接缝

- [ ] 6.1 将 stop/status/session-end/VimLeave cleanup 改为 session-owned platform dispatch，不按配置名
  猜平台。
- [ ] 6.2 保持 ADB、lldb-server、JDWP、ASLR、Android breakpoint planting 与 logcat 逻辑只在
  Android handler。
- [ ] 6.3 更新无参数 `UEDAPAttach`/`UEDAPLaunch` 的 current-target dispatch；平台不支持时保持明确
  unavailable，不 fallback。

## 7. 验证与文档

- [ ] 7.1 补 `ue_target_drivers`、`ue_target_integration`、`ue_target_tasks`、`platform`、`dap`、
  `commands`、`keymaps` 与 iOS probe tests。
- [ ] 7.2 更新 cheatsheet、README、architecture、OpenSpec canonical specs 与 changelog。
- [ ] 7.3 运行所有受影响 filters 和全量 `nvim --headless -l tests/run.lua`。
- [x] 7.4 单独记录真机 gate：工具版本、UUID 比较、resolved/hit/frame、detach/cleanup；缺外部条件时
  标 blocked/not-run。
