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
| P11 | **goto-def 不让 treesitter 给"答案"** | TS 没语义，跨翻译单元 / 模板 / macro 都看不见；TS 只做"省调用"判定，绝不替代 LSP 给精确定义（racing-goto-definition 死路）。 | `docs/architecture-symbol-resolution.md` §5、§6 |
| P12 | **csearch / gtags 不做主路** | 文本/ctags 搜索分不清重载、同名、namespace；只能在 clangd MISS 时兜底。 | `docs/architecture-symbol-resolution.md` §6 |
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
  → `docs/TOOLING.md` §Pitfalls #10; `lua/ue/dap/_persist_bp.lua`

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
    `git show e51cbe6:lua/ue/dap/android.lua`

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

- **K33 — source-file `breakpoint set -f <f> -l <N>` 崩溃 lldb-dap 22.1.6（待 platform 路径复验）**
  症状: 在直连 gdb-remote attach 路径下，attachCommands/post-attach 的 source-file
  `breakpoint set` 让 lldb-dap 在 DWARF 索引后退出 `3221226505`
  （STATUS_STACK_BUFFER_OVERRUN）。
  解决: 接通断点需在 attach 稳定后选 preseed 或 address 断点（`image lookup --line` →
  `breakpoint set --address`）；判据见归档 change 的 handshake-diagnostics "正解 vs
  workaround"。注: 该崩溃在 gdb-remote 路径观察到，platform 路径下是否仍崩需复验。
  → 归档 change `2026-06-03-android-dap-attach-bp-fix` / `-handshake-rootcause`

### 工具链 / LLVM

- **K14 — LLVM 22.0–22.1.5 的 `lldb-dap.exe` 在 Windows 启动崩溃**
  症状: DAP client 一发 `initialize` 就 `STATUS_STACK_BUFFER_OVERRUN`(`0xC0000409`)。
  根因: `liblldb.dll` 的 `NativeFile` ctor 在 pipe FD 上调 `_get_osfhandle`，跨 CRT。
  解决/现状: 当前用 **codelldb 1.12.2**（自带 patched liblldb，不受影响）。
  → `docs/TOOLING.md` §"lldb-dap" + §"Active adapter (codelldb 1.12.2)"
  （LLVM #178155 / fix #195855 未 backport 到 release/22.x）

- **K15 — 适配器迁移弧线（别照退役钉死项行事）**
  历史: lldb-dap 21.1.8 side-load → **codelldb 1.12.2（当前）** → （git 上另有 lldb-dap
  22.x platform-mode 探索分支）。`docs/TOOLING.md` 顶部 21.1.8 段落是**历史参考**，
  其 `STATUS_STACK_BUFFER_OVERRUN` 分析仍有价值，但**当前生效的适配器是 codelldb 1.12.2**。
  → `docs/TOOLING.md` 状态横幅; git log（`b9cce1d` merge `feat/lldb-dap-migration`、
  `7c70462`、release_1.0.3）

### snacks / clangd / lazy（活跃 workaround，共 9 个文件）

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

- **K21 — Lazy float 在 VimResized 时 invalid buffer**
  症状: 刚关掉 Lazy float 后窗口 resize（Neovide 启动 / zen-mode / split），报
  `lazy/view/float.lua:180: Invalid buffer id: N`。
  → `lua/workarounds/lazy/float_vimresized_invalid_buf.lua`（init.lua eager apply）

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
  → `docs/architecture-symbol-resolution.md` §2.7; commit `252e9e0`

---

## 三、约束（Constraints）

承重项。所有贡献都必须遵守。

### C1 — 工具链版本钉死

| 组件 | 版本 | 备注 | 出处 |
|------|------|------|------|
| clangd / clang | **LLVM 22.1.x**（22.1.5 verified） | **不要降级到 21.x** —— super-unity CDB pipeline 与 `.idx` 格式依赖 22.x 行为 | `docs/TOOLING.md` §clangd |
| DAP 适配器 | **codelldb 1.12.2**（当前） | 自带 patched liblldb；不需要 PATH 上的 `python310.dll`。路径解析见 `lua/utils/platform/windows.lua` `default_codelldb_paths()`，可经 `ue.config` `dap.codelldb_path` 覆盖 | `docs/TOOLING.md` §"Active adapter" |
| lldb-server（Android） | **NDK 21.4.7075529**（LLDB 9.0.9, aarch64-android） | 必须匹配 libUE4.so 构建 NDK；NDK27/AS-bundled 在该 UE 目标 `gdbserver --attach` 会 Segfault（a3ad86f3 实测）。`default_lldb_server_paths()` 已钉 NDK21 首选 | `docs/TOOLING.md` §"Android lldb-server (current)" |
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
6. **未变更时跳过写入** —— 每个生成器（CDB / PCH / .clangd）写前先比对，避免使下游 cache 失效。
→ `README.md` §Conventions

### C5 — 符号解析分层契约

- 链路: `treesitter 早退` → `cache` → `clangd(LSP)` → `csearch` → `gtags`，按
  "省调用 → 命中精度 → 兜底覆盖" 串成单链。
- cache 承载约 **70%** 请求；cache HIT 路径 = lua table lookup + jumper.jump，**不动任何子进程**。
- `.usf` / `.py` / `.Build.cs` 直接走 gtags，跳过 clangd 与 csearch。
- **每一层失败都必须 fall through**，绝不让用户看到 `lua error in lsp_fallback`；最终兜底 toast "no def"。
- clangd 永远是权威源但永不前台阻塞: spinner 600ms 后才显示，30s 硬超时。
- jumper 后置条件: 一个 `<Ctrl-O>` 回到源、恰好一条 jumplist 条目、无 `(target_buf,1,0)` 幽灵。
→ `docs/architecture-symbol-resolution.md` §1、§5、§2.7

