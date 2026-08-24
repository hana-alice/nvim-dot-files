# Archive note

The implementation and three capability deltas were complete before archival. The local environment did
not provide the `openspec` CLI, so sync/archive was performed manually using the repository's canonical
delta layout. Each archived requirement block was compared byte-for-byte with its corresponding appended
main-spec block, structure/full regressions were rerun, and the staged diff passed privacy/secret scans.

The existing `add-ios-device-debug-workflow` change remains active and untouched because its physical-device
evidence gate is unrelated to this macOS semantics/search repair.
