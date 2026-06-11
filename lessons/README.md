# Lessons · 平台怪癖与调试硬知识

> **lessons/** 区：付出过真实调试成本的陷阱与硬知识。
> 出处优先：权威踩坑清单在 `docs/CONSTRAINTS.md §二（踩过的坑 K1–K33）`，
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

### Android DAP attach platform 模式（K30–K33，宪法级）
唯一正解 = platform 模式 + serial-based `connect://[<serial>]:<port>`；
`gdbserver --attach` 在该设备从不 listen；localhost URL 被 getopt 吞空；
source-file 断点崩 lldb-dap（待 platform 路径复验）。
→ `../docs/CONSTRAINTS.md §二 Android DAP attach`；归档 change `2026-06-03-android-dap-*`

### 工具链 / LLVM（K14–K15）
LLVM 22.0–22.1.5 的 `lldb-dap.exe` Windows 启动崩（`STATUS_STACK_BUFFER_OVERRUN`）；
适配器迁移弧线（lldb-dap 21.1.8 → codelldb 1.12.2 当前）。
→ `../docs/CONSTRAINTS.md §二 工具链/LLVM`；`../docs/TOOLING.md`

### snacks / clangd / lazy（K16–K24，活跃 workaround）
picker 冷启卡死、projects picker 卡数十秒、str_byteindex 越界、smart picker 死 buffer、
clangd 非 `file://` URI 刷屏、Lazy float invalid buffer、`q` 关失效 buffer、
Neovide 残留进程、blink.cmp 换行破坏 undo。
→ 各 `lua/workarounds/<scope>/*.lua` frontmatter（权威）；`../docs/CONSTRAINTS.md §二 snacks/clangd/lazy`

### goto-def / cursor（K25）
跨 buffer 跳转 cursor 漂移；解法砍 snacks.scroll + PreserveBufferView，jumper `_on_reassert` 校正。
→ `../docs/architecture-symbol-resolution.md §2.7`

## 新增一条教训

1. 优先在权威出处记录（workaround frontmatter / `docs/CONSTRAINTS.md §二` / `docs/TOOLING.md`）。
2. 在本文件对应领域补一句主题导航 + 出处指针。
3. 必须含：症状 → 解决约束 → 出处。

相关区：决策 → `../decisions/README.md`；约束 → `../docs/CONSTRAINTS.md`；总览 → `../docs/architecture/overview.md`。
