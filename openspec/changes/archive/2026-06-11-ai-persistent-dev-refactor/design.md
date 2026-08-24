## Context

仓库是一套 Neovim UE 配置（LazyVim 基座 + 自研 `lua/ue.lua` 巨模块 + `lua/ue/` `lua/utils/` `lua/workarounds/` 等子系统）。规则与知识现状：

- **聚合在顶层**：`docs/CONSTRAINTS.md` 是唯一权威索引（禁止 P1–P17、坑 K1–K33、约束 C1–C5）。
- **散在多处**：`docs/plans/`（ADR + 迭代日志）、各 workaround frontmatter、已归档 openspec change、用户 MEMORY。
- **顶层 CLAUDE.md** 是工作流指令（不含子系统规则）；全仓只有 1 个 CLAUDE.md。

对持续介入的 AI agent，痛点是：进入 `lua/ue/dap/` 这种目录时，没有就地规则可读，只能回顶层翻 CONSTRAINTS 或靠 chat 记忆。`refra.txt` 给的剧本正是解决此问题：持久项目记忆 + 子系统边界 + **每个主要区域本地规则**。

已勘察确认的承重事实：

1. **`lua/` 布局是 runtime 契约**：Neovim 用 `runtimepath` + `lua/?.lua;lua/?/init.lua` 解析 `require("ue")`/`require("utils.platform")`。移动 `lua/` 下任何文件都会断 require，并违反 CONSTRAINTS「不做无关重构」。`tests/run.lua`、`scripts/headless_smoke.lua`、`.github/workflows/headless.yml` 均依赖此布局。
2. **游离物均 untracked**：根目录 `""`、`UsersUSERAppDataLocalTemp-artifact.html`、`lua/ue.lua.bak-20260528-185201` 都不在 git 跟踪内（`.gitignore` 已忽略 `data`/`*.log`/`.hermes/` 等），清理无历史风险。
3. **现有回归框架可复用**：`tests/run.lua` 自动发现 `tests/cases/*_spec.lua`，harness 提供断言——可发现性回归直接落为一个新 spec 文件。
4. **CLAUDE.md 是 Claude Code 原生目录级指令**：放在子目录会被自动识别为该目录上下文规则，无需额外机制。

约束（CLAUDE.md / openspec/config.yaml / CONSTRAINTS）：中文产出物、**不重写工作系统**、**不做无关重构**、不引依赖、出处优先不复制原文、公开镜像不含 secret。

## Goals / Non-Goals

**Goals:**

- 让 AI agent 进入任意子系统目录即可就地发现规则（递归本地 `CLAUDE.md`，子级继承父级、只写增量）。
- 建立持久化知识库（memory / decisions / lessons / docs/architecture），把散落知识索引/迁移进去，跨会话稳定可发现。
- 把「规则就地存在 + 知识库结构完整 + 链接不悬空」变成 headless 回归守护项，防腐烂。
- 清理根目录历史游离物，让仓库「看起来是有意组织的」。
- 全程不动 `lua/` 运行时代码、不改 init.lua、不改 require 路径。

**Non-Goals:**

- 不把 `lua/` 重组为 `src/`（runtime 契约 + CONSTRAINTS 双重否决）。
- 不重写任何工作系统、不为对齐 refra.txt 模式而发明架构。
- 不移动 `tools/` 下的第三方/生成物（`cindex-uefilter` Go 源、`__pycache__`）。
- 不把 `docs/plans/` 大搬家——倾向「`decisions/` 建索引指回原位」以遵守 refra「minimize disruptive moves」。
- 不追求文档行覆盖率，覆盖口径是「结构完整 + 可发现 + 链接有效」。

## Decisions

### 决策 0：根 CLAUDE.md = 强制执行入口（源头治理）

- **问题**：被动文档（CONSTRAINTS / testing-regression / 子目录 CLAUDE.md）只解决「规则可发现」，解决不了「新 context 的 agent 真去执行」。换模型/换 agent/上下文一长，纪律性步骤（跑回归、记 changelog、milestone）最先被丢。
- **治理点**：根 `CLAUDE.md` 是 Claude Code **每个新 context 自动注入**的唯一文件——把它从「工作流偏好」升级为**强制执行入口**：
  - 顶部加 **SESSION-START 协议块**：动代码前第一动作必须依次读 `docs/CONSTRAINTS.md` → `memory/project_overview.md` → 当前改动目录 `CLAUDE.md`（无则回落最近祖先）。表述为强制前置步骤。
  - 加 **Definition of Done**：缺一不算完成的三条硬条件 = ①按范围跑回归全绿 ②记 changelog（Validation 写回归范围）③收尾版本走 milestone（semver + 四件套）。
