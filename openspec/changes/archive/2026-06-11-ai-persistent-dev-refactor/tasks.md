## 1. 根目录卫生

- [x] 1.1 `git status` 确认根目录 `""`（空名文件）、`UsersUSERAppDataLocalTemp-artifact.html`、`lua/ue.lua.bak-20260528-185201` 均为 untracked
- [x] 1.2 删除上述游离物（或移入 `.gitignore` 已忽略位置）；删后 `git status` 复核未误删跟踪文件

## 2. 知识库骨架

- [x] 2.1 新建 `memory/` 目录与 `memory/project_overview.md`：AI 进仓「先读顺序」（CONSTRAINTS → docs/architecture/overview → 子系统 CLAUDE.md）+ 子系统速查表 + 指向各知识区域
- [x] 2.2 新建 `decisions/` 目录与 `decisions/README.md`：ADR 用途/归属 + 索引 `docs/plans/` 现有 ADR（指回原位）+ 「什么属于这里/不属于这里」
- [x] 2.3 新建 `lessons/` 目录与 `lessons/README.md`：平台怪癖/调试硬知识用途 + 索引 CONSTRAINTS §二（Android ASLR / codelldb / Windows pipe / snacks）+ 用户 MEMORY 主题
- [x] 2.4 新建 `docs/architecture/overview.md`：major subsystems（ue 引擎 / goto 解析栈 / code_search / DAP / platform 驱动 / workarounds）、data flow、platform layers、build pipeline、ownership boundaries；指针链到 `architecture-symbol-resolution.md`、`architecture-vs-lazyvim.md`、`TOOLING.md`
- [x] 2.5 四根 README 互链（memory↔decisions↔lessons↔architecture），各自声明出处优先、不复制原文

## 3. 递归本地规则（lua 代码层，零移动）

- [x] 3.1 `lua/CLAUDE.md`（父级总规则）：M.* 公共 API、async>阻塞、AST>regex、headless 可测、workaround 隔离；声明「无本地规则回落最近祖先」与「子级只写增量」
- [x] 3.2 `lua/ue/CLAUDE.md` + `lua/ue/cdb/CLAUDE.md` + `lua/ue/core/CLAUDE.md` + `lua/ue/dap/CLAUDE.md`（dap 必含 codelldb/Android 坑指针 → CONSTRAINTS §二、§一 P8/P16/P17）
- [x] 3.3 `lua/utils/CLAUDE.md` + `lua/utils/ue_goto/CLAUDE.md`（符号解析分层契约 → CONSTRAINTS C5）+ `lua/utils/code_search/CLAUDE.md`（csearch 非主路 P12/P13）+ `lua/utils/platform/CLAUDE.md`（driver 接口契约）
- [x] 3.4 `lua/config/CLAUDE.md`（init 启动顺序 C3、不重复 require P15）+ `lua/plugins/CLAUDE.md`（snacks-only P1、不集成 copilot P10）
- [x] 3.5 `lua/workarounds/CLAUDE.md`（frontmatter 契约 C2、何时隔离/何时 inline，指 README+TEMPLATE）
- [x] 3.6 `lua/trouble/CLAUDE.md` + `lua/nio/CLAUDE.md`（精简，继承 lua/CLAUDE.md，只写各自专属点）

## 4. 递归本地规则（非代码层）

- [x] 4.1 `tools/CLAUDE.md`：Python/Go 工具脚本归属、不动第三方（cindex-uefilter）、与 scripts 区别
- [x] 4.2 `scripts/CLAUDE.md`：Windows installer/profiling/lint 脚本归属、与 tools 区别、headless 测试入口指引
- [x] 4.3 `tests/CLAUDE.md`：如何新增 `*_spec.lua`、harness 约定、退出码、覆盖口径（指 docs/testing-regression.md）
- [x] 4.3 `tests/CLAUDE.md`：如何新增 `*_spec.lua`、harness 约定、退出码、覆盖口径（指 docs/testing-regression.md）；**内嵌「改动 → 必跑 spec filter」分范围速查映射表**与「不确定即升级全量、提交前必跑全量」原则
- [x] 4.4 `docs/CLAUDE.md`：文档分类约定（plans/skills/architecture/release）、出处优先、公开镜像安全

## 5. 导航与交叉链接

- [x] 5.1 根 `CLAUDE.md` 新增「子系统本地规则 + 回落语义 + 知识库入口」段，链接 memory/decisions/lessons/docs/architecture
- [x] 5.2 `docs/CONSTRAINTS.md` 新增知识库与本地规则链接出口，维护契约扩展为覆盖知识库/规则层腐烂防护
- [x] 5.3 `README.md` Layout 段补充知识库目录与递归规则层说明

## 6. 根 CLAUDE.md 强制执行入口（源头治理）

- [x] 6.1 根 `CLAUDE.md` 顶部新增 **SESSION START 协议块**：动代码前第一动作依次读 `docs/CONSTRAINTS.md` → `memory/project_overview.md` → 当前改动目录 `CLAUDE.md`（无则回落最近祖先）；表述为强制前置步骤
- [x] 6.2 根 `CLAUDE.md` 新增 **Definition of Done**：缺一不算完成的三条硬条件（①按范围跑回归全绿 ②记 changelog 含回归范围 ③收尾版本走 milestone）；明确「权威强制入口是本文件，其余为出处/细节」
- [x] 6.3 用可识别标记包裹这两块（如固定小节标题），供 structure_spec 关键字校验

