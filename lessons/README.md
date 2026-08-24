# Lessons · 平台怪癖与调试硬知识

> **lessons/** 区：付出过真实调试成本的陷阱与硬知识。
> 出处优先：权威踩坑清单在 `docs/CONSTRAINTS.md §二（踩过的坑 K1–K51）`，
> 本文件是**主题导航**，按领域聚合指回出处，不复制原文。

## 什么属于这里 / 不属于这里

- **属于**：平台怪癖（Android/Windows/LLVM）、调试中发现的非显然约束、「为什么不能那样做」的硬教训。
- **不属于**：设计抉择（→ `../decisions/`）、日常改动（→ `../docs/changelog.md`）、
  禁止项/版本钉死（→ `../docs/CONSTRAINTS.md §一/§三`）。

## 按领域导航（权威在 CONSTRAINTS §二）

### DAP / codelldb（K1–K10）
custom-request 被拒、手动 `target modules load --slide` rebase、强制 `process handle SIG*`、
LuaJIT hex 截断、Android terminate-vs-disconnect、dap-repl F-key 多模式、Neovide F11 冲突、
disconnect 死循环、Windows pipe 正斜杠、per-project 断点持久化。
→ `../docs/CONSTRAINTS.md §二 DAP/codelldb`；`../docs/TOOLING.md §Pitfalls`

### Android ASLR（K11–K13）
`--slide` 必须在 `processCreateCommands` 内、先于 setBreakpoints 下发；`/proc/maps` hidepid
权限模型（用 `platform shell`）；环境残留卡 state T。
→ `../docs/CONSTRAINTS.md §二 Android ASLR`；用户 MEMORY `project_android_dap_aslr_fix.md`

### Android DAP attach platform 模式（K30–K40，宪法级）
唯一正解 = platform 模式 + serial-based `connect://[<serial>]:<port>`；
`gdbserver --attach` 在该设备从不 listen；localhost URL 被 getopt 吞空；
F9 成功判据 = LLDB resolved + stop event（K33）；source-file `breakpoint set -f` 在旧
gdb-remote 路线崩 lldb-dap，**K30 platform route + 3.5 匹配符号下不复现**（K34）；
file:line 断点需先 `target create` symbol-rich host libUE4.so（K35）。
**会话中 F9 即时下断点经 lldb-dap evaluate backtick `breakpoint set -f/-l` 通道是正解**
（K36，真机 `ANDROID-SERIAL-B` 闸门+端到端实证；`361b9e7` 的「内核静默丢弃」不适用当前路线，
不再需 `:UEDAPReattach`）；**不下发 `target modules load --slide` 则 attach 失败，slide 为
load-bearing**（K37，`UE_DAP_NO_SLIDE` 开关供其他设备复验；wait-launch 例外＝slide「晚到」）。
`/data/local/tmp/lldb-server` root-owned 残留 chmod EPERM → rm-then-push / reuse（K38）；
最早期 crash 只有 wait-for-debugger launch（`set-debug-app -w` + JDWP 闸门 + jdb 释放）
能抓到（K39）；liveness poller 在 timer 回调里同步 `vim.fn.system(adb)` 造成全天
~50 stalls/min 的主循环卡顿 train → 周期探测必须 async `vim.system` + in_flight（K40）。
→ `../docs/CONSTRAINTS.md §二 Android DAP attach`；归档 change `2026-06-03-android-dap-*` /
  `2026-06-15-android-dap-live-breakpoints`；ADR `../docs/plans/2026-06-15-android-dap-live-breakpoints.md`；
  证据 `../tools/evidence/android-f9/livebp-*.json`

### Android SO 快速部署（K44–K49）
SO-only 不能为旧 APK 补出新的 Java/JNI/manifest 产物，versionCode 差异在 root 路径拒绝、app-private
路径明确警告（K44）；项目名/Target 必须动态派生，不能把具体项目名当目录协议（K45）；APK 安装、SO
staging 和应用启动必须是显式动作，`ui` / `uq` 不得自动启动，运行时验证只由 `ul` 触发（K46）；
root transport 先实测 root adbd / `su 0`，均不可用时仍须验证已安装包自身的 debuggable + `run-as` +
startup-agent 能力（K47）；非 root 不能靠预 `dlopen`/SONAME 猜复用，必须重排 app ClassLoader native
搜索路径并让原 `System.loadLibrary` 完成 ART/JNI 加载，以唯一 maps 路径为成功证据（K48）；多文件发布
必须用唯一 generation + 原子 pointer，并以 OS mutex 串行化 `uq`/`ul`，部分 staging 不得静默回落，
启动必须复算 generation hash 并核对 APK 文件系统身份；maps 必须精确比较 pathname，失败启动必须停进程（K49）。
→ `../docs/CONSTRAINTS.md §二 K44–K49`；`../openspec/specs/android-so-quick-deploy/spec.md`

### CDB pipeline × UE build（K51）
prepare 家族读编译产物（Module.*.rsp/receipts），与 UBT build 并跑是 WAW 冒险且 prune 满线程抢核；
解法 build 赢——build 启动 cancel 在飞 pipeline、prepare 在 build 运行时拒绝启动；pipeline python
必须 `-u` + 分步 banner + 流式日志（jobstart data 块非行对齐要拼行）。
→ `../docs/CONSTRAINTS.md §二 K51`；`../docs/changelog.md` 2026-08-18

### 工具链 / LLVM（K14–K15、K41）
LLVM 22.0–22.1.5 的 `lldb-dap.exe` Windows 启动崩（`STATUS_STACK_BUFFER_OVERRUN`）；
适配器迁移弧线（lldb-dap 21.1.8 → codelldb 1.12.2 → **LLVM 22.1.6+ lldb-dap forward-only，
当前 Android DAP**）；依赖路径向上发现的 `.clangd` 会让跨根 TU 漏掉资源门禁，而 monolithic
External index 又不能证明 LSP definition 可达 body。现状固定 `--enable-config=false`，由
generation manifest + controlled BackgroundIndex CDB 管理覆盖，禁止恢复 `.clangd` 双写（K41）。
→ `../docs/CONSTRAINTS.md §二 工具链/LLVM`；`../docs/TOOLING.md`

### snacks / clangd / lazy（K16–K24，活跃 workaround；K21 已退役 2026-07-26）
picker 冷启卡死、projects picker 卡数十秒、str_byteindex 越界、smart picker 死 buffer、
clangd 非 `file://` URI 刷屏、~~Lazy float invalid buffer~~（上游已修，workaround 删除）、
`q` 关失效 buffer、Neovide 残留进程、blink.cmp 换行破坏 undo。
→ 各 `lua/workarounds/<scope>/*.lua` frontmatter（权威）；`../docs/CONSTRAINTS.md §二 snacks/clangd/lazy`

### goto-def / cursor（K25、K42）
跨 buffer 跳转 cursor 漂移；解法砍 snacks.scroll + PreserveBufferView，jumper `_on_reassert` 校正。
裸 symbol cache、arity filter 与 standalone header parse 均不能证明 C++ overload；唯一合法答案来自
active build 的 compiler identity，header 必须在 proven origin TU 中求值。
→ `../docs/CONSTRAINTS.md §二 goto-def / cursor`；`../docs/architecture-symbol-resolution.md`

### grep 缓存 / csearch 失效（K26–K27）
负探测被永久缓存 → `<leader>/` 静默走最慢目录遍历搜不全（修：负探测不缓存 + 重探 + 回落可见）；
切平台/换引擎 grep 缓存不失效（修：csearch 按平台+配置分路径、切平台不删重来、engine_root 持久化）。
→ `../docs/CONSTRAINTS.md §二 grep 缓存/csearch 失效`；`../docs/architecture/grep-cache-invalidation.md`

## 新增一条教训

1. 优先在权威出处记录（workaround frontmatter / `docs/CONSTRAINTS.md §二` / `docs/TOOLING.md`）。
2. 在本文件对应领域补一句主题导航 + 出处指针。
3. 必须含：症状 → 解决约束 → 出处。

相关区：决策 → `../decisions/README.md`；约束 → `../docs/CONSTRAINTS.md`；总览 → `../docs/architecture/overview.md`。
