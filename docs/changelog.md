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

- `v2.12.0` → [docs/release_2.12.0.md](release_2.12.0.md) (clangd memory reclaim after background index, disk preambles with per-session TEMP, headless CI fixes; full regression 4396/4396, 2 skips; tag pending)

- `v2.12.1` → [docs/release_2.12.1.md](release_2.12.1.md) (clangd reclaim quiet-window, progress timer and prepare-owner guards; full regression 4400/4400, 2 skips; tag pending)

- `v2.12.2` → [docs/release_2.12.2.md](release_2.12.2.md) (shared Scratch, single-Escape picker cancellation and bounded workspace diagnostics; full regression 4402/4402, 2 skips; tag pending)

- `v2.12.3` → [docs/release_2.12.3.md](release_2.12.3.md) (preparation and history repairs; cold180 and complete warm semantics pending; tag pending)

- `v2.12.4` → [docs/release_2.12.4.md](release_2.12.4.md) (large-CDB digest memory repair; full regression 4419/4419, 2 skips; tag pending)

- `v2.12.5` → [docs/release_2.12.5.md](release_2.12.5.md) (absent-cache preparation repair; full regression 4421/4421, 2 skips; tag pending)

- `v2.13.0` → [docs/release_2.13.0.md](release_2.13.0.md) (real-build qualification fixes, opt-in whole-module Tier 2 and exact Tier 1 behind a strict graph gate; full regression 4462/4462, 2 skips; tag pending)

- `v2.13.1` → [docs/release_2.13.1.md](release_2.13.1.md) (engine-following caches, select-confirm fix, cold-index research record; full regression 4472/4472, 2 skips; tag pending)

- `v2.14.0` → [docs/release_2.14.0.md](release_2.14.0.md) (private prefix-PCH offline index with offline Tier 1 absorption; full regression 4485/4485, 2 skips; tag pending)

- `v2.15.0` → [docs/release_2.15.0.md](release_2.15.0.md) (offline prefix-PCH index speed-up: quiet-host cold full index 253–293 s, 7 batches with median ≤300 s; README refresh; tagged `v2.15.0`)

## Unreleased

### 2026-11-11 — Default private offline-index bin to the v26 build

**Task**
- The 2.15.0 timings were measured with the v26 private build (PGO + ThinLTO + rpmalloc + overlay cache), but the default `bin_dir` still pointed at `metadata-v24c`.

**Implemented**
- `lua/ue/config.lua`, `lua/ue/index/pch_offline.lua`, `tests/cases/index_pch_offline_spec.lua`: default `index.pch_offline.bin_dir` changed from `metadata-v24c` to `metadata-v26`. Private binaries still stay out of the public repo. If the directory is missing, behavior is the same as before (probe absent → offline path not taken).

- Fork source published: `hana-alice/llvm-project`, branch `clangd-pch/v26`, tag `clangd-pch-v26`. It is one commit on top of `llvmorg-22.1.5` (20 files, +2033/-75).
- `.gitmodules` + gitlink `third_party/llvm-project` point at that commit with `update = none` and `shallow = true`. A recursive clone does not fetch llvm. To fetch it explicitly: `git submodule update --init --checkout --depth 1 third_party/llvm-project`.
- Prebuilt Windows x64 binaries (`clangd.exe`, `clangd-pch-probe.exe`, plus LICENSE and the patch) are attached to GitHub release `v2.15.0`.

**Validation**
- `index_pch_offline` 13/13; `python -B -I tests/py/test_clangd_pch_offline.py` 42/42; full regression see commit.
