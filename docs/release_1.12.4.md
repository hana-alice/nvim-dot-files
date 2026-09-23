# hana-alice/nvim 1.12.4 — Verify native frozen-cache redirection rejection

> 日期：2026-09-23
> 类型：Patch；补齐原生回归证据，运行时行为未改变。
> Git tag：未创建，未获 tag 授权。
> 收尾复查：目录祖先事件再次触发回退；11:26:13Z 为 original client28，持续冻结运行未完成。

### 2026-09-23 — Verify redirected frozen-cache components on the real host

**Task**
- Close the direct cache-junction regression gap recorded in v1.12.1 and v1.12.3.

**Implemented**
- `tests/cases/index_batch_runtime_spec.lua`: create real Windows junctions at `verified`, `verified/.cache`, `verified/.cache/clangd` and `verified/.cache/clangd/index` within an owned fixture. Confirm the actual redirected destination with `fs_realpath`.
- Require original commands, no validation helper or guard-watch installation, and unchanged target bytes, file/directory timestamps and directory entries.
- Remove the junction itself before recursive fixture cleanup; failed unlink or a remaining link stops cleanup. Reuse the existing fixture and production guard without a new abstraction, dependency or runtime change.

**Validation**
- Focused required-native runtime **54/54**, zero failures/skips; all four new native cases executed. Lua AST lint and independent review passed.
- Full required-native regression **2130/2130** and final documentation structure **78/78**, zero failures/skips.
- Spec consistency: no behavior change. Tests verify the existing redirected-component rejection scenario in `cpp-semantic-index-coverage`; no delta or new active change is needed.

**Later live observation**
- At **11:15:29Z**, the live editor had initialized frozen client27, activation attempt3, a ready guard with 26 watches and no pending activation helper. No restart was initiated during this read-only inspection.
- The retained runtime log records two `SceneVisibility.cpp` file-change events at **11:13:16Z** and **11:14:08Z**. It lacks client/attempt identifiers and earlier file bytes, so neither the exact old-client mapping nor the writer/content-change cause is established. Earlier client24-ready observations remain valid for their recorded times.
- No retained client24 BackgroundIndex completion timestamp was found. LSP logging was off, and retained UI history only contained unrelated older progress. Absence of retained evidence proves neither completion nor noncompletion; ready guards, CDB counts and CPU samples cannot replace that measurement.

**Follow-ups**
- Direct Windows cache-junction coverage is now closed on this host. Long-session editing/recovery, proactive promotion, broader secondary compression and historical navigation/dirty/csearch dispositions remain open.
- Capture explicit per-client indexing start/end evidence with cache and input identities before reporting whole-engine timings. Whole-engine CPU/memory and cold/warm performance acceptance remain unfinished.

### 2026-09-23 — Retain the later ancestor-event fallback in acceptance

**Task**
- Correct final live-state reporting after the successful junction verification and push.

**Observed**
- The runtime warning log records an `input-changed` event at **11:18:32Z** for the configuration directory reported through its parent watch: `filename=nvim`, `action=3`, `directory=true`, `change=true`, `rename=false`.
- At **11:26:13Z**, guard status retains this exact event, is invalidated with zero watches, and initialized **original client28** serves the CDB. The earlier frozen client27-ready snapshot remains valid for its recorded instant; it is not the final state.
- The event's underlying writer and affected descendant are unknown. It predates the junction-stage commit/push and must not be attributed to those actions from timing alone. No directory-event exclusion or forced recovery was added.

**Validation**
- Documentation-only correction; production code and the passed **2130/2130** native result are unchanged. Structure **78/78** and whitespace checks passed for this correction. No spec behavior change.

**Follow-ups**
- Investigate this directory-ancestor notification and safe recovery before claiming sustained frozen activation. Preserve genuine namespace/security/identity protection; do not simply ignore directory changes.
