# hana-alice/nvim 1.11.2 — Carry Android SDK selection into UBT

> 日期：2026-09-11
> 类型：Patch（连接已配置的 SDK 禁用意图与编译参数）
> Git tag：未创建；本次脱敏提交不包含打 tag。
> 脱敏迁移状态：实现与 spec 已转向外部策略；迁移后验收 pending，历史绿灯不作为本次验收。

## 归档工作记录

### 2026-09-11 — Make Android builds honor UseSDK=0

**Task**
An existing project's runtime configuration disabled SDK, while its Target rules
enabled SDK by default unless command-line arguments explicitly disabled it. Neovim
did not pass that argument, so successful environment preparation did not prove that
the compiler excluded SDK modules.

**Implemented**
- `lua/ue/targets/android.lua`: read the external SDK policy and the selected `.uproject`
  directory's configured INI on each build plan. Value `0` appends the policy's actual
  `disable_argument`; value `1` or missing policy/file/key preserves the Target default.
  No project configuration is written.
- `lua/ue/targets/android_windows.lua` and `scripts/ue_android_so_build.ps1`: carry
  the generic `-SdkArgument <argument>` through SO-only planning to the UBT action-export invocation.
- Invalid policy or conflicting values, unreadable/oversize files and unsupported encodings produce
  unavailable plans rather than silently selecting the SDK-enabled default.
- Plan metadata exposes the boolean `sdk_disabled`; configuration contents and private mappings
  are not logged or persisted in metadata.
- `tests/cases/ue_target_drivers_spec.lua`: SDK states, fresh reads, selected-project path,
  BOM/comments, malformed/conflicting data, bounded reads and read errors.
- `tests/cases/ue_target_integration_spec.lua` and `tests/fixtures/android_so_sdk_args.ps1`:
  real PowerShell runner argument capture for both switch states, phase separation,
  space-containing paths and action-file cleanup.

**Pitfalls / Gotchas — incident review (K71)**
- Environment/runtime settings and compiler settings had different consumers. A success
  message from environment preparation was not proof that the compiled binary excluded SDK.
- The inspected branch's Target consumes explicit compiler arguments; it does not consume
  the preparation script's separate output file. This repair does not rely on that file or modify
  external preparation scripts. Private identifiers, checkout paths and unrelated INI values are omitted.
- Future investigations must verify the final build argv and the Target's actual parser,
  then distinguish argument propagation from verification of a newly compiled binary.
- SDK policy evaluation stays in the Android driver; the Windows adapter only forwards the
  runner parameter. No generic workflow policy, new dependency, or global override was introduced.

**Validation — historical, before the external-policy migration**
- Before repair, new driver cases reproduced missing disable flags and missing rejection
  of invalid values: 49/52 passed, 3 failed. The native runner rejected the original dedicated
  switch before its parameter was added (described here as a sanitized summary).
- Focused `nvim --headless -l tests/run.lua ue_target`: **89/89 passed**, zero failures/skips.
- Final full `nvim --headless -l tests/run.lua` with `NVIM_TEST_REQUIRE_NATIVE=1`:
  **1636/1636 passed**, zero failures/skips, exit 0. Local output was captured as
  `nvim-sdk-acceptance.log` in the host temp directory.
- AST bare-global lint passed for the four changed Lua files; both specs passed strict
  OpenSpec validation; `git diff --check` passed.
- Clean-process planners read the real E- and F-drive checkout configuration and returned
  the disable flag for both normal and SO builds. Only SDK-setting/argv evidence was used;
  unrelated configuration values are not reproduced in this record.
- The running editor's three stateless planning functions were updated in place, retaining
  the registry/adapter table identities. Verification immediately queried both public build
  command routes and confirmed the expected disable argument in each for the selected project.
  A rollback was prepared if verification failed; it was not needed. No compiler was launched.
- Spec synchronized: `ue-target-driver-boundary` and `android-so-quick-deploy`.
- These results establish the earlier repair only. External-policy behavior, regression,
  local mapping preservation and privacy checks require fresh acceptance; currently pending.

## Public-mirror migration: external SDK policy

The original repair embedded project-specific identifiers. The public implementation now uses
`ue.config`'s `android.sdk_policy_file`, defaulting to
`stdpath('state')/ue-android-sdk-policy.json`, for the actual mapping. The file stays outside the
public worktree. A public illustrative policy is:

```json
{
  "config_file": "Config/SDK/Runtime.ini",
  "key": "UseSDK",
  "disable_argument": "-skip-project-sdk"
}
```

These example values do not reproduce a private checkout or its Target parser. `config_file`
is relative to the selected `.uproject` directory; `disable_argument` is one actual UBT
argument supplied by the external policy. The normal build appends it directly; the SO runner
receives it through `-SdkArgument`. Metadata reports only `sdk_disabled`.

Migration must place the real mapping in the external state file and recheck both local
checkouts' plans. Missing policy intentionally injects no argument; invalid policy must fail.
No existing user build needs to be cancelled or restarted to perform read-only plan checks.
This changes where private data is supplied; it is not a spelling change, encoding scheme,
or string assembly intended to evade scanning. Private identifiers must be absent from public
source, fixtures, documents and commit content, and the normal privacy hooks remain required.

**Migration validation:** `ue_target` 91/91 passed; final full suite with
`NVIM_TEST_REQUIRE_NATIVE=1` passed **1638/1638**, zero failures/skips, exit 0. Five-file AST
lint, both strict spec checks and `git diff --check` passed. Worktree added-content review
passed both private denylist and generic credential scanners with zero findings.
New-process plans for both real checkouts preserved the exact original disable argument
through the external mapping. Real policy values were not printed into public evidence.
The running editor's update request did not return; only its diagnostic client was stopped,
not the editor. In-process migration is unverified; next startup loads the verified files.

**Follow-ups**
- Runner fixtures validate argument forwarding only; no real UE compilation, APK packaging,
  install or binary SDK-content verification is claimed.

## Subsequent user build — rebuild diagnosis

After the original repair, the user started a normal Android build. The following is an
explicitly sanitized summary of read-only observations, not verbatim log quotations:

- The running UBT command included the expected SDK-disable argument for the intended checkout.
- The terminal and engine UBT log reported makefile regeneration because command-line arguments
  changed; Target output reported that SDK inclusion was disabled.
- The build scheduled **1214 actions**. This is an action count, not a count of source files
  or proof that every possible action was rebuilt.
- The inspected Target adds an SDK enable/disable macro to `GlobalDefinitions`. The inspected
  Core PCH headers defined that macro as `0`; the Core response file included
  that PCH. Thus the compiler environment change reaches engine modules, not just SDK code.
- UBT's `TargetMakefile` rejects differing additional arguments; its `ActionGraph`
  invalidates actions for changed producing attributes or newer/outdated prerequisites.
  The available log does not provide a complete per-action invalidation breakdown, so
  this record does not assert that all 1214 actions share exactly one cause.

The assistant's earlier delivery should have explained that changing this global macro
can trigger a broad rebuild. Reporting correct argument propagation without that cost
was incomplete. After a successful build, unchanged project/target/configuration/SDK
settings are expected to permit incremental reuse, but a subsequent no-change build
has not been observed; there is no guarantee recorded here that the next invocation
will execute zero actions. The ongoing user build was neither cancelled nor restarted.
