# Local Workflow — Claude / Codex / pi 共用入口

> **单一内容源（single source of truth）。** 本文件是 Claude Code、Codex 与 pi **三端共用**的
> 项目根级说明。Claude 端由根 [`CLAUDE.md`](CLAUDE.md)（内容仅 `@AGENTS.md` 导入）读取本文；
> Codex 与 pi 端原生读取本文（pi 逐级向上拼接 `AGENTS.md`/`CLAUDE.md`）。
> **只维护这一个文件**，改一次三端同步。
>
> **禁止为让某一个 agent 生效而新增第四份并行入口**（如 agent 专属规则文件、
> `AGENTS.override.md`、重复的 spec 索引副本）——内容必须收敛回本文件层级；
> 各目录 `CLAUDE.md` 只能是 `@AGENTS.md` 导入 stub，不承载独立内容。
>
> **动任何代码之前**，先读 [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md)
> —— 禁止（禁止）/ 踩过的坑（踩过的坑）/ 约束（约束）的权威索引。

You are working in a trusted local development workflow on Windows Terminal.
Default to doing the work yourself with minimal interruption. Do not offload
routine execution back to the user. Do not stop after editing code if the next
natural step is to run, verify, or inspect the result.

<a id="super-unity-performance-contract"></a>
## 强制约束：SuperUnity 性能不得静默退化（所有 agent 必读，无需先读 spec）

**SuperUnity 的实际压缩与快速索引是承重能力。不得静默删除、绕过、关闭或退化为普通
UBT Unity / 逐文件全量索引，再以正确性修复、重构、跨平台支持或功能回归全绿宣称完成。**
这条约束对所有 agent、所有执行模式和子任务都有效；本节是共用正文，不依赖 OpenSpec 工作流。
下级规则、spec、技能或测试通过都不得视为豁免；只有用户明确调整此约束，才能改变这项验收底线。

- **保住能力，不是名字**：旧能力包含将多个 Unity 进一步二次合并；脚本仍叫 `SuperUnity`、
  只包装 UBT Unity、保留一个不再生效的参数，都不算保留了能力。替换机制必须证明等效性能。
- **正确性与性能必须同时验收**：参数/宏/PCH 冲突不得靠强行合并隐藏；也不得把全量 exact
  fallback 当作性能修复终点。必须修复兼容分组或实现经过真实工程验证的等效加速。
  安全 fallback 可以暂时保住语义，但发生性能退化时任务仍是**未完成**，必须明确报告并继续处置。
- **基线不可偷换**：必须对照最近可验证的正常实现；不得只拿已退化的万级逐文件状态作基线，
  把部分恢复报成新优化或全部恢复。历史 13/23/42 等数字属于各自输入与路线，不可冒充当前保证。
- **必须看实际产物与真实工程**：涉及 CDB、prepare、Unity 分组、索引发布/重启的改动，记录
  相同 build 的源文件数、UBT Unity 数、二次合并数、exact fallback 数、shader 记录数、覆盖/缺失，
  以及实际索引完成耗时与 CPU/内存影响；区分冷/热缓存、首次/重复 prepare。
  CDB 条目数、clangd 队列分母、编译成功数与完成耗时不得混为一谈。
- **完成门禁**：功能回归和少数跳转样例不能代替索引性能验收。输入不变不得无故重写产物、
  重启 clangd 或反复全量索引；不得靠清缓存、漏源文件、缩小平台/模块覆盖或占满宿主制造好数字。
  无法取得必要实测时，写明缺口，禁止宣称性能已恢复。

**阶段性交付（用户 2026-09-23 明确调整）**：允许先实现并交付一个已验证范围的可用版本，
再继续扩大压缩规模与优化性能；不必等待全工程目标一次全部完成。首版仍须保留正确性、
完整覆盖、真实二次合并和失效回退，并实测本次范围的收益与重复 prepare 行为。
全工程规模及完整性能恢复列为后续迭代，不能再以这些尚未完成为由无限推迟首版交付；
同时不得把阶段验收通过表述为全工程性能已经恢复。

