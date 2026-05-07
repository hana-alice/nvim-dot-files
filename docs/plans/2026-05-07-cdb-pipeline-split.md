# Phase E — CDB Pipeline Split (compile_commands)

> **Status**: Proposed → small-step extraction approved
> **Branch**: `feat/multi-platform-foundation`
> **Owner**: config maintainer
> **Created**: 2026-05-07
> **Predecessor**: `2026-05-06-multi-platform-foundation.md`

---

## Context

`lua/ue.lua` houses the entire compile_commands.json (CDB) pipeline:

| Range | Component |
|-------|-----------|
| 3361–3408 | `compile_commands_targets` / `compile_commands_candidates` — target-path resolution |
| 3640–3730 | `compile_commands_program` / `compile_commands_template_entry` / `augment_compile_commands_with_shaders` — pure JSON helpers |
| 3733–4170 | RSP-based generation (`generate_compile_commands_from_rsp`) — calls Python tooling |
| 4175–4280 | `slim_compile_commands_file` — invokes `tools/slim_compile_commands.py` |
| 4283–4416 | `run_compile_commands_pipeline` — orchestrates slim → pch-rewrite → unify → prune |
| 4418–4515 | `export_compile_commands_to_engine_root` — top-level entry |
| 4430+ | `generate_compile_commands` — dispatcher |

These functions reference shared upvalues `run_lines`, `_logged_jobstart`,
`INDEX_FN`, `cache_paths`, `resolve_context`, plus the just-extracted
`ue.core.fs` helpers. They form a tightly-coupled subsystem that cannot
be lifted wholesale without an upvalue cascade and a near-certain
violation of the 200-local main-chunk cap.

## Decision

Split Phase E into **three sub-steps**, each independently revertable.
Only step E.1 lands in this commit; E.2 and E.3 follow once E.1 has soaked
on the user's actual UE workspace.

### E.1 — Pure-function extraction (THIS COMMIT)

Lift only the parts that are **referentially transparent** (no upvalue
capture, no IO that depends on engine state):

- `compile_commands_program(entry)`
- `compile_commands_template_entry(entries)`
- `augment_compile_commands_with_shaders(ctx, content)` — uses `ctx` as
  data input only, no upvalue mutation

Move them to `lua/ue/cdb/json.lua`. ue.lua replaces the original
`local function` bodies with 1-line wrappers, identical pattern as
Phase B's `ue.core.fs` extraction.

**Effect on local count**: net 0 — three local functions in, three
1-line wrapper locals out.

### E.2 — Path-resolution extraction (FOLLOWUP)

Lift the path-target functions:

- `compile_commands_targets(ctx)`
- `compile_commands_candidates(ctx)`

To `lua/ue/cdb/paths.lua`. These read `ctx` only and call `ue.core.fs`
helpers, so they are also referentially transparent.

### E.3 — Pipeline driver (FOLLOWUP, optional)

Lift `run_compile_commands_pipeline` and the `slim_compile_commands_file`
function into `lua/ue/cdb/pipeline.lua`. These DO touch `_logged_jobstart`
and `cache_paths`, so the extraction needs an explicit dependency-injection
shim:

```lua
local pipeline = require("ue.cdb.pipeline")
pipeline.set_runtime({
  jobstart = _logged_jobstart,
  cache_paths_fn = function() return cache_paths end,
  notify_error = function(msg) require("utils.log").notify_error("cdb", msg) end,
})
```

E.3 is **NOT** done in this round because:

1. `_logged_jobstart` is used by 6 other subsystems in `ue.lua`; injecting
   it cleanly requires a similar Phase B–style "core/proc" wrapper that
   doesn't yet exist.
2. The pipeline is the single highest-value end-to-end test surface; we
   want E.1+E.2 stable for at least one PR cycle before disturbing it.

## Public-API impact

None. `require("ue").generate_compile_commands` and the user commands
`UEPrepare` / `UEExportCompileCommands` keep their current signatures and
behaviour byte-for-byte.

## Test gate

```bash
nvim --headless --clean -u NONE -c 'set rtp+=.' \
     -c 'lua require("ue.cdb.json")' +qa
nvim --headless --clean -u NONE -c 'set rtp+=.' \
     -c 'lua local c=require("ue.cdb.json"); assert(type(c.template_entry)=="function")' +qa
nvim --headless --clean -u NONE -c 'set rtp+=.' \
     -c 'lua local ue=require("ue"); assert(type(ue.clangd_cmd)=="function")' +qa
nvim -l scripts/lint_no_bare_globals.lua
```

All four must exit 0. They are folded into `scripts/headless_smoke.lua` by
Phase G.

## Rollback

Single commit. `git revert HEAD` removes:

- `lua/ue/cdb/json.lua`
- `lua/ue/cdb/init.lua`
- the wrapper bodies in `lua/ue.lua` (restoring inline definitions)

## Followup

E.2 and E.3 each get their own commit on this branch. Tracked in this ADR
as the "Followup" section above; no separate ADRs needed unless the shape
of the extraction changes.
