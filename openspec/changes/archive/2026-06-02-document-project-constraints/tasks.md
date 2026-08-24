## 1. 挖掘来源材料

- [x] 1.1 从 `README.md`（"Conventions" + 功能列表）提取 6 条约定 + 刻意排除项。
- [x] 1.2 从 `docs/architecture-vs-lazyvim.md`（"What we deliberately *don't* do" + 每节 "Why"）提取禁止项/约束。
- [x] 1.3 从 `docs/TOOLING.md` 提取版本钉死项 + codelldb Pitfalls #1–#10 + LLVM `STATUS_STACK_BUFFER_OVERRUN` 历史 + 适配器迁移弧线。
- [x] 1.4 从 `lua/workarounds/README.md` 提取 frontmatter 契约 + "何时不该隔离"；列举 11 个活跃 workaround 文件及其一句话症状。
- [x] 1.5 从 `docs/architecture-symbol-resolution.md` 提取分层 fallback 约束（clangd→csearch→gtags、cache 命中率、jumper 后置条件）。
- [x] 1.6 从 `init.lua` 提取启动顺序假设（顺序 + "不要重复 require LazyVim 自动加载模块" 的 NOTE）。
- [x] 1.7 从 MEMORY 笔记 + 相关 commit 提取 Android DAP ASLR `--slide` 时序、环境残留、BP 顺序的教训。

## 2. 撰写约束文档

- [x] 2.1 创建 `docs/CONSTRAINTS.md` 头部（目的、受众、公开镜像说明）+ 三小节目录。
- [x] 2.2 写 **禁止（Prohibitions）**：被拒绝的工具/模式，每条一行 + 理由 + 出处链接。
- [x] 2.3 写 **踩过的坑（Pitfalls）**：codelldb #1–#10、ASLR rebase、F-key 模式、Neovide F11、disconnect 死循环、Windows pipe 斜杠、snacks first-open 卡死、clangd 非 `file://` URI 刷屏、LLVM 崩溃史、适配器迁移弧线 —— 每条带 症状 + 解决约束 + 出处链接。
- [x] 2.4 写 **约束（Constraints）**：版本钉死项（clangd/LLVM 22.x、codelldb 1.12.2、NDK 27、Neovim 0.10+）、6 条约定、workaround frontmatter 契约引用，以及 `init.lua` 启动顺序假设。
- [x] 2.5 写 **维护契约**：何时/如何新增条目；要求附出处引用 +（对坑）症状与解决约束。

## 3. 交叉链接与核验

- [x] 3.1 在 `README.md`（"Conventions" 下）链接 `docs/CONSTRAINTS.md`。
- [x] 3.2 在 `docs/architecture-vs-lazyvim.md` 的 "Reading order" 列表加入 `docs/CONSTRAINTS.md`。
- [x] 3.3 在 `CLAUDE.md` 中加一个指向 `docs/CONSTRAINTS.md` 的最小指针。
- [x] 3.4 运行 `git status`；确认只改动了 `docs/`、`CLAUDE.md`、`openspec/` —— 无 `.lua`/`.py`/`.go`。
- [x] 3.5 核验每条都有可解析的出处指针；对照最新 `docs/TOOLING.md` + git log 复核 当前 vs 被取代 的适配器钉死项；确认无 secret/新私有路径（公开镜像安全）。
