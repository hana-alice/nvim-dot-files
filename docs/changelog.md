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

### 2026-05-21 (later #8) — fix(dap): UEDAPDiag clamp evaluate responses universally

**Task** Fix #7 (`image list -b` filter) 实测无效——D2 实测 buffer 仍 1124845 行。深入分析后发现：**罪魁不是 `image list` 而是 `image dump symfile "libUE4.so"`**。UE4 主 so 含数百万符号，symfile dump 每个符号一段、含 DIE/CU/sections，单次响应几十 MB / 百万行级别。`-b` flag 改 image list 行为但 symfile 不受影响，所以前一版 fix 只 patch 了一半路径，buffer 继续被 symfile 撑爆。

**改动**

1. `lua/ue/dap.lua` section E 引入 **统一 clamp** — `MAX_BYTES_PER_RESPONSE = 32KB` + `MAX_LINES_PER_RESPONSE = 200`，每条 evaluate response 在装进 buffer 前 (a) 按字节截断 + 写明 "truncated; raw was N bytes" 提示，(b) 再按行数截断防短行洪水。
2. 删掉 #7 的 image-list-only inline 过滤代码（复杂、覆盖不全），统一走 `eval()` + `clamp()` 路径。三条命令（`image list -b` / `image dump symfile <lib>` / `settings show target.source-map`）行为对称。
3. 注释明确：diag 是 one-screen 摘要不是 full dump；想看完整输出走 `:UEDAPRepl <cmd>`（将来加这命令）。

**验证（pending: 用户重启 Neovide 后跑）**

D3 attempt (PID 42176) 跑到一半 nvim 卡死 pipe 不响应，**进程没 OOM (110 MB)** 但 Windows named pipe server 失活——这是另一个独立的 nvim Win32 bug（client timeout 时 pipe server 不清理）。本 fix 防止 evaluate response 之大触发 buffer 爆涨，应该同时也能间接缓解 pipe 卡死（少量数据 buffer set lines 不会触发 vim 主 loop 长阻塞）。

**坑**

- **症状归因偏差**：#7 把锅扣在 `image list` 上做了 inline filter，但 D2 实测 fix 之后仍 1.1M 行——**因为 fix 只改了 image list 不改 symfile**。debugging 时不能只看症状关键词（"image list 1.1M 行"）就锁定它，要看 collect() 实际收到 3 段响应里**哪段贡献了**那 1.1M。今后用 `lldb_results[i]` 各段长度日志辅助定位。
- **lldb-dap 22.1.6 的 `image list -b` 行为未确认** — D2 跑出 1.1M 行说明 `-b` flag 没生效（被忽略 / 当 module name filter），但 D3 想直接 evaluate 验证时 nvim pipe 死掉。当下 fix 不依赖 `-b` 行为正确——universal clamp 兜底无论 lldb 怎么响应都安全。
- **Windows nvim named pipe failure 模式**：进程仍活，CPU normal，但 `\\.\pipe\nvim.PID.0` 直接 `FileNotFoundError`。无法救活，只能重启。本轮已 2 次复现，下次起在脚本内部捕 socket exception 立即 graceful，不一直 retry。

**Follow-up**

- 用户重启后跑 D4：实测 clamp 后 buffer 总行数 ≤ ~600 行 (3 段 × 200 + 头部)，不会 OOM。
- 加 `:UEDAPRepl <cmd>` user command 给用户跑任意 lldb 命令的逃生口（结果走单独 buffer 同样 clamp）。
- 单独 skill 记录 lldb-dap evaluate response 大小陷阱 + Windows nvim pipe 失活模式。

### 2026-05-21 (later #7) — fix(dap): UEDAPDiag `image list` 限流，避免 OOM

**Task** Phase D 实测时 `:UEDAPDiag` 在 attach 状态下跑出 **1125437 行**输出，吃掉 nvim 1.5 GB working set 后 pipe server 卡死。根因：UE Android attach 后 LLDB 加载 ~700 个共享库，`image list` 每个库一段、含 sections，单次命令出百万行。LLDB CLI 又不支持 shell pipe（`image list | head -5` → `error: unknown or ambiguous option`），不能在 LLDB 侧分页。

**改动**

