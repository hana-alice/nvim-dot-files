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
| P6 | **不阻塞主线程，且不得占满宿主**（首要原则） | 两个层面缺一不可：① 进程内——多秒等待可接受但必须 async（`nio` / 子进程），UI 卡顿 = bug；② **宿主级**——本配置启动的工作不得把机器资源占满到编辑器不可用。主循环空转再顺，若 24 核被我们自己 spawn 的子进程占满，编辑器一样卡。**资源让路优先于功能尽快完成。**只约束自己启动的进程，不得操作 rustc 等外部进程，也不得声称能保证宿主 CPU 上限。 | §三 C4 第 2 条; `openspec/specs/editor-behavior-regression/spec.md`（主循环余量）; 坑 K52/K54 |
| P7 | **不用 `string.format("%x", addr)` 处理 64 位值** | LuaJIT 下会截断到 32 位；模块 slide 的 hex 字符串必须用拼接构造。 | `docs/TOOLING.md` §Pitfalls #4 |
| P8 | **codelldb 不用 `request="custom"`**（历史，codelldb 已退役） | codelldb 1.12.2 会回 `Malformed message`；当时改用 `request="launch"` + `targetCreateCommands` + `processCreateCommands`。当前 lldb-dap 路线用 `request="attach"` + `attachCommands`。 | `docs/TOOLING.md` §Pitfalls #1；坑 K1 |
| P9 | **不用 which-key 自动 cheatsheet** | 会泄漏我们从未绑定的 plugin 键位；自渲染 `:UECheatsheet`。 | `docs/architecture-vs-lazyvim.md` §"What we deliberately *don't* do" |
| P10 | **不在配置内集成 copilot/codeium** | 推理交给外部 CLI（Claude Code / Codex），编辑器保持是编辑器。 | `docs/architecture-vs-lazyvim.md` §"What we deliberately *don't* do" |
| P11 | **C++ goto-def 不让 Tree-sitter 决定或否决目标** | TS 没有 build TU 的类型、宏与 name lookup；C++ `gd` 必须由 compiler identity 决定。TS 可服务非 C++ 兼容路径，但不得给 C++ 语义答案或以语法规则制造失败。 | `docs/architecture-symbol-resolution.md` §1、§2 |
| P12 | **C++ `gd` 禁止自动 csearch / GTAGS fallback** | 文本/ctags 搜索分不清重载、同名、namespace；Clang 语义失败必须诚实失败。显式搜索、references 和非 C++ 路径仍可使用它们。 | `docs/architecture-symbol-resolution.md` §1、§6 |
| P13 | **不用 zoekt 替代 csearch** | Windows 不可用，已论证为死胡同。 | `docs/architecture-symbol-resolution.md` §6 (`zoekt-on-windows-dead-end`) |
| P14 | **不用 PreserveBufferView / BufEnter winrestview 类 cursor 守护** | workaround 反噬模式；Vim 原生 cursor 行为已足够（见坑 K10）。 | `docs/architecture-symbol-resolution.md` §6; commit `252e9e0` |
| P15 | **不在 `init.lua` 重复 require LazyVim 自动加载的 config 模块** | `config.options`/`autocmds`/`keymaps` 由 LazyVim 自动加载，重复 require 会双执行。 | `init.lua` NOTE (line ~44); 约束 C3 |
| P16 | **Android DAP 不用 `lldb-server gdbserver --attach`** | 该形态在真机从不绑定监听端口，attach 必失败；用 platform 模式（见坑 K30/K31）。 | 坑 K30/K31 |
| P17 | **Android `platform connect` URL 不用 `localhost`/`127.0.0.1` 形式** | 经 lldb-dap getopt 会被吞成空 URL；必须用 `connect://[<serial>]:<port>` serial 形式（见坑 K30/K32）。 | 坑 K30/K32 |
| P18 | **公开镜像不得绕过本地隐私门禁** | 隐私扫描不是测试；禁止 `git push --no-verify/--all/--mirror`。plumbing 提交必须经过 `reference-transaction`，恢复引用只能放在 `refs/private-backup/`，真实 denylist 只能在 worktree 外。 | `openspec/specs/public-mirror-privacy/spec.md` |
| P19 | **Windows lldb-dap pin 上不发裸 `script` 命令** | 22.1.6 `lldb-dap.exe` 遇到任意 `script …` 直接 `0xC0000409` 崩溃且 `launch` 无 response，会话静默死；要跑 python 只能用 `command script import <path>`（见坑 K57）。 | 坑 K57 |
| P20 | **不用 shell uid 的 `test -x` 判断 app uid 能否执行** | `/data/local/tmp` 副本是 `shell_data_file`，enforcing SELinux 下 app 域可读不可执行；shell 侧 `test -x` 通过而 app uid exec 得 126。凡是判定 run path 就绪都必须经 `run-as <pkg>` 探测（见坑 K58）。 | 坑 K58 |

---

## 二、踩过的坑（Pitfalls）

已付出过真实调试成本的陷阱。格式: **症状 → 解决约束 → 出处**。

### DAP（hard-won #1–#10；仅 K1 属已退役 codelldb 路线）

- **K1 — custom-request 被拒**（历史，codelldb 路线已退役）
  症状: codelldb 1.12.2 收到 `request="custom"` 回 `Malformed message`。
  解决: 用 `request="launch"` + `targetCreateCommands` + `processCreateCommands` 数组。
  现状: codelldb 已从代码中完全移除，当前 lldb-dap 路线用 `request="attach"` +
  `stopOnEntry=true` + `initCommands`/`attachCommands`/`postRunCommands`
  （`lua/ue/dap/android.lua` `lldb_dap_attach_config`）。本条仅存档。
  → `docs/TOOLING.md` §Pitfalls #1

- **K2 — 远程 attach 不自动 rebase 模块**
  症状: attach 后 `.so` 符号全部解析到错地址。
  解决: 对每个要解析的 `.so` 显式 `target modules load --file <so> --slide 0x<base>`，
  `<base>` 取自设备上 `/proc/<pid>/maps`。当前 lldb-dap 路线在 `attachCommands` 内下发
  （见 K11/K37 的时序要求）；`processCreateCommands` 是已退役 codelldb 路线的字段名。
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

- **K11 — ASLR slide 必须在 attach 命令序列内、先于 `setBreakpoints` 下发**
  症状: Android 断点 "unresolved" 或永不命中；libUE4.so 的 ASLR slide 检测错误，
  所有断点解析到错地址。
  解决: slide 修正必须在 `process attach` 之后、`configurationDone` 返回**之前**运行——
  因为 nvim-dap 在 `configurationDone` 紧后就发 `setBreakpoints`。基于事件
  （`event_stopped`/`event_initialized`）的做法**太晚**，断点早已按错地址解析。
  当前实现: `lua/ue/dap/android.lua` 在 `attachCommands` 内、signal disposition 之后
  下发 `target modules load --file libUE4.so --slide 0x<base>`，预置断点命令插在其后。
  （历史笔记写的 `processCreateCommands` 是已退役 codelldb 路线的字段名，时序要求不变。）
  → K37（slide 为 load-bearing 的实证）；MEMORY `project_android_dap_aslr_fix.md`

- **K12 — `/proc/maps` 权限模型**
  症状: `adb shell cat /proc/PID/maps` 在 Android 10+ 静默返回空（hidepid）。
  解决: 优先用 LLDB `platform shell cat /proc/<pid>/maps`（lldb-server 以 app 用户经
  `run-as` 运行）；解析前务必确认有真实输出。
  → MEMORY `feedback_android_dap_aslr_debugging.md`

- **K13 — 环境残留导致 attach 失败**
  症状: app 卡在 state T，需要重启。
  → MEMORY `feedback_android_dap_env_residue.md`

### Android DAP attach 路线（platform 模式，真机 ANDROID-SERIAL-A 实证 2026-06-03）

