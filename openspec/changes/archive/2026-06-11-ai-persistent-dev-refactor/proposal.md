## Why

本仓库（hana-alice 的 Neovim UE 配置）历经长期有机生长，规则、架构、决策、踩坑知识分散在 `docs/CONSTRAINTS.md`、`docs/plans/`、`README.md`、各 workaround frontmatter、以及已归档的 openspec change 里。对**持续介入的 AI agent** 而言，规则只能靠「读 chat 历史 / 全局 CLAUDE.md」获取——无法在进入某个子系统目录时就地发现「这个目录该怎么改、不该怎么改」。结果是：跨会话知识流失、同一个坑被重复踩、子系统边界靠记忆而非文件。

参考 `refra.txt`（资深架构师结构化重构剧本）的目标——**持久化项目记忆 + 子系统边界 + 每个主要区域的本地规则**——本次重构把规则与知识从「聚合在顶层 / 散在 chat」改为「就地、分层、可被 AI 从文件可靠发现」。**不重写任何工作系统，不移动 `lua/` 运行时代码**（Neovim runtimepath 强依赖 `lua/` 布局，移动会全面断 require 且违反 CONSTRAINTS「不做无关重构」），重点放在文档层与递归规则层。

## What Changes

- **递归本地规则层**：为每个有独立功能的目录（递归到子级）新增本地规则文件 `CLAUDE.md`，描述该目录的：用途（purpose）、归属（ownership）、什么文件属于这里 / 不属于这里、该子系统专属编码约定、平台/性能考量、常见坑、应先读的相关文档。
  - **继承约定**：子目录规则**只写与父级不同的增量**；若某约束与父级一致则不重复，默认继承上一层。每个本地规则文件顶部声明「继承自 `../CLAUDE.md`」。
  - 覆盖范围（按当前模块树）：`lua/`、`lua/ue/`（+ `cdb/` `core/` `dap/`）、`lua/utils/`（+ `ue_goto/` `code_search/` `platform/`）、`lua/config/`、`lua/plugins/`、`lua/workarounds/`、`lua/trouble/`、`lua/nio/`、`tools/`、`scripts/`、`tests/`、`docs/`。
- **持久化 AI 知识库**：新建顶层知识目录（贴近 refra.txt 模型，按本仓实际命名），并把现有散落知识**索引/迁移**进去：
  - `memory/`：稳定的项目知识（subsystem 速查、AI agent 进入仓库先读什么）。
  - `decisions/`：架构决策记录（ADR）的归位 —— 将 `docs/plans/` 中的 ADR 性质文档归类索引。
  - `lessons/`：平台怪癖 / 调试硬知识（Android ASLR、codelldb、Windows pipe 等），从 CONSTRAINTS §二与 MEMORY 索引。
  - `docs/architecture/`：架构总览（major subsystems / data flow / platform layers / build pipeline / ownership boundaries）。
- **根目录卫生**：清理/隔离明显的历史游离物（根目录空名文件 `""`、`UserslizeqiangAppDataLocalTempmr17757.html`、`lua/ue.lua.bak-20260528-185201`），归入 `.gitignore` 或删除（均为 untracked，无 git 历史风险）。
- **交叉链接与导航**：知识库各根 README 互链，`CLAUDE.md`（根）与 `docs/CONSTRAINTS.md` 指向新知识库；保持「出处优先、索引不复制原文」的既有维护契约。
- **可发现性验证**：新增一个 headless 回归用例，断言每个主要目录都存在本地规则文件，且知识库四根（memory/decisions/lessons/docs/architecture）的 README 存在、关键内部链接可解析——把「规则就地可发现」变成回归守护项，防止腐烂。

## Capabilities

### New Capabilities
- `local-subsystem-rules`: 递归的本地规则文件体系（每个主要目录一份 `CLAUDE.md`，含继承约定），让 AI agent 进入任意子系统目录即可就地发现规则。
- `ai-knowledge-base`: 持久化项目知识库（memory / decisions / lessons / architecture）及其组织、迁移与互链约定，作为跨会话项目记忆的稳定来源。
- `structure-discoverability-regression`: 对「规则就地存在 + 知识库结构完整 + 链接可解析」的 headless 回归校验，防止文档/规则层随时间腐烂。
- `test-regression-policy`: **以根 `CLAUDE.md` 为强制执行入口**的开发政策集——根 `CLAUDE.md` 含 SESSION-START 协议（动代码前先读 CONSTRAINTS → memory/project_overview → 当前目录 CLAUDE.md）与 Definition of Done（缺一不算完成）。DoD 收口三条联动政策：①「改动后必跑回归」（按改动类型 filter 映射、提交前全量、不确定即升级）；②「改动必记 changelog」（Validation 记回归范围）；③「milestone 政策」（semver 触发，产出 release 文档 + changelog 归档 + 全量回归门禁 + git tag + 知识库同步）。设计取向是**源头治理**：让新 context 的 agent 在启动注入时即被告知流程，而非靠事后自觉；其余文档（CONSTRAINTS / tests-CLAUDE / testing-regression / changelog）为出处与细节。

### Modified Capabilities
- `project-constraints-doc`: `docs/CONSTRAINTS.md` 从「单一聚合索引」扩展为「顶层索引 + 指向递归本地规则与知识库」的导航中枢，新增对 `memory/` `decisions/` `lessons/` `docs/architecture/` 与各目录 `CLAUDE.md` 的链接出口；其作为权威可发现入口的要求范围扩大。

## Impact

- **不移动 `lua/` 运行时代码**：零 require 路径变更，零 runtimepath 影响，零 init.lua 改动。这是承重决策（详见 design.md）。
- **新增文件**（不改运行时行为）：
  - 各目录 `CLAUDE.md`（约 12–16 个，每个 20–80 行）。
  - `memory/`、`decisions/`、`lessons/` 三个顶层目录及其 README + 种子文档；`docs/architecture/overview.md`。
  - `tests/cases/structure_spec.lua`（可发现性 + 回归政策可发现性）。
- **改动后回归政策文档化**：在 `docs/testing-regression.md` 增「改动 → 必跑 spec filter」分范围映射；在 `docs/CONSTRAINTS.md` §三加约束条目、§四补维护契约；根 `CLAUDE.md` 加一句政策 + 指针；`tests/CLAUDE.md` 内嵌速查映射表。
- **移动/归位**（仅文档，保留 git 历史用 `git mv`）：`docs/plans/` 中 ADR 性质文档归类到 `decisions/`（或在 `decisions/` 建索引指回原位——二选一在 design 决定，倾向「索引指回、最小移动」以遵守 refra「minimize disruptive moves」）。
- **清理**（untracked 游离物）：根目录 `""`、临时 html、`*.bak`。
- 受影响代码：仅新增「只读 require + 文件存在性断言」的回归用例，不触碰任何模块行为。
- 依赖：不引入新依赖；规则/文档为纯 Markdown，回归为纯 Lua。
- 验证：沿用 `nvim --headless -l tests/run.lua`，新增可发现性用例纳入全量。
- 公开镜像安全：所有新增文档保持事实性、不含 secret，遵循 CONSTRAINTS §四维护契约。
