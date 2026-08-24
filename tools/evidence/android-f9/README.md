# Android F9 breakpoint — smoke evidence

Result JSON captured by `tools/nvim_android_dap_smoketest.lua` while proving the
attach-before F9 path on device `ANDROID-SERIAL-B` / `<android-package>`.
Moved here from `tools/` to keep the tool dir clean; the trail is referenced by
`openspec/changes/fix-android-f9-breakpoint-hit/code-behavior-audit.md`.

| File | What it proves |
|------|----------------|
| `nvim_android_dap_smoketest.1367.matching-symbol.result.json` | 3.5 matching symbols: `resolved=1`, `reason="breakpoint"`, `hitBreakpointIds=[1,2]`, frame0 → local `MobileShadingRenderer.cpp:1367`. The success baseline. |
| `nvim_android_dap_smoketest.1367.warning-gate.result.json` | Same hit + no false active-session warning, clean cleanup (`TracerPid=0`). |
| `nvim_android_dap_smoketest.1367.result.json` | Earlier 1367 run (pre-matching-symbol). |
| `nvim_android_dap_smoketest.1369.result.json` | 1369 source/symbol revision-mismatch lead. |
| `nvim_android_dap_smoketest.1369.latest2.result.json` | Repeat 1369 capture. |
| `baseline-preseed.result.json` | attach-time preseed baseline (paths/serial/symbol-lib reference). |
| `livebp-gate.evaluate.result.json` | **D1 gate, channel B (evaluate `breakpoint set -f/-l`)**: live plant after continue, NOT preseeded — `resolved_after_plant=1`, `saw_breakpoint`, `stop.reason="breakpoint"`, `adapter_alive`. Proves session-time live planting is feasible on this route. |
| `livebp-gate.setbreakpoints.result.json` | **D1 gate, channel A (DAP setBreakpoints)**: same live hit via nvim-dap native channel. |
| `livebp-e2e.result.json` | **Production path (tasks 4.5)**: drives the real F9 flow so `dap.listeners.after.setBreakpoints["ue_android_bp_local_response"]` → `ue_android_live_plant_via_evaluate` fires. `production_live_plant_diag=true`, `saw_reattach_warning=false`, `resolved=1`, breakpoint hits. Proves the WIRED live path (not just the gate's own channel code). |

Gate evidence (D1 conclusion): both channels A and B hit → **live is feasible** on
K30 platform route + 3.5 matching symbols. `361b9e7`'s "memory write silently
dropped" does NOT reproduce here (that was the old gdb-remote direct route).
Channel B (evaluate) is the production channel (design D2). Regenerate via
`tools/nvim_android_dap_livebp_gate.lua` (`NVIM_DAP_LIVEBP_CHANNEL=evaluate|setbreakpoints`)
or `tools/nvim_android_dap_livebp_e2e.lua` (production path).

Valid F9 proof = LLDB `breakpoint list resolved>0` + DAP `stopped reason="breakpoint"`
+ frame0 maps to local source + clean detach. Never app business output.

To regenerate, set `NVIM_DAP_SMOKE_RESULT` to a path under this dir — see the
"Run latest smoke" block in the change handoff.