- **K30 — Android attach 唯一正解是 platform 模式 + serial-based connect URL（宪法级）**
  背景: 5/21（commit `e51cbe6`）用 **lldb-dap 22.1.6 + lldb-server platform 模式**真机
  跑通过；6/02 把路线改成 `gdbserver --attach` 后再也连不上，连环误判多轮。
  **唯一验证可用的 attach 配方**（2026-06-03 真机 protocol log 背书，到 `Connected: yes`
  + `process attach` + `threads ok`）:
  - device 端: platform server 必须**以 app uid 经 `run-as <pkg>` 从 app sandbox 副本**
    启动（`/data/data/<pkg>/lldb-server platform --server --listen "*:<port>"`）。
    **⚠️ 本行 2026-09-03 被 K56 更正**：原文写的 `cd /data/local/tmp && ./lldb-server …`
    （shell uid + public 路径）在该设备**已证伪** —— shell uid 无法 ptrace app，
    forked gdbserver 在 `vAttach` 里 SIGSEGV，host 只看到
    `error: attach failed: lost connection`。`/data/local/tmp` 仍是 push 的**中转**路径，
    但不是 server 的运行路径。详见 K56。
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
  **现状（2026-06-15 真机 `ANDROID-SERIAL-B` 复验）: 在 K30 platform route + 3.5 匹配符号下
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
  解决/现状: 2026-06-15 真机 `ANDROID-SERIAL-B` D1 闸门 + 端到端复验——在 K30 platform route +
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
  （2026-07-24 真机 ANDROID-SERIAL-A 日志）。旧 `adb root` 会话推的文件 owner 是 root:root，
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
  根因: 旧路径把现场项目布局 `Source/SampleGame`、`Client_Symbols_v*`、`SampleGame-arm64` 当成 UE 固定约定。
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

- **K51 — cdb pipeline × UE build 并跑 = WAW 冒险 + prune 满线程抢核（2026-08-18 实测）**
  症状: `<Space>ub` 编译期间 python（prune_include_dirs 的 `min(20,cpu)` 线程 include 扫描 +
  310MB CDB `json.load`）吃满 CPU、编译卡顿；且 pipeline 静默（日志 exit 时才落盘、python
  stdout 管道全缓冲），kill 后才弹 `ue-pipeline failed (exit 1)`。
  根因: prepare 家族（含 cdb pipeline）**读取编译产物**（Module.*.rsp / receipts），与正在
  重写这些产物的 UBT build 并跑，产出半新半旧的脏 CDB——写后写冒险，不只是抢 CPU。
  解决约束: **build 赢**——`build_android` 启动时 `pipeline.cancel()` 掉在飞 pipeline（经
  on_fail 正常释放 writer 槽/lease）；`prepare_async` 在 `CORE_RT.ue_build_running()` 时拒绝
  启动（不排队）。pipeline python 步骤必须 `-u` + 分步 banner + 流式落盘日志（jobstart data
  块非行对齐，须 pending-buffer 拼行）；prune 用 `--sample 4 --workers 4`。
  → `lua/ue/cdb/pipeline.lua` `M.cancel`; `lua/ue.lua` `ue_build_running` / `_logged_jobstart`;
    行为测 `tests/cases/ue_cdb_spec.lua`; `docs/changelog.md` 2026-08-18

- **K52 — 「持续偷主循环」三连：RAM-only `-j` / LSP stderr 每条 flush / 2s 配置轮询（2026-08-25 实测）**
  症状: `:StallReport` 与日志 scope `[stall]` 累计 8643 条卡顿记录（p50 229ms / p90 504ms），
  **8518 条在 0.3s 内没有任何按键**（=与按键动作无关），~2s 一次成串出现，`ft=cpp` 占 6536 条；
  且**两个互不相干的 nvim 进程按小时计数完全相同**（325 vs 325）。
  **诊断陷阱（比结论更值钱）**: 逐一测量后**全部证伪**了直觉候选——输入路径（活实例里每个导航键
  p90 < 15ms）、snacks statuscolumn（warm 0.006ms、整窗 0.15ms）、lazy reloader 命中变更（21ms）、
  合成 CPU 压力（23 个满转 worker 只把 33 文件扫描从 1.3ms 推到 2.9ms，**0 次迟到 tick**）、
  合成磁盘写压力（1.2x，0 次迟到）、headless 下真实 clangd（17.4GB RSS、38 线程，**0 次卡顿**）。
  **关键方法论**: `--headless` 无渲染线程、无 UI 管道，**结构上看不到 UI 争用**——6 次 headless
  实验都报告「主循环很顺」而 GUI 会话正在卡。必须在**活的 GUI 实例**上用 `--server` 注入测量；
  另外 `jit.profile` 在空闲时会把采样记到最后运行过的栈（本例 61% 记到 `vim.schedule_wrap`），
  **它回答「哪段 Lua 跑得多」，不回答「这 250ms 是谁占的」**——判定归属要用 rusage CPU/gap 比值
  （≈1 = 本进程内阻塞；≈0 = 被剥夺调度/宿主超订）。
  根因（三个独立的**持续性**开销，都不是「某个回调很慢」）:
  ① `-j` 只按 RAM 推导（`floor(94/4)=23`），24 核机器上给 clangd **96% 的核**，只剩 1 核给
  主循环 + Neovide 渲染线程 + 合成器；索引时宿主 CPU 6%→60%、clangd 38 线程。
  ② `vim/lsp/_transport.lua:36` 把 server 的**每条 stderr 按 ERROR** 记录，而 `vim/lsp/log.lua`
  默认 WARN 门槛让 ERROR 恒通过，且每条 `write()` 后 `flush()`——现场 `lsp.log` 16.6MB / 58803 条
  **全部是 clangd 的普通 `Indexed ...` 信息输出**，实测 0.045ms/条（batched 0.094ms、max 0.63ms），
  合计约 2.6s 主循环时间，且**恰好在索引时成串爆发**。
  ③ lazy.nvim `change_detection` 的 `start(2000, 2000)` 在主循环上同步 `fs_stat` 33 个 spec 文件
  （空闲 1.2ms p50），命中变更再付 `Plugin.load()`+autocmd **21ms p50**；它还是**共享磁盘状态**，
  所以多个 nvim 会在同一个 2s 窗口一起反应——这正是「两进程计数相同」的成因。
  解决约束: **UI 余量是一等约束**（P6 的延伸：不只是「别阻塞」，还包括「别把资源占光到画不出帧」）。
  `-j` MUST 同时受 RAM 与 CPU 两个预算约束，并为 UI 保留 `UI_RESERVED_CORES`（当前 4）个逻辑核；
  `UE_CLANGD_JOBS` 显式覆盖仍优先。vim.lsp 日志级别 MUST 为 OFF（server 的 stderr 不是 error），
  排查时用 `:LspLogLevel debug` 临时提级。`change_detection` MUST 显式 `false`——本仓行为大量由
  启动**顺序**建立（C3），本就不能热重载，等于白付周期性主循环税。
  → `lua/ue/clangd_jobs.lua`（`compute`/`resolve`/`UI_RESERVED_CORES`）; `lua/ue.lua` `clangd_cmd`;
    `lua/config/ui_responsiveness.lua`; `lua/config/lazy.lua` `change_detection`;
    诊断入口 `tools/stall_profile.lua` / `tools/stall_attribute.lua` / `tools/stall_repro.lua`;
    行为测 `tests/cases/ui_responsiveness_spec.lua`; `docs/changelog.md` 2026-08-25

- **K53 — Windows 上 `vim.system():wait()` 的光 spawn 底线就是 87ms：交互路径禁止同步子进程（2026-08-25 实测）**
  症状: `gr`（references）偶发冻住数百 ms 至数秒，屏上无任何提示；卡顿日志里的多秒级极值
  （122843ms / 36247ms / 12754ms / 8447ms）都落在导航与 `:UEPrepare` 动作上，而不是普通滚动。
  根因: 两层同步阻塞叠在同一个日常按键上——`provider.sync_locations` 的
  `client:request_sync(..., 5000)` 最多堵**5 秒**；随后 `ue.gtags_references` 经
  `global_lines`→`run_lines` 进入 `vim.system(...):wait()`。**关键数据：本宿主上光是
  `vim.system():wait()` 的空 spawn 就要 87ms p50**（`global -r` 82ms p50 / 293ms max）——
  Windows 创建进程昂贵，**这笔底线即使查询一无所获也要付**。这也解释了为何卡顿分布
  p50=229ms：约等于 2–3 次同步 spawn。
  解决约束: 交互路径（按键/命令）MUST NOT 出现 `:wait()` 或 `request_sync`。新增
  `M.gtags_references_async` 并把 `references()` 整条链路改异步（`async_lsp_request` +
  async GTAGS 回退）。注意：换异步通道时必须补上 `includeDeclaration`（sync 版本一直在设，
  `async_lsp_request` 原本没设），否则会静默改变返回集——这类**行为漂移比性能回退更难发现**。
  → `lua/ue.lua` `gtags_references_async`; `lua/utils/lsp_fallback.lua` `M.references`;
    `lua/utils/ue_goto/provider.lua` `async_lsp_request`（ReferenceContext）;
    行为测 `tests/cases/ui_responsiveness_spec.lua`「交互路径禁止同步阻塞」