1. `lua/ue/dap.lua` section E 的 `image list` 调用改成 **`image list -b`**（basename-only，每模块一行 ~50 字符），在 Lua 侧 `vim.split` 后 (a) 输出模块总数 (b) 过滤含关键字 `libUE/libUnreal/libGame/<symbol_lib basename>` 的行（用户真正想看的就 1-3 个）。
2. 注释明确说明：LLDB 不支持 pipe，所以分页/过滤必须在 Lua 侧做；想看原始 `image list` 走 `:UEDAPRepl image list`（如果将来加这个命令）。
3. 三段 pending 计数不变（`image list`/`image dump symfile`/`settings show target.source-map`），只是 image list 改成 inline `session:request` + 自带 collect 回调。

**验证（pending: 用户重启 Neovide 后跑 Phase D 续集）**

上一轮 #6 的 Phase D（active attach 实测）发现：
- ✅ `type summary list -w UEFallback` 列出全部 **14 条** native summary，**lldb-dap 22.1.6 完全接受** `-x "^TArray<.+>$"` regex + 嵌套 `${var.Min.X}` 复合引用。`type category list` 显示 `UEFallback (enabled)` 第二条。
- ✅ Attach 9.2s 完成、165 threads stopped at entry、auto-continue 起效。
- ❌ `image list` 直接打爆 buffer → nvim 1.5GB / pipe 不响应（本 commit 修）。

**坑**

- **LLDB 命令行不支持 shell pipe** — `image list | head -5` 不是 LLDB 不会而是 LLDB 把 `|` 当 `head` 的参数。`grep`/`wc` 在 LLDB 内同样不可用。要分页/过滤只能 (a) 用 LLDB 自带 flag 例如 `-b` 缩量 + Lua 侧二次处理，或 (b) 写 Python 命令插件（无 Python 排除）。
- **`image list -b` 输出格式** — 每行 `[索引] basename`，不含完整路径/UUID。用户想看完整列表得自己跑 `image list`，但实测一定 OOM nvim，所以**这不是 diag 该做的事**，是单独 `:UEDAPRepl` 该做的事。
- **Active session 状态下跑 1M+ 行写入 Lua buffer 时 nvim 完全无响应** — pipe server 不接新连接（FileNotFoundError）但进程 Responding=True、CPU=0（卡在 vim API call，不在 lua loop）。强杀 nvim 是唯一恢复路径；本 commit 防止这种情况复现。

**Follow-up**

- 用户重启 Neovide 后续跑 Phase D：实测过滤后的 image list 应该只有 5-10 行；FString/FVector 等 summary 真展开（需要找一个 UE 全局变量做 eval target）。

### 2026-05-21 (later #6) — feat(dap): UE-aware watch templates + 扩展 native type summary

**Task** 接着 #3 的 FString native fallback，把无 Python 时能用纯字符串模板表达的 UE 类型全部加上 (`FVector`/`FVector2D`/`FVector4`/`FIntVector`/`FRotator`/`FQuat`/`FColor`/`FLinearColor`/`FBox`/`TArray<*>`/`TWeakObjectPtr<*>`/`TSharedPtr<*>`/`TSharedRef<*>`)，并为需要调函数的 `FName`/`UObject*`/`AActor*` 提供 **预制 watch expression 包装**（通过 `:UEDAPWatchUE` + `<leader>dW` 选 picker）。

**改动**

1. `lua/ue/dap/android.lua` `init_commands` 的 `not has_python` 分支：从只有 FString 一条扩到 14 条 native summary（`type summary add -w UEFallback ...`），覆盖 UE 最常见的数学/容器类型；`-x "^TArray<.+>$"` 走 regex 一次性覆盖所有 `TArray<T>` 实例化。
2. `lua/ue/dap.lua` 新增：
   - `_dap_watch_push(expr)` 内部 helper：去掉换行/前后空白、走 `dapui.elements.watches.add()`，dapui 不可用时 notify 退出。
   - `dap_watch_fname(expr)` / `dap_watch_uobject(expr)` / `dap_watch_actor(expr)` / `dap_watch_tarray(expr)` 四个 UE 专属 watch helper，把 "我每次都要看 X 的 Y" 模式预制好（FName→`ToString()`；UObject→`GetClass()->GetName()`+`GetName()`；AActor 再加 `GetActorLocation()`；TArray→raw + 前 4 个元素）。每个 helper 都 `_require_session()` 守门。
   - `dap_watch_template(template, expr)` 统一 dispatcher：未知模板名打 warn 但 fallback 成 raw watch（不静默吞）。