- **强制力收口**：回归/记录/milestone 三条政策的「权威入口」统一指向根 `CLAUDE.md` 的 DoD；其余文档退为出处/细节。子目录 `CLAUDE.md` 在 agent 操作到该目录时被加载，承接递归增量规则。
- 这是**源头治理**：让 agent 在 context 启动那一刻被注入流程，而非靠它事后自觉。
- 理由：用户指出「新 context 的 agent 未必照规划做」，且明确「CLAUDE.md 执行、其他兜底是擦屁股」——强制力放在启动即注入的根 CLAUDE.md，是唯一不依赖 agent 自觉的源头点。

### 决策 1：`lua/` 代码零移动，重构落在「文档层 + 递归规则层」

- 不移动/重命名 `lua/` 下任何 `.lua`。重构 = 在现有每层目录就地新增 `CLAUDE.md` + 顶层建知识库。
- 理由：runtime 契约（require/runtimepath）+ CONSTRAINTS「不做无关重构」+ refra「minimize disruptive moves / do not rewrite working systems」三者一致。
- 备选：重组为 `src/` → 否决（高风险断 require、与约束冲突，用户虽要求「力度加大」但力度应加在「知识/规则密度」而非「危险的文件搬迁」）。

### 决策 2：本地规则文件统一命名 `CLAUDE.md`

- refra.txt 首选项，且 Claude Code 原生把目录级 `CLAUDE.md` 当作该目录上下文规则——零额外机制即可被 AI 发现。
- 根 `CLAUDE.md` 已存在（工作流指令），保留；子目录新增的是「子系统规则」，职责不冲突。

### 决策 3：递归覆盖 + 继承模型（只写增量）

- 覆盖目录（按当前模块树，承担内容多的递归到子级）：
  - `lua/CLAUDE.md`（Lua 代码总规则：M.* 公共 API、async、AST>regex、headless 可测）
  - `lua/ue/CLAUDE.md` → `cdb/` `core/` `dap/` 各一份
  - `lua/utils/CLAUDE.md` → `ue_goto/` `code_search/` `platform/` 各一份
  - `lua/config/CLAUDE.md`、`lua/plugins/CLAUDE.md`、`lua/workarounds/CLAUDE.md`、`lua/trouble/CLAUDE.md`、`lua/nio/CLAUDE.md`
  - `tools/CLAUDE.md`、`scripts/CLAUDE.md`、`tests/CLAUDE.md`、`docs/CLAUDE.md`
- 继承约定：每个子级文件**顶部声明**「继承自 `../CLAUDE.md`，本文件只列差异」，正文只写该目录**专属**的约定/坑/性能点；与父级相同的不重复。
- 「无本地规则回落最近祖先」语义写进根 `CLAUDE.md` 与 `docs/CONSTRAINTS.md`。
- 理由：避免每层抄一遍变成维护负担；增量式贴合 refra「短小聚焦 20–80 行」。

### 决策 4：知识库采用顶层 `memory/` `decisions/` `lessons/` + `docs/architecture/`

- 贴近 refra 模型；`docs/architecture/` 放 docs 下（与既有 `docs/architecture-*.md` 同域，避免再造一个顶层 docs 根）。
- 迁移策略「索引优先」：
  - `decisions/README.md` 索引 `docs/plans/` 中的 ADR（指回原位，不搬文件——`docs/plans/` 已有成熟 README 与交叉链接，搬家会断大量链接）。
  - `lessons/README.md` 索引 CONSTRAINTS §二 坑条目 + 用户 MEMORY 主题（Android ASLR / codelldb / Windows pipe）。
  - `memory/project_overview.md` 给「先读顺序」与子系统速查，指向各 `CLAUDE.md`。
  - `docs/architecture/overview.md` 写子系统/数据流/平台层/构建流水线/归属边界，指针链到既有 `architecture-symbol-resolution.md`、`architecture-vs-lazyvim.md`、`TOOLING.md`。
- 理由：refra 明确要求 minimize moves + 出处优先；本仓既有 `docs/plans/` 体系成熟，硬搬弊大于利。
- 备选：全放 `docs/` 下（docs/memory 等）→ 否决，用户要求「力度加大、贴近模型」，顶层目录更显眼、更符合 refra 的 AI 可发现性目标。

### 决策 5：可发现性回归落为 `tests/cases/structure_spec.lua`