历史教训与核对证据：[索引退化调查](docs/cpp-index-restart-investigation.md)。
约束索引：[`docs/CONSTRAINTS.md` C11](docs/CONSTRAINTS.md#c11--superunity-性能保全)。

## Primary Behavior

Prefer autonomous execution within the agent's permission model. Proceed directly
with routine local development work:

- read files and search code
- inspect logs and list directories
- edit files in this repository
- run local builds, tests, formatters, and linters
- create temporary helper files inside the repository when needed
- repeat commands as needed to diagnose and verify issues

Only ask the user to run something when blocked by permissions, missing tools,
missing credentials, unavailable hardware, or inaccessible external systems.

## Do Not Hand Routine Execution Back to the User

Avoid responses like:
- "Please run this"
- "Try this command"
- "Can you execute this and send me the output"
- "Run the build and let me know"
- "Test this locally and report back"

Instead:
- run the command yourself when possible
- inspect the output yourself
- iterate yourself
- report back only after a meaningful chunk of work is complete

## Minimize Interruptions

Do not ask for confirmation during normal local development unless:
- the agent's permission enforcement explicitly requires approval
- the action is destructive
- the action is materially risky
- the action leaves the repository boundary
- the action affects accounts, credentials, production systems, or secrets

## SESSION START（强制前置·每个新 context 必做）

进入本仓、**动任何代码之前**，按序读完以下文件——这是强制前置步骤，不是建议：

0. **探针反馈**（`openspec/specs/probe-feedback-loop/spec.md` 第一条 requirement）：
   读 `stdpath('state')/ue_probes.json`（或 nvim 内 `:UEProbeReport`）。存在失败类
   证据时，**处置它（修复 / 立 change / 记录不处理理由）先于任何新工作**。
   探针由已落地改动主动埋设（`lua/utils/probe.lua`），不等用户反馈。
1. [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) — 禁止 / 踩过的坑 / 约束（权威索引）。
2. [`memory/project_overview.md`](memory/project_overview.md) — 项目总览 + 子系统速查 + 知识库导航。
3. **当前改动目录的本地规则** — 每个主要目录一份 `AGENTS.md`（单一内容源）+ 一个
   `CLAUDE.md`（内容为 `@AGENTS.md` 导入 stub）。Codex 与 pi 读 `AGENTS.md`；Claude 读
   `CLAUDE.md` 并由其 stub 展开同一内容。该目录**无**本地规则时，适用**最近祖先目录**
   的规则（回落语义）。子级规则只写相对父级的增量。
4. **改动范围对应的 spec** — `openspec/specs/<capability>/spec.md` 是**可观察行为的权威
   契约**（不是「写完躺着的文档」）。从「我要改哪个目录」一步定位治理它的 spec：查
   [`memory/project_overview.md`](memory/project_overview.md) 子系统速查表的
   **「治理 spec」列**（与 [`tests/AGENTS.md`](tests/AGENTS.md) 的 CHANGE-TO-FILTER MAP 同源）。
   **按改动范围读，不遍历 `openspec/specs/`**；本地规则或 CONSTRAINTS 与 spec 冲突时以 spec 为准
   （若冲突源于 spec 陈旧，先更正 spec）。机制见
   [`openspec/specs/spec-authority-loop/spec.md`](openspec/specs/spec-authority-loop/spec.md)。
5. **归属分层契约（如该子系统有）** —— 改动带 failure layering 的子系统前，先读其层契约：
   失败必须**先指认层与 owner，再给处置**，且能力靠**探测**而非沿用单台设备结论。
   DAP（`lua/ue/dap/`）的五层契约 L0–L4 权威在
   [`openspec/specs/dap-failure-layering/spec.md`](openspec/specs/dap-failure-layering/spec.md)，
   摘要见 [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) §三 C10。
   （本条只给指针：正文不在根文件复制，避免第四份可漂移副本。）

**回归红灯优先**：若全量回归存在任何 FAIL，**处置它（修复 / 立 change / 记录不处理理由）
先于推进无关新工作**——与上面第 0 步的探针 report-first 同一哲学。宿主（host）相关失败按
**宿主能力守卫**用例，禁止注入假可执行文件/假宿主让断言「碰巧通过」。

知识库四区：[`memory/`](memory/project_overview.md) · [`decisions/`](decisions/README.md) ·
[`lessons/`](lessons/README.md) · [`docs/architecture/overview.md`](docs/architecture/overview.md)。
行为契约：[`openspec/specs/`](openspec/specs/spec-authority-loop/spec.md)。

## Repository Constraints

- LazyVim is used as a library; project-specific behavior lives under `lua/ue.lua`,
  `lua/ue/`, `lua/utils/`, and `lua/workarounds/`.
- Do not introduce new dependencies without an explicit request.
- Do not add telescope, mason auto-install, Copilot, or Codeium integration.
- Do not globally override `vim.lsp.handlers`; use the existing fallback or
  workaround structure.
- Keep upstream bug workarounds isolated under `lua/workarounds/<scope>/<name>.lua`
  with the documented frontmatter contract.
- Prefer async work over blocking the UI thread.
- Prefer AST/Tree-sitter or structured APIs over regex for structured code.
- Public Lua APIs should hang off `M.*` and remain headless-testable.
- Do not make unrelated refactors or format unrelated files.

The authoritative list is [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md); when this
file and the constraint index differ, follow the constraint index and its linked
source documents.

## Command Style

Prefer direct commands:
- avoid compound commands like `cd ... && git status`;
- avoid chaining with `&&`, `;`, or shell wrappers unless necessary;
- do not use `bash -lc`, `sh -c`, or similar unless there is no practical
  alternative;
- assume the current working directory is already correct;
- prefer several direct commands over one dense compound command.

Use `rg` / `rg --files` for search when available.

## Git Policy

Read-only git inspection is routine:
- `git status`
- `git diff`
- `git log`
- `git show`
- `git blame`

Do not run `git commit`, `git push`, `git rebase`, `git reset`, `git clean`,
history rewriting, or destructive checkout/restore actions unless explicitly
requested by the user.

Privacy gates are not tests. In this public mirror:
- Never use `git push --no-verify`, `git push --all`, or `git push --mirror`.
- A request to skip tests or lint does not authorize skipping privacy hooks. When
  the user explicitly requests no lint, use `NVIM_SKIP_HOOK_LINT=1`; do not use
  `git commit --no-verify`.
- Plumbing flows such as `git commit-tree` must update a branch through Git so the
  local `reference-transaction` privacy gate runs before the ref moves.
- Private recovery refs belong under `refs/private-backup/`, never under
  `refs/heads/` or `refs/tags/`; they must never be pushed.
- The real private denylist remains outside the worktree. See
  `openspec/specs/public-mirror-privacy/spec.md`.

## ADB Policy

ADB is part of the normal local workflow. Prefer direct single commands such as:
- `adb devices`
- `adb shell getprop`
- `adb logcat`
- `adb shell`
- `adb push`
- `adb pull`
- `adb install`
- `adb shell am start ...`

Do not combine adb with unrelated commands in one compound shell command unless
there is a clear need.

## Build and Verification Policy

After making changes, verify them yourself whenever possible.

Preferred loop:
1. inspect
2. edit
3. run
4. verify
5. iterate
6. then report

Do not stop after step 2 if steps 3 to 5 are available.

## Definition of Done（完成的硬标准·缺一不算完成）

一次改动只有同时满足下列条件才算「完成」。这是本仓所有开发政策的**强制执行入口**；
其余文档（CONSTRAINTS / `tests/AGENTS.md` / `docs/testing-regression.md` /
`docs/changelog.md` / `openspec/specs/`）是出处与细节。

1. **跑回归并全绿** — 按改动范围跑对应 filter（映射见 [`tests/AGENTS.md`](tests/AGENTS.md)
   的 CHANGE-TO-FILTER MAP）；**提交/合并前必跑全量** `nvim --headless -l tests/run.lua`；
   **影响面不确定就升级到全量，不猜窄 filter**。权威：[`docs/testing-regression.md`](docs/testing-regression.md)。
2. **spec 与实现一致** — 改动改变了 spec 已声明的可观察行为时，**同步更新对应
   `openspec/specs/<capability>/spec.md` 或立一个承载该 spec 变更的 change**；若发现 spec
   落后于已验证正确的实现，则**反向更正 spec**。只改实现而不动 spec 的收尾**不算完成**。
   判定为「无 spec 影响」时也要显式声明。权威：
   [`openspec/specs/spec-authority-loop/spec.md`](openspec/specs/spec-authority-loop/spec.md)。
3. **记 changelog** — 在 [`docs/changelog.md`](docs/changelog.md) Unreleased 追加一条（用既有模板），
   其 **Validation 字段写明所跑回归范围与结果**，并写明本次 **spec 一致性处置**
   （同步 spec / 立 change / 判定无 spec 影响）。
4. **收尾版本走 milestone** — 满足 semver 触发时执行 milestone 政策（release 文档 + changelog 归档 +
   全量回归门禁 + spec 无未同步漂移 + git tag〔须用户确认〕 + 架构变更同步知识库）。
   权威：`docs/CONSTRAINTS.md §三 C8`。

## Reporting

Do not narrate every tiny step. Work through a meaningful batch, then report:
1. what you investigated
2. what you changed
3. what you ran
4. what happened
5. what remains blocked or risky

Always include verification status when relevant.

## User Handoff Minimization

The user should not be used as a substitute shell operator for routine local
development steps.

If you can run it, run it. If you can test it, test it. If you can inspect it,
inspect it. If you can iterate once more yourself, do that before replying.