- **K54 — 只给「我们调度的批任务」做准入控制，长驻服务与其余 spawn 点全裸奔（2026-08-26 实测）**
  症状: 已实现宿主 CPU 准入控制（85% 高水位、双水位滞回，实测 42%→ALLOW / 100%→DEFER），
  并宣称「已生效」；用户随后仍报「clangd 时不时把电脑卡死，复发了」。
  证据: AppControl `app_sysmon.db`（`binary_monitoring`，`binary_id` 映射见 `app_data.db.binary`；
  258 = `C:/Program Files/LLVM/bin/clangd.exe`）显示 clangd 当日
  **17:56–18:46 连续 50 分钟满负荷**，而全部 CPU 相关改动落盘于 **16:03–16:05** ——
  复发发生在修改之后，用户判断正确。
  根因: 准入控制只挂在 `lua/ue/index/_schedule.lua`；`rg -l "admit_background_phase"` 仅命中
  `_admission.lua`/`_schedule.lua`，而 spawn 点分散于 `ue.lua`(24)、`dap/android.lua`(16)、
  `cdb/pipeline.lua`(10)、`index/_build.lua`(4)、`task_registry.lua`(4) 等十余文件 —— **结构性缺口，
  不是漏改一处**。三类负载根本不在视野内: clangd 本体（仅启动时静态 `-j`）、UE build、Neovide 渲染。
  次因: `-j` 只「保留 4 核」→ 24 核机器给 clangd 20 核（**83%**）。固定核数在不同规模宿主上语义不同
  （保留 4/8 很激进，保留 4/64 形同没有），必须叠加**份额上限**。
  另: `--background-index-priority=background` 按 clangd `--help` 为 *OS-specific*，
  **Windows 未验证**，不得计入已有防线。
  解决约束: P6 提升为**宿主级首要原则**（见 §一 P6、§三 C4-2）。判据必须**全仓共用一份**
  （不得各子系统各写阈值）；按类型分策略——可推迟批任务→推迟启动；长驻交互服务→**可逆 OS 级降级，
  MUST NOT kill/suspend**（杀掉丢 preamble，下次导航重付分钟级）；用户显式发起的前台任务→不得自动
  推迟，但须抑制后台批任务。并发预算同时受 RAM、核数与**份额上限**约束
  （`MAX_CORE_SHARE`，24 核: `-j` 20→12）。诚实边界: 只约束自身启动的进程，不动 rustc 等外部进程，
  不承诺宿主 CPU 上限。
  教训（比结论更可复用）: **「已实测生效」必须写清生效范围**。我实测的是 index 构建路径，
  却表述为整体生效，用户因此白等一轮。声称修复时须同时说明**未覆盖什么**。
  感知层教训: **负载感知必须常驻维护缓存，不能等重活到期才冷启动。**累计 CPU 计数至少需要两个
  时间点；按需采样的第一次查询只能得到 `nil`，而旧准入将 `load-unknown` 放行，恰好让最该节流的
  第一项重活穿透。正确结构是 UI 会话低频常驻采样、查询只读缓存，并把 `warming`（正在建立差分）
  与 `unknown`（平台不可测）分开。`uv.getrusage()` 只含 Neovim 本进程、不含 live children，差值只能
  标为 `unattributed`，不得伪装成「外部占用」。
  动态纪律落地: `utils.host_admission` 是唯一水位/前台 ownership；workspace scan、ccjson、CDB
  pipeline+partition、GTAGS、csearch、controlled index 全部只在 child start 前 gate。用户显式
  build/install/deploy/PCH/core-health 不等 CPU，并在生命周期内抑制新的 batch。clangd 不能套 batch
  策略：Windows driver 以 Toolhelp32 证明 `(parent nvim pid, executable name)` 后，仅在
  `NORMAL ↔ BELOW_NORMAL` 间可逆切换 PriorityClass；发现后持有绑定原 process object 的 HANDLE，
  每轮只查 `STILL_ACTIVE`（不重复 16ms Toolhelp 全机快照，也不受 PID reuse 影响），禁止
  kill/suspend/affinity，禁止仅按进程名扫全机。
  防复发: spawn audit 同时覆盖 `vim.system`/`jobstart`/`termopen`/`uv.spawn`/`vim.lsp.rpc.start`；
  每个点必须有精确 anchor、类别、数量和理由，禁止整个文件/API whitelist。
  → `lua/ue/clangd_jobs.lua`（`MAX_CORE_SHARE`）; `lua/utils/cpu_load.lua`;
    `lua/ue/index/_admission.lua`; change `enforce-host-resource-discipline` /
    `constrain-clangd-under-cpu-pressure`; 行为测 `tests/cases/ui_responsiveness_spec.lua`
    「份额上限」与 `cpu_admission_spec.lua`

- **K55 — iOS Mach-O/dSYM UUID 相等不代表 source debug 可用（2026-08-26 真机）**
  症状: CoreDevice start-stopped、PID identity 与 Mach-O/dSYM UUID 都一致，但 LLDB source breakpoint
  永远 pending；`dwarfdump --statistics` 报 0 functions / 0 line entries，大量 compilation unit 指向
  invalid abbreviation offset。
  根因: 超过 4 GiB 的 monolithic UE DWARF 可能生成 UUID 正确但结构损坏的 dSYM；只跑 `--uuid`
  会把不可调试工件误判为可用，随后 adapter/真机符号加载耗时很久才失败。
  解决约束: CoreDevice DAP 必须在启动 adapter 或创建 suspended process 前异步执行
  `dwarfdump --verify --quiet`；失败即报告 external artifact blocker，不允许降级成 symbol-only 成功。
  device attach 是异步的，loaded UUID 检查必须在 post-run `process status` 之后输出并消费唯一
  OK/MISMATCH marker；把 `assert` 直接塞进 attach command 会过早执行，而且 lldb-dap 可能忽略其错误。
  真机 evidence 只能记录摘要/digest，不得落真实 device、bundle、PID 或个人路径。
  → `lua/ue/dap/_ios_coredevice.lua`; `tools/evidence/ios-dap/coredevice-*.current.result.json`;
    `openspec/specs/ios-device-debug-workflow/spec.md`

- **K56 — Android platform server 必须以 app uid 运行；shell uid 会让 forked gdbserver 在
  `vAttach` 里 SIGSEGV（2026-09-03 真机，更正 K30 的 device 端命令行）**
  症状: `<Space>da` 走完整 K30 配方（platform 模式 + serial-form connect URL），
  `platform connect` 成功报 `Connected: yes`、`qHostInfo`/`qfThreadInfo` 全部正常，
  但 `process attach --pid <pid>` 在 **约 1 秒**内失败，host 只看到
  `error: attach failed: lost connection`；device 上留下一个 zombie `[lldb-server]`。
  host packet log 停在 `$vAttach;<hexpid>#xx` 之后，无任何回包。
  根因: 该机是 `user` build（`ro.debuggable=0`、无 `su`、无 Yama `ptrace_scope` 文件），
  **shell uid（2000）无法 ptrace app 进程**——即使 app 是 `pkgFlags=[DEBUGGABLE]`。
  NDK 27 LLDB 18 的 lldb-server **不把这个拒绝报成错误**，它 fork 出来的 per-target
  gdbserver 子进程直接 SIGSEGV。实测真值表（139=SIGSEGV，124=`timeout` 到点即 server
  仍活着在服务=成功）：
  | server uid | target | rc |
  |---|---|---|
  | shell | shell 自己的 `sleep` | 124 ok |
  | shell | root 的 init (pid 1) | **139 SEGV** |
  | shell | app 的游戏进程 | **139 SEGV** |
  | app (`run-as`) | app 的游戏进程 | 124 ok |
  对**不存在**的 pid（999999）做对照返回干净的 rc=1 `No such process`，证明 SEGV
  专属于「权限被拒的 ptrace」而非坏输入。同一个健康目标（156 threads）上端到端 A/B、
  同 host、同 NDK 27 LLDB 18 device server、只换 server 运行 uid：
  **shell uid 3/3 全 `lost connection`（~1s）；app uid 3/3 全成功**
  （完整 155-thread stop + clean detach，6–7s）。
  **device server 版本不是变量**：LLDB 9 / 14 / 18 在 shell uid 下全部同样失败。
  ⚠️ 不要用「降级 device server 版本」来修 `lost connection`——C1 把 device server
  钉在 NDK 27 LLDB 18.x，`docs/release_1.1.0.md` 2026-06-02 那条把锅推给 NDK r27
  的记录**已被本条证伪**。
  解决: 两跳 staging + app uid 启动。
  1. `adb push` → `/data/local/tmp/lldb-server`（**仅中转**，shell uid 可写）
  2. `run-as <pkg> sh -c 'cat /data/local/tmp/lldb-server > /data/data/<pkg>/lldb-server
     && chmod 700 …'`（用 `cat` 重定向而非 `cp`，跨 sandbox 边界 `cp` 会 EACCES）
  3. `run-as <pkg> sh -c '/data/data/<pkg>/lldb-server platform --server --listen "*:<port>"'`
     —— listen 通配符**必须双引号**，否则 device shell 会把 `*` glob 成 sandbox 里的
     第一个文件名。
  收尾必须**同时** kill 两个 uid 的 lldb-server：残留的 shell-uid server 会占住端口
  并静默把 SEGV 路径带回来。
  → `lua/ue/dap/android.lua`（`ensure_lldb_server_pushed` / `start_lldb_server_platform`
    及其上方的证据表注释）; `openspec/specs/android-dap-attach/spec.md`
    「device 端 platform server 以 app uid 运行」; 行为测 `tests/cases/dap_spec.lua`
    「K56 app-uid platform server 命令构造」