- 三组断言：①「主要目录清单」每个有 `CLAUDE.md`；②知识库四根文件存在；③关键文档的相对路径 Markdown 链接不悬空（提取 `[..](rel/path.md)`，`vim.fn.filereadable` 校验）。
- 复用现有 harness + 自动发现，纳入 `nvim --headless -l tests/run.lua` 全量。
- 「主要目录清单」在用例内显式维护（冻结清单，新增子系统目录需同步——与 commands 清单同样的防误删契约）。
- 理由：把「规则不腐烂」变成 CI 可执行守护，呼应 refra Phase 6 final verification。

### 决策 6：改动后回归政策 = 文档化规则 + 分范围映射（不加强制 hook）

- 写一条**权威政策**而非自动机制：任何 `.lua` 运行时代码或 `tests/` 改动，完成前必须跑对应范围回归并全绿；新增功能必须补 `*_spec.lua`。
- **分范围、不一刀切全量**——按改动类型给「改动 → 必跑 spec filter」映射（控制回归成本）：
  | 改动位置 | 最小必跑 filter |
  |---|---|
  | `lua/config/keymaps.lua` / 命令定义 | `keymaps` `commands` |
  | `lua/ue/config.lua`（schema） | `ue_config` `smoke` |
  | `lua/ue/cdb/**` | `ue_cdb` |
  | `lua/ue/dap/**` / `lua/utils/platform/**` | `dap` `platform` |
  | `lua/utils/ue_goto/**` / `code_search/**` / `ue_paths.lua` | `ue_goto_behavior` `ue_paths` `utils` |
  | `lua/config/options.lua` / `autocmds.lua` | `options` `autocmds` |
  | `lua/workarounds/**` | `workarounds` `smoke` |
  | 文档/规则/知识库结构 | `structure` |
  | 跨子系统 / 公共 helper / 重构 / 拿不准 | **全量（不带 filter）** |
- 升级原则：**提交/合并前必跑全量**；影响面不确定时升级到全量，不猜窄 filter。
- 落点：`docs/CONSTRAINTS.md`（约束条目 + 指针）、根 `CLAUDE.md`（一句政策 + 指针）、`tests/CLAUDE.md`（速查映射表）、`docs/testing-regression.md`（权威操作细节）。
- 不加 PostToolUse hook：保持「规则靠文件发现」而非「靠工具拦截」，与仓库风格一致；强制力来自政策 + 可发现性回归守护文档存在。
- 理由：用户明确要求「衡量回归范围、不同修改对应不同范围」——映射表正是把这一诉求写成可遵循的规则。

### 决策 7：改动记录政策 = 复用既有 changelog + 提升为权威规则

- `docs/changelog.md` 已存在且有成熟模板（`### YYYY-MM-DD — 标题` + Task/Implemented/Pitfalls/Validation/Follow-ups）与 How-to-use，但该「每次改动必记」的要求**只写在 changelog 自己头部**——CONSTRAINTS、根 CLAUDE.md 都没提，AI agent 不读 changelog 头部就发现不了。
- 本决策**不新造机制**，只把这条已有约定**提升为权威可发现规则**：在 `docs/CONSTRAINTS.md` §三加约束 + §四维护契约、根 `CLAUDE.md` 加一句政策 + 指针，指向 changelog 的模板段。
- 与回归政策联动：changelog 的 Validation 字段必须记录所跑回归范围（filter 或全量）与结果——把「记录」和「回归」两条政策串起来。
- 不重复模板正文：CONSTRAINTS/CLAUDE 只给「必须记 + 用既有模板」+ 指针，模板权威仍在 `docs/changelog.md`（出处优先）。
- 理由：用户问「有没有每次修改记录的规则」——有 changelog 但规则不可发现；补的是「可发现性 + 权威性」，而非再造一个日志。

### 决策 8：milestone 政策 = semver 触发 + 四件套产出（复用既有 release 体系）

- 仓库已有 `docs/release_1.0.0..1.0.3.md` 与 changelog 的「Released / 切片归档」约定，但**没有「何时该出 milestone、出 milestone 要做什么」的可发现规则**——只有 changelog 头部一句「累积 8–12 条就切片」。
- 触发条件用 **semver 语义**（用户选定）：BREAKING → major、新能力 → minor、修复/小改 → patch；版本号接 `v1.0.3` 续号。
- milestone 产出物**四件套**（用户选定，全部必做）：
  1. `docs/release_vX.Y.Z.md`（沿用 1.0.0 格式）+ changelog Unreleased 切片归档 + Released 加交叉链接 + 清空 Unreleased。
  2. **全量回归门禁**：milestone 标记前 `nvim --headless -l tests/run.lua` 全绿（复用回归政策的「提交前全量」，此处升格为硬门禁）。
  3. git tag `vX.Y.Z`——**tag/commit 须经用户确认**（遵守仓库 git 政策「commit/push/tag 前问」），政策只规定「要打」，不自动执行。
  4. 若动了架构/子系统边界，同步 `memory/` 与 `docs/architecture/overview.md`。
