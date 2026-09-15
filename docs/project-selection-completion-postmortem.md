# Project selection completion incident — 2026-09-11

## Verified failure chain

The native input used by `UESetProject` is `vim.fn.input(prompt, default, "file")`.
An independent `nvim --clean --headless` experiment fed real `<Tab><CR>` keys into
that input. Completion returned a drive-relative directory, `isdirectory` returned
1, and the old `resolve_project_input` guard rejected it. The running editor's
selection and generated `-Project=` argument still pointed at the previous checkout.
The old command emitted WARN and returned without changing selection.

Private checkout names are deliberately omitted. In generic notation, the observed
chain was `F:workspace\checkout<Tab>` -> an existing drive-relative directory ->
rejected selection -> the previous E-drive project remained active. These are
illustrative replacements for private paths, not literal fixture inputs.

The tests now reproduce this with temporary directories, real file completion,
spaces, and a non-root drive cwd. A `C:../new project/...` path must resolve relative
to that drive's cwd: inserting `C:/` would select a different object. Additional
experiments showed `fnamemodify(path, ':p')` is unreliable for bare drive/prefix
inputs, while `vim.uv.fs_realpath` resolves the existing object. Therefore the fix
uses filesystem resolution, not string repair.

## Assistant failures and corrections

1. **Premature attribution:** the initial explanation stopped at the missing
   separator in command history. That did not establish how the string was produced.
   The user's Tab evidence required reopening the input/completion part of the chain.
2. **Unverified display claim:** source code proved a WARN call, but no captured UI
   evidence established whether that notification was visible. Claims about absent
   or inconspicuous display were withdrawn; that historical display remains unknown.
3. **Premature completion:** after reproducing completion, the assistant ended the
   turn without fixing the defect, adding regression coverage, synchronizing spec,
   recording feedback, or writing this postmortem. The user had to reopen the work.
4. **Correction discipline:** future handling must trace input production -> validation
   -> persisted/live selection -> consumer arguments. Reproduction is diagnostic
   evidence, not completion. The repository Definition of Done applies before delivery.

This is an incident record, not a new agent-rule entrypoint. Existing root AGENTS.md
remains the authority for evidence, user corrections, and completion requirements.

## Repair and observation

- `lua/ue.lua`: resolve existing drive-relative input using the OS before discovery;
  retain existing project discovery; make validation/persistence failures ERROR with
  the retained project explicitly shown.
- No new search mechanism, dependencies, global path override, or guessed drive root.
- Independent review found that the shared normalizer strips the separator from an
  absolute drive root. The final resolver classifies the original input first and
  restores the root separator after normalization. A real drive-root regression
  ensures it cannot select a project placed in the drive's current directory.
- Shared state consumers still strip drive-root separators. Rather than changing the
  widely shared path helper in this repair, selecting a project directly at a drive root
  is explicitly rejected with ERROR. Ordinary checkout subdirectories are supported;
  no claim of drive-root project support is made. This boundary is recorded in spec.
- Review also corrected the success probe from `ok` to `resolved`, the outcome
  recognized by the existing aggregate counters; tests check its recorded outcome.
- `project-selection` probe revision `completion-path-2026-09-11`: bounded observation,
  success/failure outcome keys, no private paths, all probe calls protected by `pcall`.
- `tests/fixtures/project_selection.lua`: isolated native input -> command -> selection
  -> context -> build arguments; no compiler invocation and no user project-state writes.
- Contract: `openspec/specs/multi-instance-state-isolation/spec.md`, project input
  completion and selection requirement.

## Prior feedback disposition

The session read the real probe report before implementation. The existing scan-root,
foreign-buffer, dirty-set, csearch reset and semantic-navigation/performance records
were not used as proof of this input failure. They concern separate indexing/navigation
work and are deferred for their owners; this targeted repair does not resolve them or
erase their history. Semantic records already carrying deferred dispositions remain so.
The new project-selection observation is separate from those historical topics.

## Validation

- Before repair, real Tab file/workspace tests retained the old project and failed.
- Final focused `nvim --headless -l tests/run.lua ue_project_context`: **15/15 passed**,
  zero failures/skips, including eight isolated scenarios. Disk selector readback,
  a real writer-lock conflict, probe exceptions and success aggregates are covered.
- First broader regression: **1626/1626 passed**, zero failures/skips.
- Final full `nvim --headless -l tests/run.lua` with `NVIM_TEST_REQUIRE_NATIVE=1`:
  **1629/1629 passed**, zero failures/skips, exit 0, after the final drive-root guard.
  Local output was captured as `nvim-project-selection-acceptance.log` in the host temp directory.
- Strict OpenSpec validation passed. AST bare-global lint passed for the three Lua files.
- The new standalone fixture passed StyLua check; `git diff --check` passed.
- A clean process loaded the final resolver and resolved the original drive-relative
  F-drive input to the intended existing workspace and nested project file.
- Read-only inspection of a newly opened real Neovim confirmed its selected project
  and generated `-Project=` both used the intended F-drive checkout. It had no samples
  for the new probe revision. A read-only inspection of the loaded command confirmed
  the new error text is absent from that process: it still has the previous command
  implementation in memory. The repaired implementation loads on its next normal restart.
- No full Unreal compilation or historical notification rendering has been verified.
