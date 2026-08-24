# Architecture Overview · 架构总览

> **docs/architecture/** 区：项目架构的高层视图。
> 出处优先：本文件给「全景 + 归属边界」，深度细节在各专题文档，不复制原文。
> 关联：`docs/architecture-symbol-resolution.md`（符号解析栈）、
> `docs/architecture-vs-lazyvim.md`（相对 LazyVim 的增量）、`docs/TOOLING.md`（工具链）。

## 0. 一句话

把一个万级 cpp 文件的 UE5 工程，塞进一个 24 小时跑、无人值守也不静默挂的 Neovim 开发环境：
3 分钟全量索引、亚 100ms goto-definition、一键 Android headless DAP、错误全落盘。

## 1. 主要子系统（major subsystems）

| 子系统 | 代码 | 职责 | 归属边界 |
|---|---|---|---|
| UE 引擎中枢 | `lua/ue.lua` + `lua/ue/` | 索引 / CDB / DAP / 命令注册总入口 | 公共 API 挂 `M.*`；命令在 `ue.setup()` 注册 |
| Project/session state | `lua/ue/project_state.lua` + `file_lock.lua` | 当前进程选择、canonical project bucket、跨进程 writer lease | live selection 不重读其他实例的默认值；共享写入必须 atomic/merge/lease |
| CDB 流水线 | `lua/ue/cdb/` | compile_commands.json 生成/裁剪/shader/inject | 纯函数 + 子进程；写前 skip-if-unchanged |
| 配置 schema | `lua/ue/config.lua` | `index/context/clangd/dap/cdb` 默认值 + override | `get/setup/options/reset_for_test` |
| 核心工具 | `lua/ue/core/` | fs / proc 纯函数 | 无副作用，可 headless 断言 |
| DAP 调试 | `lua/ue/dap/` | session-owner dispatch + 各平台 attach/launch | `platforms` 注册表是唯一 dispatch seam |
| Android device | `lua/utils/android_device.lua` | `adb devices -l` 枚举、当前进程 serial 选择、`adb -s` argv | `vim.g.ue_android_device_serial` 是本 Neovim 进程的交互真相；活跃任务捕获 serial |
| Android SO 迭代 | `lua/ue/targets/android.lua` + `android_windows.lua` + `scripts/ue_android_so_*.ps1` + `scripts/ue_android_so_agent.c` | Windows host 上的 SO-only UBT action 执行；root 原子替换或 debuggable app-private ClassLoader 重定向 | Windows-only compatibility adapter；不增加 macOS→Android；正常 APK 流程保持独立 |
| UE target drivers | `lua/ue/targets/` | Android / IOS / Mac / Win64 / Linux 的 UBT、UAT、产物和设备策略 | 各 target 独立实现；不得跨 driver fallback |
| 符号解析栈 | `lua/utils/ue_goto/` + `lsp_fallback.lua` | C++ compiler identity；非 C++ compatibility | header 必须有 proven origin TU；非 resolved 不猜测 |
| 代码搜索 | `lua/utils/code_search/` | csearch 亚秒级 grep | 显式搜索、references 与非 C++ 兼容路径 |
| 核心健康审计 | `lua/utils/core_health*.lua` + `scripts/nvim_core_health.lua` | 真实启动、编辑、AST、搜索、clangd/CDB/target plan 的分层证据 | 交互入口只异步启动隔离 headless runner；live workspace 只读 |
| 平台驱动 | `lua/utils/platform/` | OS 分支唯一收口 | 共享基础接口 + host-owned 可选能力；其余代码不做 OS 分支 |
| workaround 注册表 | `lua/workarounds/` | 上游 bug 隔离补丁 | 带 frontmatter；`:WorkaroundList` 可见 |
| 配置层 | `lua/config/` | keymaps/options/autocmds/lazy | LazyVim 自动加载，勿在 init 重复 require |
| 插件层 | `lua/plugins/` | per-plugin setup | snacks-only；不集成 copilot |

## 2. 数据流（data flow）

- **索引/CDB**：`:UEPrepare` → UBT `-SkipBuild` 取编译参数 → `ue/cdb/*` 生成/裁剪/inject
  compile_commands.json → cindex 建 csearch 索引 → clangd reload。UE root 的 clangd LSP 使用持久化 artifact
  gate：当前 project/target/platform/configuration 的 selection、manifest、controlled CDB 与源 CDB 签名
  仍有效时，新 Neovim 直接复用并启动；仅工件缺失、stale 或 tuple 变化时等待下一次 `:UEPrepare`。
  非 UE C++ root 不经过该 gate。全程 async + 进度 UI。
- **状态/缓存**：`:UESetProject` 把选择捕获在当前 Neovim 进程，同时更新未来进程读取的
  `selection.json` 默认值；project state/CDB/index/breakpoints/definition cache 写入 canonical-path
  project bucket。平台选择同样在进程内固定，另一个实例的修改不会重定向 live context。
  target platform 是双轴：per-project `target-selection.json` 是唯一权威；engine 级
  `target-default.json` 只作 picker 置顶建议（suggest, never inherit），新 bucket 未显式选择前
  UEBuild 先弹 picker，不以任何默认值静默构建。显式 `:UESetPlatform` 还会在当前进程保留一个
  one-shot target intent，供下一次 `:UESetProject` 消费，因此两个命令先后顺序等价；该 intent 不落成
  engine authority，也不跨 Neovim 进程传播。UBT build 与 prepare/CDB pipeline 互斥
  （build 赢：启动时 cancel 在飞 pipeline；build 运行中 prepare 拒绝启动）——prepare 读的
  Module.*.rsp/receipts 正是 build 在写的产物（WAW，见 CONSTRAINTS K51）。
- **goto-definition**：C++ source 以 controlled active CDB transport 的 exact command 在 clangd
  精确光标取得 canonical USR，并只向同 identity client 查询唯一 definition；不再为每次 source `gd`
  让 sidecar 重读全量 CDB。header 仍在 proven origin TU 中取得 libclang exact-cursor canonical USR，
  再在同 generation controlled module AST 中查唯一 body。非 C++ 兼容路径保留
  cache/LSP/csearch/GTAGS；详见
  `docs/architecture-symbol-resolution.md`。
- **Android device**：`<Space>uA` / 首次 Android 操作 → `utils.android_device` 异步执行
  `adb devices -l` → picker 展示名称 + serial → 当前进程的 `vim.g.ue_android_device_serial`；install / launch /
  logcat / 新 DAP session 捕获该值并统一形成 `adb -s <serial> ...`。
- **Android SO 快速迭代**：`<Space>us` → UBT 导出/执行 outdated action graph，不进入 Gradle；
  `<Space>uq` → 由匹配 Target/Platform/Configuration 的 UBT receipt 解析实际 SO → 生成与 APK 一致的
  stripped 临时副本 → 按 selected serial 只读选择 transport。root 设备走 installed SO 备份/原子替换/
  metadata+hash 校验；无 root 但已安装包可 `run-as` 且 debuggable 时，把 SO、nvim 自带 agent 与 hash
  manifest 写入唯一 generation，再原子发布 `current` pointer。`uq`/`ul` 对同一 serial/package 由 OS mutex
  串行化。两条路径都 force-stop 后保持停止，不自动启动；失败恢复各自的前一目标。
  用户显式 `<Space>ul` 时，只有完整、SO/agent hash 复算相等，且仍匹配 installed versionCode + APK
  path/stat/lastUpdateTime 摘要的 generation 才可通过；
  `--attach-agent-bind` 在应用类执行前把私有 native
  目录置于 app ClassLoader 搜索首位，再由原本的 `System.loadLibrary("UE4")` 走 ART/JNI 正常加载；agent 与
  host 按 maps pathname 精确要求仅出现私有路径，失败时 host 强制停止错误进程。仅当工具目录完全不存在时
  才保持普通 APK 启动；部分 staging 必须拒绝。项目目录、Target、包名、设备 serial
  和 data/native 目录均动态派生，不固定现场身份。
- **编译器语义**：用户先以 `<Space>ub` 完成当前 target 的原生 UBT build；macOS 主机上的 IOS
  `:UEPrepare` capability 分支先执行 clangd 22.1.x 预检，再通过 target driver 运行不执行
  compile/cook/package 的 tuple-scoped `GenerateClangDatabase` action-graph plan，原子发布到
  `.cache/nvim-ue/cdb/sources/<tuple>/`，随后进入公共 CDB/index 流程。IOS 首次 prepare 还在生成
  semantic source 前完成 prepared signing/private-key/device setup。IOS driver 会为 semantic 子进程
  设置工程已有的 `bSkipAOTProcess=true`，避免 Build.cs 在 action-graph 构造期执行 AOT；该变量不进入
  正常 build。若 Nvim marker 晚于已有构建上线，则只在 UBT `.target` 精确匹配 tuple 且 launch product
  存在时迁移一次 build evidence。成功发布 semantic source 后同时保存精确 tuple、build completion 与
  文件 size/纳秒 mtime；同一 build 重复 prepare 直接复用，不再启动 `Build.sh`/UBT，任一签名变化才重建。
  prepare 完成后通过原生 `FileType` autocmd 唤醒已加载 UE C/C++ buffer 的 clangd，不依赖插件命令。
  `:UECompileForNvim` 仅作为
  build → 同一 `:UEPrepare` 路径的兼容入口。其他 target 完全保留已有 response-file 路径。候选只来自
  受控路径，并按工程根与 target compiler evidence 校验；不得递归捡取 ThirdParty 测试夹具。
  Tree-sitter 语法解析与此分离，不会被 clangd/CDB 缺失伪装成失败。
- **核心健康审计**：`:NvimCoreHealth` 异步启动 `scripts/nvim_core_health.lua` → 隔离临时目录验证真实
  init、编辑事务、mandatory Tree-sitter AST、rg/csearch、clangd/CDB 与 target driver 纯计划 → 按
  `PASS/FAIL/BLOCKED/SKIP` 输出脱敏报告并清理。`--live` 只读取显式提供的既有 tuple/artifact，
  不触发安装、更新、UE build/package/device 或 DAP。
- **iOS 应用**：`:UEBuildIOS` 经 IOS target driver 和 macOS zsh wrapper 调原生 `Build.sh`；wrapper
  只在 AOT 输入指纹、SDK/工具链与上次成功 framework 产物全部匹配时注入 `bSkipAOTProcess=true`，
  输入 content hash 可在 path/device/inode/size/纳秒 mtime/ctime 全同后复用，但 output 仍逐个 hash；
  Build.sh 始终运行并由 UBT action graph 判断过期 C++ action。IOS `:UEPrepare` 在尚无有效 setup
  evidence 时自动执行 prepared identity → 临时 Mach-O 非交互私钥实签 → 唯一设备/backend → legacy
  helper 验证；`:UEIOSSetup` 保留为显式重跑/诊断入口。
  只有整条链通过才报告 daily build/install ready。临时签名副本无条件清理，不读取/保存 keychain 密码，
  相同快速探针也在已配置 build/package/install 重签大型 artifact 前执行。
  `:UESetIOSSigningCertificate` 把当前
  keychain 中精确匹配的 identity 保存到 project bucket；无参数时优先 fail-closed 导入
  `PrepareIOSQADebug.sh` 的 `Saved/IOSQADebug/signing.json`，并兼容 `workspace/Source/SampleGame` 布局，
  没有 manifest 时才显示 picker。Build/Package 用 argv-only INI override 捕获，
  Package/Install 精确 preflight，绝不选择第一张证书。日常 build 另用稳定 INI override 延后 dSYM。
  `:UEPackageIOS` 规划 UAT BuildCookRun
  （SkipBuild/SkipCook/Stage/NoCleanStage/Package，不含 Cook/Archive/Deploy/Run）；`:UEIOSSymbols`
  按需运行 parallel dsymutil、验证 DWARF 输出并比较 binary/dSYM UUID；
  `:UESetIOSDevice` 合并结构化 CoreDevice JSON、`idevice_id` 的实时 USB/Wi-Fi MobileDevice 与
  pre-iOS17 `xcdevice` fallback，并把 identifier/backend/transport 一起保存；保存设备未实时出现时，
  picker 会同时展示 live 候选与 `saved, offline` 项，禁止自动替换。单一进度句柄持续显示 CoreDevice、
  MobileDevice、legacy fallback、IOUSBHost recovery 与重探测阶段。`:UEInstallIOS` 的
  CoreDevice 路径继续消费当前 package task 的
  `Binaries/IOS/Payload/<Target>.app` provenance；legacy 路径只在当前 tuple app、匹配的
  `Saved/IOSQADebug/signing.json` 与 branch 对应 `InstallIOSClient.sh` 同时存在时，克隆并重签临时副本，
  再用 MobileDevice 原地更新；helper stdout/stderr 被流式解析为签名、上传和 device Upgrade 百分比。
  源 app 与设备 container 不被删除。`:UELaunch` 的 CoreDevice 路径消费 devicectl JSON；legacy 路径
  从 prepared signing manifest 恢复已签名 app 与已安装 bundle，在显式选择的 USB/Wi-Fi transport 上
  用 host-owned `ios-deploy --noinstall --justlaunch` 启动后复查 PID，因此 Nvim 重启不要求重做 package/install，也不触发签名
  私钥检查；两条 iOS run 路径都不隐式进入 DAP。
- **DAP**：setup 先按 host-target-operation matrix 过滤 handler，再由 `UEDAP*` 命令经
  `ue.dap.platforms` dispatch → 具体平台 `attach/launch` → `lldb-dap`。attach/launch 开始时
  捕获不可变的 session owner；后续 stop/status/reattach/cleanup 只按该 owner dispatch，UI 的当前
  target 或 device selection 改变不得劫持活跃会话。iOS 不借用 Mac process
  attach：`ios-deploy --nolldb` 只负责 legacy USB debugserver loopback bridge，Apple LLDB 选择
  `remote-ios` + 精确 DeviceSupport sysroot，以本地 symbol-rich Mach-O 创建 target，并映射设备 app
  executable。`UEDAPLaunch` 经 `SBProcess.RemoteLaunch(..., stop_at_entry=true)` 在断点下发前保持停住；
  `UEDAPAttach` 取已运行 bundle PID，再等待异步 RemoteAttach 进入 stopped。内存模块使用 `partial`
  load level，避免通过 USB 下载完整远程符号表；本地 Client DWARF 仍保持完整。`UEDAPStop` 非终止式
  detach 后杀掉并复查设备进程。Android 走 platform
  模式 + serial connect URL；K30 URL 与本次 session 捕获的 ADB serial 必须一致，切换当前进程的
  选择值不改变活跃 session 的 poll/cleanup。
  `tools/ios_dap_protocol_probe.py` 保留为脱敏 CoreDevice/legacy preflight 与协议诊断入口；生产路径已在
  legacy 真机分别验证 attach-at-launch、ordinary attach、resolved source breakpoint、source frame、
  LLDB expression 和 cleanup。

### 2.1 状态归属清单

| 作用域 | 当前状态 | 多实例语义 |
|---|---|---|
| 当前 Neovim 进程 | project/target live selection、Android serial (`vim.g`)、活跃 DAP/build/task、statusline、window title、notification history | 不读取其他实例的 live 值；长任务在启动时捕获设备/项目 |
| canonical project | state fields、target 默认 pair、CDB/csearch/GTAGS/clangd/PCH/index、dirty overlay、breakpoints、definition cache | 路径 digest 防同名项目碰撞；platform-sensitive 产物再分桶；writer 用 atomic/merge/lease |
| cwd + git branch（插件层） | `persistence.nvim` session、Snacks scratch | 项目共享；session 是最后退出快照，scratch 是同一持久文件，不是 UE live context |
| user global | theme preference、recent projects、probe feedback、Lazy plugin store | theme 为 atomic last-writer-wins；recent/probe 在 lease 内 merge；plugin store 由 Lazy 管理 |
| Neovim 内建 | shada、persistent undo、swap | 保持 Neovim 原生语义，不用 UE project selector 重定向 |
| 纯诊断 | custom debug/grep/DAP trace、`nvim-dap` main/stdout/stderr logs | 全部按 PID 分文件；任一实例不会 truncate/rotate 另一实例 |

## 3. 平台与工作流分层（platform and workflow layers）

平台相关功能按以下五层单向组合：

1. host capability 解析可执行文件、路径和宿主能力；
2. target driver 生成不含副作用的结构化 plan；
3. target workflow 拥有目标平台的设备交互、UI 决策、异步阶段与 rollback；
4. generic runner 只执行显式 plan，不解释 target 名称；
5. `ue.lua` facade 只解析公共上下文、查 registry 并调用上述入口。

依赖只能由后层指向前层。host capability 不得 import UE 模块，target driver 不得执行命令或调用
workflow，generic runner 与 facade 不得通过 target literal 重建平台策略。

- **Host layer** `lua/utils/platform/`：`windows/macos/linux/stub` 四驱动共享 path/process/tool
  入口契约；Xcode tools 是 macOS-only capability，PowerShell/debug-output/PCH build 是
  Windows-only capability。
  **这是唯一允许 OS 分支的地方**，不要求各 host 伪装成同一工具集。
- **Shell layer** `lua/utils/platform/shell.lua`：只接受显式 `posix/powershell/cmd` kind 与 host
  已选 executable，负责 quote 和 argv；不探测 OS。CDB Python phases 直接以 argv 顺序执行，
  不再拼 `&&` shell string；Windows-only `prebuild_pch_v2.py` 在非 Windows host 自动跳过。
- **Target layer** `lua/ue/targets/`：`android/ios/mac/win64/linux` 分别拥有目标平台参数、产物、
  设备、runtime strategy 与失败语义。共享 `_common.lua` 只能做 policy-free 的 argv/path/schema
  操作；任一 target driver 不得调用另一个 target driver。
- **Target workflow layer** `lua/ue/workflows/<target>/`：拥有 target-specific 的 UI、设备 I/O、
  install/launch/signing/deploy 阶段、取消与 rollback。workflow 必须先捕获 immutable snapshot，后续
  callback 不得重读 mutable project/target/device selection；跨目标复用只允许 policy-free runtime
  helper，不允许从一个 target workflow fallback 到另一个 target workflow。
- **Workflow registry** `lua/ue/workflows/`：以 `(target, operation)` 为 key 注册 workflow owner；
  facade 只能通过 registry dispatch，generic 层与 `ue.lua` 都不得手写 target `if/else` 旁路。
- **Composition resolver** `ue.targets.resolve(target, operation, host_driver)`：以各 target 的
  `host_operations` 为唯一兼容性真相。`:UESetPlatform` 的候选也由 `build` operation 过滤；模块可
  import、磁盘上有 foreign artifact 或 host 恰好有某工具，都不能绕过 matrix。
- **Generic runner** 执行 plan 与 workflow 声明的通用 async 生命周期，不按 target 名写 `if/else`；
  所有 mutable 输入都必须在启动时冻结进 snapshot。
- **Facade** `lua/ue.lua` 只解析公共上下文、查 registry 并调用结构化入口；不得承载
  IOS/Android/Mac 命令参数、设备策略、签名流程或 rollback。
- runtime orchestrator 读取 target driver 的 `runtime.launch/main_log/debug_log.strategy`；DAP 平台层经
  matrix-filtered `platforms` 注册表接入，并以冻结的 session owner 路由 stop/status/reattach/cleanup
  生命周期，后续不得回退到“当前 target/platform”推断。

### 当前 host-target-operation matrix

| Host | 可执行 targets / operations | 明确不可用 |
|---|---|---|
| Windows | Win64：build/launch/log/debug-log/DAP；Android：build/SO build+deploy/install/launch/log/DAP | IOS、Mac、Linux |
| macOS | Mac：build/launch/log/DAP；IOS：build/package/device/install/launch/DAP | Android、Win64、Linux |
| Linux | Linux：build/launch/log/DAP | Android、IOS、Mac、Win64 |

此表描述当前已实现能力，不代表 UE 理论上不能支持更多组合；新增组合必须先增加独立 host adapter、
matrix 声明与回归，不能在 generic orchestration 中添加 shell/path 猜测。

## 4. 构建流水线（build pipeline）

- 外部工具链版本钉死见 `docs/CONSTRAINTS.md §三 C1`（clangd/LLVM 22.1.x、`lldb-dap`、
  NDK lldb-server、Neovim 0.10+）。
- CDB 生成器（`tools/*.py` + `lua/ue/cdb/*`）：super-unity / prune / inject，写前比对跳过。
- CDB mutation 由 `lua/ue/cdb/pipeline.lua` 进程内 slot + filesystem lease 双层串行化；
  每个 Python phase 使用 argv 顺序启动，任一步失败即停止。UEPrepare 持有 project-scoped prepare
  lease 到 pipeline/partition 完成，controlled index phase 另持 project+platform build lease，
  禁止不同 Neovim 并发撕裂 JSON/csearch/index artifact。
- csearch 索引：`tools/cindex-uefilter`（Go fork）`-files-from` 干净建索引。
- Android SO-only（Windows host compatibility path）：`android_windows.lua` 通过 Windows-only
  `powershell_entry` 调用 `scripts/ue_android_so_build.ps1`，两阶段执行 UBT action graph；部署脚本先以
  只读 probe 选择 root adbd / verified `su 0` 或 debuggable `run-as` + startup-agent transport。
  本次 macOS 能力只面向 IOS，不实现或暗示 macOS→Android。
- macOS/iOS：host driver 提供原生 `Build.sh` / `RunUAT.sh` / Xcode executable；IOS target driver
  独占 C++ iteration wrapper、只复用 cooked data 的 BuildCookRun、按需 dSYM、SDK/签名预检、
  packaged app provenance、devicectl install/launch。AOT 指纹只写 engine `.cache/nvim-ue`，不修改
  工程或引擎代码。
- 端到端搭建流程见 `docs/skills/ue-ide-bootstrap.md`。

## 5. 关键归属边界（ownership boundaries）

- **OS 分支**只在 `lua/utils/platform/`。
- **Target-specific 策略**只在对应的 `lua/ue/targets/<target>.lua`；共享宿主不等于共享 target
  （尤其 IOS 与 Mac），禁止跨 driver 调用或 fallback。
- **Target-specific 副作用编排**只在对应的 `lua/ue/workflows/<target>/`；`ue.lua` 与 generic runner
  不能持有 target literal、平台命令模板、设备恢复或签名状态机。每个异步 workflow 只消费启动时
  捕获的 snapshot，并明确完成、失败、取消与 rollback terminal state。
- **Production boundary guard** 由 `tests/cases/ue_platform_boundary_spec.lua` 的 Tree-sitter AST contract
  维护；`ue.lua` 的 numeric ratchet 与新增 workflow 文件 800 行上限由 `tests/cases/structure_spec.lua`
  共同守门，禁止把 target policy 重新塞回 facade。
- **Android 设备选择**只在 `lua/utils/android_device.lua`；调用点消费 selected serial，
  `vim.g` 的 global 明确指当前 Neovim 进程而非所有实例；活跃长流程只消费启动时捕获的 serial，
  禁止中途重读后跨设备。
- **Android SO 快速部署**的 Lua target policy 位于 `android.lua`，既有 PowerShell transport 仅由
  `android_windows.lua` 适配；脚本负责 root/app-private staging、启动和 maps 证明，且不固定项目、
  包名、设备或设备路径。macOS host 不暴露 PowerShell capability，也不从 Android driver 获得隐式 fallback。
- **CDB 写入**只允许一个 pipeline writer；任何后续 partition/mirror 必须通过完成回调串行衔接。
- **共享状态写入**必须选择明确语义：project state/definition cache 用 per-key atomic 文件，
  probe/recent-project/dirty overlay 用 lease 下 merge，纯诊断日志按 PID 隔离；禁止无锁共享 JSON RMW。
- **插件自有日志**也必须符合同一边界；`dap.pid_scoped_logs` 在 `require("dap")` 前把
  nvim-dap 的固定 `dap*.log` 名改为 `dap*.<pid>.log`。
- **LSP 行为改动**只走 `lua/utils/lsp_fallback.lua` 或 `lua/workarounds/clangd/*`（禁全局 handler 覆盖）。
- **上游 bug 补丁**只进 `lua/workarounds/<scope>/<name>.lua`（禁 inline monkey-patch）。
- **C++ goto 精度**只信 proven libclang canonical USR + module AST 唯一 body；TS 不给答案，
  csearch/GTAGS 不参与 C++ destination。非 C++ 保留既有 LSP/csearch/GTAGS 兼容链。
- **启动顺序**固定，见 `docs/CONSTRAINTS.md §三 C3` 与 `init.lua`。

## 6. 开发纪律入口

完成的硬标准在根 `CLAUDE.md` 的 Definition of Done（回归 / changelog / milestone）。
进入任意子系统目录先读其 `CLAUDE.md`（无则回落最近祖先）。

平台边界由 `ue_platform_boundary` filter 使用 Lua Tree-sitter AST 执行：禁止 generic production Lua
直接探测 OS、用兼容 boolean 决定行为、按 concrete target literal 分支、构造宿主 executable/path、
持有 target policy literal 或 import concrete/cross-target owner。registry 数据、命令声明与 UI 文本只能
使用绑定规则、精确文件和理由的 AST-context allowlist；不得目录级放行。`stability` filter 同时对
`lua/ue.lua` 使用只减不增的数值 ratchet，并维持新 workflow Lua 文件 800 行上限。
