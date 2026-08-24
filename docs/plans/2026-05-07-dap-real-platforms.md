# Phase H — DAP Real Platforms (Win64 / macOS / Linux / iOS)

> **Historical snapshot / superseded.** 本文的 codelldb、stub handler 与 iOS-as-Mac
> 假设已过时。当前实现统一使用 lldb-dap，iOS 拥有独立真机 handler；现行契约见
> [`../architecture/overview.md`](../architecture/overview.md) 和 OpenSpec
> `dap-platform-dispatch`。

> **Status**: Proposed → H.1 (stub modules + dispatch wiring) approved
> **Branch**: `feat/multi-platform-foundation`
> **Owner**: config maintainer
> **Created**: 2026-05-07
> **Predecessors**: foundation, dap-multiplatform (F.1+F.2)

---

## Context

Phase F.2 introduced `lua/ue/dap/platforms.lua`, a registry where each
platform contributes attach/launch handlers. Today only `android` is
registered; `UEDAPAttach win64` warns "no handler".

The existing implementation already has the building blocks for other
platforms:

- `D.codelldb_paths()` resolves a portable codelldb adapter on every OS
  (`vim.fn.stdpath("data") .. "/codelldb/.../adapter/codelldb"` plus
  exe/dll/dylib/so suffix). Phase A's `utils.platform.driver()` adds
  `default_codelldb_paths()` per OS — H must reconcile the two.
- `lib/ue/dap.lua` carries Android-specific bits in `android_dap_attach` /
  `android_dap_launch` — pwsh push of `lldb-server`, package-name prompt,
  ASLR fix, etc. None of that survives moving to native debugging on
  Win64/Mac/Linux, which is just "spawn codelldb, attach to PID or
  launch binary".

## Decision

Add four sibling modules, each implementing a **minimal but real**
attach + launch flow. None of them handles UE-specific package
deployment (that's a future Phase). The goal is: when the user says
`:UEDAPAttach win64` we spawn codelldb against a UE binary they pick.

```
lua/ue/dap/
├── platforms.lua    (registry, F.2)
├── win64.lua        (NEW, this commit)
├── mac.lua          (NEW)
├── linux.lua        (NEW)
└── ios.lua          (NEW; thin macOS wrapper for now)
```

Each module exports:

```lua
return {
  attach = function() end,   -- prompt for PID, attach codelldb
  launch = function() end,   -- prompt for binary path, launch codelldb
}
```

Each handler:

1. Resolves the codelldb adapter via `utils.platform.driver().default_codelldb_paths()`,
   then falls back to `D.codelldb_paths()` for repo-vendored installs.
2. Builds a nvim-dap configuration matching the existing Android
   implementation's shape (so `dap_continue` / `dap_pause` etc. keep
   working unchanged).
3. Calls `dap.run(config)`.

Implementation detail: this commit ships **functional stubs** that build
a real config but call `vim.notify` saying "Phase H: dispatched to <id>"
before invoking `dap.run`, so that when the user actually exercises a
non-Android platform we get a visible breadcrumb. The real config-build
code is gated behind `nvim-dap` being available — when it is not, the
stub still exits cleanly with a clear message.

## Interaction with Phase I (config schema)

Once Phase I lands `dap.codelldb_path` in the schema, every platform
module reads it before falling back to the driver. H is written so that
swap-in is a one-liner:

```lua
local function find_codelldb()
  local cfg_path = require("ue.config").get("dap.codelldb_path")
  if cfg_path and require("ue.core.fs").is_file(cfg_path) then return cfg_path end
  for _, p in ipairs(driver.default_codelldb_paths()) do
    if require("ue.core.fs").is_file(p) then return p end
  end
  return nil
end
```

## Public-API impact

Additive only. `M.android_dap_attach` / `M.android_dap_launch` and the
existing `UEAndroidDAP*` user commands are untouched.

`UEDAPAttach win64` (and mac/linux/ios) now does something instead of
warning.

## Test gate

```lua
require("ue").setup()
local p = require("ue.dap.platforms")
assert(type(p.attach_handler("android")) == "function")
assert(type(p.attach_handler("win64"))   == "function")
assert(type(p.attach_handler("mac"))     == "function")
assert(type(p.attach_handler("linux"))   == "function")
assert(type(p.attach_handler("ios"))     == "function")
```

Calling them without a real DAP session is allowed to no-op + notify;
the smoke test only verifies the registry shape.

## Sanitization

No PII, no absolute personal paths. All paths go through
`vim.fn.stdpath("data")` or the platform driver.

## Rollback

Single commit. `git revert HEAD` removes the four `lua/ue/dap/<id>.lua`
files and the `register_attach`/`register_launch` calls from
`lua/ue.lua`.
