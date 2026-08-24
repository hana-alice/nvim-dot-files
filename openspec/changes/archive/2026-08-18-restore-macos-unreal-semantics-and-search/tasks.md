# Tasks — restore-macos-unreal-semantics-and-search

## Semantics and controlled CDB

- [x] Make native clangd cmd resolution project/root aware and preserve resolved argv.
- [x] Normalize command-only CDB entries into host-correct arguments.
- [x] Bound stalled semantic sidecar requests and recover the process lifecycle.
- [x] Add Apple no-rsp super-unity proof and exact fallback coverage.

## csearch/cindex

- [x] Add a POSIX installer for pinned csearch and the repository cindex fork.
- [x] Unify PATH/GOBIN/GOPATH/host Go bin discovery and missing-tool guidance.
- [x] Keep index availability probes read-only.
- [x] Fix native exact-path incremental merge and add real Go/Lua integration tests.

## Verification and documentation

- [x] Run targeted Lua regressions, Go tests, Python compile checks and shell syntax checks.
- [x] Build and query a real macOS csearch index and validate an Apple no-rsp CDB on isolated output.
- [x] Run the complete headless regression suite and privacy/secret scans.
- [x] Sync all capability deltas into main specs.
- [x] Archive the completed change without merging it into the unrelated active iOS DAP change.
