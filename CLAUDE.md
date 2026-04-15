# Local workflow

You are working in Claude Code CLI inside a trusted local development workflow on Windows Terminal.

Default to doing the work yourself with minimal interruption.
Do not offload routine execution back to the user.
Do not stop after editing code if the next natural step is to run, verify, or inspect the result.

## Primary behavior

Prefer autonomous execution within Claude Code's permission model.

Proceed directly with routine local development work:
- read files
- search code
- inspect logs
- list directories
- edit files in the repository
- run local builds
- run local tests
- run formatters and linters
- create temporary helper files inside the repository
- repeat commands as needed to diagnose and verify issues

## Do not hand routine execution back to the user

Avoid responses like:
- "Please run this"
- "Try this command"
- "Can you execute this and send me the output"
- "Run the build and let me know"
- "Test this locally and report back"

Instead:
- run the command yourself when possible
- inspect the output yourself
- iterate yourself
- report back only after a meaningful chunk of work is complete

Only ask the user to run something if Claude Code is blocked by permissions, missing tools, missing credentials, unavailable hardware, or inaccessible external systems.

## Minimize interruptions

Do not ask for confirmation during normal local development unless:
- Claude Code permission enforcement explicitly requires approval
- the action is destructive
- the action is materially risky
- the action leaves the repository boundary
- the action affects accounts, credentials, production systems, or secrets

## Command style

Prefer direct commands.

Important rules:
- do not use compound commands like `cd ... && git status`
- do not chain commands with `&&`, `;`, or shell wrappers unless absolutely necessary
- do not wrap commands in `bash -lc`, `sh -c`, or similar unless there is no practical alternative
- assume the current working directory is already correct
- prefer one direct command at a time
- prefer several direct commands over one compound command

## Git policy

Treat normal read-only git inspection as routine.

Run directly when useful:
- `git status`
- `git diff`
- `git log`
- `git show`
- `git blame`

Avoid compound git commands.
Do not stop to ask before ordinary read-only git inspection if permissions allow it.

Ask before:
- `git commit`
- `git push`
- `git rebase`
- `git reset`
- `git clean`
- history rewriting
- destructive checkout / restore actions

## ADB policy

ADB is part of the normal local workflow.

Prefer direct single adb commands such as:
- `adb devices`
- `adb shell getprop`
- `adb logcat`
- `adb shell`
- `adb push`
- `adb pull`
- `adb install`
- `adb shell am start ...`

Do not combine adb with unrelated commands in one compound shell command unless absolutely necessary.

## Build and verification policy

After making changes, verify them yourself whenever possible.

Preferred loop:
1. inspect
2. edit
3. run
4. verify
5. iterate
6. then report

Do not stop after step 2 if steps 3 to 5 are available.

## Reporting

Do not narrate every tiny step.
Work through a meaningful batch, then report:
1. what you investigated
2. what you changed
3. what you ran
4. what happened
5. what remains blocked or risky

Always include verification status when relevant.

## User handoff minimization

The user should not be used as a substitute shell operator for routine local development steps.

If you can run it, run it.
If you can test it, test it.
If you can inspect it, inspect it.
If you can iterate once more yourself, do that before replying.