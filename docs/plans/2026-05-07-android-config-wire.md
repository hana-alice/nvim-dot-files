# Phase J — Wire Android DAP into `ue.config`

> **Status**: Proposed → ready
> **Branch**: `feat/multi-platform-foundation`
> **Predecessors**: H (per-platform DAP), I (config schema expansion)

## Context

Phase I defined `dap.lldb_server_path` and `dap.android_package` in
`lua/ue/config.lua` but no consumer reads them yet. The Android attach
and launch flows in `lua/ue/dap.lua` still:

- Glob `$LOCALAPPDATA/Programs/Android Studio*/...` and the NDK
  side-by-side path, then prompt for an arm64 lldb-server when both
  globs miss.
- Prompt for an Android package name when no value is persisted in the
  per-engine state file.

For users who keep their Android tooling in a non-default location, or
who run dozens of attaches per day on a known package, both prompts are
friction the schema can absorb.

## Decision

Insert config reads at the existing prompt sites. Preserve the existing
fallbacks so anyone without an override sees identical behaviour.

### `lldb_server_path`

Resolution order at the lldb-server probe site:

1. `ue.config.get("dap.lldb_server_path")` — when set and exists, use it.
2. The two existing Windows globs (Android Studio + NDK).
3. `vim.fn.input(...)` interactive prompt.

### `android_package`

Resolution order at the package-name site:

1. Existing per-engine state file (`state.android_package`).
2. `ue.config.get("dap.android_package")` when state is empty.
3. `vim.fn.input(...)` interactive prompt.

State persistence (`update_state_field`) is unchanged; the schema only
seeds the FIRST attach, after which the state file takes over.

## Public-API impact

Additive only. No signature change in `D.android_dap_attach` or
`D.android_dap_launch`.

## Test gate

Two new smoke checks:

- Setting `dap.android_package` makes `_pick_android_package_for_test`
  (a thin extracted helper) return the schema value when state is empty.
- Setting `dap.lldb_server_path` to an existing file makes the
  `_pick_lldb_server_for_test` helper return that path without globbing.

We extract the two probe blocks into module-level helpers with `_for_test`
suffix so the smoke checks can hit them without spinning up a real
adb session.

## Sanitization

No personal paths in defaults. The schema keys default to `nil`; no
existing call site is widened to leak local paths.
