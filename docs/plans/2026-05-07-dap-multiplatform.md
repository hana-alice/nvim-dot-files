# Phase F — DAP Multi-Platform (UEDAP\* aliases)

> **Status**: Proposed → F.1 (alias registration) approved
> **Branch**: `feat/multi-platform-foundation`
> **Owner**: config maintainer
> **Created**: 2026-05-07
> **Predecessors**: foundation, cdb-pipeline-split

---

## Context

Today every DAP user command is named `UEAndroidDAP*`:

```
UEAndroidDAPAttach          UEAndroidDAPStepOver
UEAndroidDAPLaunch          UEAndroidDAPStepIn
UEAndroidDAPContinue        UEAndroidDAPStepOut
UEAndroidDAPPause           UEAndroidDAPToggleUI
UEAndroidDAPToggleBreakpoint UEAndroidDAPREPL
```

When Win64 / Mac / Linux / iOS DAP arrive, the obvious naming
(`UEWin64DAPAttach`, etc.) would force the user to update every
keymap and muscle memory across platforms.

The internal API in `lua/ue/dap.lua` is *almost* platform-agnostic
already — `dap_continue`/`dap_pause`/`dap_step_*` etc. don't take a
platform argument; only `android_dap_attach` / `android_dap_launch`
do. The naming inertia comes from the user-visible commands, not
from the implementation.

## Decision

**Three sub-steps:**

### F.1 — Add `UEDAP*` aliases (THIS COMMIT)

Register a parallel set of platform-neutral commands that delegate to
the same internal handlers:

| Old (kept, still works) | New alias | Behaviour |
|------------------------|-----------|-----------|
| `UEAndroidDAPAttach`        | `UEDAPAttach [platform]`        | platform defaults to current_platform() |
| `UEAndroidDAPLaunch`        | `UEDAPLaunch [platform]`        | same |
| `UEAndroidDAPContinue`      | `UEDAPContinue`                 | platform-agnostic |
| `UEAndroidDAPPause`         | `UEDAPPause`                    | platform-agnostic |
| `UEAndroidDAPToggleBreakpoint` | `UEDAPToggleBreakpoint`      | platform-agnostic |
| `UEAndroidDAPStepOver`      | `UEDAPStepOver`                 | platform-agnostic |
| `UEAndroidDAPStepIn`        | `UEDAPStepIn`                   | platform-agnostic |
| `UEAndroidDAPStepOut`       | `UEDAPStepOut`                  | platform-agnostic |
| `UEAndroidDAPToggleUI`      | `UEDAPToggleUI`                 | platform-agnostic |
| `UEAndroidDAPREPL`          | `UEDAPREPL`                     | platform-agnostic |
| `UEDAPDiag`                 | (unchanged — already neutral)   | |

`UEDAPAttach` / `UEDAPLaunch` accept an optional platform argument:

- `UEDAPAttach`            → uses `M.current_platform()`
- `UEDAPAttach android`    → forces android path (current behaviour)
- `UEDAPAttach win64`      → routed to a NotImplemented stub (Phase F.2)
- `UEDAPAttach mac`/`ios`/`linux` → same stub

Old `UEAndroidDAP*` commands are kept verbatim. They print no
deprecation warning yet — that lands in F.3 once the aliases have
been on the user's main install for at least a release cycle.

### F.2 — Per-platform attach/launch dispatch (FOLLOWUP)

Wire `UEDAPAttach <platform>` to a real implementation per platform.
Currently only `android` is implemented in `lua/ue/dap.lua`. Win64 /
Mac / Linux land in their own commits, each with its own platform
driver call (codelldb path, lldb-server path, attach mechanism).

### F.3 — Deprecate `UEAndroidDAP*` (FOLLOWUP, several weeks later)

Make the old commands print a one-time deprecation notice that names
the alias. Do NOT remove them — keymaps in user dotfiles will break.

## Public-API impact

- **Additive**: every new `UEDAP*` command name. No existing command
  is removed or behaviourally changed.
- **`require("ue").dap_*` functions**: unchanged.
- **Keymaps in `lua/config/keymaps.lua`**: unchanged in F.1. Optionally
  updated in F.3 to point at the new aliases.

## Test gate

```bash
nvim --headless --clean -u NONE -c 'set rtp+=.' \
  -c 'lua require("ue").setup()' \
  -c 'lua assert(vim.fn.exists(":UEDAPAttach") == 2, "UEDAPAttach missing")' \
  -c 'lua assert(vim.fn.exists(":UEAndroidDAPAttach") == 2, "old alias gone")' \
  -c 'lua assert(vim.fn.exists(":UEDAPContinue") == 2, "UEDAPContinue missing")' \
  +qa
```

Plus `lint_no_bare_globals` and the Phase D headless smoke.

## Sanitization

No PII or absolute paths introduced. Platform identifiers are the
canonical UE platform names already used by `M.current_platform()`
(`Win64`, `Android`, `Mac`, `IOS`, `Linux`).

## Rollback

Single commit. `git revert HEAD` removes the alias registrations from
`lua/ue.lua`'s setup function.
