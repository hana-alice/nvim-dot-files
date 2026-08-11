# 项目约束总览 · CONSTRAINTS

> 仓库: hana-alice/nvim-dot-files
> 受众: 在本仓库写代码的人类贡献者与 AI 编码 agent
> 公开镜像安全: 本仓库镜像到公开 GitHub remote。本文档保持事实性、不含 secret，
>   规范正文以英文术语为主，中文仅用于小节标签与说明。

这是一份**索引型**清单，回答三个问题：在动这个仓库之前，**什么是禁止的**、
**已经踩过哪些坑**、**有哪些必须遵守的约束**。

每条都只给摘要 + 出处指针（`→ 文件 §小节`）。**权威细节永远在出处**，本文档不复制
原文，只做导航。出处与摘要冲突时，**以出处为准**。

目录:
- [一、禁止（Prohibitions）](#一禁止prohibitions)
- [二、踩过的坑（Pitfalls）](#二踩过的坑pitfalls)
- [三、约束（Constraints）](#三约束constraints)
- [五、持久化知识库与本地规则（AI 可发现性）](#五持久化知识库与本地规则ai-可发现性)
- [六、维护契约](#六维护契约)

---

## 一、禁止（Prohibitions）

刻意拒绝的工具与模式。每条都试过 / 论证过，别再走。

| # | 禁止项 | 理由 | 出处 |
|---|--------|------|------|
| P1 | **不引入 telescope** | 全仓已押注 snacks.picker；两套 picker 抽象在同一会话里互相打架。 | `README.md`; `docs/architecture-vs-lazyvim.md` §"What we deliberately *don't* do" |
| P2 | **不做 mason auto-install** | 工具链版本钉死（见约束 C1）；mason 的版本漂移制造大量 "works on my machine" bug。用 winget/scoop。 | `docs/architecture-vs-lazyvim.md`; `docs/TOOLING.md` |
| P3 | **不做全局 `vim.lsp.handlers[...] = ...` 覆盖** | 任何触碰 LSP 行为的改动必须走 `lua/utils/lsp_fallback.lua` 或 `lua/workarounds/clangd/*.lua`，否则无法定位、无法回退。 | `docs/architecture-vs-lazyvim.md` §"What we deliberately *don't* do" |
| P4 | **不写 inline workaround** | 任何"因为别人的 bug 才存在"的补丁必须落到 `lua/workarounds/<scope>/<name>.lua` 并带 frontmatter；散落在 config 里的 monkey-patch 半年后无人能解释。 | `lua/workarounds/README.md`; 约束 C2 |
| P5 | **不做周期性 ticker 通知** | 至多 start + 一次中段更新，成功后自然消退；禁止轮询式 toast 刷 `:messages`。 | `README.md` §Conventions |
| P6 | **不阻塞主线程** | 多秒等待可接受，但必须 async（`nio` / 子进程）；UI 卡顿 = bug。 | `README.md` §Conventions; `docs/architecture-symbol-resolution.md` §5 |
| P7 | **不用 `string.format("%x", addr)` 处理 64 位值** | LuaJIT 下会截断到 32 位；模块 slide 的 hex 字符串必须用拼接构造。 | `docs/TOOLING.md` §Pitfalls #4 |
| P8 | **codelldb 不用 `request="custom"`** | codelldb 1.12.2 会回 `Malformed message`；改用 `request="launch"` + `targetCreateCommands` + `processCreateCommands`。 | `docs/TOOLING.md` §Pitfalls #1 |
| P9 | **不用 which-key 自动 cheatsheet** | 会泄漏我们从未绑定的 plugin 键位；自渲染 `:UECheatsheet`。 | `docs/architecture-vs-lazyvim.md` §"What we deliberately *don't* do" |
| P10 | **不在配置内集成 copilot/codeium** | 推理交给外部 CLI（Claude Code / Codex），编辑器保持是编辑器。 | `docs/architecture-vs-lazyvim.md` §"What we deliberately *don't* do" |
| P11 | **C++ goto-def 不让 Tree-sitter 决定或否决目标** | TS 没有 build TU 的类型、宏与 name lookup；C++ `gd` 必须由 compiler identity 决定。TS 可服务非 C++ 兼容路径，但不得给 C++ 语义答案或以语法规则制造失败。 | `docs/architecture-symbol-resolution.md` §1、§2 |
| P12 | **C++ `gd` 禁止自动 csearch / GTAGS fallback** | 文本/ctags 搜索分不清重载、同名、namespace；Clang 语义失败必须诚实失败。显式搜索、references 和非 C++ 路径仍可使用它们。 | `docs/architecture-symbol-resolution.md` §1、§6 |
| P13 | **不用 zoekt 替代 csearch** | Windows 不可用，已论证为死胡同。 | `docs/architecture-symbol-resolution.md` §6 (`zoekt-on-windows-dead-end`) |
| P14 | **不用 PreserveBufferView / BufEnter winrestview 类 cursor 守护** | workaround 反噬模式；Vim 原生 cursor 行为已足够（见坑 K10）。 | `docs/architecture-symbol-resolution.md` §6; commit `252e9e0` |
| P15 | **不在 `init.lua` 重复 require LazyVim 自动加载的 config 模块** | `config.options`/`autocmds`/`keymaps` 由 LazyVim 自动加载，重复 require 会双执行。 | `init.lua` NOTE (line ~44); 约束 C3 |
| P16 | **Android DAP 不用 `lldb-server gdbserver --attach`** | 该形态在真机从不绑定监听端口，attach 必失败；用 platform 模式（见坑 K30/K31）。 | 坑 K30/K31 |
| P17 | **Android `platform connect` URL 不用 `localhost`/`127.0.0.1` 形式** | 经 lldb-dap getopt 会被吞成空 URL；必须用 `connect://[<serial>]:<port>` serial 形式（见坑 K30/K32）。 | 坑 K30/K32 |

---

## 二、踩过的坑（Pitfalls）

已付出过真实调试成本的陷阱。格式: **症状 → 解决约束 → 出处**。

### DAP / codelldb（codelldb 路线，hard-won #1–#10）

- **K1 — custom-request 被拒**
  症状: codelldb 1.12.2 收到 `request="custom"` 回 `Malformed message`。
  解决: 用 `request="launch"` + `targetCreateCommands` + `processCreateCommands` 数组。
  → `docs/TOOLING.md` §Pitfalls #1; `lua/ue/dap/android.lua` `bootstrap_session`

- **K2 — gdb-remote 不自动 rebase 模块**
  症状: attach 后 `.so` 符号全部解析到错地址。
  解决: 对每个要解析的 `.so` 显式 `target modules load --file <so> --slide 0x<base>`，
  `<base>` 取自设备上 `cat /proc/<pid>/maps`。
  → `docs/TOOLING.md` §Pitfalls #2

- **K3 — 信号处置必须设置**
  症状: UE `Signal Catcher` 线程和 Chrome IO 线程不停触发 SIGSEGV/SIGBUS，每次 kick 冻结整个 app。
  解决: 强制 `process handle SIGSEGV/SIGBUS -p true -s false`。
  → `docs/TOOLING.md` §Pitfalls #3

- **K4 — LuaJIT hex 截断**
  症状: `string.format("%x", 0x7594c2a000)` 被截到 32 位，slide 算错。
  解决: 用字符串拼接构造 module-slide hex，绝不用 `string.format`（见禁止 P7）。
  → `docs/TOOLING.md` §Pitfalls #4

- **K5 — Android 不能直接 `dap.terminate`**
  症状: 默认 terminate 发 `disconnect{terminateDebuggee=true}`，会 SIGKILL 设备上的游戏。
  解决: `setup_dap` 全局 monkey-patch `dap.terminate`，UE Android 会话改走
  `disconnect{terminateDebuggee=false}`（■ 变成 detach 而非杀进程）。
  → `docs/TOOLING.md` §Pitfalls #5、§"Adapter wiring (current)"; `lua/ue/dap/_common.lua`

- **K6 — dap-repl 是 prompt buffer**
  症状: 纯 normal-mode 绑定 F-key，在 insert 模式下打出字面 `<F5>` 字符。
  解决: F-key 必须在 `n`/`i`/`t`/`v` 四种模式都绑定（`dap_fkeys` 表）。
  → `docs/TOOLING.md` §Pitfalls #6; `lua/config/keymaps.lua`

- **K7 — Neovide F11 全屏冲突**
  症状: Neovide 0.16+ 默认把 F11 绑到全屏，StepIn 被吞。
  解决: 设 `vim.g.neovide_fullscreen=false` 或把 StepIn 改绑别处。
  → `docs/TOOLING.md` §Pitfalls #7

- **K8 — disconnect 死循环**
  症状: 一个自身又发 `disconnect` 的 listener 无限重入 cleanup。
  解决: listener 只改 cleanup 状态，永远不调 `disconnect`/`terminate`。
  → `docs/TOOLING.md` §Pitfalls #8

- **K9 — Windows pipe 路径要正斜杠**
  症状: `nvim --server` 用反斜杠 pipe 路径静默失败（exit_code=2，无输出）。
  解决: 用 `//./pipe/nvim.<pid>.0` 正斜杠形式。
  → `docs/TOOLING.md` §Pitfalls #9

- **K10 — breakpoint 按 UE 项目持久化**
  症状: 断点在 nvim 重启后丢失。
  解决: F9 走 `ue.dap._persist_bp`，存到
  `<engine_root>/.cache/nvim-ue/breakpoints/<project>.json`，250ms 防抖、
  `BufReadPost` 懒恢复；该模块从 `ue.lua` 提前 `setup()`，保证 nvim-dap 懒加载前也生效。
  → `docs/TOOLING.md` §Pitfalls #10; `lua/ue/dap/_persist_bp.lua`;
    行为测 `tests/cases/dap_spec.lua`「F9 持久化往返（K10）」（JSON 往返 / 路径归一 /
    project_name sanitize / save 合并 pending 不擦除未开文件断点）

### Android ASLR（来自 MEMORY，需对当前代码复核）

- **K11 — ASLR slide 必须在 `processCreateCommands` 里下发**
  症状: Android 断点 "unresolved" 或永不命中；libUE4.so 的 ASLR slide 检测错误，
  所有断点解析到错地址。
  解决: ASLR 修正作为 inline LLDB（Python）命令，在 `process attach` 之后、
  `configurationDone` 返回**之前**运行——因为 nvim-dap 在 `configurationDone`
  紧后就发 `setBreakpoints`。基于事件（`event_stopped`/`event_initialized`）的
  做法**太晚**，断点早已按错地址解析。
  → MEMORY `project_android_dap_aslr_fix.md` / `feedback_android_dap_aslr_debugging.md`
  （注: 笔记为时点观察，断言前请对照当前 `lua/ue/dap/android.lua` 复核）

- **K12 — `/proc/maps` 权限模型**
  症状: `adb shell cat /proc/PID/maps` 在 Android 10+ 静默返回空（hidepid）。
  解决: 优先用 LLDB `platform shell cat /proc/<pid>/maps`（lldb-server 以 app 用户经
  `run-as` 运行）；解析前务必确认有真实输出。
  → MEMORY `feedback_android_dap_aslr_debugging.md`

- **K13 — 环境残留导致 attach 失败**
  症状: app 卡在 state T，需要重启。
  → MEMORY `feedback_android_dap_env_residue.md`

### Android DAP attach 路线（platform 模式，真机 a3ad86f3 实证 2026-06-03）

- **K30 — Android attach 唯一正解是 platform 模式 + serial-based connect URL（宪法级）**
  背景: 5/21（commit `e51cbe6`）用 **lldb-dap 22.1.6 + lldb-server platform 模式**真机
  跑通过；6/02 把路线改成 `gdbserver --attach` 后再也连不上，连环误判多轮。
  **唯一验证可用的 attach 配方**（2026-06-03 真机 protocol log 背书，到 `Connected: yes`
  + `process attach` + `threads ok`）:
  - device 端: `cd /data/local/tmp && ./lldb-server platform --server --listen \*:<port>`
    （**public 路径**非 app sandbox；`--listen *:N` 通配，NDK27 LLDB18 server 即可）。
  - host attachCommands 顺序: `platform select remote-android` →
    **`platform connect connect://[<serial>]:<port>`** → `process attach --pid <pid>` →
    `process handle SIG*`。
  - **关键**: connect URL 必须是 `connect://[<device-serial>]:<port>`（serial 放方括号
    里）。lldb 把非-localhost 的 hostname 当 device serial，自己经 adb forward +
    qLaunchGDBServer 拉子 gdbserver（源码 `PlatformAndroidRemoteGDBServer::ConnectRemote`
    `m_device_id = parsed_url->hostname`）。这是 remote-android 官方 serial-based URL，
    **非 workaround**。
  → `tools/dap_platform_e51cbe6.py`; 归档 change `2026-06-03-android-dap-platform-mode`;
    `git show e51cbe6:lua/ue/dap/android.lua`;
    行为测 `tests/cases/dap_spec.lua`「attach_commands（K30/K34/K37 顺序与 slide 开关）」
    （serial 方括号 URL / target create 先序 / 信号处置后置）

- **K31 — `lldb-server gdbserver --attach <pid>` 在该设备从不绑定监听端口**
  症状: ptrace 附上（`TracerPid` 非 0）但端口永不进 LISTEN（`/proc/net/tcp` 0 条），
  host gdb 握手零响应 / `Connection shut down ... initial handshake`。LLDB9/18/19/21
  server 全复现。
  解决: **不要用 `gdbserver --attach` 形态**。用 K30 的 platform 模式；若确需 gdbserver，
  只能用纯 `gdbserver <host>:<port>`（无 `--attach`）listen + 客户端 `vAttach`。
  → 归档 change `2026-06-03-android-dap-attach-handshake-rootcause`

- **K32 — `platform connect connect://localhost:<port>` 报空 `Invalid URL`**
  症状: 用 `localhost`/`127.0.0.1` 形式的 connect URL 经 lldb-dap 命令字符串执行，
  报 `error: Invalid URL:`（URL 为空）。根因: 走了需 caller-forward 的歧义路径，且
  `platform connect` 命令经 `getopt_long_only`（`OptionParser.cpp:46` + `optind=0`
  argument permute）把裸 URL 切掉。
  解决: **永远用 K30 的 `connect://[<serial>]:<port>` serial 形式**，不用 localhost 形式。
  → 归档 change `2026-06-03-android-dap-platform-mode` design §E4

- **K33 — F9 成功判据必须包含 LLDB resolved + stop event**
  症状: UI 里出现断点标记、甚至某些路径返回 `verified=true`，但目标进程运行到对应源码行
  不停，或者 LLDB `breakpoint list` 仍是 pending / no locations。
  解决: Android F9 断点成功必须同时满足：DAP 响应与真实状态一致、LLDB `breakpoint list`
  对应断点 `resolved>0`、adapter 存活（无 `3221226505`）、目标触发 breakpoint stop、
  stop frame 映射到正确本地源码行。UI 标记不算成功，合成 `verified=true` 禁止作为证明。
  → `openspec/specs/android-dap-attach/spec.md`; change `fix-android-f9-breakpoint-hit`

- **K34 — source-file `breakpoint set -f <f> -l <N>` 可能崩溃 lldb-dap 22.1.6（需按路线复验）**
  症状: 在直连 gdb-remote attach 路径下，attachCommands/post-attach 的 source-file
  `breakpoint set` 让 lldb-dap 在 DWARF 索引后退出 `3221226505`
  （STATUS_STACK_BUFFER_OVERRUN）。
  解决: 接通断点需在 attach 稳定后先证明 source-file 路径在当前 K30 platform route 下
  不崩且 resolved；若不稳定，只能在 `image lookup --line` → `breakpoint set --address`
  与 stop frame 语义等价被证明后采用 address 断点。不能把“碰巧不崩”或“UI 变绿”作为正解。
  **现状（2026-06-15 真机 `2e2df4cb` 复验）: 在 K30 platform route + 3.5 匹配符号下
  source-file `breakpoint set -f/-l` 不复现该崩溃**——闸门 evaluate 通道
  `adapter_alive=true`、`resolved=1`、命中，端到端 live F9 亦命中。该崩溃为旧
  gdb-remote 直连路线产物。session-time live 断点经 lldb-dap evaluate backtick 通道
  下发是当前正解（非 work around）。证据 `tools/evidence/android-f9/livebp-*.result.json`。
  → 归档 change `2026-06-03-android-dap-attach-bp-fix` / `-handshake-rootcause`;
    change `android-dap-live-breakpoints`

- **K35 — Android file:line 断点需要先 `target create` symbol-rich host libUE4.so**
  症状: platform attach 只看到设备 stripped `libUE4.so` 时，file:line 断点长期 pending /
  no locations，F9 不会命中。
  解决: attachCommands 第一阶段先 `target create "<symbol-rich libUE4.so>"`，再走
  `platform select` / serial-form `platform connect` / `process attach --pid`。后置
  `target symbols add` / `target modules add` 不能替代这个顺序。
  → `lua/ue/dap/android.lua`; `docs/changelog.md` 2026-05-21/2026-06-03 断点记录;
    行为测 `tests/cases/dap_spec.lua`「attach_commands」（target create 第一条 + 早于
    connect/attach）与「pick_symbol_lib（K35）」（versionCode 精确匹配优先于 mtime）

- **K36 — session-time live 断点经 lldb-dap evaluate 通道可行（本设备实证，非 work around）**
  症状/背景: 历史 `361b9e7` 记录"attach 后写断点指令被内核静默丢弃，session-time live
  断点物理不可行"，但那是旧 gdb-remote 直连路线/旧符号的观测。
  解决/现状: 2026-06-15 真机 `2e2df4cb` D1 闸门 + 端到端复验——在 K30 platform route +
  3.5 匹配符号下，attach 后 continue、再经 **lldb-dap evaluate backtick
  `breakpoint set -f/-l`**（或 DAP setBreakpoints）下发断点 **resolved=1 且命中**，
  adapter 存活（无 `3221226505`）。故会话中 F9 变更走 live evaluate 通道即时下发为正解，
  **不再要求 `:UEDAPReattach`**，attach-time preseed 降级为初始快照。`361b9e7` 结论不适用
  当前路线。证据 `tools/evidence/android-f9/livebp-gate.*.json` / `livebp-e2e.result.json`。
  → change `android-dap-live-breakpoints`; `lua/ue/dap.lua`
    `ue_android_live_plant_via_evaluate`

- **K37 — 本设备 attach 不下发 `target modules load --slide` 则 attach 失败（slide 为 load-bearing）**
  症状: 设 `UE_DAP_NO_SLIDE=1` 跳过显式 ASLR slide 时，attach 在 `android_attach_start`
  后即超时、adapter 早退 `3221226505`，从不到 `initialized` / 命中。
  解决: **保留** attachCommands 里的 `target modules load --file libUE4.so --slide 0x<base>`
  及其 plumbing（`module_rebase_command` / `read_so_base_hex` / `_module_rebase_cmd`）。
  旧注释"5/22 无 slide 也 resolved"在当前设备/版本不复现；删除前置条件（不下发 slide 仍
  resolved+命中）未满足。`UE_DAP_NO_SLIDE` 环境开关保留供后续在其他设备/版本复验。
  证据 `tools/evidence/android-f9/noslide-preseed.result.json`(timeout) vs
  `slide-recheck.result.json`(ok)。
  **wait-for-debugger launch 例外语义（2026-07-24）**: wait 模式下 attach 时 libUE4.so 尚未
  加载，attach-time slide 拿不到属**预期而非失败**；late-rebase poller 在模块出现后经
  evaluate 通道补发同一条 slide（「晚到」而非「缺席」，K37 仍成立）。
  → change `android-dap-live-breakpoints` design D5/OQ#3; `lua/ue/dap/android.lua`;
    行为测 `tests/cases/dap_spec.lua`「attach_commands」（默认含显式 slide；
    `UE_DAP_NO_SLIDE=1` 时跳过——锁住开关语义与 plumbing 存在）

- **K38 — `/data/local/tmp/lldb-server` root-owned 残留 → shell 用户 chmod EPERM**
  症状: `lldb-server bootstrap failed: chmod ... to 0755: Operation not permitted`
  （2026-07-24 真机 a3ad86f3 日志）。旧 `adb root` 会话推的文件 owner 是 root:root，
  非 root adb 的 shell 用户 chmod 必 EPERM。
  解决: unlink 看**父目录**权限（/data/local/tmp 为 shell-owned）——尺寸不符先 `rm -f` 再
  push；同尺寸且 `test -x` 通过直接 reuse（chmod 都不需要）；chmod EPERM 但已可执行 →
  WARN 继续，不中止 bootstrap。纯决策函数 `lldb_server_stage_plan`（reuse/chmod/repush）。
  → `lua/ue/dap/android.lua` `ensure_lldb_server_pushed`;
    行为测 `tests/cases/dap_spec.lua`「lldb_server_stage_plan」

- **K39 — 「启动完再 attach」永远抓不到最早期 crash → wait-for-debugger launch**
  症状: JNI_OnLoad / 模块静态 init / 引擎 PreInit 阶段的 crash，旧 launch（monkey 启完、
  pidof 轮询到再 attach）必然错过——attach 前进程已跑过出事点。
  解决: `:UEDAPLaunch android` 改为 Android Studio debug 按钮语义：`am set-debug-app -w`
  冻结在 JDWP "Waiting for debugger" 闸门（Application.onCreate 之前、libUE4.so 加载之前）→
  K30 platform attach → 布断点 → 用户首次 F5 时 jdb（`adb forward tcp:N jdwp:PID` +
  `SocketAttach`）释放闸门 + late-rebase poller 补发 slide（见 K37 例外语义）。
  粘性警告: `am set-debug-app -w` 是设备全局标志，**所有退出路径必须 `am clear-debug-app`**，
  否则后续手动启动该 app 永远冻在等调试器。
  → `lua/ue/dap/android.lua` `M.launch` / `arm_wait_mode_followup` / `_start_late_rebase_poller`;
    `docs/changelog.md` 2026-07-24; 行为测 `tests/cases/dap_spec.lua`「wait-for-debugger launch 命令形状」

- **K40 — uv timer 回调里同步 `vim.fn.system(adb …)` → 全天 stall train（违反 P6 的典型形态）**
  症状: stall_probe 记录 ~50 stalls/min、p50≈410ms/p90≈1s，从 attach 起持续整个调试日
  （2026-07-24 10:47–16:49 共 1.9 万条），与当前 buffer/按键无关。
  根因: Android liveness poller 每 1.5s 在 `vim.schedule_wrap` 内同步 `pidof()`
  （`vim.fn.system` → adb USB 往返 200–1000ms，调试会话期间 adb 被 lldb-dap 占用更慢），
  每次轮询都阻塞主循环；adapter 异常死亡而 session 未清时 poller 永不停。
  解决约束: **周期性探测一律 `vim.system`(async callback) / jobstart，禁止在 timer 回调里
  `vim.fn.system`**；timer fast-event 上下文只 spawn，状态处理 `vim.schedule` 回主循环；
  加 `in_flight` 防探测堆积；回调先复核 timer/session 仍有效（探测在飞期间可能已 stop）。
  诊断入口: `:StallReport` / log scope `[stall]`——按分钟聚类 + 看 buffer 无关性即可判定
  「后台定时器阻塞」而非「按键动作阻塞」。
  → `lua/ue/dap/android.lua` `_start_liveness_poller`; `lua/utils/stall_probe.lua`;
    `docs/changelog.md` 2026-07-24（卡顿修复条目）

- **K42 — gitsigns watch_gitdir × git fsmonitor = 自激振荡 spawn 循环 → 全程 UI 卡顿**
  症状: `<C-f>/<C-b>` 翻页、picker 输入持续卡顿；stall train 在 DAP 会话结束后仍在
  （排除 K40 后仍 ~40 stalls/min）。jit.profile 8s 采样实锤: gitsigns async spawn +
  `git/repo/watcher.lua` 占主循环 ~1600/4300 样本。
  根因: 本机 UE 仓开了 **git fsmonitor**（`core.fsmonitor=true`）。每次 git 子进程运行都
  会在 `.git/` 里落 fsmonitor cookie 文件 → gitsigns 的 gitdir watcher 观察到变化 →
  refresh → spawn git → 又落 cookie → watcher 再触发——自激振荡，永不收敛。Windows 上
  每次 spawn 主循环开销数十 ms，叠加 200ms 的 current_line_blame（每次悬停一个
  `git blame -L` spawn）雪上加霜。
  解决约束: 本机 gitsigns **必须 `watch_gitdir.enable=false`**（外部 git 操作靠
  BufWritePost/FocusGained 刷新，可接受）；`current_line_blame_opts.delay` ≥ 500ms。
  诊断入口: `jit.profile` 8s 采样（`profe_prof` 模式脚本）看 spawn 栈占比；或
  `:StallReport` 排除 DAP 后仍有 train 即怀疑 watcher 类自激。
  → `lua/plugins/gitsigns.lua`; `docs/changelog.md` 2026-07-24（gitsigns 卡顿条目）

- **K43 — Windows libuv 把 LAST_ACCESS/属性事件折叠为 `UV_CHANGE` → dirty overlay 洪水**
  症状: `dirty-set-flood/cap-hit` 探针反复出现，`dirty.json` 达 1000 上限，picker 每次搜索
  背着巨大 rg-on-dirty 集合；现场 1000 条中 965 个文件的 LAST_WRITE 仍停在 2026-06-22，
  而 csearch 索引生成于 2026-08-04，证明不是索引后的内容修改。
  根因: libuv Windows backend 的 `ReadDirectoryChangesW` 同时订阅 `LAST_ACCESS`、
  `ATTRIBUTES`、`SECURITY`、`LAST_WRITE`，却统一映射成 `UV_CHANGE`；原 watcher 对所有
  `change` 只做“文件存在”判断，元数据扫描也被当作内容变化。
  解决约束: rename/create/delete 始终保守记录；已有文件的纯 `change` 只有 LAST_WRITE
  晚于当前 `csearch.idx` 才进入 `persistent_dirty`。无可用索引或无 mtime 证据时保持记录，
  不得为降噪漏掉首次构建前/新建文件。
  → `lua/utils/ue_watch.lua`; `openspec/specs/ue-code-search/spec.md`

- **K44 — Android SO 热替换必须匹配已安装 APK 的 Java/JNI 基线**
  症状: 新 SO 能成功 strip、push、通过 hash/metadata/maps 校验，却在启动后因
  `NoSuchMethodError` 主动 SIGABRT；实机证据为 native 调用了旧 APK 中不存在的新 Java 方法。
  根因: SO-only 构建只更新 native action graph，不会更新 APK 内 Java/manifest/Gradle
  产物；把新 JNI 调用的 SO 注入旧 APK 在 ELF 层可加载，但运行时接口不兼容。
  解决约束: 部署前必须校验源 SO 同目录 `packageInfo.txt` 与设备安装包的 package/versionCode。
  root 原地替换在不一致时继续拒绝；app-private agent 路径不修改 APK，versionCode 差异只作为明确
  警告，不能伪装成 Java/JNI 兼容证明。两条路径都只支持 native-only 迭代；涉及新 Java 方法、
  manifest 或 Gradle 产物时，SO 注入本身无法让旧 APK 获得这些接口。任务已声明 SO-only 时，
  后续“重编/再试”仍只能解释为重编、部署 SO；基线不兼容是阻塞证据，不是擅自打包或安装 APK 的
  授权。只有用户明确要求“打包/装包”时才能进入 `<Space>ui` 或等价 APK 安装流程。
  → `scripts/ue_android_so_deploy.ps1`; `openspec/specs/android-so-quick-deploy/spec.md`

- **K45 — `Client` 是项目/Target 名，不是 Android 目录协议**
  症状: 非 `Client` 项目能正常编译，但 nested `.uproject`、packageInfo、symbol package 或 SO
  receipt 发现失败；测试若也只用 `Client` fixture，会把该耦合隐藏起来。
  根因: 旧路径把现场项目布局 `Source/Client`、`Client_Symbols_v*`、`Client-arm64` 当成 UE 固定约定。
  解决约束: 从显式 `.uproject` 或唯一 `Source/<Project>/*.uproject` 派生项目目录；SO 主产物从
  matching receipt 和动态 Target 派生；符号包扫描实际 `<Target>_Symbols_v*/<Target>-arm64` 目录。
  多项目/多主产物歧义必须拒绝，不能按目录或 receipt 顺序猜测。回归 fixture 必须使用非
  `Client` 的虚构项目名。
  → `lua/ue.lua`; `lua/ue/dap/android.lua`; `openspec/specs/android-so-quick-deploy/spec.md`;
  `openspec/specs/android-dap-attach/spec.md`

- **K46 — Android 安装、SO 替换与启动必须分离**
  症状: `uq` 替换后自动启动并用 PID/maps 验证，把文件部署与冷启动时序耦合；首次冷启动可能误回滚，且命令会
  在用户未要求时占用设备前台。
  解决约束: `ui` 只执行 APK 安装，`uq` 只负责 force-stop、root 原子替换或 app-private staging、
  metadata/hash 校验和必要回滚；二者成功或回滚后都不得自动启动应用。启动唯一由用户显式执行 `ul`。
  运行时 ClassLoader/maps 验证属于 `ul`，不得重新塞回 `uq`。
  → `scripts/ue_android_so_deploy.ps1`; `openspec/specs/android-so-quick-deploy/spec.md`

- **K47 — Android root transport 不能写死为 `su 0`**
  症状: `<leader>uq` 在没有 `su` 的设备直接报 `/system/bin/sh: su: inaccessible or not found`；同时 root adbd 设备本可直接执行特权命令，却也被无条件 `su 0` 阻断。
  根因: root 是设备能力，不是固定命令形状；设备全局 `ro.debuggable=0` 也不等于某个已安装 APK
  没有 `DEBUGGABLE` flag。实测目标设备为 `uid=2000(shell)`、`build_type=user`、无 `su`，但现有包
  可 `run-as` 且自身 debuggable。
  解决约束: 部署副作用前先用 `id -u` 选择 root adbd，失败后再验证 `su 0 id -u`；两者都失败时
  继续验证 package `DEBUGGABLE`、`run-as` app UID 与 `--attach-agent-bind`，满足则走 app-private agent，
  不修改 installed SO。只有 root 与 app-private 两类 transport 都失败时才拒绝。
  → `scripts/ue_android_so_deploy.ps1`; `openspec/specs/android-so-quick-deploy/spec.md`

- **K48 — 预先 `dlopen` 私有 `libUE4.so` 不能替代 ClassLoader 的绝对路径加载**
  症状: agent 报私有 SO 已 `dlopen`，随后 `System.loadLibrary("UE4")` 仍可能加载 `/data/app/.../libUE4.so`，
  形成两份映射；手工 `dlopen` 也没有完成 ART 的 classloader native-library bookkeeping 与 `JNI_OnLoad` 语义。
  根因: Android 14 `Runtime.loadLibrary0` 先调用 `ClassLoader.findLibrary` 得到绝对路径；bionic 对含 `/`
  的 `dlopen` 请求不走 SONAME 已加载复用。晚附加 agent 也错过了 zygote 阶段已发生的
  `Runtime.nativeLoad` NativeMethodBind，不能靠事件回放拿到原函数。
  解决约束: app-private agent 只能在 `ClassPrepare`（类已 prepared、尚未执行代码）阶段识别真正能把
  `UE4` 解析到 installed SO 的 app ClassLoader，调用 `addNativePath` 后把新增
  `nativeLibraryPathElements` 元素移到首位，并验证前/后绝对路径。真正加载仍由项目原有
  `System.loadLibrary` 完成；agent/host maps 必须证明私有路径存在且 installed 路径不存在，否则 fail closed。
  → `scripts/ue_android_so_agent.c`; `scripts/ue_android_so_launch.ps1`;
    `openspec/specs/android-so-quick-deploy/spec.md`

- **K49 — app-private SO 与 agent 不能作为两个独立“当前文件”发布**
  症状: 并发 `uq`/`ul` 或进程中途退出时，启动可能观察到新 SO + 旧 agent、残留 `.new`，或把半成品
  staging 当成“从未部署”而静默启动 installed SO；substring maps 判断还会把 `.previous` 误认成映射成功。
  根因: 多文件更新没有单一原子提交点；固定临时文件名与共享 status 也不具备跨进程隔离。
  解决约束: 同一 serial/package 的 `uq`/`ul` 必须用 OS mutex 串行化；每次部署写唯一 generation，
  校验 SO/agent hash 与 manifest 后只用原子 `current` pointer 发布。`ul` 必须复算 current generation
  文件 hash，并核对 installed versionCode 与 APK path/stat/lastUpdateTime 摘要；工具目录部分存在必须拒绝。
  maps 必须解析 pathname 精确比较（仅容许 ` (deleted)`），
  启动/验证失败必须 force-stop 并确认错误进程退出。
  → `scripts/ue_android_so_deploy.ps1`; `scripts/ue_android_so_launch.ps1`;
    `scripts/ue_android_so_agent.c`; `openspec/specs/android-so-quick-deploy/spec.md`

### 工具链 / LLVM

- **K41 — 依赖路径向上发现的 `.clangd` / monolithic External index → 覆盖漂移与资源失控**
  症状: UEPrepare 重生成 CDB 后 clangd `-j=24` 高 CPU/内存常驻（历史同类症状 17GB/32min）；
  `%LocalAppData%/clangd/index` shard 无界增长，或 `gd` 只有正确 USR 却停在 declaration。
  根因: `.clangd` 按源文件路径向上查找，跨根 TU 可漏掉 `Background: Skip`；另一方面，
  真实实验已证明 `clangd-indexer` YAML 中存在 `.cpp` Definition 不等于 `External.File`
  经 LSP 一定返回 body，不能把 binary index 当跨 TU definition authority。
  解决: clangd 固定 `--enable-config=false`，不再写 `.clangd`、不传 `--index-file`；current/hot/full
  发布带 generation/coverage manifest 的 controlled BackgroundIndex CDB，只接受
  compiler-authored UBT unity membership 或 exact per-file fallback，并通过官方
  `compilationDatabaseChanges` 注入打开文件 exact command。definition 的最终权威是
  canonical USR + subject module AST 唯一 body，clangd 仅作 identity-verified secondary provider。
  → `lua/ue.lua` `clangd_cmd`; `lua/ue/index/`; `lua/ue/clangd_commands.lua`;
    `tests/cases/{ue_api,index_generation,cpp_semantic_index,clangd_commands}_spec.lua`

- **K14 — LLVM 22.0–22.1.5 的 `lldb-dap.exe` 在 Windows 启动崩溃**
  症状: DAP client 一发 `initialize` 就 `STATUS_STACK_BUFFER_OVERRUN`(`0xC0000409`)。
  根因: `liblldb.dll` 的 `NativeFile` ctor 在 pipe FD 上调 `_get_osfhandle`，跨 CRT。
  解决/现状: Android DAP 当前使用 **LLVM 22.1.6+ `lldb-dap.exe`** forward-only 路线；
  22.0–22.1.5 仍禁止，历史 codelldb 记录只保留作 crash 分析参考。
  → `docs/TOOLING.md` §"Current Android DAP status"; `lua/utils/platform/windows.lua`
  `default_lldb_dap_paths()`
  （LLVM #178155 / fix #195855 未 backport 到 release/22.x）

- **K15 — 适配器迁移弧线（别照退役钉死项行事）**
  历史: lldb-dap 21.1.8 side-load → codelldb 1.12.2 → **LLVM 22.1.6+ lldb-dap
  forward-only（当前 Android DAP）**。`docs/TOOLING.md` 里的 21.1.8/codelldb 段落是
  **历史参考**，其 crash 分析仍有价值，但当前 Android 行为以顶部
  `Current Android DAP status` 和代码为准。
  → `docs/TOOLING.md` 状态横幅; `lua/utils/platform/windows.lua` `default_lldb_dap_paths()`;
  git log（`b9cce1d` merge `feat/lldb-dap-migration`、
  `7c70462`、release_1.0.3）

### snacks / clangd / lazy（活跃 workaround，共 8 个文件）

- **K16 — snacks picker 冷启动首开卡死**
  症状: Neovide 冷启后第一次开 picker 卡约 1s。
  → `lua/workarounds/snacks/picker_first_open_freeze.lua`

- **K17 — projects picker 卡死数十秒**
  症状: Neovide 里按 `p` 开 projects picker，扫描数百 oldfiles + 每条 spawn git，冻结数十秒。
  → `lua/workarounds/snacks/projects_picker_freeze.lua`

- **K18 — picker str byteindex 越界**
  症状: `<leader>ss`(Search Symbols) 偶发报错。
  → `lua/workarounds/snacks/picker_str_byteindex_oob.lua`

- **K19 — smart picker 指向已死 buffer**
  症状: 切 git 分支丢文件后，`<leader><leader>` 仍显示这些文件，选中打开空 buffer。
  → `lua/workarounds/snacks/smart_picker_dead_buffer.lua`

- **K20 — clangd 非 `file://` URI 报错刷屏**
  症状: 在 C++ 文件上开 diffview/Neogit/fugitive/gitsigns blame 后，右下角反复刷
  `clangd: -32602: ... clangd only supports file:// URIs`；Neovide 上每次 notify 强制重绘更糟。
  → `lua/workarounds/clangd/non_file_uri_detach.lua`（已在 `init.lua` eager apply）

- **K21 — Lazy float 在 VimResized 时 invalid buffer（已退役 2026-07-26）**
  症状: 刚关掉 Lazy float 后窗口 resize（Neovide 启动 / zen-mode / split），报
  `lazy/view/float.lua:180: Invalid buffer id: N`。
  现状: 上游 lazy.nvim（本机 stable）`float.lua` VimResized 回调已自带 win+buf
  双重 validity guard（校验失败 return true 自删 autocmd）——workaround 已删除
  （health-check 2026-07 F6）。若上游回归，按原 frontmatter 重建。

- **K22 — `q` 关闭已失效 buffer**
  症状: 在 snacks/noice picker 候选间导航、或 notify 气泡快速消失时报
  `vim/keymap.lua:77: Invalid buffer id`。
  → `lua/workarounds/lazyvim/close_with_q_invalid_buf.lua`（init.lua eager apply）

- **K23 — Neovide 关闭后 nvim.exe 残留**
  症状: 关掉 Neovide 窗口后底层 nvim.exe 永久存活为后台进程，跨会话累积 ghost 进程。
  → `lua/workarounds/neovide/exit_with_gui.lua`（init.lua eager apply）

- **K24 — blink.cmp 自动换行破坏 undo/preview**
  → `lua/workarounds/blink_cmp/auto_wrap_undo_preview.lua`

### goto-def / cursor

- **K25 — 跨 buffer 跳转 cursor 漂移**
  症状: 跳完后 snacks.scroll smooth-scroll 动画 / PreserveBufferView autocmd 异步把
  cursor 改走。
  解决: 砍掉 snacks.scroll + PreserveBufferView（见禁止 P14）；jumper 内
  `_on_reassert` 钩子在跳完 ~10ms 后 verify 并必要时 reassert。
  → `docs/architecture-symbol-resolution.md` §6; commit `252e9e0`

- **K42 — 裸 symbol / arity / standalone header / declaration-self 不能完成 C++ definition resolution**
  症状: 先解析无参 overload 后，按裸 symbol 缓存的 location 使另一个同名调用不请求
  clangd 就原地跳回 sibling；非自包含 UE header 的 standalone AST 同时出现
  `OverloadedDeclRef` / recovery，而真实 donor TU 能得到唯一 overload identity。
  解决: source/header 都在 proven TU 里由 libclang 求 exact-cursor canonical USR；用同一 USR
  在 controlled module 的真实 UBT TU AST 中找唯一 body，声明处也必须继续。derived-static
  virtual call 保留派生 override identity；base-static 动态类型未知时不猜派生类。只缓存绑定
  USR/CDB/overlay/toolchain 的唯一 resolved destination；negative/ambiguous 不缓存。禁止
  symbol / arity / ranking / text fallback 猜目标。
  → `docs/architecture-symbol-resolution.md`;
    `openspec/changes/make-cpp-gd-semantically-complete/`

### grep 缓存 / csearch 失效

- **K26 — csearch 负探测被永久缓存 → `<leader>/` 静默搜不全**
  症状: `<leader>/`（cached_grep）只返回残缺结果，picker 标题 `Grep All Code (Engine+Project)`
  **无 `[csearch]`/`[rg]` 后缀**（=回落到最底层 snacks 目录遍历，排除 ThirdParty、与索引无关）。
  根因: `utils/code_search` 的 `csearch_exe`/`cindex_uefilter_exe` 一旦探测失败就把
  `_probed=true`+`nil` 钉死整会话（冷启动 PATH 未就绪 / 索引重建期失败），此后
  `is_indexed()` 恒 false → grep 永走回落。
  解决: 负探测不缓存（仅成功时缓存路径）；UEPrepare 完成 / 切项目 / 切平台后
  `_reset_probe_cache()` 重探；UEPrepare finalize 清 `context_cache`。回落必须**可见**
  （一次性 WARN + 标题标 slow fallback），不给残缺静默结果。
  → `docs/architecture/grep-cache-invalidation.md`; `lua/utils/code_search/init.lua`;
    `lua/ue.lua` cached_grep / finalize_after_csearch; `lua/plugins/snacks.lua` ue_project_grep

- **K27 — 切平台/换引擎后 grep 缓存不失效**
  症状: `UESetPlatform` 走 fast-swap 只 flip cdb shard，csearch/workspace_all 原封不动；
  `UESetProject` 换引擎（engine_root 未持久化）时 engine 维度判不出"变了"。
  解决: csearch/workspace_all **按平台+配置分路径**（`cache_paths(root, platform_key)`，
  key 同源 `shards` 平台维度），切平台落不同目录、旧平台保留、不删重来；旧单一路径
  首次按当前平台 **自动 move 迁移**（`migrate_legacy_csearch_if_needed`）。
  `engine_root` 持久化进 state.json，`set_project` 比对 project+engine 任一变即失效全平台。
  → `docs/architecture/grep-cache-invalidation.md`; `lua/ue.lua` cache_paths /
    platform_key_from_state / invalidate_project_scoped_cache / set_platform

- **K28 — csearch/rg stream `on_done` 先于尾部 `on_line` → `<leader>/` 丢最后几条命中**
  症状: 命令行 csearch/rg 输出完整，但 snacks picker 末尾少 2–4 条结果；旧实现逐行
  `vim.schedule(on_line)`，exit callback 另行 `vim.schedule(on_done)`，调度顺序不可证明。
  解决: stdout read callback 同步解析进 backend 队列，由单一 scheduled flusher 先 drain
  全部 parsed hits，再在进程退出且 backlog 为空时调用 `on_done`；stop 后所有 flusher 都短路。
  → `docs/architecture/grep-cache-invalidation.md` D6; `lua/utils/code_search/init.lua`

- **K29 — watcher 批量 add 把每路径拼进 argv → `ENAMETOOLONG`**（后续被 K31g 取代写者本身）
  症状: `git checkout` / 构建批量产生几百个长 UE 路径后，`ue_watch` flush 抛
  `vim/_system.lua:256: ENAMETOOLONG: name too long`（`provider_csearch_add` 把每个
  dirty 路径作为一个 argv 元素拼进裸 `cindex` 命令，超 Windows ~32 KiB argv 上限）。
  解决（历史，2026-06-16）: provider 改委托 `build_index(.., {mode="add"})` 经
  `cindex-uefilter -files-from` 入索引。**注意：该修复把 watcher 变成 csearch.idx 的第二个
  写者，随即引出 K31g 的并发写损坏 → 2026-06-17 整体退役该写者。** argv 上限是 OS 契约、
  `-files-from` 是任意长度列表喂子进程的正解，这条结论仍成立，但现在只有 prepare 家族走该
  路径，watcher 不再写索引。
  → `docs/architecture/grep-cache-invalidation.md` D7（存档）/ D9（现状）; K31g

- **K30g — freshness 用 mtime 代理当 anchor → 后台 touch / 编译产物触发假 stale（已收敛到内容指纹 D10）**
  症状: `:UEPrepare` 完成后 `<space><space>` / `<leader>/` 仍弹
  `:UEPrepare is stale (worktree changed since last run)`，但无源码增删。两个噪声源：
  (1) `.git/index` 被 git fsmonitor / TortoiseGit 后台 refresh touch；
  (2) `dir_mtime` 被**编译产物**落进引擎树 touch（重编一次即 stale）。根因是结构性的——
  `prepare_freshness` 用 **mtime 侧信道代理**猜「文件集合是否变」，每个代理都有自己的噪声。
  中间态: D8（2026-06-16）把 git anchor 从 index 换成 commit-state（`HEAD`+`logs/HEAD`），
  只是换了个噪声更小的代理，随后被 dir_mtime 噪声再次击穿——换代理是无尽打地鼠。
  终解 **D10**（2026-06-17）: 停止代理，改对 `workspace_all.files` **内容取 sha256 指纹**
  （它就是被索引集合的确定性序列化，table.sort 后 bytes 稳定），与全量构建成功时记录的
  `state.csearch_input_hash` 比对。退役全部 mtime anchor（git index / commit-state / dir_mtime）。
  会话内集合变化由 watcher dirty 捕获，会话间由指纹捕获；内容编辑归 clangd，不在 csearch
  freshness 范围。指纹用 list 自身 (mtime,size) 作缓存键，稳态只 stat（mtime 仅作缓存失效，
  非判定）。
  → `docs/architecture/grep-cache-invalidation.md` D10（D8 存档）; change
    `csearch-freshness-content-fingerprint`; `lua/ue.lua` `prepare_freshness` /
    `list_fingerprint` / `on_full_csearch_success`; `tests/cases/freshness_fingerprint_spec.lua`

- **K31g — csearch.idx 并发写损坏（cindex `<idx>~` 路径硬编码）→ `corrupt index` + 0 字节死循环**
  症状: `:UEPrepare` 卡在 ~85%，同时刷屏
  `[ue.watch] csearch_add: cindex-uefilter exit=1 ... merge ... corrupt index: remove <csearch.idx>`；
  目录里 `csearch.idx` 0 字节、`csearch.idx~` 半截、`csearch.idx~~` 是上次好索引。
  根因: cindex 原子写协议把 staged 文件**硬编码**为 `<idx>~`（非每进程独立临时文件）。
  watcher 增量（K29 引入的 `mode="add"` 写者）与用户 `:UEPrepare` 全量并发跑同一个 `idx`，
  抢同一个 `idx~`，在 merge/rename 窗口互毁；0 字节 idx 再被下一次 `add` 撞上 → 死循环。
  解决（三层，2026-06-17）: ① **β 单写者**——`ue_watch` provider 退回 record-only（不写
  csearch.idx），写者收敛为 prepare 家族；新文件靠 persistent_dirty + rg-on-dirty overlay
  到下次手动 prepare。② **Policy A 串行**——`CORE_RT.csearch_build_running` 单标志，构建入口
  `csearch_build_begin` 拒绝并发（不排队），完成回调无条件 `csearch_build_done`。③ **韧性**——
  `build_index` 在 `mode="add"` spawn 前校验 idx 可用，不可用则拒绝并引导全量；`mode="reset"`
  永远安全。④ **清理（D-3b）**——β 把「构建成功⇒dirty 归零」责任转移给 prepare，**每条全量
  成功路径**（fast-path/cold/sync）都须 `clear_persistent_dirty_safe`；漏清会让
  `prepare_freshness` 第一道闸恒判 stale（刚 prepare 完仍弹 stale）且 overlay 背巨大脏集合
  → `<space><space>` 变卡。失败不清。
  → `docs/architecture/grep-cache-invalidation.md` D9; change `fix-csearch-index-single-writer`;
    `lua/utils/ue_watch.lua` `provider_csearch_add`（record-only）; `lua/ue.lua`
    `csearch_build_begin/done` + `clear_persistent_dirty_safe`; `lua/utils/code_search/init.lua`
    `build_index` add-guard; `tests/cases/ue_watch_csearch_spec.lua` / `csearch_build_guard_spec.lua`

---

## 三、约束（Constraints）

承重项。所有贡献都必须遵守。

### C1 — 工具链版本钉死

| 组件 | 版本 | 备注 | 出处 |
|------|------|------|------|
| clangd / clang | **LLVM 22.1.x**（22.1.5 verified） | **不要降级到 21.x** —— exact-command transport、controlled BackgroundIndex、libclang cursor ABI 与 C shim 都按 22.x 验证 | `docs/TOOLING.md` §clangd |
| DAP 适配器（Android） | **LLVM 22.1.6+ `lldb-dap.exe`**（forward-only，当前） | Android platform-mode attach 以 `lua/utils/platform/windows.lua` `default_lldb_dap_paths()` 为准；首选 `C:/tools/lldb-22/install/bin/lldb-dap.exe`。不得静默降级到 LLVM 21 或历史 codelldb 路线。 | `docs/TOOLING.md` §"Current Android DAP status" |
| lldb-server（Android） | **NDK 27 LLDB 18.x**（aarch64-android，platform server） | 当前 K30 路线使用 `/data/local/tmp/lldb-server platform --server --listen`，由 host serial-form `platform connect` 拉起目标 gdbserver；`gdbserver --attach` 路线已证伪。`default_lldb_server_paths()` 以 NDK27 platform server 为首选。 | `docs/TOOLING.md` §"Current Android DAP status" |
| adb | Platform-Tools 35.x+ | | `docs/TOOLING.md` §adb |
| Neovim | **0.10+** | 用到 `vim.uv` / `vim.system` / `vim.api.nvim__redraw` | `docs/TOOLING.md` §Neovim |
| Go（构建 cindex-uefilter） | ≥ 1.22 | 仅构建 csearch 索引工具时需要 | `README.md` §8 |

### C2 — workaround frontmatter 契约

每个 `lua/workarounds/<scope>/<name>.lua` 必须以可被 registry 解析的注释 frontmatter 开头
（`name` / `scope` / `issue` / `symptom` / `introduced` / `removal_condition` / `owner` /
`enabled`），且至少导出 `M.apply()`（幂等），可选 `M.disable()`。
用 `:WorkaroundList` 浏览、`:WorkaroundDisable <name>` 切换。
**何时不该隔离**: 修复本身就是问题的正解（不是 workaround）时，放主逻辑配普通注释；
或用户明确说"原地改"时，inline 并加 `-- NOTE`。不确定就隔离。
→ `lua/workarounds/README.md`; `lua/workarounds/TEMPLATE.lua`

### C3 — `init.lua` 启动顺序假设

固定顺序，改动前先理解依赖:
`cleanup_stale_shada_tmp` → `utils.log`(install commands) → `config.neovide` →
`config.snacks_global` → `config.lazy` → `config.windows` → `utils.recent_projects` →
`workarounds`(4 个 eager apply) → `ue.setup()`。
**NOTE**: `config.options`/`autocmds`/`keymaps` 由 LazyVim 自动加载（options 在
lazy.setup 前、autocmds+keymaps 在 VeryLazy），**不要**在 `init.lua` 再 require（双执行，见 P15）。
→ `init.lua`

### C4 — 六条仓库约定（Conventions）

1. **AST/treesitter 优先于 regex** —— 任何结构化代码问题。
2. **async 优先于阻塞** —— 多秒等待 OK，阻塞主线程不 OK。
3. **workaround 隔离** —— 仅为绕过上游 bug 的代码进 `lua/workarounds/<scope>/<name>.lua`。
4. **可自验证模块** —— 公共 API 挂 `M.*`，可 headless 测试（`nvim --headless -l`）。
5. **不做周期性 ticker 通知** —— 至多 start + 中段更新，成功后自然消退，不刷 `:messages`。
6. **未变更时跳过写入** —— 每个生成器（CDB / manifest / PCH）写前先比对，避免使下游 cache 失效。
→ `README.md` §Conventions

### C5 — 符号解析分层契约

- **C++ source TU**：active CDB 证明 → proven TU 中的 libclang exact-cursor canonical USR；
  不以 clangd 单次 definition 或 source 文件名代替 identity proof。
- **C++ header**：必须继承或选择 compiler-emitted dependency evidence 证明的 origin TU，
  由异步 libclang sidecar 在真实 argv / cwd 中解析 canonical USR；standalone header 不是 build truth。
- **跨 TU destination**：先在 subject 所属 controlled module 的 compiler-authored UBT unity /
  exact fallback AST 中按 canonical USR 找唯一 body；只有 module contexts 暂不可用时才允许
  identity-verified clangd 协助。declaration-self 不是终点，零个或多个 body 都不猜。
- C++ 终态仅 `resolved / ambiguous-context / invalid-semantic-context / unavailable`；只有
  `resolved` 可跳转，Tree-sitter、arity、ranking、workspace symbol、csearch、GTAGS 不得选择或否决结果。
- 允许缓存 live TU，以及 canonical USR + controlled CDB signatures + overlays + toolchain 绑定的
  唯一 resolved destination；negative/ambiguous 结果不跨 subject 缓存，绝不按 symbol /
  receiver / arity 持久化 C++ location。
- clangd 固定 `--enable-config=false`；semantic coverage 只来自同 generation 的 controlled
  BackgroundIndex manifests，current/hot 不得降级已有 full，打开文件 exact argv/cwd 走官方
  `compilationDatabaseChanges`。
- 所有 parse/reparse 在 sidecar 进程；spinner 600ms 后显示，UI 主循环不得同步等待。
- 非 C++ compatibility path 保留 cache/LSP/csearch/GTAGS；`.usf` / `.py` / `.Build.cs`
  可直接走 GTAGS。显式搜索和 references 不受 C++ authority invariant 影响。
- jumper 后置条件: 一个 `<Ctrl-O>` 回到源、恰好一条 jumplist 条目、无 `(target_buf,1,0)` 幽灵。
→ `docs/architecture-symbol-resolution.md` §1–§6

### C5b — grep 缓存按平台分路径 + 失效契约

- csearch 索引 + grep 文件清单（workspace_all/workspace/project/engine + GTAGS DB）
  按 `<Platform>-<Config>` 分目录（`cache_paths(root, platform_key)`）；platform_key 空时
  回落旧单一路径（兼容 + 迁移源）。**只有 grep-facing 工件分平台**，state/cdb shards/
  clangd index/pch 不分。
- `platform_key` 由 `platform_key_from_state` 生成，与 `ue.cdb.shards` 平台维度同源。
- 失效矩阵：project 或 engine 任一变 → 删全平台 grep+cdb 缓存（`set_project` 比对
  state.project_root **与** state.engine_root，故 engine_root MUST 持久化）；platform 变 →
  **不删**，切到新平台目录，旧平台保留；旧单一路径首次 **move 迁移**。
- 负探测不缓存 + UEPrepare/切换后重探 + 回落可见（见坑 K26/K27）。
→ `docs/architecture/grep-cache-invalidation.md`; `lua/ue.lua`; `lua/utils/code_search/`

### C6 — 改动后回归政策（分范围）

任何 `.lua` 运行时代码或 `tests/` 改动，**完成前 MUST 跑对应范围回归并全绿**。按改动类型跑
**最小必跑范围**（改动 → spec filter 映射），但 **① 提交/合并前必跑全量；② 影响面不确定升级到全量，不猜窄 filter**。
新增功能 MUST 补 `*_spec.lua`；冻结清单（`commands_spec` 的 `UE_COMMANDS`、`structure_spec` 目录清单）随相关项变化同步。
**强制入口在根 `AGENTS.md` 的 Definition of Done**（Claude 侧经根 `CLAUDE.md` 的 `@AGENTS.md` 展开读同一内容）；映射速查在 `tests/AGENTS.md`；权威细则在 `docs/testing-regression.md`。
→ 根 `AGENTS.md` (Definition of Done); `docs/testing-regression.md`; `tests/AGENTS.md`

### C7 — 改动记录政策（changelog）

每次落地的改动（即便一行补丁）**MUST 在 `docs/changelog.md` Unreleased 追加一条**，用既有模板
（`### YYYY-MM-DD — 标题` + Task / Implemented / Pitfalls / Validation / Follow-ups）。Implemented 含具体
文件路径与函数名；**Validation 写明所跑回归范围与结果**（与 C6 联动）。攒够 8–12 条或一项连贯工作收尾
即切片归档（见 C8）。
→ 根 `AGENTS.md` (Definition of Done); `docs/changelog.md` (Entry template / How to use)

### C8 — milestone（版本里程碑）政策

**触发**：按 semver——含 BREAKING → major、引入新能力 → minor、仅修复/小改 → patch；版本号续
`v1.0.3` 不跳号。**产出物四件套（缺一不算 milestone）**：① 生成 `docs/release_vX.Y.Z.md`（沿用
`docs/release_1.0.0.md` 格式）+ changelog Unreleased 切片归档 + Released 加交叉链接 + 清空 Unreleased；
② milestone 前跑**全量回归门禁** `nvim --headless -l tests/run.lua` 全绿；③ 打 git tag `vX.Y.Z`
（**tag/commit 须用户确认**，遵守本仓 git 政策，不自动执行）；④ 若动了架构/子系统边界，同步
`memory/` 与 `docs/architecture/overview.md`。
→ 根 `AGENTS.md` (Definition of Done); `docs/changelog.md` (Released); `docs/release_1.0.0.md` (格式范例)

---

## 五、持久化知识库与本地规则（AI 可发现性）

为让持续介入的 AI agent **从文件而非 chat 历史**发现规则，本仓提供：

- **强制执行入口（单一内容源）**：根 `AGENTS.md` 是 Claude 与 GPT/Codex **共用的唯一内容源**
  （SESSION START 协议：动代码前先读 `docs/CONSTRAINTS.md` → `memory/project_overview.md` →
  当前目录本地规则；+ Definition of Done）。根 `CLAUDE.md` 内容仅为 `@AGENTS.md` 导入 stub
  （Claude 只读 `CLAUDE.md`，由该 import 展开读同一内容；Codex 原生读 `AGENTS.md`）。
- **递归本地规则（单一内容源）**：每个主要目录一份 `AGENTS.md`（权威内容源），同目录一份
  `CLAUDE.md`（内容为 `@AGENTS.md` stub）。子级只写相对父级的增量；某目录无本地规则时，
  适用**最近祖先目录**的规则（回落语义）。**只维护 AGENTS.md 一个文件，改一次两端同步**——
  不再有「改 CLAUDE 又改 AGENTS」的双份维护。
- **持久化知识库四区**：
  - `memory/project_overview.md` — 项目总览 + 子系统速查 + 先读顺序。
  - `decisions/README.md` — 架构决策(ADR)导航（权威正文在 `docs/plans/`）。
  - `lessons/README.md` — 平台怪癖/调试硬知识导航（权威在本文件 §二）。
  - `docs/architecture/overview.md` — 架构总览（子系统/数据流/平台层/构建流水线/归属边界）。
- **可发现性回归**：`tests/cases/structure_spec.lua` 守护「目录规则存在（AGENTS.md 源 +
  CLAUDE.md stub）+ 知识库结构完整 + 内链不悬空 + 政策可发现」，跑 `structure` filter。

---

## 六、维护契约

本文档是**索引**，靠下面的规矩防腐烂:

1. **新增一个 workaround** → 在 [§二 snacks/clangd/lazy](#snacks--clangd--lazy活跃-workaround共-9-个文件) 加一行
   （症状 + 文件出处）；文件本身的 frontmatter 仍是权威出处。
2. **踩到一个新坑** → 在 §二 对应分类加条目，必须含 **症状 + 解决约束 + 出处指针**；
   并在 `lessons/README.md` 对应领域补一句主题导航。
3. **改动版本钉死项 / 约定 / 启动顺序** → 同步更新 §三，并保持指向 `docs/TOOLING.md`
   / `README.md` / `init.lua` 的出处链接。
4. **新增子系统目录 / 迁移知识** → 为新目录补一份本地 `AGENTS.md`（内容源，声明继承父级）
   **并补一个 `CLAUDE.md`（内容为 `@AGENTS.md` stub）**，
   在对应知识区 README 登记；`structure_spec` 的目录清单同步。
5. **新增 spec / 改命令清单** → 同步 `tests/AGENTS.md` 与 `docs/testing-regression.md` 的 filter 映射，
   及 `commands_spec` 冻结清单。
6. **milestone 收尾** → 须同步 `memory/` 与 `docs/architecture/overview.md`（若动架构），并按 C8 产出四件套。
7. **出处优先**: 不在此复制原文；摘要与出处冲突时以出处为准。删除某 workaround/坑
   时，对应行随 `git rm` 一并删除。
8. **公开镜像安全**: 新增条目不得引入 secret 或新的私有专属路径
   （`C:\tools\...` 等已在 `docs/TOOLING.md` 公开者除外）。
