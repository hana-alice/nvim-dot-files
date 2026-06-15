# Lessons · 平台怪癖与调试硬知识

> **lessons/** 区：付出过真实调试成本的陷阱与硬知识。
> 出处优先：权威踩坑清单在 `docs/CONSTRAINTS.md §二（踩过的坑 K1–K37）`，
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

### Android DAP attach platform 模式（K30–K37，宪法级）
唯一正解 = platform 模式 + serial-based `connect://[<serial>]:<port>`；
`gdbserver --attach` 在该设备从不 listen；localhost URL 被 getopt 吞空；
F9 成功判据 = LLDB resolved + stop event（K33）；source-file `breakpoint set -f` 在旧
gdb-remote 路线崩 lldb-dap，**K30 platform route + 3.5 匹配符号下不复现**（K34）；
file:line 断点需先 `target create` symbol-rich host libUE4.so（K35）。
**会话中 F9 即时下断点经 lldb-dap evaluate backtick `breakpoint set -f/-l` 通道是正解**
（K36，真机 `2e2df4cb` 闸门+端到端实证；`361b9e7` 的「内核静默丢弃」不适用当前路线，
不再需 `:UEDAPReattach`）；**不下发 `target modules load --slide` 则 attach 失败，slide 为
load-bearing**（K37，`UE_DAP_NO_SLIDE` 开关供其他设备复验）。
→ `../docs/CONSTRAINTS.md §二 Android DAP attach`；归档 change `2026-06-03-android-dap-*` /
  `2026-06-15-android-dap-live-breakpoints`；ADR `../docs/plans/2026-06-15-android-dap-live-breakpoints.md`；
  证据 `../tools/evidence/android-f9/livebp-*.json`

### 工具链 / LLVM（K14–K15）
LLVM 22.0–22.1.5 的 `lldb-dap.exe` Windows 启动崩（`STATUS_STACK_BUFFER_OVERRUN`）；
适配器迁移弧线（lldb-dap 21.1.8 → codelldb 1.12.2 → **LLVM 22.1.6+ lldb-dap forward-only，
当前 Android DAP**）。
→ `../docs/CONSTRAINTS.md §二 工具链/LLVM`；`../docs/TOOLING.md`

### snacks / clangd / lazy（K16–K24，活跃 workaround）
picker 冷启卡死、projects picker 卡数十秒、str_byteindex 越界、smart picker 死 buffer、
clangd 非 `file://` URI 刷屏、Lazy float invalid buffer、`q` 关失效 buffer、
Neovide 残留进程、blink.cmp 换行破坏 undo。
→ 各 `lua/workarounds/<scope>/*.lua` frontmatter（权威）；`../docs/CONSTRAINTS.md §二 snacks/clangd/lazy`

### goto-def / cursor（K25）
跨 buffer 跳转 cursor 漂移；解法砍 snacks.scroll + PreserveBufferView，jumper `_on_reassert` 校正。
→ `../docs/architecture-symbol-resolution.md §2.7`

### grep 缓存 / csearch 失效（K26–K27）
负探测被永久缓存 → `<leader>/` 静默走最慢目录遍历搜不全（修：负探测不缓存 + 重探 + 回落可见）；
切平台/换引擎 grep 缓存不失效（修：csearch 按平台+配置分路径、切平台不删重来、engine_root 持久化）。
→ `../docs/CONSTRAINTS.md §二 grep 缓存/csearch 失效`；`../docs/architecture/grep-cache-invalidation.md`

## 新增一条教训

1. 优先在权威出处记录（workaround frontmatter / `docs/CONSTRAINTS.md §二` / `docs/TOOLING.md`）。
2. 在本文件对应领域补一句主题导航 + 出处指针。
3. 必须含：症状 → 解决约束 → 出处。

相关区：决策 → `../decisions/README.md`；约束 → `../docs/CONSTRAINTS.md`；总览 → `../docs/architecture/overview.md`。
