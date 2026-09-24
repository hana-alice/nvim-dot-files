# lua/ue/dap/ — DAP 调试（lldb-dap + Android platform 模式）

> 继承 `../AGENTS.md`（ue 中枢）→ `../../AGENTS.md`（lua 总规则）。只写增量。
> ⚠️ 本目录踩坑密度最高，改动前**务必**读 `../../../docs/CONSTRAINTS.md §二 DAP` 全段。

## 归属分层契约（先读这一节；权威 = 治理 spec，CONSTRAINTS §三 C10 为摘要）

**为何存在**：34 条 DAP 坑里**只有 8 条是我们自己的 bug**（9 条目标 OS 策略、10 条调试引擎、
6 条编辑器管道）。不先分层就修，结果就是每月现场取证。

| 层 | 内容 | owner 模块 | 典型坑 |
|---|---|---|---|
| **L0** 宙主工具链 | adapter 可解析 / 版本 / python 包 | `../../utils/platform/*` | K14 K57 |
| **L1** 传输 | adb 可达、serial 捕获、forward、两跳 staging、server 启动 | `_android_transport.lua`、`../../utils/android_device.lua` | K36 K38 K56 |
| **L2** 目标 OS 策略 | 执行权限、ptrace、SELinux、sandbox、签名 | `_android_policy.lua` / `ios.lua`（per-target） | **K56 K58** K12 K38 K3 K55 |
| **L3** 调试引擎 | platform connect / attach / 命令序列 | `_android_engine.lua`、`_common.lua` + lldb 本身 | K31 K32 K37 K2 K57 |
| **L4** 符号语义 | slide、bp resolved、dSYM / versionCode | `_android_engine.lua`、`ios.lua` | K35 K37 K55 |

**Android owner 已按层拆分**（2701 → ~1870 行）：`android.lua` 只保留编排与 session 生命周期；
`_android_transport.lua`（L1）/ `_android_policy.lua`（L2）/ `_android_engine.lua`（L3）各自成文件，
沿用本目录既有的 `_ios_*.lua` 平铺约定。三者**不反向 require owner**，依赖用 `bind()` 注入
（否则循环依赖）。改命令序列前读 `_android_engine.lua` 顶部的**时序契约**（K3 → K11/K37 → K60）。
⚠️ Lua 同名函数定义两次会**静默覆盖**——拆分时真踩过（`probe_context` 委派曾永不生效），
`dap_failure_layer` 有重复定义守卫。

- **失败必须先报层再给处置**：用户可见失败 MUST 携带 `{layer, owner, evidence, remedy}`，
  先层与 owner、后处置；**不得发出无层失败**；层不可判定就**显式标 undetermined + 给判定手段**，
  **不得猜层**。evidence MUST 是命令 + 输出，不是结论文本。
- **设备能力靠探测，不靠假设**：判定「某身份能否做某事」必须以**该身份**探测
  （例：app uid 用 `run-as`）；更高权限身份的同名探测结果**零信息量**（K58）。
  不得把单台设备的结论当成其他设备的前提。
- **attach 先过 L2 门禁再连接引擎**：L2 是唯一「红灯却表现为 L3 症状」的层——
  `lost connection` / `The parameter is incorrect` / handshake 失败这三种症状**不指向任何根因**。
  宁可漏拦不可误拦：探针自身失败默认 undetermined，只有**明确拒绕证据**才判红。

## 用途

UE 专用 DAP：`_common`（adapter 接线 + env 清洗）、`_persist_bp`（断点持久化）、`_progress`、
`platforms`（dispatch 注册表）、`android/win64/mac/linux/ios`（各平台 attach/launch）。

## 专属约定 / 宪法级坑（权威见 CONSTRAINTS §二、§一）

- **host adapter = LLVM 22.1.6+ `lldb-dap.exe`，forward-only**；codelldb 已完全移除。
  attach 形态 = `request="attach"` + `stopOnEntry=true` + `initCommands`/`attachCommands`/
  `postRunCommands`（`request="custom"` / codelldb 的 `*CreateCommands` 是历史，见 P8/K1）。→ C1
- **Android attach 唯一正解**：platform 模式 + `connect://[<serial>]:<port>` serial URL；
  **不用** `gdbserver --attach`（从不 listen）；**不用** localhost URL（被 getopt 吞空）。→ P16/P17/K30–K32
