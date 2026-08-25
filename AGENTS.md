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
