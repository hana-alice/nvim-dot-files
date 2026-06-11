# project-constraints-doc Specification

## Purpose

在 `docs/CONSTRAINTS.md` 提供一份权威的、统一归纳项目禁止项、踩过的坑与约束的参考文档，并使其可被发现、可溯源、可维护。该文档以索引/链接指向仓库既有出处，而非整段复制原文。

## Requirements

### Requirement: Consolidated constraints reference document

仓库 SHALL 在 `docs/CONSTRAINTS.md` 提供一份权威文档，统一归纳项目的禁止项、
踩过的坑与约束。该文档 MUST 来源于仓库既有出处，并且 MUST 通过索引/链接指向
这些出处，而非整段复制其原文。此外，该文档 MUST 作为导航中枢，链接到持久化
知识库（`memory/`、`decisions/`、`lessons/`、`docs/architecture/`）与递归本地
规则（各目录 `CLAUDE.md`），使 AI agent 能从此入口发现就地规则。

#### Scenario: Document exists and is discoverable

- **WHEN** 贡献者或 AI agent 寻找项目规则
- **THEN** `docs/CONSTRAINTS.md` 存在，并被 `README.md`、
  `docs/architecture-vs-lazyvim.md` 和 `CLAUDE.md` 链接到

#### Scenario: Navigates to knowledge base and local rules

- **WHEN** AI agent 从 `docs/CONSTRAINTS.md` 出发寻找子系统级规则或持久知识
- **THEN** 文档含指向 `memory/`、`decisions/`、`lessons/`、`docs/architecture/overview.md`
  的链接
- **AND** 文档说明「目录无本地 `CLAUDE.md` 时回落最近祖先目录规则」的继承语义

#### Scenario: Change is documentation-only

- **WHEN** 该变更被应用
- **THEN** 没有任何 `.lua`、`.py` 或 `.go` 运行时模块被修改，没有 plugin spec 或
  运行时行为变化（允许新增纯文档 `CLAUDE.md`/README/知识库文件，以及新增只读的
  headless 回归用例 `tests/cases/structure_spec.lua`；不触碰既有模块行为）

### Requirement: Prohibitions section (禁止)

文档 SHALL 包含一个清晰标注的「禁止」小节，列举仓库刻意拒绝的模式、工具与
做法，每条配一句理由和一个出处指针。

#### Scenario: Prohibitions are enumerated with rationale

- **WHEN** 读者查阅「禁止」小节
- **THEN** 它至少列出：不用 telescope（仅用 snacks.picker）；不做 mason
  auto-install（钉死工具链）；不做全局 `vim.lsp.handlers` 覆盖（走
  `lsp_fallback`/`workarounds`）；不写 inline workaround（必须用 registry）；
  不做周期性 ticker 通知；不阻塞主线程；不对 64 位值用
  `string.format("%x", addr)`（LuaJIT 会截断到 32 位）；codelldb 不用
  `request="custom"`；不用 which-key 自动 cheatsheet；不在配置内集成
  copilot/codeium
- **AND** 每条都包含简短理由和指向出处的链接

### Requirement: Pitfalls section (踩过的坑)

文档 SHALL 包含一个「踩过的坑」小节，记录此前遭遇的陷阱。每个坑 MUST 说明
症状与解决约束，并 SHOULD 引用原始出处文件或文档。

#### Scenario: DAP, toolchain, and platform pitfalls are recorded

- **WHEN** 读者查阅「踩过的坑」小节
- **THEN** 它包含 codelldb 路线的坑（custom-request 被拒；手动
  `target modules load --slide` rebase；强制
  `process handle SIGSEGV/SIGBUS -p true -s false`；LuaJIT hex 截断；
  Android 的 terminate-vs-disconnect；dap-repl F-key 多模式绑定；
  Neovide F11 全屏冲突；disconnect 死循环；Windows pipe 正斜杠路径；
  per-project breakpoint 持久化）
- **AND** 它包含 LLVM `STATUS_STACK_BUFFER_OVERRUN` 历史、Android ASLR
  `--slide` 须先于断点 的教训、snacks picker first-open 卡死、clangd 非
  `file://` URI 报错刷屏，以及 lldb-dap ⇄ codelldb 适配器迁移弧线

#### Scenario: Each pitfall is traceable to a source

- **WHEN** 读者想核验某个坑
- **THEN** 该条目引用原始出处文件或文档（如 `docs/TOOLING.md`、
  `lua/ue/dap/android.lua`、某个 workaround 文件或 MEMORY）

### Requirement: Constraints section (约束)

文档 SHALL 包含一个「约束」小节，列出承重的版本钉死项、项目约定，以及所有
贡献都必须遵守的结构性假设。

#### Scenario: Version pins, conventions, and boot order are listed

- **WHEN** 读者查阅「约束」小节
- **THEN** 它列出工具链钉死项（clangd/LLVM 22.x —— 不要降级；codelldb
  1.12.2；NDK 27 lldb-server；Neovim 0.10+）和六条约定（AST/treesitter 优先于
  regex；async 优先于阻塞；workaround 隔离；可自验证的 `M.*` 模块；不做周期性
  ticker 通知；未变更时跳过写入）
- **AND** 它引用 `lua/workarounds/README.md` 的 workaround frontmatter 契约
  和 `init.lua` 启动顺序假设

### Requirement: Maintenance contract

文档 SHALL 声明它如何保持常新，以免腐烂；该契约 MUST 覆盖知识库与本地规则层。

#### Scenario: Update contract is stated

- **WHEN** 贡献者新增一个 workaround 或踩到一个新坑
- **THEN** 维护小节指示他们将其记入 `docs/CONSTRAINTS.md`，附出处引用，并
  （对坑而言）附症状与解决约束

#### Scenario: Knowledge base and local rules stay coherent

- **WHEN** 贡献者新增一个子系统目录，或新增/迁移一份知识到 `memory/` `decisions/` `lessons/`
- **THEN** 维护契约要求为新目录补一份本地 `CLAUDE.md`（声明继承父级），并在对应
  知识区域 README 登记新条目
- **AND** 可发现性回归（`tests/cases/structure_spec.lua`）守护这些不变量不被破坏