3. `lua/ue.lua` re-export 5 个新函数 + 注册 `:UEDAPWatchUE <type> [expr]` user command (nargs=+, complete 列出 `fname|uobject|actor|tarray|raw`)。
4. `lua/config/keymaps.lua` 加 `<leader>dW` (normal + visual)：local helper `_ue_dap_watch_picker` 用 `vim.ui.select` 弹模板选项 + 把 cword/visual selection 作为 expr 拼成 `:UEDAPWatchUE ...`。
5. `lua/utils/cheatsheet.lua` DAP Inspect/Navigate 段补 `<leader>dW` + `:UEDAPWatchUE`。

**验证**

- Headless：`require('ue.dap')` 加载，`dap_watch_template/fname/uobject/actor/tarray/_dap_watch_push` 全部 `function`。
- 真 nvim (PID 12312) hot-reload：`:UEDAPWatchUE` 注册 ✓；`<leader>dW` normal + visual 都拿到 callback；`dap_watch_template('raw','MyVar')` → push `MyVar`；`dap_watch_template('UNKNOWN_TYPE','OtherVar')` → push `OtherVar` + warning notify（fallback 设计正确，不静默吞）。
- `_lldb_dap_attach_config_for_test` 抓出来 `initCommands` 含 14 条 `type summary add -w UEFallback` 全部出现。

**坑**

- `vim.fn.maparg(lhs, mode, false, true)` 在 keymap 有 callback function 时返回的 dict 含 function reference → pynvim msgpack `Cannot convert given Lua type`。换 `vim.api.nvim_get_keymap('n')` 过滤 lhs（API 返回 `has_callback` 标志 + 字符串 desc，全部可序列化）。
- `<leader>dW` 加进 keymaps.lua 后单纯 `require('ue').setup()` reload 不触发新 mapping，因为 keymaps.lua 不属于 `ue.*` 模块树。修复 = `dofile(stdpath('config') .. '/lua/config/keymaps.lua')` 重新执行（生产环境用户重启 nvim 即可）。
- `FName::ToString()` / `UObject->GetName()` 这些 watch 模板要求 inferior 有这些符号且未被 inline 优化掉 — Development build OK，Shipping 失败时 watch 显示 `error: ...` 而不是崩；可接受降级。
- TArray `(expr).GetData()[i]` 写 watches 而不是 `(expr)[i]` 的原因：UE 的 `TArray::operator[]` 在某些版本会调 `RangeCheck()`，watches 评估 abort；`GetData()` 拿裸指针下标更安全。

**Follow-up**

- attach 状态下实测 FVector/TArray 这些 native summary 是不是真展开（无 session 只能验证字符串被发出，没法验 lldb-dap 真接受 `-x` regex 模式 + 复合 `${var.Min.X}` 嵌套引用）。
- `FName::ToString()` 在 Shipping 下到底是怎么炸的 — 看 watch 报错信息，必要时加注释告知用户。

### 2026-05-21 (later #5) — feat(dap): UEDAPDiag 充实成五段式诊断面板

**Task** 上一版 `:UEDAPDiag` 只跑 3 条 lldb 命令 (`image list` / `image dump symfile` / `source-map`)，且 **要求有 active session**，没 session 直接 `notify("No DAP session")` 退出。但绝大多数"为什么 attach 不上"的诊断需求恰恰发生在 **没有 session** 的时候。重写成五段式：无 session 也能跑，有 session 则附加 lldb 内省段。

**改动**

