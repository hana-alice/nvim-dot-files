# Phase I — `ue.config` Schema Expansion

> **Historical snapshot / superseded.** 本文记录最初 schema 设计，`codelldb_path`
> 等键名和 inline-location 描述不再是当前事实。现行 schema 以 `lua/ue/config.lua`
> 与 OpenSpec `platform-tool-resolution` 为准。

> **Status**: Proposed → I.1 (schema spec frozen) approved
> **Branch**: `feat/multi-platform-foundation`
> **Owner**: config maintainer
> **Created**: 2026-05-07
> **Predecessors**: foundation (Phase C), dap-multiplatform (Phase H)

---

## Context

Phase C introduced `lua/ue/config.lua` with a deliberately tiny seed of
keys (`index.*` timing constants + `paths.{state,cache}_dir`). The
schema shape (`setup()` deep-merge, `get(dotted)`, lazy function
values, `reset_for_test()`) is now exercised by 81 smoke checks and
by `ue.lua`'s `INDEX_RT` initialiser.

Several hard-coded values still live inline:

| Inline location | Constant | Why it should be configurable |
|---|---|---|
| `ue.lua` `clangd_candidates()` | hard list of clangd paths | per-host LLVM install dirs |
| `ue/dap.lua` `D.codelldb_paths()` | `stdpath("data")/codelldb/...` etc. | user might use Mason or custom path |
| `ue/dap.lua` android attach prompts | `state.android_package` | auto-detect once, then never re-prompt |
| `ue/cdb/pipeline.lua` script names | `expand_response_cdb.py`, `prebuild_pch_v2.py`, ... | user might rename or skip steps |

Without a schema, every per-host divergence becomes either an env-var
hack (`UE_CLANGD`) or a hard fork.

## Decision

Expand `ue.config` defaults with the keys below. **No site changes in
this commit** beyond `ue/dap/_common.lua` already reading
`dap.codelldb_path` (added in Phase H). The actual reader migration of
`clangd`, `cdb.tools_dir`, etc. is left to a followup commit so this
ADR commit is a pure schema addition.

```lua
-- additions on top of the C defaults
clangd = {
  -- Extra candidate paths tried before the platform driver's defaults
  -- and before the env-var override. Highest priority.
  candidates_extra = {},
  -- Extra args appended to the clangd command line.
  extra_args = {},
},

dap = {
  -- Concrete adapter executable. nil => probe via driver +
  -- vendored install (see ue.dap._common.find_codelldb).
  codelldb_path = nil,
  -- lldb-server (Android remote debugging). nil => probe via driver.
  lldb_server_path = nil,
  -- Default Android package name. nil => prompt on first use, then
  -- persist via update_state_field("android_package", ...).
  android_package = nil,
},

cdb = {
  -- Directory holding the python pipeline scripts. Defaults to
  -- stdpath("config")/tools so existing installs keep working.
  tools_dir = function() return vim.fn.stdpath("config") .. "/tools" end,
  -- Ordered pipeline. Removing or renaming a step lets the user
  -- skip slow ones (e.g. drop "prune" on a small project).
  steps = {
    "expand_response_cdb.py",
    "prebuild_pch_v2.py",
    "resolve_cdb_paths.py",
    "unify_include_dirs.py",
    "prune_include_dirs.py",
  },
},
```

### Precedence rules

For every key the resolution order is:

1. **Explicit env-var** (where one historically exists, e.g. `UE_CLANGD`)
2. **`ue.config` user override** via `setup({...})`
3. **`ue.config` default** (this schema)
4. **Platform driver** fallback (`utils.platform.driver().default_*()`)
5. **Hard-coded** monolith fallback (where it still exists)

This preserves backward compatibility: callers that read env-vars today
continue to do so; users with no setup() override see exactly the same
behaviour as before; new per-host customisation is one `setup({...})`
call away.

### What this commit does NOT do

- Does NOT change `ue.lua`'s `clangd_candidates()` to read the schema —
  that requires touching the platform-driver merge logic and will be a
  follow-up commit. The schema key exists for forward compatibility.
- Does NOT change `cdb/pipeline.lua` to read `cdb.tools_dir` or
  `cdb.steps` — same rationale; the schema is added so the migration
  is a one-file change later.
- Does NOT touch `M.android_package` flow in `ue/dap.lua`. The Phase H
  `_common.find_codelldb()` is the only site that already reads through
  the schema; everything else continues to hard-code defaults.

This is the smallest possible Phase I — purely additive schema growth
with a single live consumer. Future ADRs migrate the remaining sites
one subsystem at a time.

## Public-API impact

None. `M.setup`/`M.get`/`M.options`/`M.reset_for_test` signatures are
unchanged. `M.get("does.not.exist")` still returns nil for keys nobody
provided.

## Test gate

```lua
local cfg = require("ue.config")
-- new keys default-resolve
assert(type(cfg.options().clangd) == "table")
assert(type(cfg.options().dap) == "table")
assert(type(cfg.options().cdb) == "table")
assert(cfg.get("dap.codelldb_path") == nil)
assert(type(cfg.get("cdb.tools_dir")) == "string")
assert(#cfg.get("cdb.steps") == 5)

-- user override merges
cfg.setup({ dap = { codelldb_path = "/x/codelldb" }})
assert(cfg.get("dap.codelldb_path") == "/x/codelldb")
cfg.reset_for_test()
assert(cfg.get("dap.codelldb_path") == nil)
```

## Sanitization

No PII, no absolute personal paths in defaults. Default paths derive
from `vim.fn.stdpath("config")` and `vim.fn.stdpath("data")`.

## Rollback

Single commit. `git revert HEAD` restores the C-era schema defaults.
