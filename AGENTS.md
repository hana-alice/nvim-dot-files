# Local Workflow — Claude & GPT/Codex 共用入口

> **单一内容源（single source of truth）。** 本文件是 Claude Code 与 GPT/Codex 共用的
> 项目根级说明。Claude 端由根 [`CLAUDE.md`](CLAUDE.md)（内容仅 `@AGENTS.md` 导入）读取本文；
> Codex 端原生读取本文。**只维护这一个文件**，改一次两端同步。
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
   `CLAUDE.md`（内容为 `@AGENTS.md` 导入 stub）。Codex 读 `AGENTS.md`；Claude 读
   `CLAUDE.md` 并由其 stub 展开同一内容。该目录**无**本地规则时，适用**最近祖先目录**
   的规则（回落语义）。子级规则只写相对父级的增量。

知识库四区：[`memory/`](memory/project_overview.md) · [`decisions/`](decisions/README.md) ·
[`lessons/`](lessons/README.md) · [`docs/architecture/overview.md`](docs/architecture/overview.md)。

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
`docs/changelog.md`）是出处与细节。

1. **跑回归并全绿** — 按改动范围跑对应 filter（映射见 [`tests/AGENTS.md`](tests/AGENTS.md)
   的 CHANGE-TO-FILTER MAP）；**提交/合并前必跑全量** `nvim --headless -l tests/run.lua`；
   **影响面不确定就升级到全量，不猜窄 filter**。权威：[`docs/testing-regression.md`](docs/testing-regression.md)。
2. **记 changelog** — 在 [`docs/changelog.md`](docs/changelog.md) Unreleased 追加一条（用既有模板），
   其 **Validation 字段写明所跑回归范围与结果**。
3. **收尾版本走 milestone** — 满足 semver 触发时执行 milestone 政策（release 文档 + changelog 归档 +
   全量回归门禁 + git tag〔须用户确认〕 + 架构变更同步知识库）。权威：`docs/CONSTRAINTS.md §三 C8`。

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