1. `lua/ue/dap.lua` `dap_diagnose` 重写为五段：
   - **A. DAP session** — `initialized` / `stopped_thread_id` / thread count / `D._dap_run_state` / current frame / config.name|request|type
   - **B. ue.dap.android state** — package/serial/pid/port/symbol_lib + adapter 路径 + `lldb-dap --version` 解析 + python module 探针（同 `attach_commands` 探 `lib/site-packages/lldb` 那条）+ liveness poller 状态 + last reattach target
   - **C. device-side (adb)** — `adb shell ps -A | grep lldb-server` + `adb forward --list` + `pidof <pkg>` + `/proc/<pid>/status` 的 `State`/`TracerPid` (检测 `do_freezer_trap`/`tracing stop` 烂尾态)
   - **D. log files** — `stdpath('cache')/dap.log` + `os_tmpdir()/ue_dap_e2e.log` 路径 + size + mtime + tail 20 行
   - **E. lldb introspection (DAP evaluate)** — 仅 active session 时跑，保留原 image/symfile/source-map 三命令
2. 新增 `D._render_diag_buffer(sections)` —— 把上面拼好的段落 dump 到新 nofile/bufhidden=wipe buffer，botright split，按 `q` 关闭，buffer name 带秒级时间戳（`UEDAPDiag@HHMMSS`）避免覆盖前次诊断
3. lldb-dap version 解析：`vim.fn.system { dap_exe, '--version' }` 多行输出，老逻辑 `gsub('[\r\n].*$', '')` 只抓第一行 `lldb-dap: LLVM (http://llvm.org/):` 没意义。改成逐行匹配 `version%s+([%d%.]+)`，第二行 `  LLVM version 22.1.6` 命中 ✓

**测试**
- `nvim --headless -c "lua require('ue.dap')"` → 加载 OK
- pynvim hot-reload + `:UEDAPDiag` (无 session) → 输出 5 段，含
  - lldb-dap path = `C:/tools/lldb-22/install/bin/lldb-dap.exe`
  - version = `LLVM version 22.1.6`
  - python = `NO (FString native fallback only)`
  - dap.log tail 把过往 exit code `1` / `3221226505` (0xC0000409) 全暴露出来 ✓

**坑**
- buffer 命名带时间戳必须**秒级**而不是分钟级：之前测试两次连续敲 `:UEDAPDiag`，秒数一致 buffer 名重复，`nvim_buf_set_name` 撞名 silently fail，看到的还是上次的旧内容。换 `@HHMMSS` + `bufhidden=wipe`，确保 `q` 一关就被清掉，下次新建一定是干净 buffer。
- `lldb-dap --version` Windows minimal build 第一行**没有版本号**，是 "lldb-dap: LLVM (http://llvm.org/):"。要解析必须逐行扫，匹配 `version%s+([%d%.]+)`。不要假设第一行就是版本信息。
- `vim.fn.systemlist` 拿 adb shell 输出在 Windows 下行尾自动 strip CR，不用额外处理；但 `vim.fn.system` (无 list 版) 保留 CR。
- `vim.fn.stdpath('cache')` 在 Windows 上 = `C:\Users\...\AppData\Local\Temp\nvim`（短文件名 `LIZEQI~1`）— 看起来怪但路径有效。

**follow-up（剩余）**
- C (UE 专属 watch templates: UObject/FName/UEnum 一键 watch) 未做

### 2026-05-21 (later #4) — feat(dap): 补齐 IDE 调试交互能力（hover / eval / watch / run-to-cursor / frame nav）

**Task** 当前 UEDAP 命令集只覆盖 attach/stop/continue/pause/step/toggle-bp/UI 这些"启动+步进"基础项；条件断点和 logpoint 函数早就实现在 `_persist_bp.lua` 但**没接成 user command 或 keymap**，hover/eval/watch/run-to-cursor/frame-up-down/restart-frame 完全缺失。这轮把缺口补齐到 VSCode/CLion 同等水平。

**改动**

1. `lua/ue/dap.lua` 加 7 个新函数 (插在 `dap_list_breakpoints` 之后)：
   - `D.dap_hover()` — 调用 `dap.ui.widgets.hover()`；visual 模式 yank 到 reg z 当 expression
   - `D.dap_eval_prompt()` — `vim.ui.input` + `sess:request("evaluate", { context = "repl", frameId = current_frame.id })`，结果 notify 出来（不像 hover 一闪而过）
   - `D.dap_add_watch_cword()` — `dapui.elements.watches.add(expr)`；visual yank 优先于 cword
   - `D.dap_run_to_cursor()` — `dap.run_to_cursor()` (nvim-dap 内置)
   - `D.dap_frame_up()` / `D.dap_frame_down()` — 包 `dap.up()` / `dap.down()`
   - `D.dap_restart_frame()` — 包 `dap.restart_frame()` (内部 `session:restart_frame()` 走 DAP 协议 restartFrame request)
   - 共用 helper `_require_session()` 在没有 active session 时 notify warn 早退，保证 F-keys 在 attach 前按了也不报错