- **K58 — 「transport 副本已可执行」不等于「run path 就绪」；shell uid 的 `test -x`
  对 app uid 毫无意义（2026-09-03 真机，K56 落地实现里的漏洞）**
  症状: `<Space>da` 走完 K56 的两跳 staging 逻辑后**仍然**失败。host 端顺序是
  `platform connect connect://[<serial>]:<port>` →
  `error: Connection shut down by remote side while waiting for reply to initial
  handshake packet`，接着 `process attach --pid <pid>` →
  `error: attach failed: The parameter is incorrect.`，UI 上是
  `Error on attach: process exited during launch or attach` +
  `command lldb-dap.exe … exited with 1`。
  根因（trace 到生产代码真正发出的 adb 命令才看见）: `ensure_lldb_server_pushed()`
  在 transport 跳判定为 `reuse`（远端尺寸一致 + shell 侧 `test -x` 通过）时**提前
  return 了公共中转路径**，于是跳过了 Hop 2，`sess.remote_lldb_server` 是
  `/data/local/tmp/lldb-server`，`start_lldb_server_platform` 发出
  `run-as <pkg> sh -c '/data/local/tmp/lldb-server platform --server --listen "*:N"'`
  → `sh: /data/local/tmp/lldb-server: can't execute: Permission denied`，
  **exit 126**，设备端根本没有 listener。
  证据（同机实测，`getenforce` = `Enforcing`）:
  | 路径 | label / owner / mode | app uid `test -x` | app uid exec |
  |---|---|---|---|
  | `/data/local/tmp/lldb-server` | `u:object_r:shell_data_file:s0` / `shell shell` / `-rwxr-xr-x` | **rc=1** | **rc=126** `can't execute: Permission denied` |
  | `/data/data/<pkg>/lldb-server` | `u:object_r:app_data_file:s0:c…` / app uid / `-rwx------` | rc=0 | rc=0，报 `lldb version 18.0.1` |
  app 域**可读**公共副本（`head -c 4` 得到 `.ELF`），所以 `cat >` staging 仍然可行——
  缺的只有 execute。
  教训: 判定「能不能跳过 push」和判定「run path 是否就绪」是**两个独立决策**，探测
  必须用与运行时相同的 uid。`adb shell test -x <public>` 跑在 shell uid 上，对 app uid
  的执行权限**零信息量**。
  解决: transport 的 `reuse` 只置一个 `skip_transport` 标志（跳过 push/chmod/ls），
  之后一律落到 Hop 2；run path 的复用判定改用 `sandbox_stage_plan()`，其两个输入都由
  `run-as <pkg>` 在 app uid 下测得（sandbox 副本尺寸 + `test -x`）。
  验证: 删掉 sandbox 副本后重跑真机 attach ——
  `run-as … 'stat -c %s /data/data/<pkg>/lldb-server'` rc=1 → `cat >` + `chmod 700` →
  `run-as … test -x` rc=0 → 启动命令变成 sandbox 路径 → `platform connect` 报
  `Connected: yes` / `Triple: aarch64-unknown-linux-android` → `process attach` 得
  `Process <pid> stopped` → `Attached to process <pid>` → **23 threads**、
  `threads err=nil`、`session.initialized=true`。
  → `lua/ue/dap/android.lua`（`sandbox_stage_plan` / `sandbox_probe` /
    `ensure_lldb_server_pushed`）; `openspec/specs/android-dap-attach/spec.md`
    「复用快路径只以 app uid 探测 sandbox 副本」; 行为测 `tests/cases/dap_spec.lua`
    「K58 sandbox_stage_plan（run path 复用判定）」

- **K59 — 失败的 attach 也会写 `_last_session`，污染下一次包名解析（2026-09-03 实测）**
  症状: 用户把包名敲错一次后，即使后续用 `:UESetAndroidPackage` 改对，本次 Neovim
  会话内 `<Space>da` 仍报旧包名 `not running`。
  根因: `snapshot_last_session()` 在**每次** teardown 都写 `M._last_session`，而一次失败的
  attach（pkg/serial/symbol_lib 已选定、pid 探测未命中）也会走 `stop_android_debugger()`；
  `bootstrap_session` 旧代码把该存档当成 `ctx.android_package`，直接短路掉
  `pick_package()` 的持久 state 分支。
  解决: ① `snapshot_last_session()` 增加 `s.pid` 守卫（pid 只由 `_finalize_session` 写入，
  即只有真正接上设备才存档）；② 新增 `resolve_session_package(ctx, opts)`，只取显式
  ctx/opts，**MUST NOT** 回落 `M._last_session.package_name`，让持久 state 赢。
  边界: 该修复对**已在跑的**进程无效（旧代码仍在内存）——用户当时看到的症状并未
  因此消失，真正的第二重缺陷见 **K61**。
  → `lua/ue/dap/android.lua`（`snapshot_last_session` / `resolve_session_package`）;
    行为测 `tests/cases/dap_spec.lua`「K59 package 解析与 last-session 存档」

- **K60 — `exited with status = 9` 是 SIGKILL（不可捕获），不是「调试器漏了崩溃」；
  ART 的良性 SIGSEGV 只能按符号而非按信号号区分（2026-09-03 实测）**
  症状: wifi 远程 attach 后 app 死掉，用户看到的只有
  `App <pkg> exited on <serial>. Detaching.`，感知为「调试器没抓住崩溃就自己退了」。
  实测证据（lldb-dap protocol log + `$__lldb_statistics`）: attach 全程成功
  （`platform connect` / `process attach` / `target create` / `target modules load`
  / 173 个 SIGSTOP 入口停顿都 OK），`signals` 只有 `{SIGCHLD:2}{SIGSTOP:173}`——
  **零 SIGSEGV/零 SIGBUS**，全程只发过一次 `continue`，最后
  `{"body":{"category":"console","output":"Process <pid> exited with status = 9
  (0x00000009) 
"}}` + `{"body":{"exitCode":9},"event":"exited"}`。
  ⇒ 进程是被**外部 SIGKILL**，SIGKILL 无法被任何调试器捕获；lldb 如实上报了，
  缺陷在**我们的措辞**。
  工具事实: `liblldb.dll` 里只有 `" Process %llu exited with status = %i
  (0x%8.8x) %s"` 一条相关格式串，**没有** "Terminated due to signal"
  （`grep -c` = 0）→ 信号语义必须由本仓 Lua 层合成，别指望 lldb 给人话。
  另一条事实: lldb 对 `exit(N)` 与死于信号 N 打印**同一字段**，所以措辞只能是
  「matches SIGKILL」，**不得**断言「被 SIGKILL 杀死」。
  设备侧唯一能指认「谁杀的」的权威是 `adb shell dumpsys activity exit-info <pkg>`
  的 `ApplicationExitInfo`（`reason=10 (USER REQUESTED)/subreason=21 (FORCE STOP)`
  + `description=stop <pkg> due to from pid <killer>` = 外部杀；
  `reason=1 (EXIT_SELF) status=1` = app 自身崩溃路径）。它**不接受 pid 过滤**
  （`dumpsys activity -h` 只写 `exit-info [PACKAGE_NAME]`），pid 匹配放 Lua。
  第二半（可捕获性）: K3 把 SIGSEGV/SIGBUS 钉成 `--stop false`，因为 ART 用
  `libsigchain.so` 把它们当 JIT read barrier / 压缩 GC card-table / heap poisoning
  的常规机制——按**信号号**永远分不出良性与致命。按**符号**可以：NDK 27 `llvm-nm`
  实测出货 symbol `libUE4.so`（1,178,567 defined symbols）里
  `FFatalSignalHandler::OnTargetSignal(int, siginfo*, void*)` 存在，且它由
  `sigaction(SA_SIGINFO|SA_ONSTACK)` 装在**故障线程**上，ART 的良性陷阱永远走不到。
  故 attach 序列在 ASLR slide 之后追加
  `?breakpoint set --shlib libUE4.so --name "FFatalSignalHandler::OnTargetSignal"`
  （`?` = 非致命，符号不匹配的构建不得中断整个 attach），K3 的
  `--pass true --stop false` 一并保持不回退。
  待验证: ① 本次「谁杀的」无法闭环——被调试的 wifi 设备已离网（`adb connect` 拒连
  10061），拿不到它自己的 `am_kill`/`exit-info` 记录；同僚设备上虽有形状吻合的
  `USER REQUESTED/FORCE STOP`（description 指向 `pid 1976 (system)`），**不得据此
  断言**本次是 ActivityManager/watchdog 所杀。② UE 的转发信号线程会轮询
  `WaitForSignalHandlerToFinishOrExit()`，`GAndroidSignalTimeOut` 到点 `exit(0)`，
  长时间停在该符号断点上仍可能让 app 自退。
  逃生开关: `UE_DAP_NO_FATAL_BP=1`。
  → `lua/ue/dap/exit_reason.lua`（状态解读 + `exit-info` 解析）;
    `lua/ue/dap.lua`（`event_exited` 抢在 dapui 钩子前留住 `exitCode`）;
    `lua/ue/dap/android.lua`（`_report_exit_reason` + 符号断点）;
    `openspec/specs/android-dap-attach/spec.md`「会话结束原因必须讲事实」/
    「真实致命信号必须可停」; 行为测 `tests/cases/dap_spec.lua`

