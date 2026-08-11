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
| DAP 调试 | `lua/ue/dap/` | codelldb 适配 + 各平台 attach/launch | `platforms` 注册表是唯一 dispatch seam |
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
  compile_commands.json → cindex 建 csearch 索引 → clangd reload。全程 async + 进度 UI。
- **状态/缓存**：`:UESetProject` 把选择捕获在当前 Neovim 进程，同时更新未来进程读取的
  `selection.json` 默认值；project state/CDB/index/breakpoints/definition cache 写入 canonical-path
  project bucket。平台选择同样在进程内固定，另一个实例的修改不会重定向 live context。
- **goto-definition**：C++ source/header 都先在 proven TU 中取得 libclang exact-cursor
  canonical USR，再在同 generation controlled module AST 中查唯一 body；clangd 仅在 module
  contexts 暂不可用时作 identity-verified secondary provider。非 C++ 兼容路径保留
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
- **编译器语义**：`:UECompileForNvim` → clangd 22.1.x 预检 → 当前 target driver 生成原生 UBT
  build plan → 成功后复用 `:UEPrepare` 的 RSP/CDB/index 流程。Tree-sitter 语法解析与此分离，
  不会被 clangd/CDB 缺失伪装成失败。
- **核心健康审计**：`:NvimCoreHealth` 异步启动 `scripts/nvim_core_health.lua` → 隔离临时目录验证真实
  init、编辑事务、mandatory Tree-sitter AST、rg/csearch、clangd/CDB 与 target driver 纯计划 → 按
  `PASS/FAIL/BLOCKED/SKIP` 输出脱敏报告并清理。`--live` 只读取显式提供的既有 tuple/artifact，
  不触发安装、更新、UE build/package/device 或 DAP。
- **iOS 应用**：`:UEBuildIOS` 只经 IOS target driver 调 macOS `Build.sh`；`:UEPackageIOS` 经同一
  driver 规划 UAT BuildCookRun（Build/Cook/Stage/Package/Archive，不含 Deploy/Run）；
  `:UESetIOSDevice` / `:UEInstallIOS` / `:UELaunch` 使用结构化 CoreDevice JSON、当前 package task 的
  `Binaries/IOS/Payload/<Target>.app` provenance 与真实 bundle id。iOS run 不隐式进入 DAP。
- **DAP**：`UEDAP*` 命令 → `ue.dap.platforms` 按当前平台 dispatch → 具体平台 `attach/launch`
  → codelldb（Win64/Android）。Android 走 platform 模式 + serial connect URL；K30 URL 与本次
  session 捕获的 ADB serial 必须一致，切换当前进程的选择值不改变活跃 session 的 poll/cleanup。

### 2.1 状态归属清单

| 作用域 | 当前状态 | 多实例语义 |
|---|---|---|
| 当前 Neovim 进程 | project/target live selection、Android serial (`vim.g`)、活跃 DAP/build/task、statusline、window title、notification history | 不读取其他实例的 live 值；长任务在启动时捕获设备/项目 |
| canonical project | state fields、target 默认 pair、CDB/csearch/GTAGS/clangd/PCH/index、dirty overlay、breakpoints、definition cache | 路径 digest 防同名项目碰撞；platform-sensitive 产物再分桶；writer 用 atomic/merge/lease |
| cwd + git branch（插件层） | `persistence.nvim` session、Snacks scratch | 项目共享；session 是最后退出快照，scratch 是同一持久文件，不是 UE live context |
| user global | theme preference、recent projects、probe feedback、Lazy plugin store | theme 为 atomic last-writer-wins；recent/probe 在 lease 内 merge；plugin store 由 Lazy 管理 |
| Neovim 内建 | shada、persistent undo、swap | 保持 Neovim 原生语义，不用 UE project selector 重定向 |
| 纯诊断 | custom debug/grep/DAP trace、`nvim-dap` main/stdout/stderr logs | 全部按 PID 分文件；任一实例不会 truncate/rotate 另一实例 |

## 3. 平台分层（platform layers）

- **Host layer** `lua/utils/platform/`：`windows/macos/linux/stub` 四驱动只共享基础 shell/path 与
  UE 入口契约；Xcode tools 是 macOS-only capability，PowerShell 是 Windows-only capability。
  **这是唯一允许 OS 分支的地方**，不要求各 host 伪装成同一工具集。
- **Target layer** `lua/ue/targets/`：`android/ios/mac/win64/linux` 分别拥有目标平台参数、产物、
  设备与失败语义。共享 `_common.lua` 只能做 policy-free 的 argv/path/schema 操作；任一 target
  driver 不得调用另一个 target driver。
- `lua/ue.lua` 只解析上下文、查 registry、执行结构化 plan；不得承载 IOS/Android/Mac 命令参数。
- DAP 平台层 `lua/ue/dap/<platform>.lua`（win64/mac/linux/ios/android）经 `platforms` 注册表接入。

## 4. 构建流水线（build pipeline）

- 外部工具链版本钉死见 `docs/CONSTRAINTS.md §三 C1`（clangd/LLVM 22.1.x、codelldb 1.12.2、
  NDK lldb-server、Neovim 0.10+）。
- CDB 生成器（`tools/*.py` + `lua/ue/cdb/*`）：super-unity / prune / inject，写前比对跳过。
- CDB mutation 由 `lua/ue/cdb/pipeline.lua` 进程内 slot + filesystem lease 双层串行化；
  UEPrepare 持有 project-scoped prepare lease 到 pipeline/partition 完成，controlled index phase
  另持 project+platform build lease，禁止不同 Neovim 并发撕裂 JSON/csearch/index artifact。
- csearch 索引：`tools/cindex-uefilter`（Go fork）`-files-from` 干净建索引。
- Android SO-only（Windows host compatibility path）：`android_windows.lua` 通过 Windows-only
  `powershell_entry` 调用 `scripts/ue_android_so_build.ps1`，两阶段执行 UBT action graph；部署脚本先以
  只读 probe 选择 root adbd / verified `su 0` 或 debuggable `run-as` + startup-agent transport。
  本次 macOS 能力只面向 IOS，不实现或暗示 macOS→Android。
- macOS/iOS：host driver 提供原生 `Build.sh` / `RunUAT.sh` / Xcode executable；IOS target driver
  独占 BuildCookRun、SDK/签名预检、packaged app provenance、devicectl install/launch。
- 端到端搭建流程见 `docs/skills/ue-ide-bootstrap.md`。

## 5. 关键归属边界（ownership boundaries）

- **OS 分支**只在 `lua/utils/platform/`。
- **Target-specific 策略**只在对应的 `lua/ue/targets/<target>.lua`；共享宿主不等于共享 target
  （尤其 IOS 与 Mac），禁止跨 driver 调用或 fallback。
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