2. `lua/ue/dap.lua` 早就有但**之前没 export**的 3 个：
   - `D.dap_set_conditional_breakpoint()` (wrap `_persist_bp.toggle_conditional()`)
   - `D.dap_set_logpoint()` (wrap `_persist_bp.toggle_logpoint()`)
   - `D.dap_clear_breakpoints()` (wrap `_persist_bp.clear_all()`)
   - `D.dap_list_breakpoints()` (wrap `_persist_bp.list()`)
3. `lua/ue.lua` 加 11 个 `M.dap_*` re-export
4. `lua/ue.lua` 加 11 个 `UEDAP*` user command:
   - `:UEDAPCondBreakpoint` / `:UEDAPLogpoint` / `:UEDAPClearBreakpoints` / `:UEDAPListBreakpoints`
   - `:UEDAPHover` (range=true) / `:UEDAPEval` / `:UEDAPWatchAdd` (range=true)
   - `:UEDAPRunToCursor` / `:UEDAPFrameUp` / `:UEDAPFrameDown` / `:UEDAPRestartFrame`
5. `lua/config/keymaps.lua` 加 10 个 normal-mode keymap + 2 个 visual 变体:
   - `<leader>dB` Conditional / `<leader>dL` Logpoint / `<leader>dC` Clear all (大写避撞 `<leader>db/dc`)
   - `<leader>de` Eval prompt / `<leader>dh` Hover / `<leader>dw` Watch add (visual 变体走 `:cmd<cr>` 不是 `<cmd>` 因为 `<cmd>` bypass visual mode)
   - `<leader>dt` Run to cursor
   - `<leader>dk` / `<leader>dj` 帧上下 (vim 风)
   - `<leader>dR` Restart frame
6. `lua/utils/cheatsheet.lua` Android DAP 一节加 dB/dL/dC，新增 "DAP Inspect / Navigate" 一节

**测试**
- `nvim --headless -c "lua require('ue.dap')"` → 加载 OK，7 个新函数 type=function
- Pynvim hot-reload + 验证 10 个 user command + 10 个 normal-mode keymap 全部注册 ✅
- live e2e attach 流程不变（已 commit ee5d491/c941ef6/93585a7 验证过，本轮纯加交互层）

**坑**
- visual 模式的 keymap：用 `:UEDAPHover<cr>` 而不是 `<cmd>UEDAPHover<cr>`。`<cmd>` 进入命令行不走 visual 模式状态机，`nvim_get_mode()` 在命令回调里返回 `n` 而不是 `v` → 视觉选择拿不到。`:` 走 ex 命令保留 mode，回调里 yank 到 reg z 才能拿到选择。
- visual yank 必须 `noautocmd silent normal! "zy`：`noautocmd` 避免触发 `TextYankPost` 等扰乱 dap-repl 输入，`silent` 抑制 "1 line yanked"，`"z` 用 z 寄存器不污染 `"`
- `dap.restart_frame()` 比手搓 `sess:request("restartFrame", {frameId=...})` 好：nvim-dap 内部 `session:restart_frame()` 会处理 step granularity / scope refresh，手搓的话变量面板不刷新
- 没把 `K` 重新绑：LSP hover 不能让位。改用 `<leader>dh`
- `dap.ui.widgets.hover` 接受 `function(): string` 当 expression provider；visual 模式我们手工 yank 然后 `widgets.hover(function() return expr end)`，normal 模式让 widgets 自己抓 `<cword>`

**follow-up（剩余）**
- B (UEDAPDiag/Status 充实) / C (UE 专属 watch 模板) 还没动，等下次决定优先级

### 2026-05-21 (later #3) — fix: 两阶段 stop + FString 无-Python fallback

