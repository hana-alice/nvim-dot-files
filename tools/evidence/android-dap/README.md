# Android DAP smoke evidence

`smoke.current.result.json` is produced by `:UEDAPSmoke` (implementation:
`lua/ue/dap/smoke.lua`). It records the layered verdicts of one on-demand
real-device verification run.

Why this exists: every other `dap` regression case is a pure function or a
source assertion, so none of them can answer "does this attach route still
work". Without this command the only integration test is the user, on a real
device, at the moment they actually need to debug — which is why the user was
the regression detector. See `openspec/specs/dap-failure-layering/spec.md` and
`docs/CONSTRAINTS.md` §三 C10.

## Redaction contract (K55)

The artifact intentionally contains only statuses, per-layer verdicts, probe
ids, exit codes, counts, booleans, and short digests. It must never store:

- real device identifiers or names
- real application identifiers
- process ids from a real application
- personal filesystem paths
- probe `argv` (which embeds the device identifier and application id)

`lua/ue/dap/smoke.lua` enforces this **before writing**: `redaction_violations`
scans the encoded artifact and `write_evidence` refuses to write when it finds a
reverse-DNS identifier, a personal path, or a raw `pid` field. Failing closed and
storing no evidence is preferred over leaking an identity.

## Honest statuses

- `pass` — the gate passed on a real device.
- `failed` — a layer blocked; `blocking_layer` names it.
- `not_applicable` — no device or no application configured. **This is not a
  pass.** Injecting a fake host or a fake executable to turn this into a pass is
  prohibited (host-capability guard, root `AGENTS.md`).
