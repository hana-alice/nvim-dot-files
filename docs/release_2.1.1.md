# hana-alice/nvim 2.1.1 — Public history privacy repair

> Date: 2026-10-09
> Type: Patch; remove identifying remnants from public Git history.
> Tag: pending explicit authorization.

### 2026-10-09 — Remove identifying remnants from public branch histories

**Task**

Audit and sanitize workstation and project identities still searchable in the public repository.

**Implemented**

- Audit every advertised branch, tag and pull request reference, including historical deleted blobs and commit metadata.
- Replace identifying history text with neutral examples while preserving commits, merge parent order and unaffected file content.
- Replace historical private network addresses with documentation-only examples, preserving surrounding punctuation and structured text.
- Keep original recovery tips, the private matching policy and detailed diagnostics exclusively outside tracked files.
- Publish only explicit branch updates with expected-old leases; do not publish recovery refs or widen the push scope.
- Preserve unrelated local changelog entries and untracked agent configuration.

**Pitfalls / Gotchas**

- A clean current file tree does not prove that other branches or old commit objects are clean.
- Pull request references and cached commit views are managed by GitHub and require separate platform cleanup after branch rewriting.
- Existing clones must avoid merging or pushing the old history back into the repository.

**Validation**

- Full `nvim --headless -l tests/run.lua`: 2340/2340 passed, 0 failed, 38 capability skips.
- Original advertised graph: 696 commits, 3,618 trees and 4,022 blobs; no missing objects. Current feature files and its complete history already pass privacy scanning.
- Generated graph independently passes the original POSIX ERE policy and generic credential/network scanner: 655 reachable commits, 3,523 trees and 4,019 blobs, zero hits and zero missing objects.
- All 696 original commit mappings preserve ordered parents and dates; each public branch retains its commit count. Identical clean objects shared by parallel histories are reused.
- Private regex compatibility self-tests: 230 passed; documentation structure: 78/78 passed; whitespace checks passed. Final receipts remain in local Git state.
- Spec consistency: no observable editor behavior changes; this repair implements the existing `public-mirror-privacy` contract.

**Follow-ups**

- Platform-managed PR references and cached views remain external cleanup items until independently verified removed.
- Version tag requires explicit authorization.