- **K61 — 「命令不刷新缓存」的真因是写入失败被丢弃后仍报成功（lying success）
  （2026-09-03 实测）**
  症状: 用户 `:UESetAndroidPackage com.正确包名` 后看到「UE Android package set: …」，
  但 `<Space>da` 仍报 `process com.旧包名 not running`，用户描述为「UESetAndroidPackage
  failed to refresh the cache」。
  被证伪的假设（必须显式记录）: ① 「`read_state` 前面有进程内值缓存」——不存在，
  `lua/ue.lua` 的 `read_state`/`update_state_field` 是纯 delegate，`android_package`
  也不在 `SESSION_LOCAL_FIELDS` 里；② 「`invalidate_status_cache` 与包名解析有关」——无关；
  ③ 「K59 的 `snapshot_last_session` 守卫修好了用户看到的症状」——机制正确但
  **对已在跑的 Neovim 无效**（被污染的 `M._last_session` 就在那个进程内存里，
  新代码只在下一个进程生效）。
  定性证据: `project_state.update` 在本进程未选中项目时返回
  `false, "no project selected in this Neovim session"`（headless 对照实验 CASE B），
  而 `set_android_package` **丢弃了这个返回值**并照样弹成功 toast。
  另一侧磁盘证据: 用户的纠正值确实在 `state-fields/android_package.json` 里
  （`updated_at` 比投诉时间早 ~1 分钟），而旧包名 **在任何持久文件里都不存在**
  → 旧值只活在进程内存，与 K59 机制一致。
  解决: 新增 `project_state.commit(engine_root, key, value)` 作为唯一写入入口——
  写入 + **从读取方同一 bucket 回读校验**（单纯检查返回值不够：它无法表达
  writer/reader bucket 分裂）；`set_android_package` 失败时改报 ERROR
  「UE Android package NOT set: <err>」。
  → `lua/ue/project_state.lua`（`M.commit`）; `lua/ue.lua`（`set_android_package`）;
    `openspec/specs/multi-instance-state-isolation/spec.md`
    「state-setting 命令 SHALL 以回读为凭报告成败」;
    行为测 `tests/cases/multi_instance_state_spec.lua` + `tests/cases/ue_context_spec.lua`

- **K62 — 异步 spawn 回调运行在 fast event context：那里禁用一切 Vimscript 函数；
  且「同一个 rc 代表两种状态」会让门禁静默失效（2026-09-04 真机，小米 fuxi/MIUI）**
  层归属: **L2（探针实现）/ 编辑器管道**。两条都只有真机能暴露，同步 fixture 永远碰不到。
  症状 A: `vim.system` 的完成回调里读 `vim.env` 或调 `vim.fn.sha256` 直接抛
  `E5560: Vimscript function "getenv"/"sha256" must not be called in a fast event context`，
  **回调链就断在那里**，外部表现是「探针永不完成 / 超时」，看不出是 API 误用。
  解决: **在边界一次性 `vim.schedule` 回到主循环**（`preflight.system_executor` 的
  `finish`），而不是逐个把下游 API 换成纯 Lua 等价物——后者只会下次再死一次
  （实测先死 `getenv`，改掉后又死 `sha256`）。代价是一个事件循环 tick，与设备往返耗时相比可忽略。
  症状 B: 用单条 `test -x <path>` 判「app uid 能否执行 staged server」时，
  **「还没 stage」与「stage 过但不可执行」同为 rc=1**。早期实现把 rc=1 一律判
  `undetermined`（为了不误拦首跑），于是 K58 那个**真红灯永远判不出来，L2 门禁实际是死的**。
  解决: 先问存在性再问可执行性，用不同退出码分开 —— `0`=可执行 / `11`=存在但不可执行（FAIL）
  / `10`=未 stage（undetermined）。真机三态实测：未 stage → rc=10 不拦；`chmod 400` →
  rc=11 拦下且 L3/L4 skipped；`chmod 700` → rc=0 通过。
  **K58 在第二台设备上完整复现**（与原设备不同 OEM）：同一文件 `/data/local/tmp/lldb-server`
  权限 `-rwxrwxrwx`、标签 `shell_data_file`，shell uid `test -x` **rc=0**（说"能执行"），
  app uid `test -x` **rc=1**、实际 exec **rc=126** `can't execute: Permission denied`；
  `cat` 进沙箱后标签变 `app_data_file`、rc=0。⇒ 纯 SELinux 域限制，与 POSIX 权限位无关，
  P20「不用 shell uid 的 test -x 判断 app uid 能否执行」得到第二台设备背书。
  → `lua/ue/dap/preflight.lua`（`system_executor` 的 schedule 边界、`skipped` 用 `os.getenv`）;
    `lua/ue/dap/android.lua`（`app-uid-can-exec-server` 三态退出码）;
    `openspec/specs/dap-failure-layering/spec.md`; 行为测 `tests/cases/dap_failure_layer_spec.lua`

- **K63 — 探针判定必须 rc 与输出一致；`pgrep -f` 会自匹配；报告措辞不得与判定
  自相矛盾（2026-09-04 真机）**
  层归属: **L2/L4（探针实现）**。三条都由「把手工验证变成自动化用例」这一步暴露。
  症状 A: `target-process-running` 探针原本只看「输出里有没有数字」，于是
  **rc=0 且输出为空**被判 FAIL，把一次本该通过的 L2 门禁拦掉（行为测立刻抓到）。
  解决: rc 与输出**一致**才下结论 —— 进程存在 = rc=0 + pid；不存在 = rc≠0 + 空；
  两者不一致（命令未真正执行 / 输出被包装层吃掉）判 **undetermined**，不判 FAIL。
  症状 B（排查过程中的假信号，必须记下来）: 用 `pgrep -f <pattern>` 替代 `pidof` 时，
  它会匹配到**自己的命令行**——对 `zzz_nonexistent_zzz` 也返回 pid。实测同一时刻
  `pgrep -f <app-substring>` 给 28109 / 28143（每次不同），而 `ps -A | grep -c` 为 0。
  ⇒ **`pgrep -f` 不能用作进程存在性判据**；`pidof` 在该设备工作正常（对 init 返回
  `1 238`），当时 rc=1 是**正确**答案（应用确实没跑）。
  症状 C: L4 符号错配曾被标 `<== BLOCKING`，而同一份输出里 `blocks_attach=false`
  （只有 L2 真拦 attach）——两个说法互相打脸。解决: L2 标 `BLOCKS ATTACH`，其他层标
  `FIRST FAILING (does not block attach)`。
  → `lua/ue/dap/_android_policy.lua`（rc/输出一致性判定）;
    `lua/ue/dap/capability.lua`（format_report 的两种标记）;
    行为测 `tests/cases/dap_failure_layer_spec.lua`

