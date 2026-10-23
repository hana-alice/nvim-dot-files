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

- `v1.11.3` → `docs/release_1.11.3.md` (tag pending explicit confirmation)

- `v1.12.0` → [docs/release_1.12.0.md](release_1.12.0.md) (incremental scope; tag pending)
- `v1.12.1` → [docs/release_1.12.1.md](release_1.12.1.md) (tag pending)
- `v1.12.2` → [docs/release_1.12.2.md](release_1.12.2.md) (diagnostic stage; tag pending)
- `v1.12.3` → [docs/release_1.12.3.md](release_1.12.3.md) (demand-driven recovery; tag pending)
- `v1.12.4` → [docs/release_1.12.4.md](release_1.12.4.md) (native junction verification; later ancestor-event fallback recorded; tag pending)
- `v1.12.5` → [docs/release_1.12.5.md](release_1.12.5.md) (stable directory writes and complete ancestor watches; tag pending)
- `v1.12.6` → [docs/release_1.12.6.md](release_1.12.6.md) (modified-document preflight and clean demand recovery; tag pending)
- `v1.12.7` → [docs/release_1.12.7.md](release_1.12.7.md) (automatic clean-document recovery; tag pending)
- `v1.12.8` → [docs/release_1.12.8.md](release_1.12.8.md) (padded search query cancellation; tag pending)
- `v1.12.9` → [docs/release_1.12.9.md](release_1.12.9.md) (durable search overflow recovery; tag pending)
- `v1.12.10` → [docs/release_1.12.10.md](release_1.12.10.md) (second qualified SuperUnity batch; tag pending)
- `v1.12.11` → [docs/release_1.12.11.md](release_1.12.11.md) (retain document-blocked original readers; tag pending)

- `v2.0.0` → [docs/release_2.0.0.md](release_2.0.0.md) (CodeDiff default review; Diffview retained; tag pending)
- `v2.1.0` → [docs/release_2.1.0.md](release_2.1.0.md) (daily editing and maintenance diagnostics; tag pending)

- `v2.2.0` → [docs/release_2.2.0.md](release_2.2.0.md) (IDE experience; local validation complete; tag pending)

- `v2.3.0` → [docs/release_2.3.0.md](release_2.3.0.md) (search, reading and window recovery; tag pending)

- `v2.3.1` → [docs/release_2.3.1.md](release_2.3.1.md) (daily file protection and discovery; tag pending)

- `v2.3.2` → [docs/release_2.3.2.md](release_2.3.2.md) (navigation and editing entry fixes; tag pending)

- `v2.4.0` → [docs/release_2.4.0.md](release_2.4.0.md) (memory document find and editor reuse; tag pending)

- `v2.5.0` → [docs/release_2.5.0.md](release_2.5.0.md) (document locations and copy actions; tag pending)

- `v2.6.0` → [docs/release_2.6.0.md](release_2.6.0.md) (development workbench and run-owned evidence; tag pending)

- `v2.7.0` → [docs/release_2.7.0.md](release_2.7.0.md) (named investigations and interruption continuity; tag pending)

- `v2.8.0` → [docs/release_2.8.0.md](release_2.8.0.md) (staged index delivery, honest failure reporting and layout roles; tag pending)

- `v2.9.0` → [docs/release_2.9.0.md](release_2.9.0.md) (Tier 1 SuperUnity production delivery; full regression 4079/4079, 2 skips; tag pending)

- `v2.10.0` → [docs/release_2.10.0.md](release_2.10.0.md) (Tier 1 gen/src merge, context-migration shard invalidation, opt-in Tier 2, cost ceilings; tag pending)

- `v2.11.0` → [docs/release_2.11.0.md](release_2.11.0.md) (module-priority phase barrier fix, priority refresh after activation, phase probes; full regression 4381/4381, 2 skips; tag pending)

## Unreleased

### 2026-10-23 — Repair headless CI on ubuntu / macOS / windows (nvim 0.12.6)

**Task**
- CI failed on all three platforms; fix the real causes instead of fake hosts.

**Implemented**
- `document_find_process`: ripgrep < 15 reports `searches = 0, bytes_searched = 0` for a no-match
  search; accept that only when our own confirmed stdin write proves delivery.
- `prepare_inputs`: tolerate system toolchain layouts — dangling links inside read-only tool roots
  (distro LLVM lldb modules) and cross-target `*.cfg` beside the driver (macOS CommandLineTools).
  Configs clang would load for this driver/target (`<driver>.cfg`, `clang.cfg`, `<triple>-clang.cfg`,
  unknown triple) still fail closed.
- `tests/run.lua`: the physical-temp relaunch now also covers macOS `TMPDIR=/var/...` → `/private/var/...`.
- nvim 0.12 compatibility in specs (`version = 0` text edits, exited terminal channels, a ConPTY
  resize/jobstop race wait); capability guards for missing csearch tools / libclang.
- Workflow installs the cindex-uefilter fork + pinned csearch; job timeout 60 min.

**Pitfalls / Gotchas**
- nvim 0.12 on Windows segfaults when a ConPTY job is stopped within ~20 ms of a resize (upstream).
- A stale `refs/heads/<branch>.lock` left by an interrupted rebase blocks the ref update.

**Validation**
- Windows nvim 0.11.5 and 0.12.6: `ue_cdb` 208/208 (+1 skip), `ue_cdb_prepare_cache` 21/21 (new system
  toolchain fixture), `ide_refactor` 30/30, `ide_task_inspection` 7/7, `search_interaction` 16/16,
  `cpp_semantic_sidecar_freshness` 10/10, `workarounds_uri` 15/15, `ide_document_find` 28/28.
- WSL Ubuntu 24.04 (rg 14.1.0): `ide_document_find` 28/28, `search_interaction` 15 + 1 skip.
- macOS lane validated only through CI.

**Follow-ups**
- Remaining macOS-only failures (dap_persist_failure, ide_buffer_close, clipboard, ide_recovery,
  ide_workbench, ide_workspace_reuse) to be re-triaged from the next CI run.