## 7. 改动后回归政策（分范围）

- [x] 7.1 在 `docs/testing-regression.md` 新增「改动后回归政策」章：完整的「改动位置 → 最小必跑 filter」映射表（keymaps/commands、ue_config/smoke、ue_cdb、dap/platform、ue_goto_behavior/ue_paths/utils、options/autocmds、workarounds/smoke、structure；跨子系统/重构/拿不准 → 全量）
- [x] 7.2 在 `docs/testing-regression.md` 政策章写明：新增功能必须补 `*_spec.lua`、冻结清单同步、提交/合并前必跑全量、不确定即升级范围
- [x] 7.3 `docs/CONSTRAINTS.md` §三 新增一条约束（C6 改动后回归政策）：摘要 + 指针指向 `docs/testing-regression.md` 与根 `CLAUDE.md` DoD；§四维护契约补「新增 spec / 改命令清单时同步映射表」
- [x] 7.4 `tests/CLAUDE.md`（见 4.3）速查映射表与 testing-regression 映射一致；根 `CLAUDE.md` DoD 的回归条目指向二者

## 8. 改动记录政策（changelog）

- [x] 8.1 `docs/CONSTRAINTS.md` §三 新增一条约束（C7 改动记录政策）：每次改动 MUST 在 `docs/changelog.md` Unreleased 追加一条，用既有模板；摘要 + 指针指向 `docs/changelog.md`
- [x] 8.2 根 `CLAUDE.md` DoD 的 changelog 条目落地（落地任意改动后必追加记录才算完成）+ 指针
- [x] 8.3 `docs/CONSTRAINTS.md` §四维护契约补「changelog 滚动归档约定」；明确 changelog 记录的 Validation 字段须写所跑回归范围与结果（与回归政策联动）
- [x] 8.4 确认 `docs/changelog.md` 模板已含 Validation 字段（已有）；如缺「回归范围」提示则在模板注释补一句

## 9. milestone（版本里程碑）政策

- [x] 9.1 `docs/CONSTRAINTS.md` §三 新增一条约束（C8 milestone 政策）：semver 触发（BREAKING→major / 新能力→minor / 修复→patch，续 `v1.0.3`）+ 四件套产出（release 文档+changelog 归档 / 全量回归门禁 / git tag 须确认 / 架构变更同步知识库）；指针指向 `docs/changelog.md` 与 `docs/release_1.0.0.md` 格式范例
- [x] 9.2 根 `CLAUDE.md` DoD 的 milestone 条目落地（强调 tag/commit 须用户确认、全量回归是门禁）+ 指针
- [x] 9.3 在 `docs/changelog.md` 的 How-to-use 段补「milestone = semver 触发 + 四件套」一句，与既有「8–12 条切片」约定衔接
- [x] 9.4 `docs/CONSTRAINTS.md` §四维护契约补「milestone 收尾时须同步 memory/ 与 architecture overview（若动架构）」

## 10. 可发现性回归

- [x] 10.1 新建 `tests/cases/structure_spec.lua`，维护「主要目录清单」常量，断言每个目录存在 `CLAUDE.md`（缺失打印目录名）
- [x] 10.2 断言知识库四根文件存在（`memory/project_overview.md`、`decisions/README.md`、`lessons/README.md`、`docs/architecture/overview.md`）
- [x] 10.3 断言关键文档（根 CLAUDE.md、CONSTRAINTS、memory/project_overview、architecture/overview）的相对路径 Markdown 链接不悬空（跳过 http/锚点，`filereadable` 校验）
- [x] 10.4 断言强制入口可发现：根 `CLAUDE.md` 含 SESSION START 协议块 + Definition of Done 标记
- [x] 10.5 断言政策可发现：`tests/CLAUDE.md` 含 filter 映射表；`docs/CONSTRAINTS.md` 含回归政策条目；`docs/CONSTRAINTS.md` 与根 `CLAUDE.md` 含 changelog 改动记录政策与 milestone 政策条目（关键字存在性校验）

## 11. 验证

- [x] 11.1 运行 `nvim --headless -l tests/run.lua`，确认含 structure_spec 全部 PASS、退出码 0
- [x] 11.2 临时删除一个 `CLAUDE.md`、制造一个悬空链接、删一个政策块标记，确认 structure_spec 各自 FAIL 且打印具体缺失项，退出码 1，验证后还原
- [x] 11.3 `scripts/run_regression.ps1` 跑通，退出码转发正确
- [x] 11.4 人工抽查：随机进入 2–3 个子系统目录，确认其 `CLAUDE.md` 声明了继承、只写增量、指针指向真实出处
- [x] 11.5 抽查回归政策映射表与实际 `tests/cases/*_spec.lua` 清单一致（无指向已删 spec 的 filter）
- [x] 11.6 按本次 change 自身实践：在 `docs/changelog.md` 追加一条本次重构的记录（验证记录政策与 DoD 可落地、模板可用）