- **K64 — versionCode 相同 ≠ 符号匹配：必须比 build-id（2026-09-04 实测）**
  层归属: **L4 符号语义**。
  症状: 3.6 工程的 `packageInfo.txt` 与符号包目录名都是 `<code-A>`，看起来完美匹配，
  但它们**不是同一次构建**的产物。
  决定性证据（同一 `versionCode=<code-A>` 下存在 **5 个不同 build-id**）:
  | 产物 | build-id |
  |---|---|
  | Shipping so / 符号包 `<Target>_Symbols_v<code>` | `0517eb87…289ea1` |
  | Test so / Test apk | `4dbe8406…a8a355` |
  | Testarm64 apk | `3f8a49ac…3fc6a3` |
  | gpudiag apk | `a8b76e22…050c36f3` |
  | 裸 `<Target>-arm64.so` | `df611845…e87f4567` |
  根因: **versionCode 来自打包配置，build-id 来自链接产物**。同一个版本号下可以反复
  重链出任意多个不同二进制。只比 versionCode 会给出「match」的**假信号**，
  而断点仍会解析到错误二进制 —— 与 **K55**（iOS: Mach-O/dSYM UUID 相等才是判据）同构。
  解决约束: 符号一致性判据**以 build-id 为权威**，versionCode 只是必要条件：
  两边 build-id 都拿到 ⇒ `match`/`mismatch`；只有 versionCode ⇒ 最强结论只能是
  **`weak-match`**，MUST NOT 宣称已验证（反映到用户可见文本：
  `versionCode equality alone does not prove same-build`）。
  build-id 用**纯 Lua** 读 ELF note（不引入新依赖、不调外部工具）。
  实现坑（实测踩过）: ELF note 布局是 `namesz(4) descsz(4) type(4) name desc`，
  相对 name 起点 `at`，**descsz 在 `at-8`**（`at-12` 是 namesz）。把偏移写成 `at-12`
  会读到 4，长度校验不过于是函数**静默返回 nil**——看起来像「该文件没有 build-id」。
  另一条同时修正的措辞问题: `run-as: unknown package: <pkg>` 意为**根本没安装**（换设备/
  换工程的常见情形），与「已安装但 run-as 被拒」是两件事，处置也不同
  （去装 vs 去换可调试构建）；把前者报成「可能不是 debuggable」会把人往错方向引。
  → `lua/ue/dap/_android_policy.lua`（`read_build_id` / `symbol_match_verdict` /
    `run-as-available` 的 unknown-package 分支）; 行为测 `tests/cases/dap_failure_layer_spec.lua`

- **K65 — 符号库选择必须消费引擎 cache 里的构建配置，不得只按 versionCode猜
  （2026-09-04 用户指出）**
  层归属: **L4 符号语义**。
  症状: 在一个 `target_configuration = Test` 的工程上，符号库自动选择**静默选中了
  Shipping 的符号包**，于是断点会解析到用户**从未构建也从未要求**的配置上。
  证据链（均为本机实测）:
  | 来源 | 值 |
  |---|---|
  | 引擎 cache `target-default.json` / 项目 bucket `target-selection.json` | `Android` / **`Test`** |
  | Test 产物 so build-id | `4dbe8406…a8a355`（**应当匹配的目标**） |
  | Shipping 产物 so build-id | `0517eb87…289ea1` |
  | 现存符号包 build-id | `0517eb87…289ea1` ⇒ 属于 Shipping |
  根因: `pick_symbol_lib` 只按 `packageInfo.txt` 的 versionCode 匹配，**从不读
  `target_configuration`**（实测：整个 `lua/ue/dap/android.lua` 对 `configuration` 零引用）；
  而旧注释还写着 versionCode 匹配“guarantees the symbols correspond to the installed
  APK”——该说法已被 **K64** 证伪。对比：`lua/ue/targets/android.lua` **早己**用
  `configuration` 构造产物名并校验 receipt 的 `Configuration`，DAP 层绕过了这套契约。
  解决约束: 关联链必须是
  **引擎 cache 的 `target_configuration` → 该配置的产物 so → 其 build-id → build-id 相同的符号包**。
  versionCode 仅用于先收窄候选集（必要不充分）。产物命名**复用 target 层已确立的规则**
  （`<Target>-Android-<Cfg>-arm64.so`；`Development` 不带配置后缀），不另造一套。
  **关键判断**: 有期望 build-id 却无候选命中（或多个命中）时 **拒绕而非降级猜**——
  错的符号比没有符号更危险（断点看似生效却指向另一个构建）；只有在拿不到期望
  build-id（该配置的产物 so 不在本地）时，才退回 versionCode 弱匹配且仅接受唯一候选。
  → `lua/ue/dap/_android_symbols.lua`（`artifact_so_name` / `expected_build_id` /
    `select_by_build_id`）; `lua/ue/dap/android.lua`（`pick_symbol_lib` 消费
    `ctx.state.target_configuration`）; 行为测 `tests/cases/dap_failure_layer_spec.lua`

### 工具链 / LLVM

- **K57 — 22.1.6 pin 上裸 `script` 命令直接把 lldb-dap 打崩；`import lldb` 仍然不可用
  （2026-09-03 实测）**
  症状: 在 `initCommands` / `attachCommands` 里放任意裸 `script …`（`script 1` /
  `script print(1)` / `script import lldb`），`C:/tools/lldb-22/install/bin/lldb-dap.exe`
  以 `0xC0000409`（STATUS_STACK_BUFFER_OVERRUN / fail-fast）退出，`launch` 请求**永远
  拿不到 response**，会话静默死掉——从 UI 看就是「按了 `<Space>da` 什么都没发生」。
  对照组（同一 build 全部存活）：`version`、`expression 1+1`、
  `settings show target.language`、`command script import <path>`（路径存在与不存在都行）。
  ⇒ 崩溃专属于 `script` 命令进 embedded interpreter 的入口，不是「用了 python」本身。
  同时实测: 对一个内含 `import lldb` 的 .py 执行 `command script import` 报
  `error: module importing failed: … ModuleNotFoundError: No module named 'lldb'`
  （**非致命**，attach 继续）。即 21.1.8 的 no-python 限制在 22.1.6 pin 上**仍然成立**，
  `UE4DataFormatters_2ByteChars.py` 依旧加载不了，`lua/ue/dap/android.lua` 里的
  native `type summary` 兜底仍是承重结构。
  细节（别混淆两件事）: 这个 build **不是** nopython liblldb —— `liblldb.dll` 确实
  import `python311.dll` 且该 DLL 在 PATH 上可解析；缺的是 `lldb` **python 包**：
  install 树只有 `bin/`，没有 `lib/site-packages/lldb`，而那正是
  `lldb_python_relative_paths()` 探的目录。所以「python-linked」≠「`import lldb` 能用」，
  现有 `has_python` 门禁探包而不探 DLL，是对的。
  约束: Android 路线只发 `command script import`，不受影响；`lua/ue/dap/ios.lua` 确实发
  裸 `script`，但它跑在 macOS lldb 上而非本 Windows pin——**该路线未测，待验证**。
  → `docs/TOOLING.md` §"Known limitation: no Python bindings"；
    `lua/ue/dap/android.lua`（`has_python` 探针与 native `type summary` 兜底）

- **K41 — 依赖路径向上发现的 `.clangd` / monolithic External index → 覆盖漂移与资源失控**
  症状: UEPrepare 重生成 CDB 后 clangd `-j=24` 高 CPU/内存常驻（历史同类症状 17GB/32min）；
  `%LocalAppData%/clangd/index` shard 无界增长，或 `gd` 只有正确 USR 却停在 declaration。
  根因: `.clangd` 按源文件路径向上查找，跨根 TU 可漏掉 `Background: Skip`；另一方面，
  真实实验已证明 `clangd-indexer` YAML 中存在 `.cpp` Definition 不等于 `External.File`
  经 LSP 一定返回 body，不能把 binary index 当跨 TU definition authority。
  解决: clangd 固定 `--enable-config=false`，不再写 `.clangd`、不传 `--index-file`；current/hot/full
  发布带 generation/coverage manifest 的 controlled BackgroundIndex CDB，只接受
  compiler-authored UBT unity membership 或 exact per-file fallback，并通过官方
  `compilationDatabaseChanges` 注入打开文件 exact command。phase artifact 可携带 portable
  unity provenance，但发布给 clangd 的 JSON CDB 必须剥离非标准字段；generation hash 的 map
  key 必须 canonical 排序，不能受 Lua 进程 hash randomization 影响。source 不在 synthetic CDB 时，
  exact-command 首次传输必须有界重开已 attached buffer，使 cold AST 不继续使用邻近 TU 推断命令。
  clangd 的 prepare gate 必须消费持久化 tuple artifact readiness：selection/manifest/controlled CDB 与
  源 CDB 签名仍匹配时，Nvim 重启后直接复用；不得把“当前 Lua 进程执行过 UEPrepare”当作资格。
  同进程内工件发生变化也必须重新验证，缺失/stale 才 defer。
  exact argv 证明 `.cpp/.h` 实际为 Objective-C++ 时，必须保留 C++ Tree-sitter 并叠加内置 `objcpp`
  syntax；禁止把 mixed source 整体交给仅继承 C 的 `objc` Tree-sitter grammar，普通平台不得受影响。
  definition 的最终权威是
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
    `openspec/changes/archive/2026-08-08-make-cpp-gd-semantically-complete/`