- 落点：`docs/CONSTRAINTS.md` §三新增约束 + §四维护契约、根 `CLAUDE.md` 一句政策 + 指针，指向 changelog 归档约定与 release 格式范例。
- 不造新流程：milestone = 「changelog 切片 + 全量回归 + tag + 知识库同步」的组合，全部复用既有资产，只是把触发与清单写成可发现规则。
- 理由：用户问「milestone 的规则有没有」——没有可发现规则；本决策补齐触发条件与产出清单，并与回归/记录/知识库三条政策联动闭环。

### 决策 9：根目录卫生——清理 untracked 游离物

- 删除/隔离：根 `""`（空名文件）、`UsersUSERAppDataLocalTemp-artifact.html`、`lua/ue.lua.bak-20260528-185201`。均 untracked，删除无 git 历史损失。
- `.bak` 若想留存可移入 `.gitignore` 已忽略的位置；倾向直接删（git 历史里有 `lua/ue.lua` 各版本）。
- 理由：refra「historical or unused files」分类 + success criteria「intentionally organized」。

## Risks / Trade-offs

- [本地 `CLAUDE.md` 与 CONSTRAINTS 漂移] → 本地文件只写增量 + 指针引用权威出处；可发现性回归 + 维护契约约束同步更新。
- [知识库 README 沦为空壳] → 种子文档必须含实质内容（先读顺序、子系统速查、真实指针），而非占位；结构回归只能验存在性，内容质量靠 review。
- [`decisions/` 用索引而非搬家，可能显得「不够重构」] → 在 README 显式说明「ADR 权威仍在 `docs/plans/`，此处为分类导航」，符合出处优先原则；若后续确需物理归并，另开 change 用 `git mv`。
- [冻结目录清单需手工维护] → 有意为之（防误删契约），design/docs 注明新增子系统目录要同步清单 + 补 `CLAUDE.md`。
- [Markdown 链接校验的解析范围] → 只校验相对路径仓库内链接（`[..](./x)` / `[..](../x)` / `[..](dir/x.md)`），跳过 `http(s)://` 与锚点；避免误报。
- [回归范围映射可能与实际依赖不符（漏跑）] → 映射给的是「最小必跑」下限，配合「提交前全量」与「不确定即升级」兜底；映射表与 spec 文件清单同处 `tests/CLAUDE.md`，新增/重命名 spec 时同步。
- [删除 `.bak` 不可逆] → 已确认 untracked 且 `git log lua/ue.lua` 保有历史；删前再次 `git status` 确认未被 add。

## Migration Plan

1. 清理根目录游离物（确认 untracked 后删除 / gitignore）。
2. 建知识库骨架：`memory/` `decisions/` `lessons/` 目录 + 各 README/种子；`docs/architecture/overview.md`。
3. 自顶向下写递归 `CLAUDE.md`：先 `lua/CLAUDE.md`（父级总规则），再各子系统增量文件，再 `tools/scripts/tests/docs`。
4. 更新导航：根 `CLAUDE.md` 加「子系统规则 + 回落语义」段；`docs/CONSTRAINTS.md` 加知识库/本地规则链接出口；`README.md` Layout 段补知识库与规则层。
5. 写 `tests/cases/structure_spec.lua`（三组断言），跑通。
6. 全量回归 `nvim --headless -l tests/run.lua` 确认绿；制造一个临时缺失（删一个 CLAUDE.md）验证 FAIL 后还原。
- 回滚：所有改动为新增文档 + 一个只读用例 + 删除 untracked 游离物；删除新增文件即可回退，零运行时影响。

## Open Questions

- `lua/nio/`（单文件 async logger）与 `lua/trouble/sources/`（单文件）是否值得各自 `CLAUDE.md`？倾向给 `lua/nio/` 与 `lua/trouble/` 各一份精简规则（继承 `lua/CLAUDE.md`），保持「每个有独立功能的目录都有规则」的一致性；tasks 阶段最终敲定清单。
- `decisions/` 是否最终物理收纳 `docs/plans/` 的 ADR？本 change 用索引；若团队倾向单一物理根，留作后续 `git mv` change。
