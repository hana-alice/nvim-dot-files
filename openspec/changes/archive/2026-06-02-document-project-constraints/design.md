## Context

项目的制度性知识——什么是禁止的、哪些坑已经付出过时间成本、哪些约束是承重的
——真实且详尽，但散落在多个文件里：

- `README.md` —— "Conventions" 与那些刻意的排除项。
- `docs/architecture-vs-lazyvim.md` —— 每节的 "Why" 与 "What we deliberately
  *don't* do"。
- `docs/TOOLING.md` —— 版本钉死项 + "Pitfalls (codelldb route, hard-won) #1–#10"
  + LLVM `STATUS_STACK_BUFFER_OVERRUN` 分析 + lldb-dap→codelldb 的迁移弧线。
- `lua/workarounds/README.md` + 11 个 workaround 文件 —— frontmatter 契约和
  具体 quirk 修复（snacks 卡死、clangd 非 `file://` URI 刷屏等）。
- `docs/architecture-symbol-resolution.md` —— 分层 goto-def fallback 规则。
- `init.lua` —— 明确的启动顺序（shada cleanup → log → neovide → snacks
  global → lazy → windows → recent_projects → workarounds → ue），以及一条
  "不要重复 require LazyVim 自动加载的 config 模块" 的 NOTE。
- MEMORY 笔记 + git history —— Android ASLR `--slide` 时序、F10 节流、
  多线程 stopped 突发、适配器迁移的相关 commit。

没有单一入口能回答 "在我写代码之前，什么不能做、已经出过什么问题？"。本次变更
构建这个索引。它是纯文档的；每条事实的权威出处都已存在。

## Goals / Non-Goals

**Goals：**
- 一份权威、可速览的 `docs/CONSTRAINTS.md`，分三段：
  禁止（Prohibitions）、踩过的坑（Pitfalls）、约束（Constraints）。
- 每条都标注出处，便于核验，且原始细节永不丢失（文档做索引，不做替代）。
- 从 README、架构审计文档、CLAUDE.md 都能发现它。
- 一份维护契约，保证文档常新。

**Non-Goals：**
- 不改源码、plugin-spec 或运行时行为。
- 不从 TOOLING.md / workaround README 整段搬运原文——只做摘要+链接。
- 不发明新的禁止项/约束；只记录仓库已经在执行的内容。
- 不是 keymap cheatsheet（那是 `docs/ue_lazyvim_cheatsheet.md`）。

## Decisions

**D1 —— 单文件 `docs/CONSTRAINTS.md`，而非 `docs/constraints/` 目录树。**
内容只有几页，单文件更便于速览和 grep。按域拆分会把我们正在合并的知识重新
碎片化。

**D2 —— 三个固定小节，对应需求（禁止 / 坑 / 约束）。** 用户问的正是
"什么是禁止的, 踩过哪些坑, 有哪些约束"；匹配这个结构能让文档贴合团队的
思考方式。

**D3 —— 索引并链接，不复制。** 每条 1–2 行 + 出处指针（如
`→ docs/TOOLING.md §Pitfalls #4`）。避免摘要与权威出处随时间漂移；一条约束
有两份拷贝，迟早会互相矛盾。

**D4 —— 从 CLAUDE.md 交叉链接，且最小化。** agent 契约是 AI agent 最常读的
文件，所以在那里放一个指针最能提升遵从度。这条编辑只放一个指针，避免打扰
既有的 local-workflow 规则。

**D5 —— 公开镜像安全。** TOOLING.md 已注明仓库公开镜像、须保持事实性且
英文。CONSTRAINTS.md 沿用此规则：正文规范内容用英文，中文只出现在小节标签/
括注里；不含 secret、不引入新的私有专属路径（`C:\tools\...` 适配器路径已在
TOOLING.md 中公开出现）。

**D6 —— 把迁移弧线作为历史而非当前状态来呈现。** DAP 适配器经历了
lldb-dap(21.1.8) → codelldb(1.12.2) → lldb-dap(22.1.6 platform mode)（见 git
log）。文档清楚标出*当前*适配器，并把被取代的路线标为 "保留作参考"，与
TOOLING.md 自身的状态横幅一致，确保读者不会照着退役的钉死项行事。

## Risks / Trade-offs

- [文档腐烂——摘要偏离出处] → D3 链接到出处 + 维护契约要求；文档作为索引，
  权威细节更新会通过引用自动传导。
- [不完整——漏掉某条真实约束] → 任务期间挖掘所有列举的来源；维护契约让后续
  补充成本低且属预期之内。
- [过期适配器钉死项造成困惑] → D6：显式标注 当前 vs 被取代，写作时对照最新
  `docs/TOOLING.md` 与 git log 复核。
- [与 README "Conventions" 冗余] → 接受：README 保持电梯演讲并向下链接；
  CONSTRAINTS.md 才是详尽清单。

## Migration Plan

1. 创建 `docs/CONSTRAINTS.md`（三小节 + 维护契约）。
2. 加链接：README "Conventions"、architecture-vs-lazyvim "Reading order"、
   CLAUDE.md 指针。
3. 核对 `git status` 仅显示 `docs/`、`CLAUDE.md`、`openspec/`。
4. 回滚（若需要）：`git rm docs/CONSTRAINTS.md` + 还原 3 处链接编辑；运行时
   零影响，故回滚无风险。

## Open Questions

- 无阻塞项。可选的后续工作：一条 CI lint，断言 `lua/workarounds/<scope>/` 下
  每个文件都有合法 frontmatter —— 本次范围之外。
