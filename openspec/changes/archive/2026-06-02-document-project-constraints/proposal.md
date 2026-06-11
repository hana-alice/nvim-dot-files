## Why

本仓库是一套基于 LazyVim 的 Neovim 配置，专门用于在 Windows 上编辑超大型
Unreal Engine C++ 项目。经过 100+ 次提交，它沉淀了大量非显而易见、来之不易的
工程经验：刻意定下的**禁止项**（"不用 telescope"、"不做全局 `vim.lsp.handlers`
覆盖"）、已经付出过真实调试成本的**坑**（codelldb 的 `request="custom"` 被拒、
LuaJIT 下 `string.format` 64 位 hex 截断、LLVM 的 `STATUS_STACK_BUFFER_OVERRUN`
事故、Android ASLR `--slide` 的下发时序），以及承重的**约束**（clangd/LLVM 只能22.1.6版本以上
、NDK 27、codelldb 1.12.2、六条仓库约定、workaround frontmatter 契约）。

目前这些知识散落在 `README.md`、`docs/architecture-vs-lazyvim.md`、
`docs/TOOLING.md`、`lua/workarounds/README.md` 及各文件 frontmatter、
`docs/architecture-symbol-resolution.md`、MEMORY 笔记和 commit message 里。
没有一个统一入口能回答：*在动这个仓库之前，什么是禁止的、已经踩过哪些坑、
我绝对不能破坏什么？* 这个缺口的代价很具体——重新引入一个早已解决过的坏模式。

## What Changes

- 新增一份权威参考文档 `docs/CONSTRAINTS.md`，它**索引**（而非复制）项目知识，
  分成与需求对应的三个部分：
  - **禁止（Prohibitions）** —— 被拒绝的工具/模式，每条配一句理由并链接到
    其权威出处。
  - **踩过的坑（Pitfalls）** —— 已经踩过的陷阱，每条给出 症状 + 解决约束 +
    出处指针（codelldb #1–#10、ASLR rebase、F-key 模式、Windows pipe 斜杠、
    snacks 卡死、LLVM 崩溃史、lldb-dap→codelldb→回退 的迁移弧线）。
  - **约束（Constraints）** —— 版本钉死项与六条约定，并引用 workaround
    frontmatter 契约和启动顺序假设。
- 一份简短的维护契约，保证文档随新增 workaround/坑 一起更新，而不是腐烂。
- 从 `README.md`、`docs/architecture-vs-lazyvim.md`（"Reading order"）和
  `CLAUDE.md`（agent 契约）交叉链接到新文档。
- 纯文档变更：不改 `.lua`/`.py`/`.go`，不改 plugin-spec，运行时行为零变化。

## Capabilities

### New Capabilities
- `project-constraints-doc`：一个可维护的参考能力，归纳本 UE/Neovim 配置的
  禁止项、坑与约束；定义固定的三段式结构、每条都带权威出处链接，并配一份
  更新契约以防腐烂。

### Modified Capabilities
<!-- 无。openspec/specs/ 下当前没有可修改的既有 capability。 -->

## Impact

- **新增文件**：`docs/CONSTRAINTS.md`。
- **修改的文档**：`README.md`（"Conventions" 下加链接）、
  `docs/architecture-vs-lazyvim.md`（"Reading order" 列表）、`CLAUDE.md`
  （给 agent 的最小指针）。
- **不改代码**：不动 `.lua`/`.py`/`.go`；不改 plugin spec；既有测试、
  headless 探针、DAP 接线均不受影响。
- **受众**：人类贡献者与 AI 编码 agent。
- **挖掘来源（只读）**：`README.md`、`docs/architecture-vs-lazyvim.md`、
  `docs/TOOLING.md`、`lua/workarounds/README.md` 及 11 个 workaround 文件、
  `docs/architecture-symbol-resolution.md`、`init.lua` 启动顺序、MEMORY 笔记
  与 git history。
- **公开镜像安全**：仓库镜像到公开 GitHub remote；本文档不引入任何 secret
  或新的私有专属路径。
