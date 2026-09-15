# hana-alice/nvim 1.11.1 — Project completion selects the intended checkout

> 日期：2026-09-11
> 类型：Patch（修复项目选择输入与文件补全不一致）
> Git tag：未提交或打 tag；未请求 Git 发布操作。

## 归档工作记录

### 2026-09-11 — Accept native project completion without retaining the wrong checkout

**Task**
Fix `UESetProject` rejecting existing drive-relative paths produced by Tab completion.

**Implemented**
- `lua/ue.lua`: resolve drive-relative input through the host filesystem before project
  discovery; retain existing nested-workspace discovery and persist absolute selection.
- Validation/persistence failures report ERROR, the cause and the retained project.
- Bounded `project-selection` observation revision `completion-path-2026-09-11` records
  outcomes without private paths; probe exceptions cannot break selection.
- Eight isolated command scenarios cover native Tab for files/workspaces, absolute paths,
  drive-root rejection, missing/empty directories, persistence lock contention and probe failure.
- Spec synchronized in `multi-instance-state-isolation`; retrospective indexed through K70
  in CONSTRAINTS and lessons: [incident record](project-selection-completion-postmortem.md).

**Pitfalls / Gotchas**
- A drive-relative path must follow the OS's drive cwd; inserting a slash can select
  another object. The native resolver, not user retyping, closes the completion mismatch.
- Projects directly at a drive root remain unsupported and are rejected explicitly;
  the shared path normalizer was not changed globally.
- The retrospective retracts premature attribution, unsupported notification-display claims,
  and the assistant's premature completion after reproduction.

**Validation**
- Focused `ue_project_context`: **15/15 passed**, zero failures/skips.
- Final full `nvim --headless -l tests/run.lua` with `NVIM_TEST_REQUIRE_NATIVE=1`, after
  the drive-root rejection guard: **1629/1629 passed**, zero failures/skips, exit 0.
- Three-file AST lint, fixture StyLua check, strict OpenSpec validation and `git diff --check` passed.
- New-process resolution of the original input returns the intended F-drive workspace and `.uproject`.
- Read-only inspection of the reopened editor confirms its selection and `-Project=` use F drive.

**Follow-ups**
- No full Unreal compilation was launched. The reopened editor had no samples for the new
  probe revision; the updated command is loaded on the next editor restart.
- Independent review confirmed rejection occurs before persistence, including root-level
  project files whose dirname loses its slash. No real root-level project file was created
  for that review; this latter branch is supported by source inspection.
