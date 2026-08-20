# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)

## Unreleased

### 2026-08-20 — Preserve target install progress in notification history

**Task**

修复 `<leader>ui` 的 IOS target install 只显示短暂 Fidget/notify、但 `:NotificationHistory` 查不到记录的问题。

**Implemented**

- `lua/ue/target_tasks.lua` 的 progress controller 现在记录用户触发流程的开始与终态，并保留调用方 scope；
  中间百分比更新不入历史，避免把高频 progress 变成 history spam。
- `lua/ue.lua` 为 target install 指定 `ue.install` scope，并让成功终态携带 bundle id、device id 以及 legacy
  MobileDevice backend（如适用），使 `<leader>ui` 的最终结果可在历史中完整复查。
- `tests/cases/ue_target_tasks_spec.lua` 增加 Fidget 存在时的回归，证明 history 仍收到且只收到开始/终态两条。

**Pitfalls / Gotchas**

- Fidget progress 不经过 `vim.notify`；而本仓为避免插件冲突也不会 monkey-patch `vim.notify`，所以必须在
  progress controller 边界显式写 notification history。

**Validation**

- 定向：`ue_target_tasks` 7/7、`ue_target_drivers` 45/45、`ue_target_integration` 22/22、`platform` 23/23、
  `commands` 105/105、`ue_api` 55/55、`smoke` 19/19、`utils` 51/51、`structure` 39/39。
- 全量 `nvim --headless -l tests/run.lua` 1021/1021；bare-global lint 140 files OK。

**Follow-ups**

- 无。

### 2026-08-20 — Sync/archive iOS build-device OpenSpec contract

**Task**

按 `sync → archive → commit → push` 收口本轮 iOS build/setup/device/install 与 fail-closed debug gate 契约。

**Implemented**

- 将 active change 的 3 个 `ios-build-run-workflow` MODIFIED requirements 同步到 canonical spec：安全 AOT/
  dSYM/package 复用、prepared signing/private-key setup，以及 CoreDevice/pre-iOS17 legacy 设备分流。
- 发布 canonical `ios-device-debug-workflow`，明确真机 protocol/breakpoint/frame/UUID/cleanup evidence 完成前
  IOS DAP 保持 unavailable。
- 将 change 归档到 `openspec/changes/archive/2026-08-20-add-ios-device-debug-workflow`；未完成 DAP tasks 原样
  保留为 deferred history，archive note 不把它们误报为已实现。

**Pitfalls / Gotchas**

- 本机没有 `openspec` CLI，因此按仓库既有 manual sync/archive 流程逐 requirement 比对。
- archive 表示当前已实现范围与 fail-closed 边界收口，不代表物理 iOS DAP 已解锁。

**Validation**

- canonical/delta requirement comparison：3 个 modified blocks 与 1 个 added capability 一致。
- `structure` 39/39；全量 `nvim --headless -l tests/run.lua` 1020/1020；bare-global lint 140 files OK；
  `git diff --check` 通过。

**Follow-ups**

- iOS DAP 需新的 active change 消费 canonical 真机 evidence gates 后才能实现。

### 2026-08-20 — 让 prepare 工件跨 Nvim 重启复用并修正成员 Ctrl-click

**Task**

修复已经执行过 `UEPrepare`、当前 tuple 工件仍有效，但重启 Nvim 后 clangd 又被进程内 gate 拦截的问题；
同时修复 `<C-LeftMouse>` 把 `ParallelRenderCommandEncoder.GetPtr()` 的点号成员误判成文件扩展名并执行 `gf`。

**Implemented**

- clangd root gate 改为验证持久化的 tuple build key、index selection/artifact、controlled/semantic CDB 与源 CDB
  签名；ready 工件跨 Nvim 重启直接复用，missing/stale/building 才 defer，且同进程内每次重新验证。
- 新 controlled artifact 在尚无 clangd client 时发布，也会唤醒已加载的 UE C/C++ buffer；不会因 client list
  为空提前 return。
- smart Ctrl-click 仅在 `<cfile>` 含路径分隔符或能由 `vim.filetype.match()` 识别为真实文件名时走 `gf`；
  `object.Method` 交还 LSP definition，普通显式文件引用保持原行为。
- mixed Apple `.cpp` 即使 clangd 暂时 defer，也从既有 exact CDB 异步恢复 `objcpp` lexical overlay；不构建、
  不索引、不启动 LSP。

**Pitfalls / Gotchas**

- “磁盘上有 compile_commands.json”本身不是充分证据；必须同时绑定当前 tuple、artifact fingerprint 与源 CDB
  签名，避免复用另一个 target/configuration 或已变化的 build。
- positive readiness 不能永久缓存在 Lua table，否则同一进程里 CDB 更新后会继续误放行旧 artifact。
- `object.Method` 的最后一段形似扩展名，但 `vim.filetype.match()` 不认识它；用任意 `.<word>` 判文件会截断 LSP。

**Validation**

- TDD：`ue_context` 新增重启复用、同进程重验证与 stale/missing 拒绝；`index_generation` 新增无 client 的
  artifact promotion wake；`keymaps` 新增 dotted-member 不调用 `gf`；`autocmds`/`clangd_commands` 覆盖
  deferred 状态下 mixed syntax 恢复。
- 真实当前 Nvim 未重跑 `UEPrepare`：持久 snapshot `readiness=ready`，`MetalCommandEncoder.cpp` 自动恢复
  `clangd attached=1`、`ft=cpp`、`syntax=objcpp`；`GetPtr` definition 返回 `ThirdParty/mtlpp/.../ns.hpp:66`。
- 独立新 headless Nvim 打开同一 source，未执行 prepare 即返回 `snapshot=ready` 与当前 engine root。
- 目标回归：`ue_context` 13/13、`index_generation` 24/24、`keymaps` 55/55、`commands` 105/105、
  `options` 14/14、`autocmds` 7/7、`clangd_commands` 5/5、`cpp_semantic_index` 1/1、
  `ue_api` 55/55、`smoke` 19/19、`structure` 39/39。
- 全量回归：`nvim --headless -l tests/run.lua` 1020/1020；bare-global lint 140 files OK；
  `git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-08-20 — 补齐 Apple UBT mixed Objective-C++ 语法

**Task**

修复 iOS exact CDB 已以 Objective-C++ 编译 `.cpp/.h`，但 Neovim 仍只按扩展名使用 `cpp` Tree-sitter，
导致 `@autoreleasepool`、message expression 与 interface 等 Objective-C 构造没有语法高亮的问题。

**Implemented**

- `lua/ue/clangd_commands.lua` 从 exact `compilationCommand` 读取 `-x objective-c[++]` language evidence。
- 对 `.cpp/.h` mixed buffer 保留原 `cpp` filetype 和 Tree-sitter，只叠加 Nvim 内置 `objcpp` syntax；
  command 回到普通 C/C++ 时仅撤销本模块拥有的 overlay，不覆盖用户手动 syntax 设置。
- 普通 C/C++、Android、Win64 与不含 Objective-C language flag 的命令保持原行为；未新增 parser/dependency。

**Pitfalls / Gotchas**

- `tree-sitter-objc` 只继承 C grammar；把 `objcpp` 直接映射过去会让 Objective-C 可见，却破坏同文件的 C++。
- UE Apple toolchain 会给扩展名仍为 `.cpp` 的文件传 `-x objective-c++`，所以不能只靠扩展名判定语言。

**Validation**

- TDD：`clangd_commands` 从 4/5 到 5/5；同时守护普通 C++ syntax 不变、filetype 仍为 `cpp`、
  `@autoreleasepool` 命中 `objcPool`。
- 真实当前 Nvim：`MetalRenderPass.cpp` 保持 `ft=cpp`、C++ Tree-sitter active、`syntax=objcpp`、
  `@autoreleasepool` 命中 `objcPool`，clangd attached=1。
- 全量回归：`nvim --headless -l tests/run.lua` 1014/1014；裸全局 lint 扫描 140 个文件通过；
  `git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-08-20 — 让 clangd 真正消费 SuperUnity background CDB

**Task**

修复 IOS `:UEPrepare` 已生成 SuperUnity，但 clangd 仍显示数千条后台索引的问题。

**Implemented**

- current/hot/full phase artifact 继续保留 `nvim_ue_members` / `nvim_ue_module_root` provenance；发布给
  clangd 的合并 CDB 只保留标准 JSON compilation database 字段，避免一个未知 key 拒绝整份数据库。
- generation、CDB digest、toolchain identity 与 artifact fingerprint 改用递归 canonical JSON key ordering，
  相同 build evidence 跨 Nvim 进程得到相同 generation ID。
- exact command 首次交付给一个已 attached source buffer 时，按协议顺序执行一次
  `didClose → didChangeConfiguration → didOpen`，防止 synthetic CDB 中没有该 source 时 clangd 长期保留
  邻近 TU 的错误推断 AST；重复 `gd` 不重复 reopen。
- `symbolInfo` 的冷 preamble timeout 从独立 5 秒对齐到 provider 统一 30 秒 hard ceiling。
- 重新发布并重建当前 IOS full artifact；当前 clangd 已自动重载标准 CDB。

**Pitfalls / Gotchas**

- SuperUnity 文件存在不等于 clangd 已使用它：现场日志先显示 active CDB `Enqueueing 9407 commands`，
  后又因 `Unknown key: \"nvim_ue_module_root\"` 拒绝受控 background CDB。
- provenance 对 semantic sidecar 是必要证据，但 clangd 的 JSON parser 不允许扩展字段，因此必须保留
  “富 phase artifact / 标准发布视图”双层边界。
- `vim.json.encode()` 不保证 Lua map key 顺序；直接 hash 编码结果会让同一 CDB 跨进程产生不同 generation。
- command update 到达 clangd 不会主动重建已经 didOpen 的 AST；现场 exact source preamble 用时 7.9 秒，
  因而既需要有序 reopen，也不能沿用 5 秒 identity timeout。

**Validation**

- TDD：`index_generation` 从 21/22 到 22/22（CDB schema），再从 22/23 到 23/23（canonical hash）。
- 真实当前 IOS CDB：active 9,407 条；修复后 full background 625 条（490 SuperUnity + 135 个安全
  exact fallback），字段仅 `arguments/directory/file`；clangd 日志确认 `Loaded compilation database`、
  `Enqueueing 625 commands`。
- 两个独立 headless Nvim 对当前 build 计算出相同 generation
  `466b73dd12b06d2f6053c8d50bdd06ff97be6f833b02ad6b0a4c15cb1df71c44`。
- 目标回归：`cpp_semantic_index` 1/1、`clangd_commands` 4/4、`ue_api` 55/55、`structure` 39/39；
- cold exact-command TDD：`clangd_commands` 从 3/4 到 4/4；`ue_goto_behavior` 从 7/8 到 8/8；
  `cpp_semantic_client` 16/16。
- 真实当前 Nvim：重启 clangd 后第一次 `gd` 有序 reopen，7.9 秒完成 exact IOS preamble 并跳到
  `blit_command_encoder.hpp:64`；最后恢复 `MetalRenderPass.cpp:1893:24`。