**Task** Follow-up #2 + #3 from the lldb-dap live-attach session:
- #3: `:UEDAPStop` 现在等 `disconnect` 响应再 killall lldb-server（避免 ptrace lock leak）
- #2: 自动探测 lldb-dap 是否带 Python，无 Python 时退到 native `type summary` FString fallback

**改动**
1. `lua/ue/dap/android.lua` `stop_android_debugger()` 重写：
   - 改成两阶段 teardown：先 `sess:request("disconnect", ..., callback)` 异步发，
     callback 里 `vim.schedule(finalize)` 再做 `_cleanup_device_side` + `reset_session`
   - 加 `cleanup_done` 闭包 guard + `vim.defer_fn(finalize, 1500)` 安全兜底，
     如果 lldb-dap 已死/响应永不来，1.5s 后也强清，保证 `:UEDAPStop` 幂等
   - 根因：原版同步并发跑 disconnect (异步) 和 killall (同步)，killall 比
     disconnect ACK 快，gdbserver 子进程死时 `PT_DETACH` 还没下发到 kernel，
     inferior 留在 state=T（TracerPid=0 但 SIGSTOP 仍在），只能 `kill -9`。
     现在让 killall 等到 DAP 协议层确认 detach 完成再发。
2. `lua/ue/dap/android.lua` `attach_commands()` 加 Python detection + fallback：
   - 探针：`<lldb-dap install_root>/(lib|Lib)/site-packages/lldb/` 目录是否存在
   - 22.1.6 Windows 最小化 build 无 Python module → 走 native 分支：
     - `type summary add -w UEFallback --summary-string "${var.Data.AllocatorInstance.Data%s}" FString`
     - `type category enable UEFallback`
     - 一次性 INFO notify 告知 FName/TArray/TMap/FVector 无 summary
   - Python build → 原 `command script import` 路径不变（向后兼容）
   - 根因：Epic 的 `UE4DataFormatters_2ByteChars.py` 第一行 `import lldb`，
     22.1.6 Windows minimal build 只装了 liblldb.dll + lldb-dap.exe，没有
     `lldb` Python 模块 → `ModuleNotFoundError: No module named 'lldb'` 灌到
     console（不致命但难看）。Native summary-string 只能写最简单的指针-到-cstring
     映射，所以只救 FString（最常用），其余类型放弃 summary。

