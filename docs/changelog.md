# Neovim Config Changelog

Working log for every change inside this Neovim configuration. Every commit
should add an entry here even if it is tiny. When entries pile up, slice off
a versioned `release_X.Y.Z.md` and keep this file rolling forward.

## Entry template

```
### YYYY-MM-DD — Short title

**Task**

**Implemented**
- concrete changes

**Pitfalls / Gotchas**
- traps and fixes

**Validation**
- exact regression scope and result

**Follow-ups**
- remaining work
```

## How to use

1. Skim the latest entries before modifying the config.
2. Record every landed change and its exact validation scope.
3. At a coherent milestone, move entries into a release document, run the full regression, and only tag after explicit user confirmation.

## Released

- `v1.0.0` → `docs/release_1.0.0.md`
- `v1.0.1` → `docs/release_1.0.1.md`
- `v1.0.2` → `docs/release_1.0.2.md`
- `v1.0.3` → `docs/release_1.0.3.md`
- `v1.1.0` → `docs/release_1.1.0.md`
- `v1.2.0` → `docs/release_1.2.0.md`
- `v1.3.0` → `docs/release_1.3.0.md` (tag pending explicit confirmation)
- `v1.4.0` → `docs/release_1.4.0.md` (tag pending explicit confirmation)
- `v1.5.0` → `docs/release_1.5.0.md` (tag pending explicit confirmation)
- `v1.6.0` → `docs/release_1.6.0.md` (tag pending explicit confirmation)
- `v1.7.0` → `docs/release_1.7.0.md` (tag pending explicit confirmation)
- `v1.8.0` → `docs/release_1.8.0.md` (tag pending explicit confirmation)
- `v1.9.0` → `docs/release_1.9.0.md` (tag pending explicit confirmation)

- `v1.9.1` → `docs/release_1.9.1.md` (tag pending explicit confirmation)
- `v1.9.2` → `docs/release_1.9.2.md` (tag pending explicit confirmation)
- `v1.9.3` → `docs/release_1.9.3.md` (tag pending explicit confirmation)
- `v1.10.0` → `docs/release_1.10.0.md` (tag pending explicit confirmation)
- `v1.11.0` → `docs/release_1.11.0.md` (tag pending explicit confirmation)
- `v1.11.1` → `docs/release_1.11.1.md` (tag pending explicit confirmation)
- `v1.11.2` → `docs/release_1.11.2.md` (tag pending explicit confirmation)

## Unreleased

### 2026-09-11 — Keep project SDK mappings outside the public mirror

**Task**
Preserve local SDK selection while removing private identifiers from public code, fixtures and documentation.

**Implemented**
- Define the external JSON policy selected by `ue.config`'s `android.sdk_policy_file`, defaulting
  to `stdpath('state')/ue-android-sdk-policy.json`; its fields are `config_file`, `key`, and `disable_argument`.
- Normal builds append the policy's actual argument; SO builds use generic `-SdkArgument` forwarding;
  metadata exposes the `sdk_disabled` boolean. Public examples use `Config/SDK/Runtime.ini`,
  `UseSDK`, and `-skip-project-sdk` only.
- Sanitize the release's incident/log summary and K71 navigation; preserve historical test counts
  and mark them as preceding this migration. Actual mappings belong outside the worktree.

**Pitfalls / Gotchas**
- Removing private data from public source requires external configuration, not renamed, encoded,
  or assembled private identifiers that evade the scanner. Normal privacy hooks remain required.
- Missing policy preserves the Target default; invalid policy fails. Migration must verify that
  each existing checkout still receives its intended argument from the external mapping.

**Validation**
- Spec synchronized: `ue-target-driver-boundary` and `android-so-quick-deploy`.
- Migration documentation checks: `structure` 75/75 passed, zero failures/skips; both changed
  specs passed strict OpenSpec validation; scoped `git diff --check` passed.
- Migration acceptance: `ue_target` 91/91; final full suite with `NVIM_TEST_REQUIRE_NATIVE=1`
  1638/1638, zero failures/skips, exit 0. Five-file AST lint passed.
- Both real local checkouts preserved their original disable argument in new-process normal/SO plans.
- Worktree-added-content review passed both private and generic scanners with no findings;
  normal commit/ref privacy hooks remain enabled for the commit.

**Follow-ups**
- Real mappings were installed outside the worktree. The running editor did not return its update
  request, so in-process migration is unverified; next startup loads the verified files and policy.

### 2026-09-11 — Explain the first SDK-disabled rebuild from live evidence

**Task**
Explain why the user's next Android build recompiles after the SDK-argument repair.

**Implemented**
- Append live command, UBT makefile invalidation, 1214-action count and global-macro/PCH
  evidence to `docs/release_1.11.2.md`; record the omitted rebuild-cost explanation.

**Pitfalls / Gotchas**
- A global compiler definition affects engine PCHs/modules. Argument propagation is not
  a promise of an incremental first build; the log does not explain every action individually.

**Validation**
- Read-only live terminal, process argv, Target source, Core PCH/RSP and UBT source checks.
- Documentation structure regression: 75/75 passed, zero failures/skips. No spec impact:
  investigation only, no behavior change.

**Follow-ups**
- No subsequent unchanged build has been observed; current user build is left running.

原始修复及外部策略迁移见 [1.11.2](release_1.11.2.md)；脱敏后的最终全量回归 1638/1638，spec 已同步。