- **K43 — 把“会话全局”和磁盘全局混为一谈 → 多实例串项目 / 丢状态 / 撕裂缓存**
  症状: 两个 Neovim 指向同一 engine 时，旧的顶层 `state.json` 让后写实例改变另一个实例的
  project/platform；共享 JSON 的无锁 read-modify-write 丢字段；两个 prepare/cindex writer
  争用同一输出；固定日志名互相 truncate/rotate。
  解决: `vim.g` 只作为**当前 Neovim 进程**状态；project/platform 选择在进程内捕获，
  `selection.json` 只给未来进程提供启动默认值；持久数据按 canonical project path 分桶，
  platform-sensitive CDB/clangd 产物再按 platform 分桶；独立字段/definition cache 使用原子
  per-key 文件，共享集合用 lease 下 merge，prepare/CDB/csearch 用跨进程 writer lease，诊断日志
  带 PID。旧顶层 state 只读迁移，禁止继续作为写入真相。
  → `lua/ue/project_state.lua`; `lua/ue/file_lock.lua`;
    `openspec/specs/multi-instance-state-isolation/spec.md`

- **K50 — nvim-dap 固定 `dap*.log` 且以 `w+` 打开 → 两实例互相截断调试证据**
  症状: 自定义 UE 日志已按 PID 分路，但 nvim-dap 上游 `dap.log.create_logger()` 仍在
  首次创建时直接 `io.open(stdpath('cache')/<name>, 'w+')`，同时调试的第二个 Neovim
  会清空第一个的 main/stdout/stderr log。
  解决: `workarounds.dap.pid_scoped_logs` 必须在 `require('dap')` 前安装，统一将
  `*.log` 改写为 `*.<pid>.log`；`:UEDAPDiag` 只读当前 PID 的真实路径。
  → `lua/workarounds/dap/pid_scoped_logs.lua`; `lua/plugins/dap.lua`

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

- **K27 — 切项目/平台后 grep 缓存维度错误**
  症状: `UESetPlatform` 走 fast-swap 只 flip cdb shard，csearch/workspace_all 原封不动；
  `UESetProject` 换引擎（engine_root 未持久化）时 engine 维度判不出"变了"。
  解决: canonical project path 是第一层缓存维度；不同 project（即使共用 engine 或同名）
  落不同 bucket。csearch/workspace_all 在**同一 project 内平台无关**，切平台复用；gtags 与
  CDB/clangd/PCH 在 project bucket 内继续按 platform+configuration 分片。切项目只切换活跃
  bucket 并保留旧项目缓存，不删除、不把旧 project 的状态带入当前进程。
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
| DAP 适配器（iOS） | **selected Xcode Apple `lldb-dap`** | iOS 17+ 使用 CoreDevice device/PID attach；pre-iOS17 使用 validated MobileDevice bridge。session 冻结 backend/adapter，禁止 Homebrew、Mac 或跨 backend fallback。 | `docs/TOOLING.md` §"macOS host and iOS application workflow" |
| lldb-server（Android） | **NDK 27 LLDB 18.x**（aarch64-android，platform server） | 当前 K30/K56 路线：`run-as <pkg> /data/data/<pkg>/lldb-server platform --server --listen "*:<port>"`（**app uid**，sandbox 副本；`/data/local/tmp` 仅作 push 中转），由 host serial-form `platform connect` 拉起目标 gdbserver；`gdbserver --attach` 路线已证伪。`default_lldb_server_paths()` 以 NDK27 platform server 为首选；**不得**因 `lost connection` 降级 device server 版本（K56）。 | `docs/TOOLING.md` §"Current Android DAP status" |
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
2. **async 优先于阻塞，且不得占满宿主** —— 多秒等待 OK，阻塞主线程不 OK；本配置启动的重活也不得把机器 CPU 占满到编辑器不可用（P6 首要原则，资源让路优先于功能尽快完成）。
3. **workaround 隔离** —— 仅为绕过上游 bug 的代码进 `lua/workarounds/<scope>/<name>.lua`。
4. **可自验证模块** —— 公共 API 挂 `M.*`，可 headless 测试（`nvim --headless -l`）。
5. **不做周期性 ticker 通知** —— 至多 start + 中段更新，成功后自然消退，不刷 `:messages`。
6. **未变更时跳过写入** —— 每个生成器（CDB / manifest / PCH）写前先比对，避免使下游 cache 失效。
7. **Facade / workflow 归属可审计** —— `ue.lua` 只做公共上下文、registry 查询与命令入口；
   target-specific 副作用编排必须落在 `lua/ue/workflows/<target>/`；`lua/ue/targets/<target>.lua`
   只允许 pure plan/parser/policy contract，不得执行命令或 UI。`ue_platform_boundary` 的 Tree-sitter AST
   contract 守门 façade / workflow / target 边界，`tests/cases/stability_spec.lua` 负责 `ue.lua`
   numeric ratchet 与新 workflow 文件 800 行上限。
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
**回归红灯优先**：全量回归存在任何 FAIL 时，处置它（修复 / 立 change / 记录不处理理由）MUST 先于推进无关新工作；
宿主相关失败 MUST 按**宿主能力守卫**用例（与 fail-closed 语义一致），MUST NOT 注入假可执行文件/假宿主让断言「碰巧通过」。
**强制入口在根 `AGENTS.md` 的 Definition of Done**（Claude 侧经根 `CLAUDE.md` 的 `@AGENTS.md` 展开读同一内容）；映射速查在 `tests/AGENTS.md`；权威细则在 `docs/testing-regression.md`。
→ 根 `AGENTS.md` (Definition of Done); `docs/testing-regression.md`; `tests/AGENTS.md`

### C7 — 改动记录政策（changelog）

每次落地的改动（即便一行补丁）**MUST 在 `docs/changelog.md` Unreleased 追加一条**，用既有模板
（`### YYYY-MM-DD — 标题` + Task / Implemented / Pitfalls / Validation / Follow-ups）。Implemented 含具体
文件路径与函数名；**Validation 写明所跑回归范围与结果**（与 C6 联动）**以及本次 spec 一致性处置**
（同步 spec / 立 change / 判定无 spec 影响，与 C9 联动）。攒够 8–12 条或一项连贯工作收尾
即切片归档（见 C8）。
→ 根 `AGENTS.md` (Definition of Done); `docs/changelog.md` (Entry template / How to use)

### C8 — milestone（版本里程碑）政策

**触发**：按 semver——含 BREAKING → major、引入新能力 → minor、仅修复/小改 → patch；版本号续
`v1.0.3` 不跳号。**产出物四件套（缺一不算 milestone）**：① 生成 `docs/release_vX.Y.Z.md`（沿用
`docs/release_1.0.0.md` 格式）+ changelog Unreleased 切片归档 + Released 加交叉链接 + 清空 Unreleased；
② milestone 前跑**全量回归门禁** `nvim --headless -l tests/run.lua` 全绿，且确认所有已落地行为变更
均已反映到 `openspec/specs/`（无未同步的 spec 漂移）；③ 打 git tag `vX.Y.Z`
（**tag/commit 须用户确认**，遵守本仓 git 政策，不自动执行）；④ 若动了架构/子系统边界，同步
`memory/` 与 `docs/architecture/overview.md`。
→ 根 `AGENTS.md` (Definition of Done); `docs/changelog.md` (Released); `docs/release_1.0.0.md` (格式范例)

### C9 — spec 一致性属于完成定义（spec 是行为权威）

