# Archive note

The completed iOS build/setup/device/install slice was synced manually because this host does not provide
the `openspec` CLI. The three modified `ios-build-run-workflow` requirements were compared against the
canonical spec, and the new `ios-device-debug-workflow` contract was published under `openspec/specs/`.

The unchecked DAP implementation tasks are intentionally retained as deferred history, not reported as
completed work. Production IOS `dap_attach` / `dap_launch` remain unavailable until the canonical physical-
device protocol, breakpoint-frame, UUID, and cleanup evidence gates are satisfied. Archiving this change
therefore records the implemented fail-closed boundary and the future capability contract; it does not claim
that physical-device iOS debugging is available.

Validation at archive time: canonical/delta requirement comparison, structure regression, full headless
regression 1020/1020, bare-global lint over 140 Lua files, and `git diff --check`.
