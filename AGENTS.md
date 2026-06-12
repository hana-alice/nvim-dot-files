# GPT/Codex Local Workflow

> This is the GPT/Codex entry point for this repository. It mirrors the intent of
> [`CLAUDE.md`](CLAUDE.md) without assuming Claude Code-specific behavior.
> Before writing code here, read [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md).

You are working in a trusted local development workflow on Windows. Default to
doing the work yourself with minimal interruption. Do not hand routine execution
back to the user when local tools are available.

## Primary Behavior

Proceed directly with routine local development work:
- read files and search code
- inspect logs and list directories
- edit files in this repository
- run local builds, tests, formatters, and linters
- create temporary helper files inside the repository when needed
- iterate commands as needed to diagnose and verify issues

Only ask the user to run something when blocked by permissions, missing tools,
missing credentials, unavailable hardware, or inaccessible external systems.

## Session Start

Before changing code in a new context, read these in order:

1. [`docs/CONSTRAINTS.md`](docs/CONSTRAINTS.md) — prohibitions, known pitfalls,
   and load-bearing constraints.
2. [`memory/project_overview.md`](memory/project_overview.md) — project map,
   subsystem index, and knowledge-base navigation.
3. The local rules for the directory being changed:
   - this root `AGENTS.md` is the GPT/Codex entry point;
   - read a closer nested `AGENTS.md` if one exists in the target subtree;
   - otherwise read the nearest ancestor `CLAUDE.md` for the target directory;
   - child rules are incremental over parent rules.

Knowledge-base roots:
[`memory/`](memory/project_overview.md),
[`decisions/`](decisions/README.md),
[`lessons/`](lessons/README.md),
[`docs/architecture/overview.md`](docs/architecture/overview.md).

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

Use `rg`/`rg --files` for search when available.

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

## Definition of Done

A change is complete only when all applicable items are satisfied:

1. **Regression is green** — run the matching test filter from
   [`tests/CLAUDE.md`](tests/CLAUDE.md). Before commit/merge, run the full
   suite: `nvim --headless -l tests/run.lua`. If impact is unclear, run full.
2. **Changelog is updated** — append an entry to
   [`docs/changelog.md`](docs/changelog.md), including the validation scope and
   result.
3. **Milestone policy is followed when triggered** — semver release docs,
   changelog archival, full regression gate, user-confirmed git tag, and
   knowledge-base sync as described in `docs/CONSTRAINTS.md` C8.

## Reporting

Do not narrate every tiny step. Work through a meaningful batch, then report:
what was inspected, what changed, what was run, what passed, and what remains
blocked or risky.
