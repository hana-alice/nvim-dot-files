# Neovim Config Changelog

Working log for every change inside `~/AppData/Local/nvim/`. Every commit
should add an entry here even if it's tiny — the goal is total recall across
sessions, not curated release notes. When entries pile up, slice off a
versioned `RELEASE_vX.Y.Z.md` (see `release_1.0.0.md` for the format) and
keep this file rolling forward as the unreleased section.

## Entry template

```
### YYYY-MM-DD — Short title

**Task** (one line — why you touched the config)

**Implemented**
- bullet list of concrete changes (file paths + function names)

**Pitfalls / Gotchas**
- traps hit during the change, with the fix

**Validation**
- how you proved it works (headless probe, live nvim test, etc.)

**Follow-ups**
- links to `.hermes/plans/*.md` or TODO bullets
```

## How to use

1. Before touching anything under `~/AppData/Local/nvim/`, skim the latest
   N entries here. Fresh sessions don't carry context — this is where you
   recover it.
2. After landing a change (even a one-line patch), append an entry.
3. When 8–12 entries have piled up OR a coherent multi-change effort wraps,
   move them into `docs/release_vX.Y.Z.md`, tag the commit, leave a
   one-line cross-link under "Released" below.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`

## Unreleased

### 2026-05-21 (later) — lldb-dap 22.1.6 nvim live attach 端到端验证

**Task** 接续上午"lldb-dap 22.1.6 迁移落地"。Phase 1 用 `probe_attach.py` 验过裸
DAP 协议；本次在 user 实际 Neovide nvim (PID 45484, --embed) 里跑
`:UEDAPAttach android` 完整端到端。

**Validation**
- `pynvim` 走 `\\.\pipe\nvim.45484.0` (Win 路径必须 forward-slash 形式) 探查
- 旧 nvim 缓存了过期 adapter (`C:/tools/lldb-21/...`)；强制清
  `package.loaded[ue.dap*|utils.platform*|ue.config|ue]` 后 `require('ue').setup()`
  → adapter 切到 `C:/tools/lldb-22/install/bin/lldb-dap.exe` (22.1.6)，
  `:UEDAPStop`/`:UEDAPStatus`/`:UEDAPReattach` 命令重新注册
- 装 DAP listener trace 写 `Temp/ue_dap_e2e.log`
- 多设备弹 snacks.picker（emulator + 工作机两台），
  `nvim_input('<CR>')` 确认 emulator
- 完整 attach 拿到：`has_session=true initialized=true thread_count=174`
  (qm-thread, CrashSightThread, V8 worker, hwuiTask, OkHttp 等都在)
- `_last_session` 全字段填齐 (serial=<emulator>, package=com.example.mygame,
  symbol_lib=<project>/Source/Client/Binaries/Android/<sym-dir>/Client-arm64/libUE4.so,
  source-map <build-host-path> ↔ <local-project-path>)
- `$__lldb_version: 22.1.6 fc4aad7b` 在 trace 里确认
- `:UEDAPStop` → disconnect 异步 ~3s 后 `dap.session()=nil` 干净

**Pitfalls / Gotchas**
- **Neovide --embed 不能 jobstart 重启自己**：必须用 RPC 强制清
  `package.loaded` + 手 `require('ue').setup()` 才能让正在运行的 nvim 拾起
  改过的 windows.lua / android.lua。否则跑的还是缓存。
- **`vim.fn.input` ≠ snacks.picker**：`pick_serial_async` 多设备走
  `vim.ui.select` 被 LazyVim 桥到 snacks。`nvim_feedkeys` 不进 picker
  input 的 keymap，要用 `nvim_input`（走真键盘输入循环）。
- **端到端时游戏 PID 跳了**：attach 前 PID=8238 → stop 后 `pidof` 空 → 几秒
  后看 `ps -A | grep <pkg>` 是 PID=9346 (state=S, do_freezer_trap)。
  Android 应用在 attach 期间 SIGSEGV 触发了 launcher 自动重启。
  init/preRun 里有 `process handle SIGSEGV --notify false --pass false
  --stop false` 但 trace 显示 174 个 thread 各发了一次 SIGSTOP
  event_stopped——这是 attach 时 lldb-server 自己发的 SIGSTOP，不被
  `process handle` 管。看是否需要在 platform connect 后立即 `continue`
  (open follow-up)。
- **LLDB Python 模块缺失**：`UE4DataFormatters_2ByteChars.py` 加载报
  `No module named 'lldb'`——LLVM 22.1.6 Windows 自建版本没打包 lldb python
  module。FString/TArray pretty-print 失效。可接受 caveat，记 follow-up。

**Follow-ups**
- Attach 后立刻 `continue` 让游戏不要在 SIGSTOP 状态裸奔（可能是 PID 跳的根源）
- LLDB python 模块：要么改用带 python 的 LLVM build，要么干脆改用纯 LLDB
  format string formatter (lldb-dap 支持 `command alias` 而非
  `command script import`)
- `:UEDAPStop` 杀 lldb-server 顺序：先发完 detach 再 killall，避免 ptrace
  泄漏给游戏

### 2026-05-21 — lldb-dap 22.1.6 迁移落地（删 codelldb，砍 136 行）

**Task** 端到端验证通过 (probe_bp_v13 confirmed real BP hit on FEngineLoop::Tick
on 2026-05-21) 后正式迁移：android.lua 从 codelldb + gdbserver --attach 切到
lldb-dap + platform remote-android。一次性删除全部 codelldb 路径，遵循用户
红线"不留两个并存入口"。

**Implemented**
- `lua/ue/dap/android.lua`：
  - 文件头 doctring 全段重写（codelldb→lldb-dap, gdbserver→platform mode）
  - `ensure_lldb_server_in_app` (run-as sandbox copy + ndk27 后缀) →
    `ensure_lldb_server_pushed` (PUBLIC /data/local/tmp/lldb-server)
  - `start_lldb_server_gdbserver` (sh-in-sh hack 脚本 + tracerpid 轮询) →
    `start_lldb_server_platform` (`./lldb-server platform --server --listen *:N`)
  - `pick_libue4_base` 整段删除（platform mode 自动 sync module slides）
  - `init_commands`：保留 packet-timeout / inline-breakpoint / formatter
    导入；新增 `target.exec-search-paths` 指向 host-side libUE4.so 目录，
    避免拉 device 上 stripped 副本
  - `attach_commands` 新增（codelldb 没有等价物）：4 行 platform select +
    connect + process attach --pid + 3× `process handle ... --notify FALSE`
    （CRITICAL：去 false 直接复现 1820+ stopped event 风暴 = adapter 死）
  - `lldb_dap_attach_config` 替换 `codelldb_attach_config`：type="lldb",
    request="attach", attachCommands+initCommands 取代 targetCreateCommands
    +processCreateCommands+postRunCommands
  - `_cleanup_device_side`：run-as pkill → 直接 killall（PUBLIC location 不
    需要 run-as），fallback 端口 5045→5039
  - `M.attach/launch/reattach` config name "(codelldb)" → "(lldb-dap)"
  - `M.status` 删 libUE4 base 行
  - `M._codelldb_attach_config_for_test` → `M._lldb_dap_attach_config_for_test`
- `lua/ue/dap/_common.lua` 整段删除：
  - `M.find_codelldb` / `M.ensure_codelldb_adapter` / `M.run_codelldb`
  - 该文件历史最末段 88 行 codelldb (Android route) 整体清掉
- `lua/ue/dap.lua` setup_dap：
  - 删 `C.find_codelldb()` + `C.ensure_codelldb_adapter()` 段
  - dap.configurations.cpp 默认条目 type "codelldb"→"lldb",
    request "launch"→"attach", name "(codelldb)"→"(lldb-dap)"，并兼容旧
    name 防止用户已有 launch.json 重复注入
- `lua/utils/platform/windows.lua`：删 `default_codelldb_paths()` 17 行
- `tools/test_e2e_android_codelldb.lua` → `tools/test_e2e_android_lldb_dap.lua`
  （文件 git mv + 内容 codelldb→lldb-dap 文案修整 + default port 5045→5039）

**Pitfalls / Gotchas**
- platform mode wildcard listen：`--listen *:port` 必须在 git-bash 命令行
  转义成 `\\*:port` (这里有反斜杠转义层 + sh 层 + adb shell 层)，否则
  shell glob 把 `*` 展开成当前目录里第一个文件名 → lldb-server 启动失败。
  android.lua 里我们用 `\\*:%d` 拼 string.format 后整串走 `vim.fn.system
  { adb, ..., "shell", cmd_string }`，由 adb shell 直接交给 device sh，
  避开 host-side 展开。
- `target.exec-search-paths` 是 lldb 设置项不是 dap setting，必须放在
  `initCommands` 里以 `settings set` 形式发，不能塞 dap config 顶层。
- 兼容已存在 launch.json：原来 nvim-dap configurations.cpp 里若有用户手动
  添加的 "UE Android Attach (codelldb)" 条目，现在 setup_dap 不会重复
  注入新条目（match 旧名也算 have_ue_attach）。但旧条目 type="codelldb"
  会失败 — 用户重启 nvim 即可清除。
- 不再需要 host-side libUE4.so 也能跑：lldb-dap platform mode 会从 device
  pull stripped libUE4.so 进 ~/.lldb/module_cache（一次性 3.85GB）。
  symbol_lib 现在是"强烈建议"而非"必需"，缺它仍能 attach + setBP，只是
  source 视图为空。

**Validation**
- `nvim -l scripts/headless_smoke.lua` → 97/97 passed, 0 failed
- `nvim -l scripts/lint_no_bare_globals.lua` → 95 files scanned, OK
- `lua/ ` 下死 codelldb 引用 = 0（grep
  `find_codelldb|run_codelldb|ensure_codelldb_adapter|adapters.codelldb|
   type="codelldb"` 全空）
- 4 个核心模块（ue.dap / ue.dap.android / ue.dap._common /
  utils.platform.windows）headless require 全部 OK

**净删 136 行**（5 files: 211 + / 347 -）

**Follow-ups**
- 真机端到端：装好的 nvim 跑 `:UEDAPAttach`，验完整 attach + 命中 +
  variables panel 链路。Probe 已在 lldb-dap 协议层证明可行
  (probe_bp_v13.py)，nvim/dapui 集成仍需触发一次。
- 长期：LLVM 22.2 / 23 release 出来重跑 probe_bp_v12 / v13 作 regression。
- docs/TOOLING.md 还有 codelldb 段（150-159 行），下次顺手清。

### 2026-05-21 — lldb-dap 22.1.6 platform-mode 迁移评估（**翻案**：可迁，根因不在 LLVM）

**Task** 续前一条 "驳回" 评估，用户要求 "继续追踪"。结果**翻案**：lldb-dap
22.1.6 + platform remote-android 是**可用的**，之前 100% hang 是我们 probe
脚本自己写错了 `process handle --notify true`，导致 lldb-dap 给每个 SIGSEGV
+ 每个 thread 发一个 DAP `stopped` event，1820+ event 在几百毫秒内淹没
Win32 stdio pipe → write 返回 EINVAL → adapter 死。

**Diagnosis 关键转折**
- 一直追源码、追上游 issue 都查不到对症 bug。
- **真正破案**靠在 probe 里加 `log enable gdb-remote packets`（路线 1 的
  packet log），看 hang 期间 wire 上发生啥。结果：
  - 442× `$xADDR,800` memory read
  - 458× `$qXXX` query
  - 507× `$pXX` register read
  - 只 **3× `$Z` breakpoint insert**，**全部 `$OK`！**
- 也就是说 BP 已经成功 plant 了，hang 在后续 memory/register read 风暴里。
- 交叉 LLDBDAP_LOG (internal): 临死前 250ms 内连发 1820+ `stopped` event。
- 顺藤摸瓜：我们刚 `process handle SIGSEGV --notify true` —— notify 风暴。

**验证修复**
- `probe_bp_v12.py` 改为 `--notify false`：连续两次 run
  - `setFunctionBreakpoints {"name":"FEngineLoop::Tick"}` → `success=True`
    `id=2, instructionReference=0x75AC7003D4, line=1`
  - `alive=True`，final `stopped_count=85`（vs 1820+ 风暴的死亡情形）

**bug 现场指向 `lua/ue/dap/android.lua:545-547`**
```lua
"process handle SIGSEGV --notify true --pass true --stop false",  -- 给 codelldb 还能凑合
"process handle SIGBUS  --notify true --pass true --stop false",
"process handle SIGPIPE --notify false --pass true --stop false",
```
codelldb 不死是因为它内部对 stopped 事件做了节流/合并；lldb-dap 1:1 转发，被这玩意儿淹。

**Implemented**
- `lua/ue/dap/_common.lua:179-198` 整段 "codelldb (Android route)" 注释重写：
  删掉错的 LLVM #102254/#138096/#126935 引用（那三个 issue 实际是
  NSan/clangd-hover/FD-inheritance，跟我们一点关系没有），改为引到新 skill。
- skill `software-development/lldb-dap-22-platform-mode-breakpoint-crash` **完全重写**：
  改为 "appears to crash, but root cause is --notify true; fix is --notify false"，
  含三个排除性假设的表格、packet-log 诊断方法、`probe_bp_v12.py` 作为 contract test。

**没动的**
- `lua/ue/dap/android.lua` 的 `post_run_commands` **保留 `--notify true`** —
  codelldb 路径还在用，没必要改。等真要迁 lldb-dap 时一并改。
- 不加 `use_lldb_dap` flag —— 用户红线 "两个并存入口"。

**Pitfalls / Gotchas**
- `log enable -f <file> lldb gdb-remote packets process`：channel name list 加了
  `process` 之后整个 log 被 Process layer state-machine 噪音淹没，packet line
  一个都不出。要拿 wire packet 用 `log enable -f <file> gdb-remote packets`
  单独一个 channel。
- termux LLDB 21.1.8 deb 是 GNU SONAME (`libz.so.1`)，扔 Android `/data/local/tmp`
  跑直接 `CANNOT LINK libz.so.1 not found`。dead end，记入 skill。
- `curl -C -` 续传跨 mirror 时**可能拼出比权威 Content-Length 还大的脏文件**，
  导致 lzma decompress 报 corrupt。永远先 `curl -sI` 比对 Content-Length，
  不一致就 `rm` 全新下，不要 trust resume。
- 不到非要 cross-compile LLVM 22.1.6 lldb-server for Android（"host==device
  完全同 commit"）的地步 —— 三档 device server (LLDB 9/18/21) 在错配置下
  全 hang，对配置下全通，device 版本根本不是变量。skill 记 dead end #2。

**Validation**
- `/c/tools/lldb-22/probe_bp_v12.py` 两次连续跑全过 ✅ (probe-level: attach + setBP only)
- 输出格式: `[main] func setBreakpoints: alive=True success=True`
  `final stop_count=85`
- **端到端真机命中 (probe_bp_v13)** ✅ 2026-05-21 补测：
  - 流程 DAP-spec 正确：initialize → initialized event → setFunctionBreakpoints
    → configurationDone → continue → 等 stopped(reason=breakpoint)
  - 60s 内拿到 `*** BP HIT *** reason=breakpoint tid=6273 desc="breakpoint 1.1"`
  - stack frame #0 = `FEngineLoop::Tick()` @ libUE4.so，完整调用栈到 `__pthread_start`
  - scopes (Locals/Globals/Registers) + variables 链路全通
  - stop_count=21 (远小于 hang 时 1820+ 风暴), alive=True 全程
  - stderr 0 字节，disconnect terminateDebuggee=false 干净退
  - 注意：`continue` response success 字段 = False 是 lldb-dap 已知行为，
    但 stopped event 正确到达，证明 continue 实际生效

**Follow-ups**
- 端到端已 PASS，**可以**正式 migrate android.lua → lldb-dap：
  1. `dap.adapters.lldb-dap` 替 `dap.adapters.codelldb`
  2. attach config 用 `attachCommands` 一次性塞：process attach + 3× process handle
     `--notify false`（参考 probe_bp_v13.py main() 段）
  3. 跑 `probe_bp_v13.py` 作 regression
  4. 验 libUE4 rebase 是否还需要（lldb-dap platform mode 自动 sync module
     slides，不像 codelldb 的 gdb-remote port 模式）
- 当前分支：`feat/lldb-dap-migration` (本条记录的所有改动落在这里)
- 用户红线："两个并存入口" = 红线，迁移=一次性砍 codelldb，不留 fallback

### 2026-05-21 — lldb-dap 22.1.6 platform-mode 迁移评估（验证后驳回，已被上一条翻案）

**Task** 试 LLVM 22.1.6 lldb-dap + NDK 21 lldb-server + platform remote-android，
看能否把 `lua/ue/dap/android.lua` 从 codelldb 迁到 lldb-dap stdio
（上一次 5/13 session 假设 22.1.6 修了 #102254 / #138096，让 lldb-dap 在 Android
platform mode 下可用）。**结论：迁移驳回。lldb-dap 22.1.6 + platform mode 在
首个 breakpoint plant 仍然 100% hard-crash。**

**验证产物（不改 nvim 仓库内文件）**
- `C:\tools\lldb-22\install\bin\lldb-dap.exe` (LLVM 22.1.6 私有安装, 7z 抽 NSIS)
- 设备 `/data/local/tmp/lldb-server` 替为 NDK 21.4.7075529 LLDB 9.0.9
- probe 脚本三件套：
  - `probe_attach.py` v2 — attach happy path（170 threads, Client-arm64.so 3GB
    DWARF, configurationDone + deferred attach response, threads enumerated）✅
  - `probe_bp.py` v3 — DAP `setFunctionBreakpoints` → lldb-dap 进程 hard crash ❌
  - `probe_bp_v4.py` v4 — `evaluate "breakpoint set --name X"`（绕开 DAP）→
    同样 hard crash ❌
  - v5 加 `--shlib Client-arm64.so` 范围限定 → 仍 hard crash ❌
- 复现率 100%（连续 3 次，不同 BP 名 / 不同 scope）

**Findings 固化**
- 新 skill: `software-development/lldb-dap-22-platform-mode-breakpoint-crash`
  含完整 probe 流程 + 再次评估新 LLVM release 时的验证脚本路径。

**Decision**
- `lua/ue/dap/android.lua` codelldb 路径**保持不动**（它工作）。
- 不加 `use_lldb_dap` flag（违反"两个并存入口"红线，且只会把用户暴露给已知 crash）。
- 下次有 22.1.7+ 出来，跑 `probe_bp_v4.py` 验证一遍再考虑——不许凭"应该修了"提迁移。

**深挖根因（同日，clone 源码后）**
clone `llvm-project @ llvmorg-22.1.6` (commit fc4aad7b) sparse-checkout 到
`/c/src/llvm-project`。三个对照实验排除掉了 DWARF / device server 版本 / SIGSEGV
三个早先假设：
- probe v8 (host-only 3.92GB Client-arm64.so, 无 device, 无 platform mode):
  `breakpoint set` <1 秒返回带 inlined frame + 源码行 + address ✅ → **DWARF parser 没问题**
- probe v9 (NDK 27 LLDB 18 替换 NDK 21 LLDB 9 在 device 上): 完全一样的 hang →
  **device-side server 版本不是变量**
- probe v7 (`process handle SIGSEGV --pass true --stop false` 在 BP 前): 一样 hang →
  **不是 ART signal handler 干扰**

定位到代码路径: `lldb/tools/lldb-dap/FunctionBreakpoint.cpp` 的
`SBTarget::BreakpointCreateByName` 在 `platform remote-android` 模式下进入
liblldb 的 platform driver，**hang 在 liblldb 自身**，不在 lldb-dap 翻译层。
证据: LLDBDAP_LOG 最后一行 `queued (command=evaluate seq=N)` 之后 120 秒零输出；
stderr 0 字节（既不是 LLVM PrettyStackTrace 也不是 LLVM assert）；
`BaseRequestHandler::Run` 没 try/catch（任何 C++ exception/AV 直接 std::terminate）。

**为什么 codelldb 不死**: codelldb 用 `gdb-remote 127.0.0.1:<port>` 模式，
不是 `platform remote-android`。同一个 `BreakpointCreateByName` 走另一条 platform
driver 路径不死锁。bug 在 `lldb/source/Plugins/Platform/Android/`，
跟 host DWARF parser、DAP 消息循环、device server 版本都无关。

对应上游 issue 也吻合: #126935（platform-android 模式不枚举 modules）、
#102254 / #138096（setBreakpoints crash in remote-platform 上下文）—— 全都是
`platform remote-android` 特有问题。

skill `lldb-dap-22-platform-mode-breakpoint-crash` 同步更新 "Root cause analysis"
小节，含 4 个排除性实验完整记录。

**Follow-ups**
- 如 `lua/ue/dap/_common.lua:183` 注释提到 LLVM #102254 / #138096，今天可以
  补一条："re-verified 2026-05-21 with LLVM 22.1.6, still crashes" — 可选。
- LLVM 上游 issue tracker 可贴一次 platform-mode + Android UE 的复现 trace
  （probe_bp_v4.log + probe_bp.log）作为额外数据点，帮助上游修。可选 follow-up。

### 2026-05-21 — Snacks dashboard 加彩色像素头像

**Task** 用户想把 dashboard 默认 golden ASCII art 换成自己的彩色像素头像
(`C:/Users/lizeqiang/Downloads/20260520-150031.jpg`)。需要在 terminal/Neovide
里能正常渲染（不依赖图片协议），且不破坏 snacks dashboard 的 keys/startup section。

**Implemented**
- `lua/dashboard_pix.lua` (新增, AUTO-GENERATED by `Temp/img2pixblock.py`)：每
  字符一个 `▀` 半块，fg = 上像素 RGB，bg = 下像素 RGB。导出 `M.hl_defs`（颜色
  名→hex）+ `M.combos`（fg/bg pair → 唯一 hl group 名 `DashPxF<i>B<j>`）+
  `M.lines`（每行是 `{str, hl_name}` runs 数组）。
- `lua/plugins/snacks.lua` opts function：
  - pcall require `dashboard_pix`；存在则跑 `nvim_set_hl` 把所有 combos 注册成
    `default=true` 的 hl group（不覆盖 colorscheme 已有同名 group，但实际上
    `DashPxF*B*` 命名空间唯一不会冲突）。
  - `opts.dashboard.preset.header = ""` 清掉默认 ASCII；
  - 拼一个 `pix_section`（align=center, padding=1）把每行 runs 转成 snacks
    `text = { {str, hl=hlname}, ... }` form；下面叠一个 `title_section`
    （"Zeqiang's IDE" 大字 `SnacksDashboardHeader`）；
  - `opts.dashboard.sections = { pix_section, title_section, keys, startup }`
    完整接管 sections（不靠 preset 合并，因为我们要在 keys 上面塞像素行）。

**Pitfalls / Gotchas**
- `▀` (U+2580) Upper Half Block 是渲染彩色像素的标准 trick：fg=上半 / bg=下半，
  两像素一字符。注意终端宽度按 cell（不是字节），所以每行渲染宽度 = 源图宽 / 2
  字符（这里 `img2pixblock.py` 已经把图缩到合适尺寸）。
- snacks dashboard `sections` 接管后 preset.header 即使不清空也不会渲染——但留
  着会在没 `dashboard_pix` 时退化成空白头；设 `header = ""` 防御。
- pcall 包一层：`dashboard_pix.lua` auto-generated，万一缺失/损坏 dashboard 不
  会整个炸，回退到 snacks 默认 preset。

**Validation**
- 文件结构 OK：195 行，`M.hl_defs` / `M.combos` / `M.lines` 三表存在。
- snacks.lua require 成功（活的 nvim reload）+ dashboard 真实渲染像素头像
  待用户实测 `:Dashboard` / 开新 nvim。

### 2026-05-20 — Android DAP 顺手细节补完

**Task** 用户反馈 `<space>da` attach 后 app 退出/被杀没人检测，session 僵死；缺一堆 IDE 顺手细节（reattach、status、重入保护、多设备选择、stop 命令）。

**Implemented**
- `lua/ue/dap/android.lua`
  - **liveness poller**: `M._start_liveness_poller` / `_stop_liveness_poller`。attach 成功后启动 `uv.new_timer`，2s 首次、之后 1.5s 周期 `pidof`。连续 2 次 miss → 自动 `stop_android_debugger()` + WARN notify（含 pid 变化提示）。**直接 stop+notify，不弹 reattach 提示**（dapui 浮窗会抢焦点）。
  - **多设备 vim.ui.select**: 新 `list_devices`（解析 `adb devices -l` 含 model+status），`pick_serial_async` 区分 ready/unauthorized/offline。0 ready 给针对性 hint（'Allow USB debugging' / `adb kill-server`）；1 ready 静默用；**>1 ready 必走 `vim.ui.select`，不缓存默认**（用户明确策略）。bootstrap_session 改全异步链以适配。
  - **attach 重入互斥**: `M._attach_in_progress` flag + `dap.session()` 检查；attach/launch/reattach 入口都拦截，避免连按 `<space>da` 跑两遍 push/forward。
  - **reattach (M.reattach)**: 末位成功 session 保存到 `M._last_session`（snapshot_last_session，模块顶部 forward-declared）。`:UEDAPReattach` 复用 pkg/serial/symbol_lib/lldb_server_local，跳过所有 pick_*；只 poll pid（10s 内）+ 确保 lldb-server 还在 sandbox（重装会清）+ `_finalize_session`。
  - **status (M.status)**: `:UEDAPStatus` 一行总览 session/attaching/pkg/serial/pid/port/libUE4 base/symbol_lib/liveness 状态/last reattach target。
  - stop_android_debugger 和 cleanup 都加 `_stop_liveness_poller()` 和 `snapshot_last_session()`（在 reset_session 前，否则丢 state）。
- `lua/ue/dap.lua`：新 `D.android_dap_reattach` / `D.android_dap_status` forwarder。
- `lua/ue.lua`：M.android_dap_reattach / M.android_dap_status 暴露；新建 `:UEDAPStop` / `:UEDAPReattach` / `:UEDAPStatus` 三条 user command。

**Decisions（用户拍板）**
- A. **不加新 keymap**——`<leader>dx` 保持 reset layout；stop 用 `:UEDAPStop` 命令调。
- B. App 退出后**直接 stop + notify**，提示用户用 `:UEDAPReattach`。不弹询问浮窗。
- 多设备**永远弹选**，不缓存默认。

**Pitfalls / Gotchas**
- `snapshot_last_session` 是 local 函数，被 `M.stop_android_debugger`（在它之前定义）调用——lua local forward-ref 会失败。把定义+`M._last_session = nil` 移到 `reset_session` 之后、`pick_port` 之前，确保被引用前已定义。
- `bootstrap_session` 原来同步返回 bool，新版必须改异步回调 `(opts, on_ready)`——因为 `vim.ui.select` 是异步的，多设备分支不能同步等。`pick_serial`（同步 wrapper）保留给 tests，但生产代码全走 `pick_serial_async`。
- liveness poller 必须在 `M._cleanup_device_side` / `reset_session` **之前** snapshot，否则 `M._last_session` 拿不到 pkg/serial/symbol_lib。
- poller 容忍 1 次 transient miss（adb hiccup / 设备短时 unauthorized），第 2 次才判定退出。

**Validation**
- `nvim --headless` parse OK：android.lua / dap.lua / ue.lua 三文件。
- `require('ue.dap.android')` 加载 OK；attach/launch/reattach/status/stop_android_debugger/_start_liveness_poller/_stop_liveness_poller 全部 type=function。
- `m.status()` 输出格式正确（idle 状态显示 9 行）。
- `m._start_liveness_poller()` 无 pid 时 nil-guard 正确（timer=nil 不创建）。
- `m.reattach()` 无 last_session 时给 WARN 不崩。

**Follow-ups**
- 可选：wait-for-debugger 模式（`am set-debug-app -w <pkg>` + zygote-fork attach）让 launch 路径不漏掉早期 init。当前 launch 用 monkey 启完才 attach。
- 可选：进程匹配从 `pidof -s` 改 `ps -A | grep pkg` 多结果让选（处理 `pkg:gpu_process` 等 sandboxed child）。
- 用户实测：跑一次正常 attach → kill app → 看 1.5s × 2 后是否自动 stop + 出现 notify；再 `:UEDAPReattach` 验证快速路径。

### 2026-05-19 (hotfix #2) — Alt+R 被 NVIDIA App 全局劫持，换成 Alt+G

**Task**: hotfix #1 改完用户实测 `<a-r>` 依然完全无反应（其他 `<a-w>/<a-x>/<a-c>`
正常）。诊断折腾很久（怀疑 IME / Neovide winit / ESC+r 拆分 / mapping order），
最后用户截图：**NVIDIA App Performance Overlay 的 FPS/GPU/CPU/LAT 半透明条**。
Alt+R 是 NVIDIA 默认开/关 overlay 的全局快捷键，OS 级 hook，nvim 永远收不到。

**Root cause**
- NVIDIA App / GeForce Experience 默认 hotkey: **Alt+R = Performance Overlay**。
  系统级键盘 hook，先于任何应用消费 keypress。任何 GUI 程序在该机上绑 Alt+R
  都失效。
- 决定性诊断：`nvim_input("<M-r>")` 通过 RPC 注入能触发 mapping 一次（绕过
  OS 键盘链）；物理按 Alt+R 0 次触发 → 100% OS 层劫持。

**Implemented**
- `lua/ue.lua` `cached_grep` csearch + rg 两分支：`<a-r>` → `<a-g>`
  （grep 谐音，无任何已知冲突；snacks 默认 `<C-g>` = toggle_live 是 Ctrl 不是
  Alt，不打架）。其他三键 `<a-x>/<a-w>/<a-c>` 保持。
- 注释明确写 "Alt+R is GLOBALLY hooked by NVIDIA App"，避免后续会话看到
  键盘表里没有 `<a-r>` 觉得奇怪要补回去。

**Pitfalls / Gotchas**
- 这次浪费了大量时间在错误假设上（IME → Neovide winit → ESC+r 拆分），全
  因为没**先**做"RPC 注入 vs 物理按键"对照实验。**以后只要"特定某个 Alt+
  字母不响应而其他 Alt+ 都正常"，第一反应必须是 OS hook**（NVIDIA / Logitech
  G HUB / Steam / Discord 全局快捷键）。
- 已落地 skill `nvidia-app-alt-r-and-friends-global-hijack`（写了完整诊断套路
  + NVIDIA 默认快捷键清单 Alt+R/Z/F1/F9/F10/F12 + 安全键名单 Alt+g/q/e/d 等）。
- 之前 RPC 探针卡死用户 nvim（累积 `nvim_input`/`vim.notify` 把主循环堵了），
  下次类似诊断要节制注入次数。

**Validation**
- 文件 reload 到活的 nvim (PID 1884) 成功。物理实测 `<a-g>` 待用户复测。
- skill 文件落盘 `~/AppData/Local/hermes/skills/software-development/
  nvidia-app-alt-r-and-friends-global-hijack/SKILL.md`。

**Follow-ups**
- 用户可在 NVIDIA App → Settings → Keyboard Shortcuts 改 Performance Overlay
  默认键以释放 Alt+R 给应用（如果坚持要 `<a-r>` mnemonic）。但本次默认 Path A
  = 换键。

### 2026-05-19 (hotfix) — grep mode toggle 体验修正

**Task**: 上一条改动落地后用户实测：(1) "Alt-r R 只出现不消失" (2) "Alt-w 鼠标
飞出窗口还跳出输入模式"。诊断后两个问题：

**Root causes**
- **Alt-w 飞窗口**：snacks 默认 `<M-w>` 绑的是 `cycle_win`，把焦点切到 list
  窗口。用户直觉 "w = word"，按下后被 snacks 默认抢走了。我之前只绑了 `<a-x>`
  没占 `<a-w>`。
- **R 不消失**：snacks `toggles.regex` 默认 `value = false`，意思是 "opts.regex
  == false 时才显示 R"。我们默认 regex=false → R 恒亮；按 Alt-r 切到 regex 模
  式（true）时 R 才会消失。语义跟用户直觉相反（用户预期"启用 regex 显示 R"）。
- **题外**：title 字母指示在 telescope 布局下不一定立刻可见，光看 title 反馈
  不够清楚。

**Implemented (覆盖上一条改动)**
- `lua/ue.lua` `cached_grep` csearch + rg 两分支：
  - `toggles` 显式声明 `regex = { icon="R", value=true }` 覆盖 snacks 默认 →
    R/W/C 三个字母统一语义：**显示 = 该模式 ON**。
  - 自己写 `ue_grep_toggle_regex/word/case` action 替代 snacks 自动生成的
    `toggle_<name>`：每次 flip 后立刻 `snacks.notify` 一行
    （"✓ regex ON" / "✗ regex OFF (literal)"），用户不用盯 title 也知道当前
    模式。
  - keymap 改成 `<a-r>/<a-x>/<a-w>/<a-c>` 全部路由到 `ue_grep_toggle_*`。
    `<a-w>` 也绑 word（用户直觉 w = word；snacks 默认 cycle_win 没人用 —
    全配置仅在 changelog 出现过）。
- snacks 内建 `toggle_regex` 这次不复用了，因为它的 value=false 语义跟我们
  想要的 "ON-shows-icon" 反，且我们要加 notify 反馈。

**Validation**
- 活的 nvim (PID 28712) headless reload + picker probe：
  - `<M-r>/<M-x>/<M-w>/<M-c>` 全部正确绑到 `ue_grep_toggle_*`（`<M-r>` 不再是
    snacks 默认 `toggle_regex`，`<M-w>` 不再是 `cycle_win`）。
  - 程序触发三个 action → opts 都正确 flip（regex/word/case 依次 true）。
  - 初始 `opts.regex=false word=false case=false` 不变。

**Pitfalls / Gotchas**
- snacks 把 `<a-r>` 在内部 normalize 成 `<M-r>` (vim 的 keycode 等价表示)。
  调试时 `picker.opts.win.input.keys["<a-r>"]` 是 nil，要查 `<M-r>` 才对。
  上一条 diag 我用 `<a-r>` 查，得出 "keys 没生效" 的错误结论。其实合并是
  对的，只是键名换了形态。
- snacks `toggles.<name>.value` 是 **匹配值**（opts[name]==value 时显示
  icon），不是开关默认值。这是文档不直白的细节。
- snacks 自动生成的 `toggle_<name>` 跟我们手写的同名 action 在 `opts.actions`
  里会发生覆盖：snacks merge 序列让用户 opts 在后，所以**我们写的赢**。
  保险起见我用了 `ue_grep_toggle_*` 这个唯一名字。
- `picker.list:set_target()` + `picker:find()` 是 snacks 重启 finder 的标准
  套路（看 `picker/config/init.lua` 自动生成 toggle 的实现里就是这两句）。

**Follow-ups**
- 如果 cycle_win 后续有人想要，可在 `<a-W>` (大写) 上挂回去。
- 把这个 keymap 同步进 `docs/ue_lazyvim_cheatsheet.md` 的 "Inside a Snacks
  Picker" 段落（下次有空再加，不阻塞 hotfix）。

### 2026-05-19 — `<leader>/` grep 加 literal/word/case 切换入口

**Task**: 用户 `<space>/` 历史日志里有 `error parsing regexp: invalid character
class range: \Pr` 的 csearch warn — 因为输入直传 RE2，`\P{...}` 当 Unicode
属性 negation 解析。需要 literal mode 默认 + 正则/全字/大小写运行时切换入口，
已有的去重不要重复加。

**Implemented**
- `lua/utils/code_search/init.lua` `stream_csearch`：新增 `opts.regex`（默认 true=RE2；
  false=literal，对所有 RE2 metachar `^$()%.[]*+-?{}|\` 做反斜杠 escape）、
  `opts.word`（`\b...\b` 包裹）、`opts.case`（true=禁用 smart-case `(?i)` 注入）。
  pattern rewrite pipeline 顺序：literal-escape → word-wrap → case-flag，全部发
  生在 stream 内部，rg 路径不走这里（rg 用原生 `-F`/`-w`/`-s`/`-i`）。column-finding
  needle 保留 raw 用户文本（不能用 escape 后的 pattern 去 plain-find 真实行文本）。
- `lua/ue.lua` `cached_grep` csearch + rg 两条分支：
  - 给 `snacks.picker.pick` 传 `regex=false, word=false, case=false` + `toggles = {
    word = { icon="W", value=true }, case = { icon="C", value=true } }`。snacks
    自动 merge 内建 `regex` toggle 并对每个 toggle 名生成 `toggle_<name>` action
    （flip `picker.opts[name]` + `picker:find()` 重启 finder，title 区显示 RWC 字母）。
  - `win.input.keys` 加 `<a-x>` → `toggle_word`、`<a-c>` → `toggle_case`（`<a-r>`
    snacks 默认已有，不动）。`<a-w>` 是 snacks 默认 `cycle_win`，避让。
  - finder 体里读 `finder_ctx.picker.opts.{regex,word,case}` 传给 stream（csearch
    分支）或拼进 base_args（rg 分支：`--fixed-strings`/`--word-regexp`/`--case-sensitive`
    vs `--smart-case`）。
- 默认 `regex=false`（literal）= 用户输入 `\Pr` `[1-9]` `(foo|bar)` 都不再炸。

**Pitfalls / Gotchas**
- snacks `toggles` 表 **不要手动 merge** snacks defaults — 之前写过
  `vim.tbl_extend("force", require("snacks.picker.config.defaults").toggles, {...})`
  返回 nil 因为 toggles 在 `M.defaults.toggles` 子表里而不是 module 顶层。
  snacks 自己在 `picker/config/init.lua` `M.get()` 里 deep-merge defaults +
  user + source + opts，我们只要传增量即可。
- `<a-w>` 在 snacks default keys 里被 `cycle_win` 占用 → 用 `<a-x>` 做 word
  toggle（也跟 cheatsheet `<leader>sx` 全字风格一致）。
- column estimation 用 raw 用户文本，**不要**用 rewritten pattern：literal 模
  式下 `Foo.Bar` 重写成 `Foo\.Bar`，plain-find 找 `\.` 永远找不到。
- pattern rewrite 顺序固定：literal-escape **先** 于 word-wrap，否则 `\b...\b`
  自己会被当 metachar escape。
- RE2 case-sensitive 不能用 `(?-i)` 取消我们注入的 `(?i)` — 不互斥的实现细
  节，所以做成"`case=true` 直接不注入 `(?i)`"。

**Validation**
- `Temp/test_grep_modes.lua` headless：8/8 pattern rewrite case 通过（含 `\Pr`、
  `Foo.Bar`、`[1-9]`、word `\b...\b`、case 真假、regex 透传）。
- `Temp/test_csearch_e2e.lua` 真 csearch + workspace idx：
  - `\Pr` regex 模式 → RE2 报错（复现原 bug）
  - `\Pr` literal 模式 → exit=0 / 217 hits ✅
  - `Foo.h` literal=4 hits vs regex=106 hits（`.` 区别明显）✅
  - `FRDGBuilder` word → 2503 hits ✅
  - `fRDGBuilder` (小写 f) case=true → 0 hits ✅
- 活的 nvim (PID 20820) 热 reload + headless 打开 picker 探 opts：
  `opts.regex=false / word=false / case=false`，`toggle_regex/word/case` 三个
  action 全自动生成，`toggles.regex` 自动合并自 snacks 默认（icon=R）。

**Follow-ups**
- 可考虑加 `<leader>s/` 时记住上次的 mode 组合（resume 已有，是否携带 toggle
  没验）。
- snacks UI 上 R/W/C 三字母指示是否在 telescope layout 的 title 栏渲染清楚，
  下次实际用时观察一下。

### 2026-05-18 — `.clangd` External.File 自动同步进 :UEPrepare

**Task**: 用户 :UEPrepare 跑完后 clangd 依然 background-index 烧 17GB+ /
32min CPU，根因是 `.clangd` 的 `Index.External.File` 留在 v3 cache 迁移前
的老路径 `<root>/.clangd-index/`，而真实 idx 已经搬到
`<root>/.cache/nvim-ue/clangd/index/`。LSP 找不到 external idx 静默回落
到 background build。修复 = 让 :UEPrepare 的 hot/current/full 索引完成
路径自动把 `.clangd` 的 External 块改写到 `cache_paths().active_index` 的
权威路径。

**Implemented**
- `lua/ue.lua` 新增 `INDEX_FN.sync_dot_clangd(ctx)` (放在
  `INDEX_FN.promote_active_index` 后面)：surgical 编辑 `<engine_root>/.clangd`
  里的 `Index.External.{File,MountPoint}` 两行；用 Lua pattern 局部替换
  保留 `CompileFlags:` (/vctoolsdir + MSVC 14.29.30133 + winsdkversion
  pin) / 注释 / Diagnostics 等用户内容；atomic write (tmp + fs_rename) 避
  免 clangd 中途读到半截文件；idempotent — 内容一致直接返回 unchanged
  不写盘。
- `lua/ue.lua` 在 `INDEX_FN.build_phase_async` 的 success 分支
  (L~2914)、`promote_active_index` 之后 `clear_module_dirty_flags` 之前
  `pcall(INDEX_FN.sync_dot_clangd, ctx)`。pcall 兜底网络盘 / 只读盘失败
  不阻断 pipeline。
- `.hermes/plans/2026-05-18_112303-sync-dot-clangd-into-ueprepare.md`
  Plan 落盘（Goal / 6 风险 / 验证矩阵）。
- `.hermes/tests/test_sync_dot_clangd.lua` 单测脚本（headless luafile）：
  覆盖三件事 — 路径正确切换、CompileFlags byte-preserve、二次调用 byte-
  identical。

**Pitfalls / Gotchas**
- Lua pattern 不是真 regex：先 `gsub(..., 1)` 拿到 `_, n_replaced`，n==0
  时再走 inject fallback，避免 "External: 有但 File: 没" 的边角 case
  整段被吞。
- `vim.fn.environ()` 在 Windows 下 `key = nil` 移除不掉 — 这是另一条
  既有教训，不在本次范围。
- `pcall` 包 sync_dot_clangd：网络盘 / 只读 .clangd / engine_root 是文
  件 (而非目录) 都不应炸断 pipeline 后续 `maybe_restart_clangd_for_index`。
- LuaJIT 200-local 上限：新增的 helper 全部挂 `INDEX_FN.` 表（不增 main
  chunk local 数），headless require 通过。
- 已存 clangd 进程是用旧 .clangd 启的，sync 后必须 :LspRestart / 杀进程
  才会读新配置。本次直接 `Stop-Process` PID 42792 (1.6h CPU/14.8GB) 让
  nvim 下次 attach 自动新生。

**Validation**
- `nvim --headless +'lua print(pcall(require,"ue"))' +q` → OK (无 200
  local 爆 / 无语法错)。
- `nvim --headless -c 'luafile .hermes/tests/test_sync_dot_clangd.lua'`
  → ALL TESTS PASSED：
  - CALL 1: ok=true msg=updated, File 从 `.clangd-index\` → `.cache\nvim-ue\clangd\index\`
  - CALL 2: ok=true msg=unchanged (byte-identical)
  - CompileFlags /vctoolsdir + 14.29.30133 完整保留
  - 注释块 (VS2026 STL builtins 说明 11 行) 完整保留
- 杀 clangd PID 42792 完成，下次 nvim attach 读新 .clangd 直接 mmap
  external idx (沿用 v1.0.2 super-unity 产物 hot.idx 99 MB)。

**Follow-ups**
- inject_definitions_to_cdb.py per-file 路径 70% TU 缺 UE_BUILD_DEVELOPMENT
  (独立 follow-up，与 sync 无关)。
- ue.lua `clangd_cmd` 还在传 `--background-index`，跟 `.clangd` 的
  `Background: Skip` 冲突 (clangd 行为：.clangd 覆盖 CLI，所以是 cosmetic
  not functional)。可选清理。
- state.json 残留 project_root=`E:/proj/other_project_dev` (跨项目)，对当
  前 D:/project/UnrealEngine 场景无害但要 follow-up 修 (resolve_context
  没 invalidate)。