### C6 — 改动后回归政策（分范围）

任何 `.lua` 运行时代码或 `tests/` 改动，**完成前 MUST 跑对应范围回归并全绿**。按改动类型跑
**最小必跑范围**（改动 → spec filter 映射），但 **① 提交/合并前必跑全量；② 影响面不确定升级到全量，不猜窄 filter**。
新增功能 MUST 补 `*_spec.lua`；冻结清单（`commands_spec` 的 `UE_COMMANDS`、`structure_spec` 目录清单）随相关项变化同步。
**强制入口在根 `CLAUDE.md` 的 Definition of Done**；映射速查在 `tests/CLAUDE.md`；权威细则在 `docs/testing-regression.md`。
→ 根 `CLAUDE.md` (Definition of Done); `docs/testing-regression.md`; `tests/CLAUDE.md`

### C7 — 改动记录政策（changelog）

每次落地的改动（即便一行补丁）**MUST 在 `docs/changelog.md` Unreleased 追加一条**，用既有模板
（`### YYYY-MM-DD — 标题` + Task / Implemented / Pitfalls / Validation / Follow-ups）。Implemented 含具体
文件路径与函数名；**Validation 写明所跑回归范围与结果**（与 C6 联动）。攒够 8–12 条或一项连贯工作收尾
即切片归档（见 C8）。
→ 根 `CLAUDE.md` (Definition of Done); `docs/changelog.md` (Entry template / How to use)

### C8 — milestone（版本里程碑）政策

**触发**：按 semver——含 BREAKING → major、引入新能力 → minor、仅修复/小改 → patch；版本号续
`v1.0.3` 不跳号。**产出物四件套（缺一不算 milestone）**：① 生成 `docs/release_vX.Y.Z.md`（沿用
`docs/release_1.0.0.md` 格式）+ changelog Unreleased 切片归档 + Released 加交叉链接 + 清空 Unreleased；
② milestone 前跑**全量回归门禁** `nvim --headless -l tests/run.lua` 全绿；③ 打 git tag `vX.Y.Z`
（**tag/commit 须用户确认**，遵守本仓 git 政策，不自动执行）；④ 若动了架构/子系统边界，同步
`memory/` 与 `docs/architecture/overview.md`。
→ 根 `CLAUDE.md` (Definition of Done); `docs/changelog.md` (Released); `docs/release_1.0.0.md` (格式范例)

---

## 五、持久化知识库与本地规则（AI 可发现性）

为让持续介入的 AI agent **从文件而非 chat 历史**发现规则，本仓提供：

- **强制执行入口**：根 `CLAUDE.md` 的 SESSION START 协议（动代码前先读
  `docs/CONSTRAINTS.md` → `memory/project_overview.md` → 当前目录 `CLAUDE.md`）+ Definition of Done。
- **递归本地规则**：每个主要目录一份 `CLAUDE.md`，子级只写相对父级的增量；
  **目录无 `CLAUDE.md` 时回落最近祖先目录的规则**。
- **持久化知识库四区**：
  - `memory/project_overview.md` — 项目总览 + 子系统速查 + 先读顺序。
  - `decisions/README.md` — 架构决策(ADR)导航（权威正文在 `docs/plans/`）。
  - `lessons/README.md` — 平台怪癖/调试硬知识导航（权威在本文件 §二）。
  - `docs/architecture/overview.md` — 架构总览（子系统/数据流/平台层/构建流水线/归属边界）。
- **可发现性回归**：`tests/cases/structure_spec.lua` 守护「目录规则存在 + 知识库结构完整 +
  内链不悬空 + 政策可发现」，跑 `structure` filter。

---

## 六、维护契约

本文档是**索引**，靠下面的规矩防腐烂:

1. **新增一个 workaround** → 在 [§二 snacks/clangd/lazy](#snacks--clangd--lazy活跃-workaround共-9-个文件) 加一行
   （症状 + 文件出处）；文件本身的 frontmatter 仍是权威出处。
2. **踩到一个新坑** → 在 §二 对应分类加条目，必须含 **症状 + 解决约束 + 出处指针**；
   并在 `lessons/README.md` 对应领域补一句主题导航。
3. **改动版本钉死项 / 约定 / 启动顺序** → 同步更新 §三，并保持指向 `docs/TOOLING.md`
   / `README.md` / `init.lua` 的出处链接。
4. **新增子系统目录 / 迁移知识** → 为新目录补一份本地 `CLAUDE.md`（声明继承父级），
   在对应知识区 README 登记；`structure_spec` 的目录清单同步。
5. **新增 spec / 改命令清单** → 同步 `tests/CLAUDE.md` 与 `docs/testing-regression.md` 的 filter 映射，
   及 `commands_spec` 冻结清单。
6. **milestone 收尾** → 须同步 `memory/` 与 `docs/architecture/overview.md`（若动架构），并按 C8 产出四件套。
7. **出处优先**: 不在此复制原文；摘要与出处冲突时以出处为准。删除某 workaround/坑
   时，对应行随 `git rm` 一并删除。
8. **公开镜像安全**: 新增条目不得引入 secret 或新的私有专属路径
   （`C:\tools\...` 等已在 `docs/TOOLING.md` 公开者除外）。
