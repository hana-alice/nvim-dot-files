# docs/plans

Architecture decision records (ADRs) and iteration logs for this
configuration. Read **iteration logs** first when you need to know
"what changed and why"; read individual **ADRs** when you need to
know "how this specific subsystem is shaped."

## Iteration logs (start here)

| File | Span | What it covers |
|---|---|---|
| `2026-05-07-iteration-log.md` | 2026-05-06 → 2026-05-07 | The 16-commit `feat/multi-platform-foundation` branch: A→J phases, before/after architecture, performance, public-API freeze, quality contracts, deferred followups |

## ADRs (per-subsystem deep dives)

### Multi-platform foundation series (2026-05)

| File | Phase(s) | Subject |
|---|---|---|
| `2026-05-06-multi-platform-foundation.md` | A · B · C · D | Foundation: platform driver, `ue/core/`, `ue/config.lua`, headless test gate |
| `2026-05-07-cdb-pipeline-split.md` | E.1 · E.2 · E.3 | Split `compile_commands.json` pipeline out of `ue.lua` into `ue/cdb/{json,paths,shaders,pipeline}.lua` |
| `2026-05-07-dap-multiplatform.md` | F.1 · F.2 · F.3 | Platform-neutral `UEDAP*` user commands, dispatch registry, deprecation of `UEAndroidDAP*` |
| `2026-05-07-dap-real-platforms.md` | H | Real attach/launch handlers for Win64 / macOS / Linux / iOS via `ue/dap/<platform>.lua` |
| `2026-05-07-config-schema-expansion.md` | I | Add `clangd.*`, `dap.*`, `cdb.*` keys to `ue.config` schema |
| `2026-05-07-android-config-wire.md` | J | Wire `ue/dap.lua` Android prompts (`lldb_server_path`, `android_package`) through `ue.config` |

### Earlier ADRs (2026-04)

| File | Subject |
|---|---|
| `2026-04-17-instant-goto-architecture.md` | tier-2 split of the goto-definition engine into `lua/utils/ue_goto/` |
| `2026-04-20-syntax-overload-disambiguation.md` | C++ overload disambiguation strategy for instant goto-def |

### Baselines

`baselines/` holds frozen output snapshots that ADRs reference for
before/after diffs. Do not edit by hand.

## Conventions

- Filename pattern: `YYYY-MM-DD-<kebab-slug>.md`
- Each ADR is dated by **decision date**, not implementation date
- Phase tags (A, B, ...) are scoped to the iteration log they belong
  to and reset per branch
- Iteration logs are added **once a branch is ready to merge**, not
  during work. They reference the commit hashes on the branch
- Sanitization rules: paths in new ADRs use `vim.fn.stdpath` or
  `<USER>`/`<LOCAL_APPDATA>` placeholders; existing PII in 2026-04
  ADRs is intentionally left untouched (see iteration log §7)

## How to add a new ADR

1. Pick a kebab slug for the subject
2. Create `docs/plans/<today>-<slug>.md` with these sections:
   - Status / Branch / Owner / Created
   - Predecessors (link earlier ADRs by relative path)
   - Context (what's broken / missing / needed)
   - Decision (what we're going to do)
   - Architecture (before / after, code shape)
   - Public-API impact (freeze-list deltas)
   - Test gate (specific commands)
   - Sanitization (PII rules for the changes)
   - Rollback (how to revert)
3. Add a row to this README under the appropriate group
4. If the work spans 3+ commits, also append it to the active
   iteration log