`openspec/specs/<capability>/spec.md` 是**可观察行为的权威契约**。**SESSION START MUST 包含
「读改动范围对应的 spec」一步**（按范围读，不遍历全部 spec；从 `memory/project_overview.md`
子系统速查表的「治理 spec」列一步定位）。**改动落地前 MUST 满足 spec 与实现一致**：行为变更
同步对应 spec 或立 change；**spec 落后于已验证正确的实现时反向更正 spec**；只改实现不动 spec
的收尾不算完成。本文档与各目录本地规则**不得与 spec 冲突**（冲突以 spec 为准；冲突源于 spec
陈旧则先更正 spec）。spec 与规则文档中的**仓内路径引用 MUST 真实存在**（`structure` filter 的
spec 引用完整性用例守护）。强制力入口在根 `AGENTS.md` 的 Definition of Done 第 2 条。
**禁止为让某一个 agent 生效而新增第四份并行入口文件**（Claude/Codex/pi 三端只从 `AGENTS.md`
层级读取；各目录 `CLAUDE.md` 只能是 `@AGENTS.md` stub）。
→ 根 `AGENTS.md` (Definition of Done); `openspec/specs/spec-authority-loop/spec.md`;
  `memory/project_overview.md` (治理 spec 列); `tests/cases/structure_spec.lua`

### C10 — DAP 归属分层契约（失败先报层，再给处置）

**为何分层**：34 条 DAP 坑（K1–K61）按契约归属方统计，**只有 8 条是本仓自己的 bug**；
9 条是目标 OS 策略、10 条是调试引擎、6 条是编辑器管道——即**多数不是我们能修的，
而是我们没建模的外部契约**。分层的作用是一步区分这两类，而不必每次现场取证。

| 层 | 内容 | owner | 典型坑 |
|---|---|---|---|
| **L0** 宙主工具链 | adapter 可解析、版本、python 包 | `lua/utils/platform/*` | K14 K57 |
| **L1** 传输 | adb/设备可达、serial 捕获、forward | `lua/utils/android_device.lua` | K36 |
| **L2** 目标 OS 策略 | 执行权限、ptrace、SELinux、sandbox、签名 | 各 target owner（`dap/android.lua` 等） | **K56 K58** K12 K38 K3 K55 |
| **L3** 调试引擎 | platform connect / attach / 命令序列 | `dap/_common.lua` + lldb | K31 K32 K37 K2 |
| **L4** 符号语义 | slide 解析、bp resolved、dSYM/versionCode | `dap/android.lua`、`dap/ios.lua` | K35 K37 K55 |

**纪律**：任何用户可见的 DAP 失败 MUST 携带 `{layer, owner, evidence, remedy}`，且
**先呈现层与 owner，再呈现处置**；MUST NOT 发出不带层归属的失败；层不可判定时
**显式标注未判定**并给出判定手段，**MUST NOT 猜一个层**。evidence MUST 是命令 + 输出，
不是结论文本。设备能力 MUST 由**探测**得出（以将要执行动作的**那个身份**探测），
MUST NOT 沿用单台设备的结论。attach MUST 先过 L2 门禁再连接调试引擎（L2 是唯一
「红灯却表现为 L3 症状」的层）。
**新增一条 DAP 坑时 MUST 标注其归属层**（见 §六 第 2 条）。
→ `openspec/specs/dap-failure-layering/spec.md`（正文权威）; `lua/ue/dap/AGENTS.md`（就地可发现）;
  `docs/TOOLING.md`（排查入口）; `tests/cases/dap_failure_layer_spec.lua`

---

## 五、持久化知识库与本地规则（AI 可发现性）

为让持续介入的 AI agent **从文件而非 chat 历史**发现规则，本仓提供：

- **强制执行入口（单一内容源）**：根 `AGENTS.md` 是 Claude Code / Codex / pi **三端共用的唯一内容源**
  （SESSION START 协议：动代码前先读探针反馈 → `docs/CONSTRAINTS.md` → `memory/project_overview.md` →
  当前目录本地规则 → **改动范围对应的 `openspec/specs/<capability>/spec.md`**；+ Definition of Done）。
  根 `CLAUDE.md` 内容仅为 `@AGENTS.md` 导入 stub（Claude 只读 `CLAUDE.md`，由该 import 展开读同一
  内容；Codex 与 pi 原生读 `AGENTS.md`）。**禁止为让某一个 agent 生效而新增第四份并行入口文件。**
- **递归本地规则（单一内容源）**：每个主要目录一份 `AGENTS.md`（权威内容源），同目录一份
  `CLAUDE.md`（内容为 `@AGENTS.md` stub）。子级只写相对父级的增量；某目录无本地规则时，
  适用**最近祖先目录**的规则（回落语义）。**只维护 AGENTS.md 一个文件，改一次两端同步**——
  不再有「改 CLAUDE 又改 AGENTS」的双份维护。
- **持久化知识库四区**：
  - `memory/project_overview.md` — 项目总览 + 子系统速查 + 先读顺序。
  - `decisions/README.md` — 架构决策(ADR)导航（权威正文在 `docs/plans/`）。
  - `lessons/README.md` — 平台怪癖/调试硬知识导航（权威在本文件 §二）。
  - `docs/architecture/overview.md` — 架构总览（子系统/数据流/平台层/构建流水线/归属边界）。
- **行为契约权威（spec）**：`openspec/specs/<capability>/spec.md` 是**可观察行为的权威**；
  本文档与各目录本地规则**不得与之冲突**（冲突时以 spec 为准；若冲突源于 spec 陈旧，
  先更正 spec 再对齐规则）。从「改动哪个目录」一步定位治理它的 spec：见
  `memory/project_overview.md` 子系统速查表的**「治理 spec」列**（与 `tests/AGENTS.md` 的
  CHANGE-TO-FILTER MAP 同源对齐）。权威机制见 `openspec/specs/spec-authority-loop/spec.md`。
- **可发现性回归**：`tests/cases/structure_spec.lua` 守护「目录规则存在（AGENTS.md 源 +
  CLAUDE.md stub）+ 知识库结构完整 + 内链不悬空 + spec 引用不悬空 + capability 覆盖映射
  可解析 + 政策可发现」，跑 `structure` filter。

---

## 六、维护契约

本文档是**索引**，靠下面的规矩防腐烂:

1. **新增一个 workaround** → 在 [§二 snacks/clangd/lazy](#snacks--clangd--lazy活跃-workaround共-9-个文件) 加一行
   （症状 + 文件出处）；文件本身的 frontmatter 仍是权威出处。
2. **踩到一个新坑** → 在 §二 对应分类加条目，必须含 **症状 + 解决约束 + 出处指针**；
   并在 `lessons/README.md` 对应领域补一句主题导航。**DAP 类坑还 MUST 标注其归属层**
   （L0–L4，见 §三 C10），使读者能判断该坑是**外部契约**还是**本仓缺陷**。
3. **改动版本钉死项 / 约定 / 启动顺序** → 同步更新 §三，并保持指向 `docs/TOOLING.md`
   / `README.md` / `init.lua` 的出处链接。
4. **新增子系统目录 / 迁移知识** → 为新目录补一份本地 `AGENTS.md`（内容源，声明继承父级）
   **并补一个 `CLAUDE.md`（内容为 `@AGENTS.md` stub）**，
   在对应知识区 README 登记；`structure_spec` 的目录清单同步。
5. **新增 spec / 改命令清单** → 同步 `tests/AGENTS.md` 与 `docs/testing-regression.md` 的 filter 映射、
   `memory/project_overview.md` 的「治理 spec」列，及 `commands_spec` 冻结清单。
5b. **改动改变了 spec 已声明的可观察行为** → 同步更新对应 `openspec/specs/<capability>/spec.md`
   或立一个承载该 spec 变更的 change；若发现 spec 落后于已验证正确的实现，则**反向更正 spec**。
   两种处置都必须在 `docs/changelog.md` 的 Validation 字段留痕（见 C7）。
5c. **spec 或规则文档引用的仓内文件被删除/重命名/归档** → 同步更正该引用（或更正 spec 的产出物
   要求）；`structure_spec` 的 spec 引用完整性用例守护「引用不悬空」。
6. **milestone 收尾** → 须同步 `memory/` 与 `docs/architecture/overview.md`（若动架构），并按 C8 产出四件套。
7. **出处优先**: 不在此复制原文；摘要与出处冲突时以出处为准。删除某 workaround/坑
   时，对应行随 `git rm` 一并删除。
8. **公开镜像安全**: 新增条目不得引入 secret 或新的私有专属路径
   （`C:\tools\...` 等已在 `docs/TOOLING.md` 公开者除外）。