- **device 端 platform server 必须以 app uid 运行**：`run-as <pkg>` +
  `/data/data/<pkg>/lldb-server`（`/data/local/tmp` 仅作 `adb push` 中转，两跳 staging 用 `cat`
  重定向而非 `cp`），listen 参数写 `--listen "*:<port>"`（不加引号会被 device shell glob）。
  shell uid 在 `ro.debuggable=0` 的 user build 上无权 ptrace app，LLDB 只把该拒绝暴露成
  `attach failed: lost connection`；**遇到 `lost connection` 先查 uid，不得把 device server
  版本当首要变量**（LLDB 9/14/18 在 shell uid 下同样失败）。→ K56
- **设备 serial 单一来源**：程序化 `context/opts` 显式值优先，否则读
  `utils.android_device` 的 `vim.g.ue_android_device_serial`；普通 attach 缺值就 picker，
  不猜 last-session。活跃 session 的 poll/cleanup 始终使用捕获的 `session.serial`，且
  K30 URL 与设备端全部 `adb -s` 必须一致。
- **ASLR `--slide` 必须在 attach 命令序列内、先于 setBreakpoints**（基于事件太晚）。→ K11
- **ASLR `--slide` 是 load-bearing，别删**：真机 `UE_DAP_NO_SLIDE=1` 复验显示去掉它 attach 直接
  超时 / adapter `3221226505`。删除前必须在目标设备复验「无 slide 仍 resolved+命中」。→ K37
- **不对 64 位 slide 用 `string.format("%x")`**（LuaJIT 截 32 位，用字符串拼接）。→ P7/K4
- **Android 不直接 `dap.terminate`**（会 SIGKILL 游戏）→ detach。→ K5
- **F-key 四模式绑定**（dap-repl 是 prompt buffer）。→ K6
- **会话中 F9 即时下断点 = 正解，经 lldb-dap evaluate backtick `breakpoint set -f/-l` 通道**
  （`ue_android_live_plant_via_evaluate` in `../dap.lua`），不再 `:UEDAPReattach`、不 detach+reattach、
  不假 `verified`（回读 `breakpoint list resolved=N`，0/失败则诚实 warn）。preseed 降级为初始快照。→ K36
- **launch = wait-for-debugger（AS debug 按钮语义）**：`am set-debug-app -w` 冻住 JDWP 闸门 →
  K30 attach（此时 libUE4.so 未加载，attach-time slide 拿不到属**预期**）→ 首次 continue 时
  jdb 释放闸门 + late-rebase poller 经 evaluate 通道补发显式 slide（K37 语义「晚到」而非「缺席」）。
  任何退出路径必须 `am clear-debug-app`（粘性标志会冻住后续手动启动）。失败经 `wait_notice`
  每会话去重记录（notify + ue-dap-bp-diag.log）。
- **nvim-dap 没有 before-request hook**：`listeners.before.setBreakpoints` 在响应管线触发
  （签名 `session, err, response, request, seq`），**不能**改 outgoing `args.source`；恢复请求行须读
  `request` payload。别再起 `*_source_rewrite` 这种暗示 wire-mutation 的命名。
- **合成帧绕路收敛到单一 chokepoint**（`before.stackTrace` 把合成帧置 `line=-1`）；`_frame_set` patch
  与 bp-response remap 是薄 defence-in-depth。改前看 `dap.lua` 的 `ANCHOR(ue-synthetic-frame-guard)`。
- `platforms` 注册表是唯一 dispatch seam；新平台在此注册，不散落分支。

## 改动 → 必跑回归

改 `dap/**` → `dap` `platform` `dap_failure_layer`；改 `_common` 等被多平台共用面 → 提交前全量。
注意 `platforms._reset_for_test` 与 `ue.setup()` 幂等的交互（见 `tests/cases/dap_spec.lua`）。

## 先读

`../../../docs/CONSTRAINTS.md §二`、`../../../docs/TOOLING.md`、
ADR `../../../docs/plans/2026-06-15-android-dap-live-breakpoints.md`（live 断点决策 + 不变量）、
归档 change `openspec/changes/archive/2026-06-03-android-dap-*` / `2026-06-15-android-dap-live-breakpoints`、
真机证据 `../../../tools/evidence/android-f9/`。

**治理 spec**（可观察行为的权威；与本文冲突时以 spec 为准）：
`../../../openspec/specs/dap-failure-layering/spec.md`（**归属分层契约正文**）、
`../../../openspec/specs/dap-platform-dispatch/spec.md`、
`../../../openspec/specs/android-dap-attach/spec.md`、
`../../../openspec/specs/android-dap-live-breakpoints/spec.md`。