- 全量回归：`nvim --headless -l tests/run.lua` 1013/1013；裸全局 lint 扫描 140 个文件通过；
  `git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-08-20 — 修复 prepare 完成后 clangd 未附着与 source gd 假死

**Task**

修复 build/`:UEPrepare` 已完成、CDB 也有效，但当前 UE C++ buffer 没有 clangd client，导致 `gd` 仍无法
跳转；同时消除 source `gd` 每次让 sidecar 重读约 290MB CDB、等待十余秒后因 libclang parse-failed 终止。

**Implemented**

- prepare 标记 clangd session ready 后，以 250ms 有界重试原生 `FileType` wake，直到 clangd 已附着；
  prepare 早于 UI attach 时挂一次性 `UIEnter` 恢复，不依赖不存在的 `:LspStart`。
- exact compile-command transport 的成功回调同时返回已发送给 clangd 的 compiler evidence；provider 将其
  与 exact-cursor canonical USR、client identity 绑定。
- source TU 的 `gd` 直接使用该 controlled exact command 调 clangd `symbolInfo` + `definition`，不再进入
  sidecar 全量 CDB/LibClang parse；跳进 header 时继续把 exact command 保存为 proven origin context。
  header-in-context、无文本 fallback、其他平台与非 C++ 导航逻辑不变。

**Pitfalls / Gotchas**

- `UEPrepare` 的 pipeline/task 全部 done 不等于 LSP 已附着；现场 buffer 的 client list 为空，而手动重放
  `FileType` 立即成功，说明一次性 wake 会丢失，必须以实际 client attachment 作为完成条件。
- clangd 对现场两个 `GenerateMipmaps` 调用都能立即给出唯一正确目标；失败来自上层 source 路径仍先调用
  sidecar，后者每次解析全量 CDB 约 15 秒并以 `parse-failed` 终止，不能把它误判为 build/CDB 无效。

**Validation**

- TDD：`ue_context` 从 9/10 到 10/10；`clangd_commands` 从 3/4 到 4/4；`ue_goto_behavior`
  从 6/7 到 7/7；`cpp_semantic_client` 16/16。
- 真实当前 Nvim：clangd client 已附着；`MetalRenderPass.cpp:1896` 的实际 `gd` 跳到
  `blit_command_encoder.hpp:64`，暖路径 `:1897` 在 1 秒内跳到 `MetalBlitCommandEncoder.h:45`；最后恢复
  用户原 buffer/cursor。
- 全量回归 `nvim --headless -l tests/run.lua`：1010/1010；bare-global lint：140 files OK；
  `git diff --check`：通过。

**Follow-ups**

- 无。

### 2026-08-20 — 接纳既有 IOS UBT 构建证据并隔离 prepare 的 AOT 副作用

**Task**

修复已经成功执行 `Client / IOS / Development` build 后，`:UEPrepare` 仍因 Nvim marker 缺失而要求重复
`<leader>ub`；同时确保 semantic CDB 的 action-graph 生成不会触发工程 Build.cs 内的 AOT 编译。

**Implemented**

- IOS driver 可从 `Binaries/IOS/<Target>.target` 恢复旧构建证据，但仅接受 target/platform/configuration
  精确匹配且 receipt 声明的 launch binary 仍存在的结果；恢复后写入当前 project bucket，之后仍走原有
  tuple evidence 校验；解析器独立在 IOS 专属子模块，主 driver 保持 800 行门禁以内。
- IOS semantic-CDB plan 仅为自身子进程设置工程已支持的 `bSkipAOTProcess=true`，并由通用 terminal runner
  透传 plan env；正常 `<leader>ub` 的 AOT 指纹/cache 策略以及其他平台路径不变。
- 成功发布 IOS semantic source 后记录精确 tuple、build completion 和文件 size/纳秒 mtime；同一 build
  重复 `:UEPrepare` 直接复用，不再启动 `Build.sh`/UBT，证据或文件变化才重新生成。
- prepare 完成后以原生 `FileType` autocmd 唤醒已加载 UE C/C++ buffer 的 clangd，移除对未注册
  `:LspStart` 插件命令的依赖。
- 已把当前 `Client / IOS / Development` 的 2026-08-19 UBT receipt 迁移进真实 project bucket，无需重编。

**Pitfalls / Gotchas**

- `-NoExecCodeGenActions` 只能阻止 UBT 执行 action，无法阻止项目 ModuleRules 构造器自行启动外部 AOT；
  必须使用该工程已有的 `bSkipAOTProcess` 开关，而且只能限制在 semantic 子进程。
- 仅凭 `.app` 目录或文件时间不能证明 tuple 构建成功，因此恢复证据以 UBT receipt + launch product 为双门。
- semantic source 复用同时绑定 build completion 与源文件签名，不能只因路径存在就跨 build 复用。

**Validation**

- TDD：`ue_target_drivers` 从 44/45 到 45/45；`ue_target_integration` 先从 20/21 到 21/21，
  semantic reuse 用例再从 21/22 到 22/22；clangd 原生唤醒约束 `ue_context` 9/9；
  `ue_target_tasks` 6/6。
- 真实 receipt 恢复后复核 state 为 `Client / IOS / Development`，build completion 为
  `2026-08-19T12:52:44Z`；真实 `UEPrepare` semantic UBT 输出确认
  `Enable AOT: True, Skip AOT Process: True`，且未启动 `mono-aot-cross`。
- 全新 headless Nvim 对同一 tuple 执行真实 `UEPrepare`，报告复用 14073 条 semantic CDB，pipeline no-op；
  prepare 前后进程树均无 `Build.sh`、UBT、`GenerateClangDatabase`、AOT 或 clang++。
- `platform` 23/23、`commands` 104/104、`ue_api` 55/55、`structure` 39/39、`smoke` 19/19、
  `stability` 9/9、`ue_cdb` 31/31、`cheatsheet` 142/142；Lua bare-global lint 扫描 140 个文件通过，
  `git diff --check` 通过；全量 `nvim --headless -l tests/run.lua` → 1009/1009。

**Follow-ups**

- 无。

### 2026-08-20 — 补齐 iOS 设备/安装进度并延后 UE clangd 启动

**Task**

消除 `:UESetIOSDevice` 和 `<leader>ui` 异步执行期间的无反馈空档，并阻止 UE 工程 clangd 在本次
`:UEPrepare` 发布有效 CDB/index 前自行启动并扫描数千文件。

**Implemented**

- target task runner 新增可复用的 fidget progress controller，以及不丢失最终 stdout/stderr 的流式输出
  callback；没有 fidget 时使用同 ID replace notification，避免阶段通知堆叠。
- `:UESetIOSDevice` 从触发当帧开始显示单一进度，依次报告 CoreDevice、pre-iOS17 MobileDevice、
  `ResetIOSUSB.sh` 软件恢复、重新探测和 picker/完成阶段；仅 IOS 路径进入恢复，其他 target 不变。
- `<leader>ui` 显示 signing/private-key preflight、artifact 解析和安装启动阶段；legacy helper 输出被
  增量解析为签名、上传、`ideviceinstaller Upgrade` 百分比和完成状态，stdout/stderr 各自保留分片缓冲。
- lspconfig 的 clangd root callback 增加 project/target/platform/configuration artifact gate：当前 tuple 的
  持久 selection/manifest/CDB readiness 有效时直接启动；无有效工件时等待 prepare 完成后唤醒已加载的
  UE C/C++ buffer。Tree-sitter 始终可用，非 UE C++ root 不受 gate 影响。

**Pitfalls / Gotchas**

- prepare gate 不能只检查 CDB 存在，也不能只看进程内布尔值；它必须验证当前 tuple 的持久 artifact
  fingerprint 与源 CDB 签名，避免另一个 tuple 的完成状态提前启动 clangd，也避免重启后无故重复 prepare。
- legacy helper 的 stdout 和 stderr 不能共用同一个残行缓冲，否则两个 fd 的交错 chunk 会拼出假阶段；
  两条流分别解析，但汇报到同一 workflow progress controller。

**Validation**

- TDD 基线：`ue_target_tasks` 4/6、`ue_target_drivers` 43/44、`ue_context` 6/9、
  `ue_target_integration` 19/20；实现后分别 6/6、44/44、9/9、20/20。
- 关联回归：`ue_cdb` 31/31、`ue_api` 55/55、`cheatsheet` 142/142、`structure` 39/39、
  `smoke` 19/19。
- Lua bare-global lint 扫描 139 个文件通过；`git diff --check` 通过；全量
  `nvim --headless -l tests/run.lua` → 1006/1006。

**Follow-ups**

- 无。

### 2026-08-20 — 区分 iPhone 物理连接与 MobileDevice 可安装状态

**Task**

修复 legacy iOS 安装在 USB 设备已被 IOKit 枚举、但 `usbmuxd/MobileDevice` 数据通道不可用时，
仍只报告 `matched 0 usable legacy USB devices`，导致用户误以为 Nvim 没有识别已连接设备。

**Implemented**

- 3.6 外部 `InstallIOSClient.sh` 先用 IOKit 精确核对目标 UDID；设备物理存在时短暂等待
  `usbmuxd`，只把 `ideviceinfo` 可读的设备视为 usable。若数据通道丢失，自动复用 3.6 已有的
  `ResetIOSUSB.sh --force <UDID>`，通过 `IOUSBHostDevice resetWithError` 重新枚举精确目标；恢复后继续
  原签名与 container-preserving update install，无需解锁、重插数据线或重启 Mac。
- Nvim legacy install failure mapping 同时识别新诊断与旧 helper 的 `matched 0 usable legacy USB devices`
  输出，将 `<leader>ui` 错误统一转成可操作的 MobileDevice 恢复提示；CoreDevice 和其他平台路径不变。

**Pitfalls / Gotchas**

- IOKit 能读取 USB descriptors 只证明物理链路已枚举，不证明 usbmux 数据端点健康；系统日志中的
  `MuxInterfaceVersionSend ... kIOReturnNotResponding` 可由精确目标的 IOUSBHost re-enumeration 恢复。
  reset helper 只匹配 `SupportsIPhoneOS` 设备，不重置其他 USB 外设，也不接触 App/资源。
- 已启动且载入旧 Lua module 的 Nvim 需要重启或重新加载配置后才会使用新的错误映射；外部 helper 修改
  会在下一次 `<leader>ui` 子进程中立即生效。

**Validation**

- `ue_target_drivers` 43/43，覆盖新旧两类 helper 输出，并验证解锁、USB accessories 与 Trust 提示。
- 3.6 helper 通过 `bash -n`；真实目标 UDID 验证命中 IOKit 物理设备、等待 usbmux 后输出新的精确诊断，
  随后由 `ResetIOSUSB.sh` 原地恢复，`ideviceinfo` 再次返回 `iPhone`。
- 3.6 Python 全量回归 30/30；真实 `Client.app` 完成签名、临时 IPA 封装与 legacy upgrade，安装进度
  到达 `Complete`，exit 0；未 uninstall、未启动 App、未主动删除 Documents/Library。
- Lua bare-global lint 扫描 139 个文件通过；`git diff --check` 通过；全量
  `nvim --headless -l tests/run.lua` → 999/999。

**Follow-ups**

- 无。

### 2026-08-19 — 收敛为 build → UEPrepare → install 的 iOS 日常流程

**Task**

外部 `PrepareIOSQADebug.sh` 与 `InstallIOSClient.sh` 完成后，允许 `:UESetProject`、
`:UESetPlatform IOS` 任意顺序执行，并把 Nvim 侧的一次性 IOS setup 与 semantic CDB 生成收进
`:UEPrepare`；`:UEPrepare` 本身不得触发编译，其他 target 除 project/platform 解耦外保持原逻辑。

**Implemented**

- `:UESetPlatform` 的显式选择通过进程内 one-shot intent 与下一次 `:UESetProject` 对接；project bucket
  仍是唯一 target authority，engine 默认仍只作建议，意图不会跨 Neovim 实例传播。
- IOS build 成功后记录精确 project/uproject/target/platform/configuration evidence；IOS `:UEPrepare`
  仅在 evidence 匹配且没有 build 在飞时继续，否则要求先完成 `<leader>ub`，绝不隐式编译。
- macOS 主机上的 IOS prepare capability 分支自动完成 clangd 22.1.x 预检、prepared identity/private-key/
  device/helper setup，再生成并验证 tuple-scoped `GenerateClangDatabase` source，最后进入公共 CDB/index
  流水线；`:UEIOSSetup` 与 `:UECompileForNvim` 只保留为可选诊断/兼容入口。
- IOS setup 的内部 platform normalization 只更新当前 project，不会伪装成用户的显式
  `:UESetPlatform` 并把 IOS 意图泄漏到之后切换的工程。
- Win64、Android、Linux、Mac target 不进入 IOS semantic/setup 分支，原 response-file prepare 路径不变；
  同时修正 Windows-host 默认 target 用例，使其显式注入 Windows driver，不再依赖运行测试的宿主 OS。

**Pitfalls / Gotchas**

- build 与 prepare 继续执行 WAW 互斥；必须等待 `<leader>ub` 完整成功后再运行 `:UEPrepare`。
- project/platform 解耦的 handoff 仅属于当前 Neovim 进程；内部 IOS setup 明确使用 current-only 更新，
  避免把隐式操作传播给下一个工程。

**Validation**

- TDD/目标回归：`multi_instance_state` 13/13、`ue_target_integration` 20/20、
  `ue_target_drivers` 42/42、`ue_target_tasks` 4/4、`ue_context` 6/6。
- 关联回归：`commands` 104/104、`ue_api` 54/54、`ue_project_context` 7/7、`ue_cdb` 31/31、
  `keymaps` 54/54、`cheatsheet` 142/142、`platform` 23/23、`structure` 39/39、`stability` 9/9、
  `smoke` 19/19、`options` 14/14。
- Lua bare-global lint 扫描 139 个文件通过；`git diff --check` 通过；全量
  `nvim --headless -l tests/run.lua` → 998/998。
- 本机没有 `openspec` CLI；OpenSpec 结构由 `structure` 回归覆盖。本轮未重复触发真实 UE build/设备安装；
  同日上一条记录已覆盖同一 IOS target 的真实 build、semantic CDB、setup 与 install 证据。

**Follow-ups**

- 无。

### 2026-08-19 — 将 iOS 外部前置条件收敛到一次性 setup

**Task**

在运行 `PrepareIOSQADebug.sh` 与 `InstallIOSClient.sh` 后，把 Nvim 的必要配置和真实 readiness 验证
收敛到一个入口，避免设备、prepared identity、私钥 ACL、helper 与 artifact 问题在日常写代码后才逐个暴露。

**Implemented**

- 新增 `:UEIOSSetup`：自动设置 IOS target、导入当前 workspace 的 prepared identity、自动选择唯一可用
  CoreDevice/pre-iOS17 USB 设备，并在 legacy backend 下验证 branch 对应 `InstallIOSClient.sh`。
- 签名选择不再把 `security find-identity` 当作私钥可用证明；保存选择前会复制一个 Nvim 自有临时 Mach-O，
  用精确 SHA-1 执行非交互 `/usr/bin/codesign`，验证后无条件清理。
- 已配置 identity 的 build/package/install 复用同一快速私钥探针，在克隆或重签大型 app、触碰设备前暴露
  keychain/ACL 问题；不读取、不传递、不保存 keychain 密码。
- 一次性 Nvim 入口收敛为 `:UESetProject` → `:UEIOSSetup` → `:UECompileForNvim`；之后日常 legacy 循环为
  `:UEBuildIOS` → `<leader>ui`。当前 tuple app 继续自动发现，无需先伪造 package provenance。
- Setup 现在严格要求当前 workspace 的 prepared signing manifest；异步探测期间切换 project 会中止，且
  device/package/install/launch 任一 project-state 写入失败都会报错，不再显示虚假的 selected/ready/success。
- macOS clangd 发现顺序新增用户级 `~/.local/opt/llvm@22` 与 Apple Silicon/Intel Homebrew `llvm@22`
  versioned keg，仍由 `:UECompileForNvim` 对最终二进制执行 22.1.x fail-closed 版本门禁。

**Pitfalls / Gotchas**

- 证书出现在 `security find-identity` 只证明证书/私钥配对存在，不证明 SSH/Zellij 中的非交互
  `/usr/bin/codesign` 已获授权；必须以真实签名探针为准。
- macOS keychain 锁定策略属于系统安全边界；setup 不会保存密码或静默降低 keychain 安全设置。
- Xcode 自带 Apple clangd 17 不满足仓库 LLVM 22.1.x 合同；clangd 门禁通过后，最终 index 阶段还要求
  GNU Global 的 `gtags`，两者都是一次性宿主工具链前置。

**Validation**

- TDD 基线：`ue_target_drivers` 39/41、`ue_target_integration` 16/18、`commands` 103/104；实现后分别
  42/42、19/19、104/104。
- 关联回归：`ue_target_tasks` 4/4、`platform` 23/23、`keymaps` 54/54、`structure` 39/39、
  `cheatsheet` 142/142；zsh 语法检查通过，Lua bare-global lint 扫描 139 个文件通过。
- 解锁 login keychain 后，精确 identity 私钥探针通过；真实 3.6 workspace 的 `:UEIOSSetup` 完整通过，
  选择 `legacy-mobiledevice` 的唯一 iPhone，并验证 branch 对应 helper；当前 tuple 自动发现既有
  `Binaries/IOS/Payload/Client.app`。
- 安装并解析 Homebrew arm64 clangd 22.1.8 后，真实 `:UECompileForNvim` 的 IOS Development build 与
  semantic CDB 均 exit 0，发布 14073 条 tuple evidence；安装 GNU Global 6.7 后单独重跑 `:UEPrepare`
  成功，active CDB 保留 9407 条，GTAGS/GRTAGS/GPATH 与 csearch index 均已落盘。
- 再次执行 `:UEIOSSetup` 全绿；真实 `:UEInstallIOS` 自动发现 `Client.app`，复用 prepared
  identity/provision 与 branch helper，通过 legacy MobileDevice 成功安装
  `com.zeqiang.iosqadebug.wzfsw8bgyp` 到所选 iPhone。
- `git diff --check` 通过；全量 `nvim --headless -l tests/run.lua` → 987/987。

**Follow-ups**

- 当前 login keychain 保留系统 `lock-on-sleep` 策略；睡眠后若被锁定，需要再次由用户在本机解锁。
  配置不保存密码，也不静默降低这项系统安全策略。

### 2026-08-19 — 在 SSH/Zellij 中强制使用 OSC 52 copy

**Task**

避免持久 Zellij session 丢失 `SSH_TTY` 后 Neovim 自动检测失败，让远程 yank 稳定穿透到 Windows
终端剪贴板，同时禁止 OSC 52 反向读取造成等待。

**Implemented**

- 新增 `config.clipboard`：在 `SSH_TTY`、`SSH_CONNECTION` 或 `ZELLIJ` 环境中提前设置
  `clipboard=unnamedplus` 和显式 OSC 52 `+/*` copy provider。
- `+/*` paste callback 只同步返回 unnamed register；Windows → 远程 Nvim 继续使用 Rio 终端粘贴与
  bracketed paste，不发 OSC 52 clipboard read。
- 原生 Windows 与 Neovide 不启用该覆盖，保留各自的系统剪贴板 provider。

**Pitfalls / Gotchas**

- `config.options` 由 LazyVim 在 clipboard provider 初始化前自动加载；本配置从 options 内调用 helper，
  没有在 `init.lua` 重复 require 自动加载模块。
- `"+p` 在 OSC 52 模式下不是读取 Windows 当前剪贴板，而是回退到 Nvim unnamed register；外部内容
  必须由终端 paste 注入。

**Validation**

- TDD 基线：`options` 因缺少 `config.clipboard` 为 0/1；实现后 `options` 14/14。
- 关联回归：`autocmds` 6/6、`structure` 39/39；Lua bare-global lint 扫描 139 个文件通过，
  `git diff --check` 通过。
- 模拟 Zellij 完整启动并触发 `User VeryLazy` 后得到 `clipboard=unnamedplus`、provider=`OSC 52`。
- 全量 `nvim --headless -l tests/run.lua` → 980/980。

**Follow-ups**

- 无。

### 2026-08-19 — 让 Nvim 识别 pre-iOS17 USB 设备

**Task**

修复 macOS 已通过 USB/MobileDevice 识别 iOS 15 真机，但 `:UESetIOSDevice` 因只检查
CoreDevice tunnel 而报告 `no available device`。

**Implemented**

- 新增结构化 `xcrun xcdevice list --timeout 5` fallback，只接纳可用、物理、USB 连接且
  低于 iOS 17 的 iPhoneOS 设备，并标记为 `legacy-mobiledevice` backend。
- 设备选择仍以 `devicectl` CoreDevice 为主；主命令失败、结果文件不可用、解析失败或设备列表为空时，
  才异步执行 fallback，并把设备 ID、名称和 backend 一并持久化到 runtime。
- CoreDevice 设备显式标记 backend；legacy `UEInstallIOS` 在没有 package provenance 时只重新发现
  当前 tuple app，并把精确 UDID、prepared identity/profile/bundle 交给 branch 对应的
  `InstallIOSClient.sh`。helper 克隆/重签临时副本后通过 MobileDevice 原地更新，不改源 app、不卸载、
  不启动；legacy `UELaunch` 继续 fail closed。
- 将 legacy `codesign` 的 `errSecInternalComponent` 转成可操作的 login keychain / `/usr/bin/codesign`
  解锁提示，避免只暴露 Security framework 的不透明错误码。
- 新增 driver 与 integration 回归，并同步 iOS workflow change spec、任务清单和架构说明。

**Pitfalls / Gotchas**

- 当前 iOS 15.4.1 真机可通过 MobileDevice/`xcdevice` 使用，但没有 iOS 17+ CoreDevice tunnel；
  `devicectl` 中的 unavailable 历史记录不能等同于 USB 未连接。
- legacy 安装允许消费当前 tuple 的现有 app，但它不被持久化或伪装成 package provenance；缺少
  Prepare metadata、匹配证书/profile 或 helper 时仍 fail closed。
- `security find-identity` 只证明证书/私钥配对存在，不证明当前非交互进程可以使用私钥；login keychain
  锁定或 ACL 未授权时，真实签名仍会在触碰设备前失败。
- 已加载旧 Lua module 的 Nvim 进程需要重启或重新加载配置后才能使用新发现路径。

**Validation**

- 设备发现 TDD 基线：`ue_target_drivers` 37/39、`ue_target_integration` 14/16；实现后继续扩展到
  41/41、17/17。legacy install 新增用例的实现前基线分别为 38/40、16/17。
- 关联回归：`ue_target_tasks` 4/4、`platform` 22/22、`commands` 103/103、`structure` 39/39、
  `stability` 9/9。
- 真实 `xcdevice` JSON 解析得到 1 台 `iPhone`（iOS 15.4.1，`legacy-mobiledevice`）；
  `idevicepair validate` 成功，`ideviceinstaller -l` 可读取应用列表。
- 当前 3.6 workspace + iPhone 12 的真实 helper dry-run 通过：精确命中当前 tuple app、UDID、profile、
  Bundle ID，并规划 container-preserving `ideviceinstaller -i`，无 uninstall/launch。
- 真实安装验证在签第一个 framework 时因 login keychain 拒绝非交互私钥访问而停止
  (`errSecInternalComponent`)；尚未封装 IPA，也未改动设备。来自正在运行 Nvim 的同一探针得到相同结果。
- `lua` bare-global lint 扫描 138 个文件通过；`git diff --check` 通过；
  全量 `nvim --headless -l tests/run.lua` → 977/977。
- 本机没有 `openspec` CLI，未执行其严格校验；OpenSpec 文件结构已由仓库 `structure` 回归覆盖。

**Follow-ups**

- pre-iOS17 的普通启动仍需要独立 lifecycle evidence；当前 `:UELaunch` 继续 fail closed。

### 2026-08-18 — 让 `<leader>ui` 按 active target 安装

**Task**

统一安装快捷键的平台语义：Android 保持替换 APK，IOS 使用当前 tuple 已签名 staged app
原地更新，不在安装前卸载应用。

**Implemented**

- 新增 `:UEInstall` 平台分派入口，并让静态与 runtime `<leader>ui` 映射都只调用该入口；
  Android 复用既有 `adb install -r`，IOS 复用 target-driver `devicectl device install app`。
- 保留 `:UEInstallAndroid` / `:UEInstallIOS` 作为显式兼容命令；Mac 等桌面 target 明确报告不支持，
  不猜测设备工作流。
- IOS 安装继续消费 package provenance 对应的已签名 `.app`，不重签名、不启动，并新增禁止
  uninstall/delete/remove 的 planner 回归。
- 同步命令冻结表、快捷键、AI context、速查文档和 Android/IOS 主规格。

**Pitfalls / Gotchas**

- “增量安装”在这里指保留应用身份与数据的原地更新，不承诺传输层只发送二进制差量；CoreDevice
  是否优化传输由 Xcode/devicectl 决定。
- IOS 安装仍要求当前 tuple 已成功 package、已选择物理设备且 package/install 签名预检通过。

**Validation**

- 安装核心：`keymaps` 54/54、`commands` 103/103、`ue_target_integration` 14/14、
  `ue_target_drivers` 37/37、`ue_target_tasks` 4/4、`ue_context` 3/3。
- 关联边界：`platform` 22/22、`ue_project_context` 7/7、`ue_api` 54/54、`smoke` 19/19、
  `cheatsheet` 140/140、`structure` 39/39。
- `git diff --check` 与脱敏扫描通过；全量 `nvim --headless -l tests/run.lua` → 970/970。

**Follow-ups**

- 未执行真实 iOS 设备安装；配置回归只验证路由、计划 argv、结果解析契约与无卸载边界。

### 2026-08-18 — 恢复 `<leader>ub` 的 IOS 专属 UBT 参数

**Task**

确保当前 target 为 IOS 时，通用构建快捷键 `<leader>ub` / `:UEBuild` 最终调用 macOS
`Build.sh` 的参数与其他 target 明确分层，并恢复 target-driver 拆分时遗漏的日常构建参数。

**Implemented**

- IOS `build_plan` 在 project 参数后稳定追加 `-WaitMutex`、`-FromMsBuild` 与
  `-disablev8pointercompression`；现有 AOT wrapper、日常 dSYM override 和可选签名 override 保持不变。
- Mac 不继承上述三个参数；`-disablev8pointercompression` 明确保持 IOS-only，不泄漏到
  Android、Win64 或 Linux driver。
- 新增纯 planner 与 `<leader>ub → UEBuild → IOS driver → macOS wrapper → Build.sh` 集成断言，
  并把参数顺序与平台边界同步到 iOS build 主规格。

**Pitfalls / Gotchas**

- target-driver 拆分前的通用 build 路径包含 `-WaitMutex/-FromMsBuild`，拆分后 IOS planner 没有保留；
  仅凭参数名称把 `-FromMsBuild` 判断为 Windows-only 会掩盖这个行为回归。
- `-disablev8pointercompression` 此前从未进入仓库，必须由 IOS driver 显式拥有，不能放到 host entry
  或共享 helper，否则其他平台会被静默污染。

**Validation**

- TDD：新增 planner 用例先以缺少 `-WaitMutex` 失败（36/37），实现后 `ue_target_drivers` 37/37。
- `ue_target_integration` 12/12、`ue_target_tasks` 4/4、`platform` 22/22、`commands` 102/102、
  `keymaps` 53/53。
- `structure` 39/39；全量 `nvim --headless -l tests/run.lua` → 965/965。

**Follow-ups**

- 未启动真实外部工程构建；该验证会产生工程工件，不属于配置回归。现有长驻 Neovim 会话需重新加载
  配置后才会采用新的 IOS driver argv。

### 2026-08-18 — 补齐 macOS csearch 与 Apple super-unity 运行链

**Task**

审计并修复此前只按 Windows 环境验证的 csearch/cindex 与 super-unity：让 macOS 能完整安装、
发现和增量更新 trigram 索引，并在 Apple 构建不保留 `.o.rsp` 时仍安全压缩受控 background CDB。

**Implemented**

- 新增 POSIX `scripts/install_csearch.sh`，把仓内 `cindex-uefilter` 与固定版本
  `csearch v1.2.0` 一并安装；运行时统一发现 PATH、`GOBIN`、多段 `GOPATH/bin` 与 `~/go/bin`，
  health/live health 和 UEPrepare 缺工具提示复用同一安装入口。
- `cindex-uefilter -files-from` 的非 reset 路径把每个输入文件登记为 exact merge path，
  修复 staged index 有 names 却无 Paths 导致的 `merge: inconsistent index` panic；新增和修改文件
  现在都会替换旧 trigram，删除仍保守升级为 reset。reset 不复制全量 path table，避免大型 UE 索引膨胀。
- csearch index 路径探测改为只读；只有实际 build 创建父目录，避免工具安装后
  `is_indexed()` 在不可写缺失路径上抛错。
- Apple 无 `.o.rsp` 时，super-unity 仅在 active UBT wrapper 的 include 全部唯一映射、member cwd
  相同且 compiler-authored argv 在剥离逐文件写出参数后完全一致时复用 exact argv；保留
  target/arch/sysroot/defines/includes/PCH，证据不足继续 exact per-file fallback。
- 补 Go 原生 merge 集成、Lua→cindex→csearch 往返、POSIX 安装器、AppleClang no-rsp grouping、
  语义漂移 fallback、非 Apple `-arch` 拒绝及 write-only flag 清理回归，并同步 README/skill 契约。
- 将新增合同同步到 `ue-code-search`、`macos-ios-cdb-semantic-prepare` 与
  `cpp-contextual-definition-navigation` 主规格，并归档完成的
  `restore-macos-unreal-semantics-and-search` change；未混入仍受真机证据门禁约束的 iOS DAP change。

**Pitfalls / Gotchas**

- upstream `index.Merge` 依赖 staged `Paths` 划定替换区间；只有 `AddFile` 会在任何平台 panic，
  而只靠 mock 的 Lua 回归看不见这个错误。
- `-o` 不能按字符串前缀粗暴剥离，否则会误删 `-openmp` 等语义参数；仅精确剥离成对 `-o`，
  dependency 输出则保留无歧义的 `-MF/-MT/-MQ/-MJ` attached-form 处理。
- 探针中的 `provider|missing/partial` 是本轮开始前语义索引尚未收敛的历史记录；本轮没有新增
  provider 失败，后续 warm/cold 记录已 resolved，因此不把它误归因到 csearch/super-unity。

**Validation**

- 原生工具：`go test -count=1 ./...` 通过；`python3 -m py_compile`（受控 CDB 工具链）通过；
  `sh -n scripts/install_csearch.sh` 与 `git diff --check` 通过。
- 定向回归：`csearch_build_guard` 22/22、`index_generation` 21/21、`utils` 51/51、
  `core_health` 28/28、`ue_watch_csearch` 13/13、`grep_cache` 29/29、`ue_api` 54/54、
  `structure` 39/39；合计 257/257。
- 全量门禁：`nvim --headless -l tests/run.lua` → 964/964。
- OpenSpec CLI 在本机不可用；已逐块比对 archived delta 与主规格同步内容，并由 `structure` 与全量
  回归覆盖仓库结构，归档内容通过 staged privacy/secret scan。
- macOS 实机：安装后 deterministic search health 为 PASS；真实工程 csearch reset 索引
  227,614 文件、325,869,011 bytes、29.3s，运行时判定 `backend=csearch` 且已验证真实查询命中。
- 真实 IOS hot CDB：2648 输入源中 2616 个进入 142 个 proven groups，32 个 exact fallback，
  输出 174 TUs（15.2x）；2648 member 全覆盖且无重复，wrapper 中对象/依赖写出 flag 为 0。

**Follow-ups**

- 当前磁盘上的旧 IOS controlled CDB 仍是语义正确的 exact fallback；下次正常 hot/full index refresh
  会按新契约重发压缩产物。独立真实数据生成已验证新产物，不为追求即时压缩破坏现有可用索引。
- 完整 headless `UEPrepare` 被本机缺少 GTAGS 阻断；未新增依赖，改用 csearch 自身受控 API 完成
  索引与 snapshot 发布。GTAGS 能力与本任务无关。

### 2026-08-18 — 修复原生 LSP 下 UE 语义解析与受控 CDB 启动链

**Task**

修复大型 Unreal Engine 源码树中语义解析整体失效：clangd 未使用 project-scoped 编译数据库，
当前文件退回 fallback command，并在错误的全量数据库上产生不可接受的索引开销。

**Implemented**

- clangd 配置改用 Neovim 原生 LSP `cmd` factory，在 `root_dir` 解析后生成 project-scoped argv；
  移除原生配置不会执行的 legacy `on_new_config`，并保留实际 argv 供精确命令 transport 判定。
- 精确编译命令 transport 支持 project-bucket 的 platform-scoped active CDB，不再按旧缓存层级
  猜测根目录；成功通知不再错误附带失败原因。
- 新增共享 CDB argv normalization，将 macOS/POSIX 与 Windows `command` 字符串按宿主规则转换为
  无歧义的 `arguments`，再进入 current/hot/full 受控索引生成，避免定义注入阶段破坏引号。
- libclang semantic sidecar 请求上限收紧到 30 秒；超时立即终止无响应进程并完成结构化失败，
  不再让卡死进程持续占用 CPU、使后续 `gd` 永久排队。
- 增加 native cmd factory、project-bucket 路径、精确命令传输及 command-only CDB 的回归覆盖。

**Pitfalls / Gotchas**

- nvim-lspconfig 的原生 `vim.lsp.config` 路径目前不执行 `on_new_config`；仅在静态配置时调用
  `clangd_cmd()` 会把 scoped CDB 静默降级成工程根下的 legacy CDB。
- `cmd` 变为 factory 后，`client.config.cmd` 是函数而非 argv；精确命令 transport 必须读取启动时
  保留的 resolved argv。
- CDB 同时允许 `command` 与 `arguments`，但受控 super-unity/definition 注入只接受结构化 argv；
  对 command string 直接重新拼引号会改变编译器原始语义。
- 仅从 pending map 移除超时请求不足以恢复 sidecar：libclang 正在原生 parse 时无法读取后续 cancel，
  必须回收整个进程；下一次请求再按现有 process manager 冷启动。

**Validation**

- TDD：native cmd factory、command-only CDB、project-bucket active CDB 与成功回调原因用例均先红后绿。
- 定向：`smoke` 19/19、`index_generation` 18/18、`clangd_commands` 4/4、
  `cpp_semantic_index` 1/1、`ue_api` 54/54、`cpp_semantic_context` 11/11、
  `cpp_semantic_client` 16/16、`cpp_semantic_sidecar` 15/15、`ue_goto_behavior` 7/7、
  `utils` 47/47 passed。
- 真实 UE 会话：重启后 clangd 使用受控 platform-scoped background CDB，自动收到当前文件精确命令；
  Tree-sitter captures 与 LSP semantic tokens 同时存在，`CoreMinimal.h` 缺失类 fallback 诊断消失，
  仅保留 3 条真实工程诊断；受控 full phase ready，clangd 稳态 RSS 约 1.2 GB（错误路径曾约 15.8 GB）。
- 语义导航探针：同一真实缓冲区完成 `resolved`，新 evidence 为 ready/partial generation；卡死 sidecar
  在 30 秒边界被回收且 pending 清零，导航随后由同 generation clangd provider 完成，不遗留后台进程。
- 全量：`nvim --headless -l tests/run.lua` 956/956 passed；`git diff --check` passed。

**Follow-ups**

- 当前机器未发现仓库约束指定的 LLVM 22.1.x clangd，运行时使用系统 clangd 17；功能已通过真实会话，
  但工具链版本仍需在环境层补齐。

### 2026-08-14 — 落地 iOS 签名选择与可证明的增量前置

**Task**

在只聚焦 macOS 本机 Neovim/iOS debug 的工作中，修正两个前置假设：签名证书必须由命令显式
设置；增量编译必须按可证明的阶段跳过工作，而不是把整个 Build.sh 省略。同时把真机 DAP 接线
隔离为可审计的 protocol probe，未取得设备证据前不开放生产能力。

**Implemented**

- 新增 `:UESetIOSSigningCertificate[!] [identity]`：支持 picker、完整证书名/SHA-1 精确选择和清除，
  将选择保存到 project state；build 捕获当次 identity 并通过结构化 INI argv 注入，Package/Install
  则在未选择或 keychain 精确复验失败时 fail closed。
- 与 `PrepareIOSQADebug.sh` 的重签流程对齐：无参数命令优先读取标准项目或
  `workspace/Source/Client` 上层 workspace 的 `Saved/IOSQADebug/signing.json`，验证 v1、完整
  identity、profile/Bundle/Team 和 `get-task-allow=true` 后再精确复验 keychain；没有 manifest 时
  才打开 picker，损坏/stale/多份 manifest 不静默降级。
- iOS C++ iteration 的 AOT 指纹升级为 v2 input manifest：path/device/inode/size/纳秒
  mtime/ctime 全匹配时复用 content digest，否则仅重算变化输入；输出 frameworks 每次仍做 SHA-256
  校验，任何证据缺失均退回完整 AOT。Build.sh/UBT 仍每次执行且从不传 `-SkipBuild`。
- 新增独立 `tools/ios_dap_protocol_probe.py`，冻结 Xcode/Apple `lldb-dap`、host binary↔dSYM UUID、
  CoreDevice process identity、raw DAP 断点命中、源码帧、non-terminating detach 与进程存活证据；
  preflight 证据已脱敏写入 `tools/evidence/ios-dap/`。
- 增加显式 `legacy-preflight --device ... --symbols ...`：对 CoreDevice 不可达的 pre-iOS17 设备验证
  MobileDevice USB、`ios-deploy`、精确 ProductType/OS/build DeviceSupport 与 LLDB `remote-ios`，并补齐
  40-hex/现代连字符两类 Apple UDID 的统一脱敏。实机 partial evidence 已证明 DeveloperDiskImage、
  debugserver listener 和 target create；设备端明确阻塞于 development profile 未被用户信任，现有重签包
  也不含 source DWARF，因此仍未开放生产 DAP。
- 新增/更新 driver、integration、command、script 与 probe 回归，并同步 OpenSpec、cheatsheet、tooling
  和架构文档；签名解析/preflight 独立到 `ios_signing.lua`，使 target driver 保持在 800 行门禁内。
  当前 preflight 发现 0 台可用物理 iOS 设备，因此保持 IOS DAP matrix unavailable，未修改生产
  `lua/ue/dap/ios.lua`。

**Pitfalls / Gotchas**

- keychain 中“至少有一张有效证书”不能证明当前 project 使用了正确 identity；Package/Install/debug
  必须要求显式选择，长任务只使用开始时捕获的 identity。
- 证书 display name 暂不接受逗号：本地 UE `ConfigFile(string)` 会按逗号拆分 INI override，静默
  接受会改变实际传入值；SHA-1 选择最终也会解析到同一 display name，因此同样 fail closed。
- AOT 输入 hash 的 metadata fast path 只有 path/device/inode/size/mtime/ctime 全匹配才可复用；任何
  miss 仍完整 AOT，output artifact 始终逐个验证。
- UBT 的 `-SkipBuild` 会跳过 compile actions，只适用于另有产物证据的准备/打包路径，不是 C++
  incremental build 开关。
- CoreDevice 的 available 记录不等于当前 USB 设备可调试：本机 pre-iOS17 设备只出现在 MobileDevice，
  对应 legacy backend 必须固定精确 DeviceSupport `Symbols`；backend 失败不能在同一 session 内 fallback。
- 本地严格验签、证书/profile/entitlements/device membership 全部一致仍可能被设备拒绝；本次设备日志
  给出 `Needs Explicit User Trust`，该设置只能在设备上完成，不能由 probe 伪造或绕过。
- transport/listener/target create 通过也不等于 source debug 通过；没有 DWARF/dSYM 的重签包不能满足
  resolved breakpoint、真实命中与正确源码帧门禁。

**Validation**

- 实机本地 parser probe：`security find-identity -v -p codesigning` 输出可解析，发现 2 个有效 identity；
  测试及持久化证据不记录证书名。
- Protocol probe：`self-test` 通过；`preflight` 正确以 exit 2 fail closed，并输出脱敏 blocker
  `no-available-physical-ios-device`；显式 `legacy-preflight` exit 0，确认 pre-iOS17 USB、精确 Symbols 与
  LLDB `remote-ios` ready，partial transport 则诚实记录 `explicit-user-trust-required` 与
  `source-dwarf-unavailable`。
- 实机 transport：从设备抓取并解包精确 DeviceSupport 成功，DeveloperDiskImage mount、debugserver
  loopback listener、LLDB `remote-ios` 与 target create 均通过；设备 SpringBoard 明确报告 profile
  `Needs Explicit User Trust`，因此 launch/attach 未伪造为通过。
- 工程真实增量 build：完整 AOT 后进入 UBT/clang，最终 exit 6；唯一 fatal 是已生成 wrapper 引用不存在的
  project/engine header。未修改业务源码，也未用手工拼 app 绕过；该结果不计为 repo regression 失败。
- 定向：`ue_target_drivers` 36/36、`ue_target_integration` 12/12、`ue_ios_cpp_iteration` 3/3、
  `ios_dap_probe` 3/3、`commands` 100/100、`ue_target_tasks` 4/4、`ue_api` 54/54、`smoke` 18/18、
  `platform` 22/22、`cheatsheet` 139/139、`multi_instance_state` 11/11、`structure` 39/39 passed。
- 全量：`nvim --headless -l tests/run.lua` 950/950 passed；`zsh -n scripts/ue_ios_cpp_iteration.zsh`
  passed；`git diff --check` passed。
- 当前环境无 `openspec` executable，未运行 CLI strict validate；change 已按 canonical requirement
  和 scenario 结构人工核对。

**Follow-ups**

- 在设备上显式信任 development profile 后，先重跑 legacy launch/attach transport；再生成本地
  binary+dSYM/source evidence 并运行严格 attach probe。只有 breakpoint、源码帧、detach 和 app-survival
  证据全部通过，才实现/注册生产 IOS DAP。
- 当前 checkout 还需通过其正式 wrapper 生成流程移除/重建对缺失 header 的 stale generated wrapper，
  再重跑 `:UEBuildIOS`；本变更不直接修改工程生成物。

### 2026-08-14 — 修复 Neovide 早期启动遗漏 UE 快捷键

**Task**

修复 Neovide 启动阶段 `<Space>ub` 偶发完全无响应；按用户复查结果，dashboard `p` 已恢复，
不纳入本次改动。

**Implemented**

- `config/keymaps.lua` 在自身加载阶段立即安装带 `nowait=true` 的 `<leader>u*` runtime overrides，
  不再根据 `vim_did_enter` 等待另一次 `VeryLazy`。
- 新增真实子进程回归，在 `vim_did_enter=0` 时直接加载 keymaps，冻结 `<Space>ub -> :UEBuild`
  必须立即可见的启动契约。

**Pitfalls / Gotchas**

- LazyVim 已按「默认 keymaps → 用户 keymaps」顺序加载该文件；用户文件内部再次等待
  `VeryLazy` 不会增加排序保障，反而会在 Neovide 的早期启动窗口留下未安装映射。
- 当前 Neovide 实例检查确认 `:UEBuild` 与 `<Space>ub` 均存在；本次只消除启动时序窗口，
  不触发真实 iOS build，也不改 dashboard / picker。

**Validation**

- TDD：新启动时序用例先复现 `mapped=false`，实现后 `keymaps` 53/53 passed。
- 定向：`commands` 99/99 passed；独立 pre-VimEnter 探针得到 `did=0 ub=1`。
- 全量：`nvim --headless -l tests/run.lua` 937/937 passed；`git diff --check` passed。

**Follow-ups**

- 无。

### 2026-08-14 — 将 macOS/iOS 开发链路安全整合到最新主线

**Task**

把当前 macOS/iOS 开发分支 rebase 到最新 `main`，保留主线的 project-bucket、多实例 writer
与 target matrix 契约，并确保公开 PR 不携带用户名、项目名、设备、签名或本机绝对路径。

**Implemented**

- 合并主线的 project-scoped state/lease 与本分支的 iOS target、AOT 复用、build monitor 和
  Neovide 适配；冲突按当前架构边界解决，没有恢复已退役的全局状态写法。
- iOS 增量脚本改为在项目内容目录下唯一发现 `ScriptAssemblies`，不再硬编码私有项目目录名；
  缺失或存在多个候选时 fail closed。
- 修复 POSIX wrapper CDB 从 staging 迁移到稳定目录时的路径重写、真实路径 canonicalization、
  macOS `xcrun` 编译 cursor shim 与测试侧 `python3` 发现。
- 修复多 Neovim 并发创建嵌套缓存目录的 `E739` 竞争，并强化 recent-project 异步重试与
  definition-cache 并发测试 flush，避免短命子进程退出前丢写。
- 测试夹具、发布记录和脚本说明统一改为合成示例；不记录私有项目、用户、设备、签名、SDK
  小版本、精确包体数量或耗时。

**Pitfalls / Gotchas**

- `mkdir(..., "p")` 在多个进程同时创建不同深度的同一目录树时，可能因中间父目录被抢先创建而
  抛出 `E739`，此时最终目标目录尚未出现，不能只检查一次 `isdirectory()`。
- Windows 风格反斜杠替换无法命中 macOS/Linux 生成的 wrapper CDB；稳定目录发布必须同时识别
  POSIX 与 Windows 两种路径拼写。
- rebase 后远端 feature branch 历史已变化，推送必须使用带 lease 保护的 force push。

**Validation**

- 定向：`index_generation` 16/16 passed；`multi_instance_state` 双路并发压力复跑均 11/11 passed；
  Python CDB 工具 `py_compile` passed。
- 全量：`nvim --headless -l tests/run.lua` 936/936 passed。
- 静态/规格：`lint_no_bare_globals` 135 files OK；三个新增 OpenSpec main specs 在官方 CLI 1.9.0
  下 strict validation 均 valid；`git diff --check` passed。
- 脱敏：公开 PR 新增行通过仓库 secret hook；私有用户名、项目名、域名、bundle、设备/签名、包号
  与本机绝对路径扩展扫描均为零命中，保留项仅为明确的合成测试 identity。

**Follow-ups**

- 物理 iOS 设备上的签名、安装、启动与增量动态库替换仍需在私有环境验证；公开记录不包含其输出。

### 2026-08-14 — 保留 project-bucket 升级前的 UE 索引与 CDB

**Task**

修复升级到 canonical project bucket 后，已有 checkout 的 `<Space>/` 因新 bucket 无 csearch index
而失效，并同时处置探针记录的 `active-compile-command-missing`。

**Implemented**

- `lua/ue.lua` 新增显式 pre-v4 engine-wide cache path model；迁移不再经当前 project-aware
  `cache_paths()` 错把新 bucket 当作 legacy source。
- `migrate_legacy_csearch_if_needed()` 先比较旧 state 与当前 bucket 的 canonical project key，
  只导入同一项目的 csearch snapshot、active-platform GTAGS、engine-root active CDB 与 controlled CDB state。
- 大型索引/CDB 通过同文件系统 hard link + 唯一临时名 + atomic rename 发布；保留旧路径供已运行的
  旧 Neovim 使用，并让并发 canonical writer 优先，避免 UI 主线程复制数百 MB/GB 文件。
- `tests/cases/grep_cache_spec.lua` 新增同项目导入、旧路径保留和异项目拒绝回归；
  `multi-instance-state-isolation` 主规格补齐旧工件迁移与身份隔离契约。

**Pitfalls / Gotchas**

- v4 的旧迁移函数仍调用 project-aware `cache_paths()`；项目被捕获后 legacy/active 实际指向同一路径，
  现有平台迁移测试未建立 project selection，因而没有覆盖这个确定回归。
- 当前实例位于另一个已有 engine checkout；先前 checkout 重建成功不能证明迁移正确，每个未导入的
  checkout 都会再次表现为 `<Space>/` 无 picker。
- `multi_instance_state` 与其他测试进程并行时会争用全局 probe 测试文件并出现 8→7；串行复跑
  11/11 通过，提交门禁继续使用仓库规定的串行全量入口。

**Validation**

- TDD：新增 legacy project-bucket 场景先稳定复现 `28/29`（迁移返回 false），实现后
  `grep_cache` 29/29 passed。
- 定向：`multi_instance_state` 11/11、`ue_project_context` 7/7、`ue_api` 54/54、`smoke` 18/18 passed。
- 真实实例：后台 `:UEPrepare` 生成 331,301,737-byte csearch index，`indexed=true`；
  `<Space>/` 等价搜索 `SubmitActiveCmdBuffer` 返回 34 个真实 csearch hits，preview window/buffer 均存在。
- 全量：`nvim --headless -l tests/run.lua` 808/808 passed。

**Follow-ups**

- 无。

### 2026-08-13 — 隔离多 Neovim 实例的 UE 状态与共享 writer

**Task**

审计当前配置中 process-global / project-scoped / user-global 状态，修复两个 Neovim 同时使用
同一 engine 时可能发生的项目/平台串扰、共享 JSON 丢更新与 cache writer 竞争。

**Implemented**

- 新增 `lua/ue/project_state.lua`：live project 与 target 捕获在当前 Neovim 进程；
  `selection.json` 只作为未来进程的启动默认；持久状态按 canonical uproject path 分 bucket，
  target platform/configuration 作为原子 pair，旧顶层 state 只读迁移。
- 新增 `lua/ue/file_lock.lua`：PID/token owner 的 filesystem lease、live-owner 拒绝、stale-owner
  回收与 token-checked release；UEPrepare、CDB pipeline、csearch、controlled semantic-index phase
  均增加跨进程 single-writer 门禁。
- `lua/ue.lua` / `ue.cdb.*` 将 active CDB、index scheduler/controlled CDB、clangd index/PCH
  放入 canonical project + platform 路径；CDB shard catalog 仅在同 project 内跨平台共享；
  project switch 只切换 live bucket，保留旧缓存。
- Android device 明确为当前 Neovim 进程内 `vim.g`；新增独立 child-process 回归，证明一个实例
  的 `:UESetAndroidDevice` 不会修改另一个实例。
- breakpoint persistence 改为 canonical project bucket，并在 lease 内合并当前打开 buffer 的改动；
  definition cache 改为 per-key atomic JSON，避免 shared monolithic JSON RMW 丢 key。
- probe、recent projects、watch dirty overlay 改为 lease 下重读+merge+atomic replace；csearch 成功后
  只退役 build-start captured dirty，保留其他实例新增或 build 期间再次修改的路径；
  `:UEPrepare!` 不再在 rebuild 成功前预清 dirty evidence。
- debug/grep/DAP protocol 日志改为 PID 路径；UE job log 增加 PID+hrtime；AI context 双文件导出
  由 lease 保护；content-addressed libclang cursor shim 先编译到 PID 临时文件再原子发布。
- 复扫发现 nvim-dap 上游 logger 仍以 `w+` 打开固定 `dap*.log`；新增
  `workarounds.dap.pid_scoped_logs` 在 dap 加载前统一插入 PID，`:UEDAPDiag` 改读当前
  PID 的 nvim-dap / protocol / breakpoint 诊断日志。
- 新增 `openspec/specs/multi-instance-state-isolation/spec.md`，同步约束、架构、测试映射、Android
  device/UE search 主规格与中英文使用文档。
- OpenSpec main specs 已直接同步当前实现。两个旧 active change 未污染主规格：
  `android-dap-platform-walkthrough` 保留已被证伪路线的未完成任务，
  `add-architecture-boundary-regression` 保留未拍板的 DRAFT；两者脱敏后归档到
  `openspec/changes/archive/2026-08-13-*`，均明确记录为 archive-without-sync。

**Pitfalls / Gotchas**

- `vim.g` 只在一个 Neovim OS process 内“全局”，不会跨实例；真正的串扰来自旧的 engine 顶层
  `state.json` 和共享 cache 文件，而不是 `vim.g.ue_android_device_serial`。
- 单次并发测试曾复现偶发丢 key，复跑变绿不能证明修复；definition cache 最终改为一 key 一文件，
  5 轮连续 8-writer 压测才稳定全绿。
- 只给最终 JSON 做 atomic rename 不能阻止 stale read-modify-write；共享集合必须在 lease 内重读并
  merge，独立字段/key 则应从结构上拆文件。
- csearch 增量路径旧实现先写固定 `csearch_incremental.txt` 再拿 writer slot，失败实例可能删除
  正在被另一实例读取的清单；现在顺序固定为先拿跨进程 lease，再生成唯一临时清单。
- 只扫自己写的日志不够；nvim-dap 的固定路径由上游 logger 内部生成，需在
  `require('dap')` 之前改写 logger filename，否则首次 `w+` 已经造成截断。

**Validation**

- 并发：`multi_instance_state` 11/11 passed；其中 definition-cache 8 writers 连跑 5 轮均通过，
  project/target/probe/recent/dirty/lease child-process 用例全绿。
- 定向：`grep_cache` 27/27、`ue_watch_csearch` 13/13、`csearch_build_guard` 21/21、
  `ue_cdb` 17/17、`index_generation` 16/16、`android_device` 14/14、`dap` 56/56、
  `ue_project_context` 7/7、`ue_context` 3/3、`ue_api` 54/54、`smoke` 18/18、
  `utils` 46/46、`probe` 19/19、`theme` 11/11、`cpp_semantic_sidecar` 15/15、`structure` 38/38。
- 静态/规格：`lint_no_bare_globals` 119 files OK；5 个受影响 OpenSpec main specs strict validation
  均 valid；`git diff --check` passed。
- nvim-dap 真实加载实验：`dap.log.create_logger('dap.log'):get_path()` 返回
  `.../dap.<pid>.log`；`workarounds` 15/15、`dap` 56/56、`smoke` 18/18 passed。
- OpenSpec：当前五个受影响 main specs strict validation 均 valid；归档前
  `android-dap-platform-walkthrough` strict valid；`add-architecture-boundary-regression` 按其
  DRAFT 状态保留“无 delta section”验证失败，未伪造完成状态。
- 全量：`nvim --headless -l tests/run.lua` 806/806 passed。

**Follow-ups**

- 无。

### 2026-08-13 — 为当前 Neovim 窗口设置会话名称

**Task**

为并行工作的 Neovim/Neovide 窗口提供可辨识的系统标题，并保留一键恢复自动标题的路径。

**Implemented**

- 新增 `lua/utils/window_title.lua`，提供 `set` / `reset` / `prompt` / `setup`，名称只作用于当前会话；`%` 按字面转义，C0/DEL 控制字符被清理，长度限制为 80 个 Unicode 字符。
- 新增 `:WindowTitle [name]`、`:WindowTitle!`、`:WindowTitleReset`；无参数打开输入框，确认空值恢复自动标题，取消不改变已有标题。
- `lua/config/keymaps.lua` 新增 `<leader>uW` 输入入口；浮动 cheatsheet、Markdown 速查和 keymap/command 主规格同步该行为。
- 新增 `tests/cases/window_title_spec.lua`，并将新模块加入测试范围映射；现有 keymap/command 冻结回归同步更新。

**Pitfalls / Gotchas**

- `'titlestring'` 使用 statusline 语法，原样写入 `%{...}` 会被求值；实现必须双写 `%`，不能只做终端控制字符过滤。
- `titlestring=""` 且 `title=true` 才是 Neovim 的自动标题；reset 不应关闭 `'title'`。

**Validation**

- TDD 红灯：新增 `window_title` spec 后因 `utils.window_title` 尚不存在而按预期失败；实现后 `window_title` 7/7 passed。
- 定向：`keymaps` 54/54、`commands` 92/92、`cheatsheet` 126/126、`structure` 38/38 passed。
- 静态/规格：`lint_no_bare_globals` 116 files OK；`openspec validate keymap-command-regression --type spec --strict` valid；`git diff --check` passed。
- 全量：`nvim --headless -l tests/run.lua` passed。

**Follow-ups**

- 无。
### 2026-08-12 — Restore complete IOS/Metal clangd compilation evidence

**Task**

- Fix the incomplete IOS semantic parse after a successful MetalRHI build and `:UEPrepare`, without changing project or engine source/configuration.

**Implemented**

- Stopped recursively discovering arbitrary nested `compile_commands.json` files; the previously published three-entry database was an LLVM Python test fixture under `Engine/Source/ThirdParty`.
- Added root-ownership and IOS compiler-evidence validation before any existing CDB can replace the canonical database.
- Added an IOS target-driver `semantic_cdb` plan. After `:UECompileForNvim` builds successfully, it runs UBT `GenerateClangDatabase` with `-NoExecCodeGenActions` in the existing build terminal, validates the full tuple, atomically publishes it under `.cache/nvim-ue/cdb/sources/<tuple>/`, and then invokes the existing prepare-only pipeline.
- Prioritized that tuple-owned source over derived canonical mirrors, required every IOS entry to match the active target/configuration, and carried source-publication state into the pipeline so an unchanged post-process still restarts clangd. This fixes `gd` on macros such as `CompiledMetalFx` remaining attached to the previous three-entry database.
- Kept `:UEPrepare` read/transform-only: it can consume response files or a validated tuple-scoped source but never invokes UBT, Cook, Package, Deploy, or Run.

**Pitfalls / Gotchas**

- `MetalRHI` belongs to the IOS game/client target and is covered. `MetalShaderFormat` is a host-side developer/editor module and is intentionally not mixed into the device-target database.
- The host-provided Apple clangd remains below the repository's pinned LLVM clangd 22.1.x contract; accurate CDB coverage and clangd compatibility are separate gates.

**Validation**

- A sanitized local `SampleGame / IOS / Development` probe produced a tuple-complete database covering the target's MetalRHI sources without Cook, Package, or compile actions.
- The final canonical CDB retained complete IOS compiler evidence and rejected all foreign fixture entries; project-specific entry counts and timings are intentionally omitted.
- Focused headless regressions: `ue_cdb` 24/24, `ue_target_drivers` 31/31, `ue_target_integration` 10/10, plus real init startup passed.
- Full headless regression: `nvim --headless -l tests/run.lua` — 855/855 passed.

### 2026-08-11 — Shorten local iOS C++ iteration without touching the project

**Task**

- Apply the iOS build-time improvements that can live entirely in Nvim/scripts, with local packaging explicitly reusing cooked data and never cooking.

**Implemented**

- Wrapped native IOS `Build.sh` in a macOS zsh helper that fingerprints AOT DLLs, runtime inputs, AOT tools, postprocessing code, SDK/toolchain identity, and the adapter build file.
- Injected `bSkipAOTProcess=true` only after a prior successful build published a matching manifest and every recorded framework path and content hash still match; cache misses clear inherited AOT skip/disable variables and run the full process.
- Added stable command-line INI overrides that suppress automatic dSYM generation/bundling during daily C++ builds.
- Changed `:UEPackageIOS` to `-skipbuild -skipcook -stage -nocleanstage -package -nodebuginfo`, removing local build/cook/archive/deploy/run stages.
- Added `:UEIOSSymbols` to run `dsymutil` only when needed, print binary/dSYM UUID evidence, and reject mismatches without producing a ZIP.

**Pitfalls / Gotchas**

- The first build, any input/toolchain change, or any missing recorded framework intentionally pays the full AOT cost; the cache fails closed rather than guessing freshness.
- `-nocleanstage` is a local C++ iteration optimization. A release/distribution pipeline remains responsible for a clean content build outside this command.
- These changes write only engine `.cache/nvim-ue` state and normal build outputs; no project or engine source/config file is modified.

**Validation**

- Focused: `ue_target_drivers` 28/28, `ue_target_integration` 9/9, `ue_target_tasks` 4/4, `platform` 22/22, `commands` 95/95, `ue_api` 55/55, `smoke` 18/18, `structure` 39/39, and `ue_ios_cpp_iteration` 3/3 passed.
- Full: `nvim --headless -l tests/run.lua` — 843/843 passed.

### 2026-08-11 — Show silent UE build activity in the existing terminal

**Task**

- Keep `<leader>ub` build diagnostics inside its existing terminal window instead of opening a separate monitor view.

**Implemented**

- Added a macOS-owned process snapshot capability using native `/bin/ps`; Windows and Linux drivers do not pretend to support it.
- Added an asynchronous, build-scoped process-tree monitor that identifies the active child tool/file, CPU use, elapsed time, process count, and the two preceding stage observations.
- Rendered the heartbeat as terminal-buffer virtual lines, preserving the real UBT output, terminal stdin, exit code, and quickfix behavior.
- Bound monitor startup/cleanup to the existing `termopen` job, including job exit and terminal-buffer wipeout.

**Pitfalls / Gotchas**

- This exposes activity while a child process buffers its own output; it cannot recover log lines that the project process has not emitted.
- The process snapshot capability is intentionally macOS-only until another host receives its own native driver implementation.

**Validation**

- Added parser, descendant filtering, active-stage selection, lifecycle, same-buffer virtual-line, platform ownership, and UE terminal integration regressions.
- Real macOS terminal probe observed `[UE heartbeat] ... sleep ...` from a live child process and cleaned it up without touching terminal output.
- Focused: `ue_build_monitor` 7/7, `platform` 22/22, `commands` 94/94, `ue_api` 55/55, and `smoke` 18/18 passed.
- Full: `nvim --headless -l tests/run.lua` — 836/836 passed.

### 2026-08-11 — Clear LazyHealth package-provider warnings

**Task**

- Resolve all current `:checkhealth lazy` errors and warnings.

**Implemented**

- Disabled Lazy's unused LuaRocks/hererocks provider because no configured plugin requires LuaRocks.
- Removed the empty legacy `site/pack/core/opt` directory that Lazy reported as an existing package root.

**Pitfalls / Gotchas**

- Installing hererocks would add an unused second Lua runtime without helping any current plugin.
- The legacy package path was verified empty before removal.

**Validation**

- `:checkhealth lazy` — 0 errors, 0 warnings.
- Focused: `core_health` 28/28 passed.
- Full: `nvim --headless -l tests/run.lua` — 828/828 passed.

**Follow-ups**

- Re-enable `rocks` only if a future plugin explicitly requires LuaRocks.

### 2026-08-11 — Expose Neovide and restore native Open Folder

**Task**

- Make the installed Neovide app callable from zsh and add the missing `o` Open Folder action on the macOS Neovide dashboard.

**Implemented**

- Added the Neovide app-bundle CLI directory to the login zsh PATH.
- Added a macOS-owned native folder-picker plan and an async Neovide handoff that changes cwd before opening the Snacks file picker.
- Added one idempotent dashboard `o` entry, visible only in Neovide on macOS; native dialog cancellation is a silent no-op.

**Pitfalls / Gotchas**

- `/Applications/Neovide.app` was already installed; Homebrew did not expose its bundled executable on PATH.
- Native AppleScript selection remains in the macOS host driver rather than leaking into the dashboard/plugin layer.

**Validation**

- Focused: `neovide` 3/3, `platform` 21/21, and `smoke` 18/18 passed.
- Full: `nvim --headless -l tests/run.lua` — 828/828 passed.

**Follow-ups**

- None.

### 2026-08-11 — Make host, target, and shell compatibility explicit

**Task**

- Audit and correct platform adaptation across iOS/Android/Win64/Mac/Linux targets, macOS/Windows/Linux hosts, and PowerShell/cmd/POSIX shells.

**Implemented**

- Added a central host-target-operation matrix and filtered target selection, lifecycle planning, runtime launch/log routing, and DAP registration through it.
- Added target-owned runtime strategies so generic launch/log modules no longer dispatch on hard-coded target names; kept IOS, Mac, and Android implementations independent.
- Added a host-neutral shell argv/quoting layer; moved PowerShell launch/log/debug-output behavior into Windows or Android-Windows adapters and removed PowerShell/cmd assumptions from macOS paths.
- Made CDB phases sequential argv jobs, skipped the Windows-only PCH generator on non-Windows hosts, preserved UNC/POSIX URIs, and delegated PCH execution to the Windows host driver.

**Pitfalls / Gotchas**

- An importable target module is not evidence that its operation can execute on the current host. iOS DAP remains explicitly unavailable and never falls back to Mac attach.
- Windows argv conversion must distinguish host filesystem paths from Unreal object paths such as `/Game/Maps/Main`.

**Validation**

- Focused: `platform`, `ue_target_drivers`, `ue_target_integration`, `ue_cdb`, `dap`, `android_device`, `task_registry`, and `commands` passed.
- Full: `nvim --headless -l tests/run.lua` — 824/824 passed.

**Follow-ups**

- On-device iOS build/install/launch and native Windows/Android execution remain environment-dependent verification lanes.

### 2026-08-11 — 同步并归档已完成的任务管理与 Android F9 规格

**Task**

收尾两个长期处于 complete 状态的 OpenSpec change，使已落地行为进入主规格并清理 active change 列表。

**Implemented**

- 新建 `openspec/specs/task-management/spec.md`，同步 `ue-task-manager` 的 11 条任务注册、派生状态、取消、picker/命令、statusline 与竞态消除要求。
- 新建 `openspec/specs/android-f9-breakpoint-hit/spec.md`，同步 Android F9 单一 owner、端到端命中、LLDB 证据、address 等价与诊断要求。
- `android-dap-attach` 主规格已经完整覆盖 delta，且包含后来落地的全局 serial 与 live F9 更强合同；同步保持当前主规格，没有用旧 delta 降级。
- 将 38/38 tasks 完成的 `ue-task-manager` 归档至 `openspec/changes/archive/2026-08-11-ue-task-manager/`，将 31/31 tasks 完成的 `fix-android-f9-breakpoint-hit` 归档至 `openspec/changes/archive/2026-08-11-fix-android-f9-breakpoint-hit/`。

**Pitfalls / Gotchas**

- delta 是变更当时的意图，不是覆盖当前主规格的快照；Android attach 主规格已演进到“不重连即时生效”，因此只核对 requirement/scenario 覆盖，不反向恢复旧的“提示手动 reattach”终态。
- 本次搜索/cheatsheet 改动没有对应 active change；不得为了执行 archive 指令而擅自归到两个无关历史 change 中。

**Validation**

- tasks 审计：`ue-task-manager` 38/38、`fix-android-f9-breakpoint-hit` 31/31，均无未完成项；artifacts 均为 done。
- requirements 交叉检查：`task-management` 11/11、`android-f9-breakpoint-hit` 6/6、`android-dap-attach` 2/2，无缺失。
- `openspec validate ue-task-manager|fix-android-f9-breakpoint-hit --strict`：归档前均 valid；`task-management` 与 `android-f9-breakpoint-hit` 主规格 strict validation 均通过。
- `nvim --headless -l tests/run.lua`：776/776 passed；公开仓库已知 serial/package/user-profile/private-key/API-secret 扫描 0 命中，`git diff --check` 通过。

**Follow-ups**

- 无。

### 2026-08-10 — 让快捷键帮助可以按键位实时搜索并保留分类

**Task**

回归 `<leader>?` 的快捷键入口与界面信息架构，让 `wW`、`aA` 这类成对大小写键位无需猜 tab，输入后立即找到对应操作和原始分类。

**Implemented**

- `lua/utils/cheatsheet.lua` 新增 `/` 实时搜索和 `<C-l>` 清除筛选；匹配覆盖键位、说明、tab 与 section，并按相关度排序。
- 搜索结果继续以 `Tab › Section` 分组；`wW` 顶部命中 `Basics › Motions` 的 `w / W`，`aA` 顶部命中 `Basics › Modes` 的 `a / A`。
- 将 word/WORD motions 与 insert-entry modes 改成逐动作的大小写成对展示，空格包围的展示分隔符不参与精确键位匹配，实际 `/` 键仍可搜索。
- `tests/cases/cheatsheet_spec.lua` 新增全表可发现性/分类审计及真实 `/wW<CR>`、`/aA<CR>` 浮窗交互；`tests/cases/keymaps_spec.lua` 锁定 `<leader>?` → `UECheatsheet`。
- `openspec/specs/keymap-command-regression/spec.md` 与 `docs/ue_lazyvim_cheatsheet.md` 同步搜索及分类合同。

**Pitfalls / Gotchas**

- Snacks 的 keymap picker 只看实际映射，无法覆盖 `w/W/a/A` 等 Vim built-in；因此入口必须基于 cheatsheet 的完整教学数据，而不是复用 `<leader>sk`。
- 普通 lowercase 搜索会把 `wW` 折叠成 `ww`；只有先把 `w / W` 这类展示分隔符归一化，才能既保持大小写不敏感又命中成对键位。

**Validation**

- TDD 红灯：`nvim --headless -l tests/run.lua cheatsheet` 初始 `119/124`，5 条搜索/分类合同按预期失败。
- 定向：`cheatsheet` `126/126`、`keymaps` `53/53`；真实按键输入后 extmark 可见内容包含预期 `Tab › Section` 与键位。
- 静态/规格：`lint_no_bare_globals` 115 files OK；`openspec validate keymap-command-regression --type spec --strict` PASS；`git diff --check` PASS。
- 全量：`nvim --headless -l tests/run.lua` `776/776` PASS。

**Follow-ups**

- 无。

### 2026-08-10 — 让 `<Space>/` 默认真正 literal，并让每条结果都可预览

**Task**

修复默认搜索单个 `.` / `/` 不启动、literal 命中在 preview 中仍像 regex 一样高亮，以及按文件插入
synthetic header 导致结果分类重复、首项和大量列表项没有真实源码预览的问题。

**Implemented**

- `lua/utils/code_search/init.lua` 的 literal quote 改为与 RE2 `regexp.QuoteMeta` 一致，只转义真正
  metacharacter；`/`、`-`、`%` 保持字面值。
- `lua/ue.lua` 允许默认 literal 模式下的单字符标点搜索，同时继续拦截单字符 identifier 和单字符
  regex；literal hit 写入精确 `end_pos`，Snacks preview 不再用 raw 输入二次执行 Vim regex。
- 删除可选中的 synthetic file-header item。csearch 按文件流式输出时仅缓冲当前文件，给真实命中标注
  Project / Engine / Workspace、相对路径、组内序号与命中数；首行承担分组标题但仍是实际命中，后续行
  保留缩进层级，因此任意结果都能 preview/confirm 到准确位置。
- picker 标题明确显示 `[scope: all]` 或当前模块/plugin scope；literal 与 regex 分别显示 `L` / `R`。
  `docs/ue_lazyvim_cheatsheet.md` 同步修正 visual toggles 与旧的 inline-rg-flags 误导。

**Pitfalls / Gotchas**

- backend 已按 literal 转义并不等于整个 UI 是 literal：Snacks 在没有 `end_pos` 时会把
  `filter.search` 再交给 `vim.regex`，所以 `.` 的结果集合正确但 preview 高亮仍像“任意字符”。
- synthetic header 看似能分组，但它也是 picker selection；初始项必落 header，单命中文件又让约一半
  列表项没有真实 match preview。分组信息必须附着在真实 hit 上。

**Validation**

- 真实 csearch 小索引证明 `/` 与 `\\/` 都只命中字面 slash，`\\.` 只命中字面 dot，`.` regex
  会扩展到任意字符；实现回归锁定 RE2 quote 集和 literal exact span。
- `grep_cache` 27/27、`utils` 46/46、`ue_api` 54/54、`smoke` 18/18、`commands` 90/90 passed。
- `openspec validate ue-code-search --type spec --strict` passed；
  `nvim -l scripts/lint_no_bare_globals.lua lua` 115 files OK；全量回归 768/768 passed。

**Follow-ups**

- 无；保留 `:UEGrepGroupingToggle` 作为 structured presentation 的诊断 A/B 开关。

### 2026-08-10 — Root 设备可显式选择可回滚的 app 私有 SO 注入

**Task**

在不修改已安装 APK/native library 的前提下，为 root 调试设备提供显式的 app 私有 SO 验证路径，
同时保留既有 root 原子替换作为默认行为。

**Implemented**

- `scripts/ue_android_so_deploy.ps1` 新增 `-PreferRunAs`；仅在显式传入时优先选择
  `run-as/startup-agent`，未传入时的 root/run-as 自动选择顺序不变。
- `tests/fixtures/android_so_deploy/run_as_transport_spec.ps1` 固定默认选择前提，并新增
  root-capable 场景的显式 run-as 选择合同，禁止该路径探测或使用 root transport。

**Pitfalls / Gotchas**

- app 私有 SO 能发布并被 `/proc/<pid>/maps` 证明已映射，不代表它与已安装 APK 的 Java/JNI
  基线兼容。实机运行在 `GameActivity.getDid()` 上得到 `NoSuchMethodError`，随后 ART 因 pending
  exception 中的 JNI 调用中止；该失败不能归因于 VRS 或锁屏。
- 作用域错误留底：用户已要求 SO-only 后，“编一下再试试”只能重编/部署 SO；本次错误地把 JNI
  mismatch 扩成 APK 打包并执行 `adb install -r -d`。今后版本不兼容只能 fail closed，禁止把它
  当成打包/装包授权；必须等用户明确说“打包/装包”。
- 设备 `versionCode=176314399`，本地 build metadata 已被中止的 package flow 改写为 `1`；
  warning-only 的 app 私有路径只证明 transport 可用，不能绕过版本/JNI 兼容性验证。

**Validation**

- fixture `run_as_transport_spec.ps1`：PASS；`nvim --headless -l tests/run.lua ue_api`：54/54 passed。
- 实机 `<PRIVATE_IP>:43581` preflight 证明选择 `run-as/startup-agent` 且不改变设备状态；实际发布后
  maps 证明只映射 app 私有 SO。失败后只删除本次 347 MB staging 目录，已安装 `libUE4.so`
  SHA-256 仍为 `e26864ba506d0bdeb46d3678b611917bb708fd4cb099fc8a4f606cc09e447dfe`；
  不带 agent 的 15 秒 control launch 保持前台存活。
- 新 SO 日志证明设备支持 `VK_KHR_fragment_shading_rate`（`pipeline=1, rates=7`）；因 JNI 中止发生在
  PSO 创建前，尚未证明 fixed-VRS PSO 的 `2x2` 执行路径。

**Follow-ups**

- 取得与 native build 同基线、包含 `GameActivity.getDid()` 且版本匹配的 APK 后，再验证
  `r.Mobile.OnePassShadowMask.ShadingRate=2` 与 `fragmentSize=2x2` PSO 日志。

### 2026-08-08 — 让 C++ `gd` 从 canonical entity 完整到达唯一函数体

**Task**

修复 overload、头文件 declaration 与 derived virtual call 已取得正确实体身份却仍停在声明处的问题；
建立不依赖名称/arity/path ranking 的完整语义链，并以真实 Android Vulkan 源码验证。

**Implemented**

- source/header 都先以 active CDB 或 compiler-emitted origin evidence 建立不可变 transaction，在
  proven TU 的 exact cursor 取得 libclang canonical USR；异步 provider 只能使用 snapshot 的
  URI/position/version，stale 响应没有 UI 副作用。
- `lookup-definition` 使用同 generation 的 controlled current→hot→full CDB，在 subject module 的
  compiler-authored UBT unity / exact fallback AST 中按相同 USR 找唯一 body。LuaJIT 无法可靠传递
  by-value `CXCursor` callback，因此按 LLVM toolchain + source hash 懒编译最小 C ABI shim；shim
  复用当前 libclang/TU，不加载第二份库、不重新 parse，超长路径/overflow/零或多个 body 均 fail closed。
- resolved cache 只绑定 canonical USR、CDB signatures、overlays 与 toolchain；同一实体换调用点/声明可
  复用，negative/ambiguous 结果不跨 subject 缓存。新增 `:UEDefExplain`、稳定 stage/reason 和失败/
  性能 probe，保留 150ms 可取消进度与 stale gate。
- current/hot/full 改为 generation manifest + coverage-superset selector；clangd 固定
  `--enable-config=false`，打开文件 exact argv/cwd 经官方 `compilationDatabaseChanges` 传输。
  不再写 `.clangd` 或把 `External.File`/`--index-file` 当 definition authority；受控 CDB 只接受
  active build 的真实 UBT unity membership，无法证明时保留 exact per-file TU。
- 为保持 800 行结构门禁，将 generation、C++ navigation coordinator、module definition lookup 分拆为
  `_generation.lua`、`semantic_navigation.lua`、`semantic_sidecar_definition.lua`；入口 API 与非 C++
  cache/LSP/csearch/GTAGS compatibility path 不变。

**Pitfalls / Gotchas**

- `clangd-indexer` YAML 记录 `.cpp` Definition 不代表 monolithic External index 的 LSP definition
  会返回 body；真实实验仍只到 declaration，故该路线已证伪。
- 人工跨 module/same-module argument union 会产生真实 Clang diagnostics；只有 UBT 自己写出的 unity
  wrapper + 匹配 `.o.rsp` 是可接受 membership evidence，不用 workaround 掩盖 parse error。
- 默认 `max_tus=1` 下真实 4-wrapper module lookup 的三个 cold USR 各约 29–31 秒，sidecar RSS
  1797–1818 MiB；这是已记录的冷路径成本。同一 canonical USR 的下一 subject 为 0ms，不通过并发
  多个大 TU 换速度。

**Validation**

- 真实 Android Vulkan 只读 smoke 6/6 PASS：二参数 `SubmitActiveCmdBuffer` call/declaration 都到
  `VulkanCommandBuffer.cpp:645`；无参 overload 都到 inline `VulkanCommandBuffer.h:421`；
  `FVulkanCommandListContext&` call 与 `final override` declaration 都到 `VulkanCommands.cpp:1098`。
  三组 canonical USR hash 互异、组内一致，shim ABI=1、`tu_count=1`；未写引擎/项目源码，未访问设备。
- 聚焦回归：`cpp_semantic_context` 11/11、`cpp_semantic_client` 15/15、
  `cpp_semantic_sidecar` 15/15、`cpp_semantic_transaction` 5/5、`ue_goto_behavior` 7/7、
  `index_generation` 15/15、`clangd_commands` 2/2、`cpp_semantic_index` 1/1、`ue_api` 54/54、
  `utils` 45/45、`stability` 9/9，全部通过；Python 生成器 syntax compile 通过。
- `openspec validate make-cpp-gd-semantically-complete --strict` passed；新增/修改行脱敏扫描 clean。
- 全量 `nvim --headless -l tests/run.lua`：765/765 passed。

**Follow-ups**

- cold module parse 的 29–31 秒与约 1.8 GiB RSS 是剩余性能边界；后续优化必须保持 canonical-USR
  authority、真实 compile context 与 fail-closed 合同，禁止回加 symbol/arity/path ranking。

### 2026-08-07 — 关闭 build terminal 不再终止 `<Space>us`

**Task**

修复 `<Space>us` 偶发以 exit code 143 结束的问题，并让 Android build preflight 只报告真实发生的 DAP 清理。

**Implemented**

- 运行中的 UE build terminal 使用 `bufhidden=hide`；关闭窗口只隐藏输出 buffer，不再 wipe buffer 并向
  PowerShell/UBT 发送终止信号。任务退出后恢复 `bufhidden=wipe`，保持既有的已完成 terminal 清理语义。
- Android DAP cleanup 仅在确有 active DAP session 时返回 `adapter_killed=true`，空闲状态的 `<Space>us`
  不再错误提示 “stopped lldb-dap adapter”。
- 增加 terminal 生命周期与 DAP cleanup 结果回归，防止重新引入关窗即取消和虚假清理提示。

**Validation**

- 历史 `nvim-debug.log` 记录 `<Space>us` exit 143；独立 terminal 实验复现 `bufhidden=wipe` 在 buffer
  删除时稳定返回 143。
- 使用当前真实 Android Development build state 完整执行两阶段 action graph：两阶段均 exit 0，
  `Target is up to date`，未进入 Gradle/APK/ADB。
- 真实 `:UEBuildAndroidSO` 启动后立即关闭 terminal：buffer 仍有效、job 仍运行，最终 `status=BOK`、exit 0；
  退出后 `bufhidden` 恢复为 `wipe`，且不再虚报停止 lldb-dap adapter。
- `ue_api` 56/56 passed；`dap` 56/56 passed。
- `openspec validate android-so-quick-deploy --type spec --strict` passed；全量
  `nvim --headless -l tests/run.lua` 729/729 passed。

### 2026-08-07 — 以实测能力而非 Android API 白名单选择 startup-agent transport

**Task**

修复 `<Space>uq` 在具备所需能力的 Android 15 / API 35 设备上被 `sdk == 34` 旧验证门禁提前拒绝的问题。

**Implemented**

- `ue_android_so_deploy.ps1` 与 `ue_android_so_launch.ps1` 不再把 Android API 精确版本当作 transport
  能力；继续 fail closed 检查 package `DEBUGGABLE`、`run-as` UID、ActivityManager
  `--attach-agent-bind`、设备/app ABI 以及发布 generation 的 identity/hash。
- startup agent 的 ClassLoader 错误与注释改为描述所需运行时契约，不再错误声称该契约只属于 API 34。
- 主 spec 将 app-private staging 前置条件改为可观测 capability；fixture 使用 API 35 锁定未来版本不会因版本号
  被拒绝，同时保留“缺少 attach-agent-bind 必须拒绝”的负例。

**Validation**

- PowerShell 5.1 `run_as_transport_spec.ps1`：API 35 capability-positive 与 capability-negative 用例通过。
- PowerShell 5.1 `startup_agent_spec.ps1`：deploy/launch/agent contract 通过，精确 API 34 门禁被列为禁止模式。
- `ue_api` 55/55 passed；`openspec validate android-so-quick-deploy --type spec --strict` passed。
- 全量 `nvim --headless -l tests/run.lua`：727/727 passed。
- 指定唯一设备的只读 preflight 未执行：验证时 ADB 返回 `device not found`；未切换到其他设备，
  未执行 staging、force-stop 或启动。

### 2026-08-06 — 在非 root 设备保留原签名并以 ClassLoader generation 替换 SO

**Task**

让已安装且自身 debuggable 的 APK 在 production user / 无 `su` 设备上复用原签名与安装数据，直接消费
app-private 新 SO；不修改引擎、项目源码、APK 或 `/data/app`。

**Implemented**

- `ue_android_so_deploy.ps1` 在 root 不可用时验证 package `DEBUGGABLE`、`run-as` app UID、
  `--attach-agent-bind`、API 34、设备 ABI 与 app `primaryCpuAbi=arm64-v8a`；源 SO 同时校验
  ELF64/AArch64 与 `DT_SONAME=libUE4.so`。
- `ue_android_so_agent.c` 以 startup JVMTI `ClassPrepare` 找到原本精确解析到 installed `libUE4.so` 的
  app ClassLoader，调用 `addNativePath` 并把新增 native path element 移到首位；原项目
  `System.loadLibrary("UE4")` 仍走 ART nativeLoad、原 linker namespace 与正常 `JNI_OnLoad` 路径。
- 非 root 发布改为唯一 generation：SO、agent 与 hash manifest 全部验证后才原子切换 `current` pointer；
  `ul` 会实际复算两个文件 hash。manifest 记录 installed versionCode 及 APK lastUpdateTime/path/stat 摘要，
  同 versionCode 重装或 APK 文件身份变化也会在启动前拒绝。
- `uq` 与 `ul` 对同一 serial/package 共用 Windows OS mutex；并发操作直接拒绝，异常进程退出后不留锁文件。
- `ue_android_so_launch.ps1` 只在工具目录完全不存在时走普通 APK 启动；partial generation、损坏 manifest
  或 baseline 漂移一律 fail closed。attach 后失败会 force-stop 并有界确认错误进程已退出。
- agent/host 都解析 `/proc/*/maps` pathname 后精确比较（允许 ` (deleted)`），不再用 substring；agent 在
  私有 SO 映射后继续监控 installed SO。状态改称 `mapped`，不冒充 `JNI_OnLoad` / 引擎初始化已返回。
- 删除了要求重签/重装的 wrapper baseline 路线和相关入口；运行时代码与 fixture 不保存现场包名、项目名或
  设备序列号，测试身份全部为虚构值。

**Pitfalls / Gotchas**

- 预先 `dlopen` 私有 SO 不能替代 Android 14 `Runtime.loadLibrary0` 的 ClassLoader 绝对路径解析，也不能
  代替 ART 的 native-library bookkeeping；晚注册 `NativeMethodBind` 又不会回放 zygote 期已有绑定。
- “data unchanged” 是不准确表述：该方案会更新工具自有 `code_cache/nvim-ue-so`；准确边界是 APK、签名、
  `/data/app` 与工具目录之外的既有业务数据不变。
- 修正上一条日志中“production user build 只能 root”的过度结论：设备全局不可调试不等于已安装 APK
  不可调试；现有 APK 自带 `DEBUGGABLE` 且具备 `run-as` / attach-agent-bind 时存在非 root 官方能力路径。

**Validation**

- PowerShell 5.1：startup-agent、root transport、run-as transport 三个 fixture 全部通过；额外独立实验
  证明同名 OS mutex 能跨两个 PowerShell 进程互斥。
- `ue_api` 55/55 passed；`openspec validate android-so-quick-deploy --type spec --strict` passed。
- agent 以 NDK clang `-std=c11 -Wall -Wextra -Werror` 成功交叉编译；`llvm-readelf` 证明产物为
  ELF64/AArch64、SONAME `libnvim_ue_so_agent.so`，依赖仅 `libdl` / `liblog` / `libc`。
- 唯一允许测试的已连接设备只执行显式 serial 的只读 preflight：确认 Android 14/API34、arm64、
  debuggable `run-as` 与 attach-agent-bind transport，输出 `no device state was changed`。
- 全量 `nvim --headless -l tests/run.lua`：727/727 passed。

**Follow-ups**

- 设备仍在使用，本轮没有执行真实 `uq` staging、force-stop 或 `ul` 启动；最终端到端 maps / 引擎存活证据
  留待设备可动时，只能在用户指定的唯一 serial 上执行。

### 2026-08-06 — 按设备能力选择 Android SO root transport

**Task**

修复 `<Space>uq` 把 root 执行写死为 `su 0`，导致无 `su` 设备在部署前抛出底层 shell 错误的问题。

**Implemented**

- `scripts/ue_android_so_deploy.ps1` 新增 `Resolve-RootTransport`：先验证 direct `adb shell id -u`，再验证 `su 0 id -u`，只接受明确返回 UID 0 的 transport。
- 新增 `Invoke-AdbRoot`，stat/test/mkdir/cp/chown/chmod/chcon/mv/sha256sum/rm 与回滚全部统一路由，不再各自写死 `su 0`。
- 两种 root transport 都不可用时，在 force-stop、strip、push、备份和替换前失败；错误包含 shell UID、build type、`ro.debuggable` 与 `:UESetAndroidDevice` 指引。
- `root_transport_spec.ps1` 覆盖 root adbd、verified `su 0`、production user build 无 root 三条路径，并验证无 root 路径只执行四条只读 probe。
- 同步 Android SO 主规格、架构边界与 K47 教训；没有修改引擎或项目源码。

**Pitfalls / Gotchas**

- “设备支持 root”不能等价成“设备存在 `su 0`”：engineering/root-adbd 设备不需要 `su`，production user build 则可能两者都没有。
- 当前所选设备实测为 shell UID 2000、`build_type=user`、`ro.debuggable=0` 且无 `su`；该设备不能执行原地 SO 替换，脚本修复只能准确拒绝，不能凭配置绕过 Android 权限模型。

**Validation**

- 回归先以 `ue_api` 52/53 失败复现缺少 root transport abstraction；实现后 53/53 passed。
- `structure` 38/38 passed；全量 `nvim --headless -l tests/run.lua` 725/725 passed。
- `openspec validate android-so-quick-deploy --type spec --strict` passed。
- 当前设备只读实测：`id -u=2000`、`build_type=user`、`ro.debuggable=0`、`command -v su` 失败。
- 以当前设备执行部署 preflight：在任何 installed SO 修改前返回新的 root-unavailable 证据错误。

**Follow-ups**

- 要在该设备使用 `<Space>uq`，必须先让设备本身提供 root adbd / `su 0`，或通过 `:UESetAndroidDevice` 选择 rooted test device；production user build 不能由本脚本提升权限。

### 2026-08-05 — 让头文件声明继续解析唯一的跨 TU 定义

**Task**

修复 C++ `gd` 到达 `SubmitActiveCmdBuffer` 头文件声明后原地终止的问题，同时保持 compiler identity 是唯一跳转依据。

**Implemented**

- `lua/utils/lsp_fallback.lua` 在 libclang 只能看到 declaration 时，以同一精确光标请求 clangd `symbolInfo`；只有 clangd USR 与 sidecar canonical USR 完全相等，才继续请求跨 TU definition。
- `lua/utils/ue_goto/provider.lua` 把返回该 USR 的 clangd client id 一并交给 definition 请求；未通过身份校验的其他 LSP client 不能贡献 location。
- definition location 先去重，再排除原 declaration 与当前位置；仅剩唯一 location 时才跳转。USR 缺失/不一致、零个或多个 definition 都保持当前位置，不按名称、arity 或返回顺序猜选。
- 从其他头文件调用点出发时，跨 TU 定义不可证明仍可退到 libclang 已证明同一 USR 的 declaration；已经位于该 declaration 时不制造自跳。
- `tests/fixtures/cpp_semantic/caller.cpp` 建立“origin TU 只含声明、body 位于另一 TU”的真实 libclang fixture；`ue_goto_behavior_spec.lua` 覆盖 USR 相等、USR 不一致、只回声明和多 definition 四条分支。
- 同步 C++ contextual navigation 主规格与符号解析架构文档；没有修改引擎或项目源码。

**Pitfalls / Gotchas**

- `clang_getCursorDefinition` 只在当前 origin TU AST 中找 definition；canonical USR 已解析成功不代表另一 `.cpp` TU 的 out-of-line body 会出现在该 AST。
- 直接信任 clangd 跨 TU index 会重新引入上下文漂移风险；libclang/clangd 的精确 USR 相等是跨 provider 交接的必要门禁。

**Validation**

- 两条回归均先失败：旧 header 路径完全没有发出 clangd USR/definition 请求，旧 provider 也会接收未校验 client 的 location；最终 `ue_goto_behavior` 4/4 passed。
- 真实 libclang fixture：`cpp_semantic_sidecar` 10/10 passed，并证明 declaration-only origin TU 返回非空 canonical USR、合法 declaration 与 `definition=nil`。
- `cpp_semantic_context` 10/10、`cpp_semantic_client` 10/10、`utils` 44/44、`structure` 38/38 passed。
- `nvim --headless -l tests/run.lua`：724/724 passed。
- `openspec validate cpp-contextual-definition-navigation --type spec --strict`：valid。

**Follow-ups**

- 当前已打开的 Neovim 会话需执行一次 `:UEDefReload`（revision `contextual-clang-v2`）或重启后再在 line 419 实测；实现不会触碰 Android 设备。

### 2026-08-05 — 分离 Android 安装、SO 替换与显式启动

**Task**

让 `<Space>ui` / `<Space>uq` 完成文件操作后保持应用停止，运行统一由用户显式 `<Space>ul` 触发，避免部署命令擅自占用设备前台。

**Implemented**

- `scripts/ue_android_so_deploy.ps1` 删除成功路径和回滚路径的 `monkey` 启动，以及与启动耦合的 PID/maps/稳定窗口验证。
- `<Space>uq` 现在只执行基线校验、force-stop、等待旧进程退出、strip/push、原子替换、metadata/hash 校验和必要回滚；成功后明确保持应用停止并提示使用 `<Space>ul`。
- `<Space>ui` 的既有实现经回归确认仍严格只有 `adb -s <serial> install -r <apk>`，不包含启动动作；`<Space>ul` / `:UELaunch` 是唯一显式启动入口。
- 同步 Android SO 主规格、架构数据流和 K46 教训；没有修改引擎或项目源码。

**Pitfalls / Gotchas**

- 文件部署命令若自动启动并要求运行时加载证据，就必然把部署结果与 Android 冷启动时序耦合；这与用户要求的显式启动边界冲突。
- 去掉自动启动后不能保留伪装成部署校验的 `/proc/<pid>/maps` 检查；静态完成判据是远端 metadata 与 SHA-256，实际运行由后续显式 `ul` 承担。

**Validation**

- PowerShell AST parser：通过。
- 无设备 mock：force-stop 延迟三轮后成功，永久不退出时在 1 秒内有界失败。
- `nvim --headless -l tests/run.lua ue_api`：52/52 passed。
- `nvim --headless -l tests/run.lua android_device`：13/13 passed。
- `nvim --headless -l tests/run.lua`：721/721 passed。
- `openspec validate android-so-quick-deploy --type spec --strict`：valid。
- 真机操作未执行：设备正在使用，按用户要求不触碰设备。

**Follow-ups**

- 无。

### 2026-08-05 — 让 C++ gd 服从当前 TU 的 Clang 实体身份

**Task**

修复 C++ 重载调用按裸 symbol cache 复用 sibling 落点的问题，并为非自包含 UE 头文件建立可证明的真实编译 TU 上下文；不修改引擎或项目源码，不加入 arity/ranking/text fallback workaround。

**Implemented**

- `lua/utils/lsp_fallback.lua` 将 C/C++ `gd` 从 legacy cache/csearch/GTAGS 链中隔离：source TU 只接受 active CDB 证明后的 clangd exact-position USR + 唯一 definition，header 只接受 contextual libclang 的 canonical USR 与同身份 definition/declaration。
- `lua/utils/ue_goto/semantic_{context,protocol,client,sidecar}*.lua` 与 `scripts/ue_clang_semanticd.lua` 实现 proven context、严格 NDJSON、异步 sidecar、unsaved overlays、stale request gate、live-TU LRU/idle eviction 和脱敏性能指标；source proof 要求明确 active shard 成员身份与 merged CDB freshness，并使用 clangd 消费的 post-processed merged command，模块按 context/client runtime/libclang/TU/catalog 边界拆分且均低于 800 行。
- `lua/ue/cdb/shards.lua` 修正 active shard 选择：匹配当前 platform/config/build class 时保留 `manifest.active`，显式 target 优先，并区分 Editor / non-Editor build class，避免较新的单文件 sibling shard 冒充当前构建。
- 头文件 context 只消费 active build 的真实 CDB 与 compiler-emitted `.cpp.json`、`.d`、rsp、unity membership；active-build 路径校验复用 `ue.cdb.shards.classify_rsp_path` 的 UBT grammar，不做 basename、目录距离、最近使用或路径子串猜测。
- 删除 C++ `gd` 已失效的 `syntax_filter`、arity、ranking、pair winner、自动 csearch/GTAGS 路径及对应脚本；保留非 C++ compatibility 与显式文本搜索入口。
- 新增真实 libclang fixtures、请求 stale/overlay/process 回归、只读 `scripts/ue_cpp_semantic_smoke.lua` 与脱敏证据；同步架构、约束、测试索引、cheatsheet、memory/decisions/lessons，将 OpenSpec delta 合并到主规格并归档 change。

**Pitfalls / Gotchas**

- standalone header clangd parse 在缺失真实 include/macro 前置上下文时会产生 recovery AST；只有被 build dependency evidence 证明的 origin TU 才有权决定 header 落点。
- 旧 LLVM/NDK 组合会在到达目标 AST 前触发诊断数量上限；sidecar 仅为语义 parse 添加 `-Wno-error -ferror-limit=0`，不改变原始 argv fingerprint 或实体选择。
- 光标移开再移回也必须永久 supersede 旧 token；只在回调时比较最终坐标会误放行 stale 跳转。
- source→header 的 origin context 必须直接来自已证明的 source CDB entry；用 `catalog(source.cpp)` 反推会在 cpp.json 只记录 includes 的正常形态下返回空。sidecar stop 也必须显式进入 stopping 状态，否则飞行中请求会被退出回调误当成可重试任务并重启进程。
- 初版 source proof 错误要求 raw active shard 与 merged CDB argv 完全相等。现场同一源文件分别为 189 / 622 个参数；回到 CDB pipeline 源码确认 merged CDB 会经过 slim/PCH/resolve/unify/prune 后处理，因此 exact equality 不是 provenance。现改为 active membership + merged freshness，并由 merged command 驱动查询。
- 单个 UE TU 的 libclang working set 很大。单点重复 warm 查询稳定不等于 reparse 内存已解决；最终完整 smoke 仍观察到 content-changing reparse 约 2.888 GB，因此只采用 max-TU=1、30 秒 idle eviction、版本不变内容复用与成功响应不携带 diagnostics 等有证据的边界控制。

**Validation**

- `ue_cdb` 15/15、`cpp_semantic_context` 10/10、`cpp_semantic_client` 10/10、`cpp_semantic_sidecar` 9/9、`ue_goto_behavior` 2/2、`utils` 44/44 passed；覆盖 active manifest/target/build-class 选择、同 arity 不同类型、默认参数、cv/ref、模板、ADL、继承、多 context、invalid AST、overlay、LRU、source→header origin、飞行中 stop、raw/merged command 分离、active membership 缺失拒绝、真实 sidecar 进程和 active-build 假前缀拒绝。
- 当前 live Nvim 在 `VulkanCommands.cpp:250` 的 source proof 返回 `resolved` 且携带 compile command；实际触发 `gd` 落到 `VulkanCommandBuffer.h:421`，没有 `active-compile-command-missing`。
- 已连接目标工作区的只读 smoke：两处嵌套双参数调用得到同一 canonical USR hash 并落到 `VulkanCommandBuffer.cpp:645`；无参调用得到不同 USR hash 并落到 `VulkanCommandBuffer.h:421`；exit 0，未写引擎/项目源码。
- 性能实测：cold parse 8,953 ms，warm query 复用同一 TU 且不按键 spawn compiler，content-changing reparse 15,437 ms；宽 evidence root 的精确预筛 + artifact 复核 1,998 ms。
- `nvim --headless -l tests/run.lua`：720/720 passed（包含保留的 `test_jumper_headless.lua`）；`openspec validate replace-cpp-goto-with-contextual-clang-resolution --strict`：valid。

**Follow-ups**

- high-water reparse working set 是已记录的剩余成本，不宣称已消除；若后续数据证明 max-TU/idle eviction 仍不足，另立 change 评估 clangd extension，禁止回加 symbol/arity/path ranking workaround。

### 2026-08-05 — 泛化 Android 项目标识并修复 SO receipt/APK 基线

**Task**

修复 `<Space>us` 已生成 SO、但 `<Space>uq` 错报 `Android SO not found`，并阻止新 JNI SO 被注入不兼容的旧 APK。

**Implemented**

- `lua/ue.lua` `android_so_from_receipt` 校验 UBT `<Target>.target` 的 TargetName/Platform/Configuration，并解析 receipt 声明的真实 SO build product；兼容 UE4 实际输出的 `<Target>-arm64.so`，不按 mtime 或通配符猜配置。
- receipt 含多个 `.so` 时，仅接受名称匹配当前动态 Target、类型为 Executable 的唯一主产物；插件 SO 或歧义候选不会被部署到 `libUE4.so`。
- nested `.uproject`、Android packageInfo 和 DAP symbol package 发现改为动态 `Source/<Project>` / `<Target>_Symbols_v*` / `<Target>-arm64`，不再把现场项目名当协议。
- `scripts/ue_android_so_deploy.ps1` 在 strip/push 前比较源 SO 同目录 `packageInfo.txt` 与设备安装包的 package/versionCode；不匹配时要求先通过 `<Space>ui` 安装一次基线 APK。
- `scripts/ue_android_so_deploy.ps1` 用 .NET `SHA256.ComputeHash(Stream)` 替代环境相关的 `Get-FileHash` cmdlet，保持大 SO 流式计算且不要求额外 PowerShell module。
- 回归 fixture 统一改用虚构的非 `Client` 项目，并覆盖 matching receipt、插件 SO 排除、错误配置、nested 项目与 DAP 符号发现；同步两个主规格、架构说明与 K44/K45 坑位。

**Pitfalls / Gotchas**

- 当前 UE4 的 Development 产物使用配置中性 `<Target>-arm64.so`；配置身份必须读 `<Target>.target`，不能从通用文件名推测。
- 首次真机替换虽然通过 ELF/hash/metadata/maps，但旧 APK 缺少新 SO 所需的 Java 方法，触发 `NoSuchMethodError` → SIGABRT；自动回滚后原应用恢复运行。
- 安装 matching versionCode APK 后同一 SO 成功部署并持续运行，证明失败是 Java/JNI 基线不匹配而非 strip 或文件替换问题。

**Validation**

- 回归测试先以 47/48 精确复现 receipt 文件名缺陷；最终 `ue_api` 51/51、`dap` 55/55、`ue_context` 3/3 passed，包含非 `Client` 项目、插件 SO 排除和多主产物歧义拒绝。
- 不匹配 APK 基线实测在 strip/push 前拒绝；匹配 APK 后实机部署 exit 0，hash/metadata/PID/maps 全部通过。
- 移除 `Get-FileHash` 后以同一真机路径复验：exit 0，.NET 流式 SHA-256 与设备端 `sha256sum` 一致，应用启动并映射替换后的 `libUE4.so`。
- `openspec validate android-so-quick-deploy|android-dap-attach|ue-code-search --type spec --strict`：全部 valid。
- `nvim --headless -l tests/run.lua`：688/688 passed；PowerShell AST、敏感信息扫描与 `git diff --check` 通过。

**Follow-ups**

- 纯 C++ 改动可持续使用 `<Space>us` → `<Space>uq`；Java/JNI/manifest/Gradle 输入变化后必须先重新安装一次匹配 APK 基线。

### 2026-08-04 — 过滤 Windows fs_event 元数据洪水

**Task**

处理持久化性能探针中反复出现的 `dirty-set-flood/cap-hit`，避免 1000 条伪 dirty 路径拖慢每次 picker 搜索。

**Implemented**

- `lua/utils/ue_watch.lua` 缓存当前 `csearch.idx` 内容时间锚；Windows/libuv 的已有文件 `change` 仅在文件 LAST_WRITE 晚于索引时进入 `persistent_dirty`。
- rename/create/delete、无索引和缺失 mtime 证据的场景继续保守记录，避免把带旧 timestamp 的新文件误过滤。
- 全量 csearch 成功清空 dirty 时同步推进 anchor，防止构建期间排队的旧元数据通知立刻重新污染集合。
- `tests/cases/ue_watch_csearch_spec.lua` 新增旧/equal/newer mtime、rename 与无索引行为回归；`ue-code-search` 主规格和 K43 坑位同步。

**Pitfalls / Gotchas**

- libuv Windows backend 同时订阅 LAST_ACCESS/ATTRIBUTES/SECURITY/LAST_WRITE，但只向 Lua 暴露统一 `change`；仅检查“文件仍存在”无法判定内容是否真的变化。
- 现场 1000 条 dirty 中 960 条已存在于刚生成的 csearch snapshot，只有 9 条内容 mtime 晚于索引；旧实现把元数据扫描放大成 overlay 洪水。
- `csearch-smart-build/reset: no snapshot` 的最新记录来自项目切换后的首次构建；当前 `csearch.idx.files` 已存在且与索引同时完成，属于预期冷启动，不另改逻辑。

**Validation**

- `nvim --headless -l tests/run.lua ue_watch_csearch`：11/11 passed。
- 现场 1000 条 dirty 回放：保留 9 条真实新写入，过滤 991 条索引前元数据事件，耗时 43.529 ms。
- `nvim --headless -l tests/run.lua`：682/682 passed。
- `openspec validate ue-code-search --type spec --strict`：valid。

**Follow-ups**

- 修复加载后重新观察 `dirty-set-flood`；若仍有 cap-hit，按新证据区分真实批量源码变更与其他事件源。