**测试**
- `nvim --headless -c "lua require('ue.dap.android')"` → 加载 OK
- `nvim --headless luafile lua/ue/dap/android.lua` → exit 0
- ✅ **fresh Neovide 实测通过 (2026-05-21 18:49)**：
  - `:UEDAPAttach android` → 171 threads, PID 11788 → 11788 (#1 修复确认)
  - `type summary list UEFallback` 返回 `FString: ${var.Data.AllocatorInstance.Data%s}`，
    summary rule 注册成功 (#2 修复确认)
  - `:UEDAPStop` → dap.session() 清空 +1.17s, lldb-server gone +1.83s
    （killall 后于 disconnect ACK，符合两阶段设计）；
    post-stop 游戏 state=S TracerPid=0，**不再 stuck 在 T (tracing stop)** (#3 修复确认)

**坑（实测发现）**
- Android `do_freezer_trap` 状态：app 在后台被 cgroup freezer 冻住（不是 SIGSTOP），
  ptrace attach 会卡住但不报错。要 attach 必须先 `monkey -p PKG -c LAUNCHER 1` 或
  `am start -W` 拉到前台直到 GameActivity resumed。判据：`ps` state 从 `do_freezer_trap`
  变成 `do_epoll_wait`/`do_select`。
- 旧 stuck ptracer 清理：如果上次 stop 失败留下 `State: t TracerPid: <pid>`，
  `killall -9 lldb-server` 把 tracer 干掉后 state 变 `T (signal stop) TracerPid: 0`
  ——这时仍卡住，需要 `kill -CONT <inferior_pid>` 或 ANR watchdog 触发 launcher 重启。
  **这就是 follow-up #3 修复要根除的烂尾态**。

**坑**
- `dap.session():request(cmd, args, cb)` 真签名（nvim-dap 上游 session.lua:1883）：
  `function Session:request(command, arguments, on_result)` —— 没 callback 时
  会用当前协程 resume，跑同步流不要漏 callback，否则收不到响应也不会出错
  (`on_result = function(_, _) end` swallow)
- `vim.uv.fs_stat` (Neovim 0.10+) vs `vim.loop.fs_stat`（旧）兼容：写成
  `vim.uv and vim.uv.fs_stat(...) or vim.loop.fs_stat(...)`
- `type summary` 的 `--summary-string` 对 char16_t* 的 `%s` 格式说明符理论上
  打 UTF-16 cstring。如果实测乱码可能要换成 `${var.Data.AllocatorInstance.Data}: char16_t*`
  让 lldb 自己选 summary，待 fresh nvim 实测确认。

**follow-up（剩余）**
- ✅ #1 PID 跳变修复：fresh 实测确认（见上方测试段）
- #4: nvim-dap hot-reload 后 lldb-dap 0xC0000409 STATUS_STACK_BUFFER_OVERRUN。
  fresh nvim 不复现，仅 `package.loaded[...]=nil; require('ue').setup()` 后 attach
  触发。怀疑 ensure_adapter 重新喂 stdio pipe 时 `_get_osfhandle(3)` 失效（skill
  ue-android-codelldb-attach-traps Bug 5）。短期 workaround：改 ue.lua 配置后重启
  Neovide，不要 hot-reload。后续要修可以加 ensure_adapter 内的 stdio fd 验证。

### 2026-05-21 (later #2) — fix: auto-continue `entry` stops on Android attach (PID jump fix)

**Task** Follow-up #1 from the lldb-dap live-attach session: stop the Android
inferior from getting relaunched by Android's watchdog mid-attach. Root cause
was the 174 `event_stopped` events (one per thread, `reason = "entry"`) that
lldb-dap emits after `process attach --pid` returns under platform mode with
stopOnEntry=true — the inferior sat frozen, system_server flagged it as ANR
within seconds, the launcher relaunched the app, and the user saw PID jump.

**Implemented**
- `lua/ue/dap.lua` `dap.listeners.after.event_stopped["ue-dap-run-state"]`:
  add `entry` to the auto-continue benign-reason whitelist alongside
  `exception`. Remove the now-redundant `_dap_attach_in_progress` guard —
  the inner `has_bp` / `reason` filters already exclude real breakpoints
  and user `pause` requests.

**Root-cause trace evidence** (Temp/ue_dap_e2e.log, 17:55 attach)
- `EVT event_stopped body={ allThreadsStopped=true, description="signal SIGSTOP", reason="entry", threadId=8238 }`
- Repeated 174× (one per thread) with `reason="entry"` — the listener's
  old `reason=="exception"` filter dropped every single one, so no
  auto-continue ever fired, inferior stayed in SIGSTOP indefinitely.

**Pitfalls / Gotchas**
- The OLD listener comment specifically called out "Android sends stray
  SIGSTOP/SIGSEGV on unrelated threads". The author was thinking about
  *post-attach* signals (`reason="exception"`), not realizing the
  *attach-time* SIGSTOP wave comes in as `reason="entry"`. Two different
  DAP reasons for what looks like the same signal class.
- stopOnEntry=true is non-negotiable on platform-mode Android (see the
  comment in `android.lua` lldb_dap_attach_config) — we can't fix this by
  flipping stopOnEntry to false. The fix has to be on the consumption side.

**Validation**
- Headless luafile syntax check OK.
- Live e2e verification deferred: during attempted in-place validation the
  running Neovide nvim's lldb-dap spawn hit a 0xC0000409
  (STATUS_STACK_BUFFER_OVERRUN) startup crash on the SECOND attach,
  blocking re-test in the same nvim instance. Standalone `lldb-dap.exe
  --help` and a fresh probe_attach.py both pass against 22.1.6, so the
  binary itself is healthy — the stdio fd-3 invalidation seems to be a
  nvim-dap-side condition triggered by hot-reloading the adapter wiring
  in a long-running Neovide session. Captured as new follow-up.

**Follow-ups**
- Stdio fd-3 invalidation after `ensure_adapter` re-wires in a hot-reloaded
  ue.setup() — surfaces as 0xC0000409 on the next lldb-dap spawn. Needs
  reproducer outside Neovide to isolate.
- Followups 2 (FString formatter) and 3 (UEDAPStop ordering) still open.

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

