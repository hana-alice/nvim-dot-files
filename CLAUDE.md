# Local workflow

> **Before writing code here**, read [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md)
> — the consolidated list of what is forbidden (禁止), what pitfalls have already
> cost time (踩过的坑), and which constraints are load-bearing (约束).

You are working in Claude Code CLI inside a trusted local development workflow on Windows Terminal.

Default to doing the work yourself with minimal interruption.
Do not offload routine execution back to the user.
Do not stop after editing code if the next natural step is to run, verify, or inspect the result.

## Primary behavior

Prefer autonomous execution within Claude Code's permission model.

Proceed directly with routine local development work:
- read files
- search code
- inspect logs
- list directories
- edit files in the repository
- run local builds
- run local tests
- run formatters and linters
- create temporary helper files inside the repository
- repeat commands as needed to diagnose and verify issues

## Do not hand routine execution back to the user

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

Only ask the user to run something if Claude Code is blocked by permissions, missing tools, missing credentials, unavailable hardware, or inaccessible external systems.

## Minimize interruptions

Do not ask for confirmation during normal local development unless:
- Claude Code permission enforcement explicitly requires approval
- the action is destructive
- the action is materially risky
- the action leaves the repository boundary
- the action affects accounts, credentials, production systems, or secrets

## Command style

Prefer direct commands.

Important rules:
- do not use compound commands like `cd ... && git status`
- do not chain commands with `&&`, `;`, or shell wrappers unless absolutely necessary
- do not wrap commands in `bash -lc`, `sh -c`, or similar unless there is no practical alternative
- assume the current working directory is already correct
- prefer one direct command at a time
- prefer several direct commands over one compound command

## Git policy

Treat normal read-only git inspection as routine.

Run directly when useful:
- `git status`
- `git diff`
- `git log`
- `git show`
- `git blame`

Avoid compound git commands.
Do not stop to ask before ordinary read-only git inspection if permissions allow it.

Ask before:
- `git commit`
- `git push`
- `git rebase`
- `git reset`
- `git clean`
- history rewriting
- destructive checkout / restore actions

## ADB policy

ADB is part of the normal local workflow.

Prefer direct single adb commands such as:
- `adb devices`
- `adb shell getprop`
- `adb logcat`
- `adb shell`
- `adb push`
- `adb pull`
- `adb install`
- `adb shell am start ...`

Do not combine adb with unrelated commands in one compound shell command unless absolutely necessary.

<!-- SESSION START PROTOCOL -->
## SESSION START（强制前置·每个新 context 必做）

进入本仓、**动任何代码之前**，按序读完以下文件——这是强制前置步骤，不是建议：

1. [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) — 禁止 / 踩过的坑 / 约束（权威索引）。
2. [`memory/project_overview.md`](memory/project_overview.md) — 项目总览 + 子系统速查 + 知识库导航。
3. **当前改动目录的 `CLAUDE.md`** — 子系统本地规则。该目录**无** `CLAUDE.md` 时，
   适用**最近祖先目录**的 `CLAUDE.md`（回落语义）。子级规则只写相对父级的增量。

知识库四区：[`memory/`](memory/project_overview.md) · [`decisions/`](decisions/README.md) ·
[`lessons/`](lessons/README.md) · [`docs/architecture/overview.md`](docs/architecture/overview.md)。
<!-- END SESSION START PROTOCOL -->

<!-- DEFINITION OF DONE -->
## Definition of Done（完成的硬标准·缺一不算完成）

一次改动只有同时满足下列条件才算「完成」。这是本仓所有开发政策的**强制执行入口**；
其余文档（CONSTRAINTS / `tests/CLAUDE.md` / `docs/testing-regression.md` / `docs/changelog.md`）是出处与细节。

1. **跑回归并全绿** — 按改动范围跑对应 filter（映射见 [`tests/CLAUDE.md`](tests/CLAUDE.md)
   的 CHANGE-TO-FILTER MAP）；**提交/合并前必跑全量** `nvim --headless -l tests/run.lua`；
   **影响面不确定就升级到全量，不猜窄 filter**。权威：[`docs/testing-regression.md`](docs/testing-regression.md)。
2. **记 changelog** — 在 [`docs/changelog.md`](docs/changelog.md) Unreleased 追加一条（用既有模板），
   其 **Validation 字段写明所跑回归范围与结果**。
3. **收尾版本走 milestone** — 满足 semver 触发时执行 milestone 政策（release 文档 + changelog 归档 +
   全量回归门禁 + git tag〔须用户确认〕 + 架构变更同步知识库）。权威：`docs/CONSTRAINTS.md §三 C8`。
<!-- END DEFINITION OF DONE -->

You are working in Claude Code CLI inside a trusted local development workflow on Windows Terminal.

Default to doing the work yourself with minimal interruption.
Do not offload routine execution back to the user.
Do not stop after editing code if the next natural step is to run, verify, or inspect the result.

## Build and verification policy

After making changes, verify them yourself whenever possible.

Preferred loop:
1. inspect
2. edit
3. run
4. verify
5. iterate
6. then report

Do not stop after step 2 if steps 3 to 5 are available.

## Reporting

Do not narrate every tiny step.
Work through a meaningful batch, then report:
1. what you investigated
2. what you changed
3. what you ran
4. what happened
5. what remains blocked or risky

Always include verification status when relevant.

## User handoff minimization

The user should not be used as a substitute shell operator for routine local development steps.

If you can run it, run it.
If you can test it, test it.
If you can inspect it, inspect it.
If you can iterate once more yourself, do that before replying.