# Tooling Requirements

External binaries and version constraints for this Neovim configuration.

> **Regression tests:** run `nvim --headless -l tests/run.lua` (or
> `pwsh -File scripts/run_regression.ps1` on Windows) after any change.
> Full guide: [`testing-regression.md`](testing-regression.md).

This file is **English-only** (this repo is mirrored to a public GitHub
remote). Keep notes here factual and reproducible.

## Current Android DAP status

As of 2026-09-03, the active Android route in `lua/ue/dap/android.lua` is:

```text
nvim-dap
  -> LLVM 22.1.6+ lldb-dap.exe
    -> run-as <pkg> /data/data/<pkg>/lldb-server platform --server --listen "*:<port>"
      -> platform connect connect://[<adb-serial>]:<port>
      -> process attach --pid <pid>
```

Hard constraints:

- Use serial-form `platform connect connect://[<serial>]:<port>`.
- Do not use `platform connect connect://localhost:<port>` or
  `connect://127.0.0.1:<port>` for Android.
- Do not use `lldb-server gdbserver --attach <pid>` as the production route.
- Run the platform server **as the app uid** via `run-as <pkg>`, from the app
  sandbox copy `/data/data/<pkg>/lldb-server`. Stage it in two hops:
  `adb push` to `/data/local/tmp/lldb-server` (transport only), then
  `run-as <pkg> sh -c 'cat <public> > <sandbox> && chmod 700 <sandbox>'`.
  A shell-uid server cannot ptrace the app on this `user` build and its forked
  gdbserver SIGSEGVs inside `vAttach`, surfacing only as
  `error: attach failed: lost connection` (docs/CONSTRAINTS.md K56).
- Quote the listen wildcard as `--listen "*:<port>"` so the device shell cannot
  glob it against the sandbox directory contents.
- Prefer the NDK 27 LLDB 18.x `lldb-server` for the platform server path, as
  ordered by `lua/utils/platform/windows.lua`. Do **not** downgrade the device
  server to "fix" a `lost connection` attach — LLDB 9 / 14 / 18 all fail
  identically under the shell uid, and all work under the app uid (K56).

## Diagnosing a failed attach: start with the layer, not the symptom

Run **`:UEDAPPreflight`** first. It needs no live session (unlike `:UEDAPDiag`,
which is post-mortem) and reports a per-layer verdict L0→L4 with the exact
command and exit code behind each one:

| Layer | Question | Owner |
|---|---|---|
| L0 host toolchain | does the adapter resolve, is it ≥ 22.1.6, is the python package present? | `lua/utils/platform/*` |
| L1 transport | is the device reachable, is a serial captured, can we forward? | `lua/utils/android_device.lua` |
| L2 target OS policy | can the identity that must run the server execute it and ptrace the target? | `lua/ue/dap/android.lua` |
| L3 debug engine | platform connect / process attach / command sequence | `lua/ue/dap/_common.lua` + lldb |
| L4 symbol/semantic | slide resolved, breakpoints resolved, symbols match the build | `lua/ue/dap/android.lua` |

**L2 is the only layer whose red light used to surface as an L3 symptom.**
`attach failed: lost connection` (K56), `The parameter is incorrect` and
`Connection shut down ... initial handshake packet` (K58) all pointed at nothing.
Attach now refuses at L2 *before* connecting the engine, and reports the denying
command. Override with `UE_DAP_SKIP_PREFLIGHT=1` (the skip is recorded in any
subsequent failure so later forensics is not misled).

`:UEDAPSmoke` runs the same gate on demand and writes redacted evidence to
`tools/evidence/android-dap/`. With no device it reports `not_applicable`, never
`pass`. Authority: `openspec/specs/dap-failure-layering/spec.md`;
`docs/CONSTRAINTS.md` §三 C10.

Android F9 breakpoint success requires evidence from the debugger, not just UI:

- DAP `setBreakpoints` response must reflect the real state.
- `breakpoint list` must show the target location as `resolved>0`.
- The adapter must stay alive, with no `3221226505`.
- The inferior must emit a breakpoint stop event.
- The selected frame must map back to the expected local source line.

Attach-time breakpoint preseed is owned by `lua/ue/dap/android.lua`. Generic
host-side DAP glue in `lua/ue/dap.lua` must not inject Android attachCommands.
Session-time F9 changes (after `configurationDone`) are planted **live** through
the lldb-dap evaluate backtick `breakpoint set -f/-l` channel
(`ue_android_live_plant_via_evaluate` in `lua/ue/dap.lua`); they resolve and hit
without a reattach (verified on device `ANDROID-SERIAL-B`, 2026-06-15 — see
`docs/CONSTRAINTS.md` K36 and `tools/evidence/android-f9/livebp-*.json`). The
live plant reads back `breakpoint list resolved=N` and surfaces an honest
warning on `resolved=0`; it MUST NOT fake success and MUST NOT silent
detach+reattach. The explicit `target modules load --slide` ASLR rebase remains
load-bearing on this device (K37); `UE_DAP_NO_SLIDE=1` skips it for re-verification.

> **Two historical sections follow later in this file** — `## Historical lldb-dap
> 21 side-load` and `## Historical adapter route (codelldb 1.12.2)`. They are
> retained only because their crash analyses remain useful reference; nothing in
> them is an install requirement, and neither may be used to justify downgrading
> the host adapter. **One exception:** inside the 21 section,
> `### Known limitation: no Python bindings` is **still live** — re-measured
> 2026-09-03 on the 22.1.6 pin, `import lldb` still fails there. Every other
> section below (`## clangd`, `## adb`,
> `## Neovim`, `## Android lldb-server (platform route)`, `## Pitfalls`, …) is
> **live**. For current Android behavior follow **Current Android DAP status**
> above and the source in `lua/ue/dap/android.lua`.

## clangd / clang / libclang (C++ LSP + semantic sidecar)

- **Required**: LLVM **22.1.x** (22.1.5 verified)
- **Source** (Windows): `winget install LLVM.LLVM`
- **Source** (macOS): `brew install llvm@22`; if the Homebrew bottle registry is
  unavailable, install the official macOS ARM64 release under
  `~/.local/opt/llvm@22`.
- **Install path** (Windows): `C:\Program Files\LLVM\bin\`
- Used by: clangd controlled BackgroundIndex, exact-command transport, libclang
  canonical-USR sidecar, and the on-demand cursor-walk C ABI shim.

Do **not** downgrade clang/clangd/libclang to 21.x — controlled BackgroundIndex,
the official `compilationDatabaseChanges` transport, and the libclang/shim ABI
are verified as one LLVM 22.x toolchain identity.

On macOS, the Xcode-provided Apple clangd is not a substitute for the pinned
LLVM build. The IOS-target `:UEPrepare` branch on macOS checks `clangd --version`
before generating Apple semantic evidence and accepts only 22.1.x; Tree-sitter
highlighting remains available when that compiler-semantic gate is not met.
Nvim checks the user-local versioned
install first, then the Apple Silicon and Intel Homebrew `llvm@22` kegs.

## macOS host and iOS application workflow

The macOS host driver uses only native engine and Xcode entry points:

- `<engine>/Engine/Build/BatchFiles/Mac/Build.sh` for UBT target builds; the
  Nvim-owned zsh wrapper only adds a fail-closed AOT fingerprint cache and the
  stable daily no-dSYM override before invoking this native entry.
- `<engine>/Engine/Build/BatchFiles/RunUAT.sh BuildCookRun` for local iOS
  `-skipbuild -skipcook -stage -nocleanstage -package`; cooked data must already
  exist and Nvim never starts a local Cook.
- `xcrun dsymutil --linker parallel --verify-dwarf=output` plus
  `xcrun dwarfdump --uuid` for explicit `:UEIOSSymbols`; daily builds do not
  create or ZIP dSYM bundles. The parallel/output-verification pair prevents a
  >4 GiB monolithic UE `.debug_info` overflow from passing on UUID alone.
- `/usr/bin/xcrun devicectl` with `--json-output <file>` for physical-device
  discovery, `.app` install and process launch.
- `/usr/bin/security` for a read-only code-sign identity gate and
  `:UESetIOSSigningCertificate[!] [exact-name-or-SHA1]`; the selected identity
  is project-scoped and injected through an argv-only Engine ini override.
  With no argument, a valid `Saved/IOSQADebug/signing.json` produced by
  `PrepareIOSQADebug.sh` wins over the picker so UE build/package and the later
  re-sign/install step cannot silently choose different certificates.
  `/usr/bin/plutil` remains the `CFBundleIdentifier` extractor.
- `python3 tools/ios_dap_protocol_probe.py preflight` for a redacted Apple
  LLDB/CoreDevice gate. An explicit `legacy-preflight --device ... --symbols ...`
  additionally checks a pre-iOS17 MobileDevice/`ios-deploy` candidate and exact
  ProductType/OS/build DeviceSupport layout without persisting the device id or
  personal path. The production `:UEDAPAttach` / `:UEDAPLaunch` handler freezes
  the selected backend: iOS 17+ `coredevice` sessions use structured `devicectl`
  JSON plus `target create` → `device select` → `device process attach -p`;
  pre-iOS17 `legacy-mobiledevice` sessions retain the validated USB bridge.

Requirements:

- Full Xcode selected by `xcode-select`, with an iPhoneOS SDK visible through
  `xcrun --sdk iphoneos --show-sdk-path`.
- Versioned LLVM 22 from `brew install llvm@22` and GNU Global from
  `brew install global`; the IOS `:UEPrepare` prelude needs clangd 22.1.x and
  its final index phase needs `gtags`.
- The engine-bundled .NET environment used by `Build.sh` and `RunUAT.sh`.
- A project identity selected with `:UESetIOSSigningCertificate`, still valid
  in the current keychain, plus compatible provisioning for package/install.
- A paired, connected physical iOS device for install/launch.
- `idevice_id`, `ios-deploy`, `ideviceinfo`, and `ideviceinstaller` on PATH; legacy launch follows the explicitly selected USB/Wi-Fi transport, while DAP remains USB-scoped.

The installable app produced by this engine lives at
`<project>/Binaries/IOS/Payload/<Target>.app`. The similarly named
`Saved/StagedBuilds/IOS` tree is raw stage input, not the signed app bundle.
The normal build/install/launch workflow still does not use UE's legacy
fastlane/instruments deploy route. Legacy launch uses `ios-deploy --noinstall
--justlaunch` against the prepared signed app on the explicitly selected transport, then verifies the installed bundle PID.
iOS DAP is a separate production operation:
on iOS 17+, `devicectl` queries the exact installed app/process identity and
debug-launches with `--terminate-existing --start-stopped`; selected Xcode
`lldb-dap` then attaches to that frozen CoreDevice PID. The host Mach-O and dSYM
must have equal UUIDs, the dSYM must pass `dwarfdump --verify --quiet`, and the
loaded executable UUID must emit the post-run OK marker before first continue. Ordinary attach preserves and
revalidates the existing process; debug-launch terminates only its captured PID. On pre-iOS17 devices,
`ios-deploy --nolldb` exposes the validated DeveloperDiskImage/debugserver
loopback bridge. Neither backend falls back to Mac process attach or to the other
iOS backend after a session starts.

## Historical lldb-dap 21 side-load (DAP debugger adapter, Windows)

> **Historical / retired.** The pinned host adapter is LLVM **22.1.6+**
> (CONSTRAINTS C1, `default_lldb_dap_paths()` is forward-only). The
> "**Required**: LLVM 21.1.8 — NOT 22.x" line below was true in 2026-05 and is
> **no longer a requirement**; it is kept only to record why the side-load
> existed. Do not use this section to justify downgrading the host adapter.

- Historically required: LLVM **21.1.8** (at the time, **not** 22.x)
- Historical install path: `C:\tools\lldb-21\bin\` (private side-load, not on PATH)

### Why 21.1.8 specifically

LLVM **22.0.0 through 22.1.5** ship a `lldb-dap.exe` that crashes on
startup on Windows with `STATUS_STACK_BUFFER_OVERRUN` (`0xC0000409`)
the moment a DAP client sends `initialize`.

Root cause: `liblldb.dll` `NativeFile` ctor calls `_get_osfhandle(fd)`
on a pipe FD whose CRT table lives in `lldb-dap.exe`'s CRT, not
`liblldb.dll`'s CRT — invalid parameter handler fires `__report_gsfailure`.

References:
- Issue: https://github.com/llvm/llvm-project/issues/178155
- Fix:   https://github.com/llvm/llvm-project/pull/195855 (merged into
  `main` 2026-05-05, **NOT backported** to `release/22.x`; 22.1.5 still
  crashes; next 22.x patch ETA ~2 weeks per cadence)

LLVM **21.1.8**'s `lldb/source/Host/common/File.cpp` predates the
offending change entirely — no `_get_osfhandle` call in the ctor, no
crash. Side-loading 21.1.8's `lldb-dap.exe` + `liblldb.dll` works
without disturbing the 22.1.5 toolchain.

### Required files in `C:\tools\lldb-21\bin\`

| File             | Source                                       | Notes                              |
| ---------------- | -------------------------------------------- | ---------------------------------- |
| `lldb-dap.exe`   | `LLVM-21.1.8-win64.exe` → `bin\lldb-dap.exe` | ~1.4 MB                            |
| `liblldb.dll`    | `LLVM-21.1.8-win64.exe` → `bin\liblldb.dll`  | ~104 MB; links `python310.dll`     |
| `python310.dll`  | `python-3.10.11-embed-amd64.zip`             | required by liblldb at load time   |
| `python310.zip`  | `python-3.10.11-embed-amd64.zip`             | optional; suppresses some warnings |

Download sources:
- https://github.com/llvm/llvm-project/releases/download/llvmorg-21.1.8/LLVM-21.1.8-win64.exe
- https://www.python.org/ftp/python/3.10.11/python-3.10.11-embed-amd64.zip

Extract `lldb-dap.exe` and `liblldb.dll` from the LLVM installer using
7-Zip (`7z x LLVM-21.1.8-win64.exe -o<dir> "bin/lldb-dap.exe" "bin/liblldb.dll"`).

### Known limitation: no Python bindings (⚠️ STILL LIVE on the 22.1.6 pin)

> This subsection sits inside the historical 21 section for provenance, but its
> conclusion is **current** — re-measured 2026-09-03 against the pinned 22.1.6
> adapter. See the two measured blockquotes at the end.

LLVM 21.1.8 ships a **nopython** build of `liblldb`. `import lldb` from
inside lldb scripts will fail with `ModuleNotFoundError: No module named
'lldb'`. Effects:

- ✅ Attach / launch / breakpoints / step / variables / memory: **work**.
- ❌ `UE4DataFormatters_2ByteChars.py` (UE FString / TArray / TMap
  pretty-printers): import fails harmlessly. UE strings will display as
  raw `TCHAR*` arrays instead of decoded text.

If pretty-printers are needed urgently, the only options at the time were
(a) wait for 22.1.6+ with the backported fix, or (b) build LLVM 22 main HEAD
locally (~1.5h compile).

> **Still applies on the current pin — measured 2026-09-03, not inferred.**
> Option (a) did *not* resolve it. Driven against the pinned adapter
> `C:/tools/lldb-22/install/bin/lldb-dap.exe` (`lldb version 22.1.6`, rev
> `fc4aad7b`) over a real DAP `launch` + `initCommands`:
>
> - `command script import` on a .py file that does `import lldb` →
>   `error: module importing failed: … ModuleNotFoundError: No module named
>   'lldb'`. **Non-fatal** — the attach continues and the process still stops.
>   This is exactly the 21.1.8 symptom, so `UE4DataFormatters_2ByteChars.py`
>   still does not load, and the native `type summary` fallback in
>   `lua/ue/dap/android.lua` is still load-bearing.
> - Nuance, for the record: this build is **not** a `nopython` liblldb —
>   `liblldb.dll` does import `python311.dll`, and that DLL is resolvable on
>   PATH. What is missing is the `lldb` **python package**: the install tree
>   contains only `bin/`, no `lib/site-packages/lldb`, which is precisely what
>   `lldb_python_relative_paths()` probes for. So "python-linked" ≠ "`import
>   lldb` works"; the fallback gate keys on the package, correctly.

> **⚠️ Do not put a bare `script …` command in `initCommands` / `attachCommands`
> on this pin — it hard-crashes the adapter.** Measured 2026-09-03: any bare
> `script` command (`script 1`, `script print(1)`, `script import lldb`) kills
> `lldb-dap.exe` with `0xC0000409` (STATUS_STACK_BUFFER_OVERRUN / fail-fast) and
> the `launch` request never gets a response — the session just dies silently.
> Controls that all survive on the same build: `version`, `expression 1+1`,
> `settings show target.language`, and `command script import <path>` (both for a
> missing path and for a real file). So the crash is specific to the `script`
> command's embedded-interpreter entry, not to python usage in general.
> The Android route is unaffected (it emits `command script import`, never bare
> `script`); `lua/ue/dap/ios.lua` does emit bare `script` commands, but that
> route runs against a macOS lldb, not this Windows pin. **Untested there —
> 待验证.**

### Adapter wiring (historical, retired)

> **Retired.** `lua/utils/platform/windows.lua` `default_lldb_dap_paths()` is
> now forward-only and lists `C:/tools/lldb-22/install/bin/lldb-dap.exe` first;
> it deliberately never falls back to `C:/tools/lldb-21` (CONSTRAINTS C1). The
> notes below describe the retired 21.1.8 side-load, not current resolution.

- Adapter type is **stdio** (`type='executable'`), wired in
  `lua/ue/dap/_common.lua` `ensure_adapter()`. This part is still current.
- We previously used `type='server'` + `--connection listen://` as a
  TCP workaround for the 22.x crash. That workaround is retired; stdio is
  the default.

## adb

- **Required**: any recent Android Platform-Tools (35.x+ verified)
- **Install path**: `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`

## Neovim

- **Required**: 0.10+ (uses `vim.uv`, `vim.system`, `vim.api.nvim__redraw`)
- **Install path**: `C:\Program Files\Neovim\bin\nvim.exe`

---

## Historical adapter route (codelldb 1.12.2)

> **Historical / retired 2026-05-21.** codelldb was fully removed from the code
> (`lua/ue/dap/_common.lua` no longer has `find_codelldb`, `windows.lua` no
> longer has `default_codelldb_paths()`). Current Android DAP behavior is in
> **Current Android DAP status** at the top of this file. Nothing in this
> section is an install requirement any more; the `ue.config` key
> `dap.codelldb_path` and the file list below are dead references kept for
> archaeology.

### Why codelldb (and not stock lldb-dap)

On Windows host + Android `lldb-server` (gdb-remote target), every stock
`lldb-dap.exe` we tested in the LLVM 21.x / 22.0–22.1 line crashed on the
first `setBreakpoints` request:

- LLVM 22.0–22.1.5: `STATUS_STACK_BUFFER_OVERRUN` in `NativeFile` ctor
  on pipe FD (LLVM #178155, fix #195855 not yet backported)
- LLVM 21.x: distinct cross-CRT abort on the gdb-remote path
  (LLVM #102254 / #138096) before any breakpoint resolves

`codelldb` from `vadimcn/codelldb` ships its **own** patched
`liblldb.dll` (`22.1.4-codelldb`) inside the VSIX, so it is not affected
by either bug. It is statically linked against its own python and does
**not** require `python310.dll` on PATH, so the `lldb-21 + python310.dll`
side-load described above is also retired.

### Required files

| Path                                                         | Source                                                 |
| ------------------------------------------------------------ | ------------------------------------------------------ |
| `C:\tools\codelldb\extension\adapter\codelldb.exe`           | `codelldb-x86_64-windows.vsix` — unpack with 7-Zip     |
| `C:\tools\codelldb\extension\lldb\bin\liblldb.dll`           | same VSIX (loaded by `codelldb.exe`, do **not** move)  |

VSIX download:
<https://github.com/vadimcn/codelldb/releases/download/v1.12.2/codelldb-x86_64-windows.vsix>

Other accepted locations (resolved in this order by
`lua/utils/platform/windows.lua` `default_codelldb_paths()`):

1. `C:/tools/codelldb/extension/adapter/codelldb.exe` (recommended)
2. `%USERPROFILE%/.local/share/codelldb/extension/adapter/codelldb.exe`
3. `%LOCALAPPDATA%/codelldb/extension/adapter/codelldb.exe`
4. `%USERPROFILE%/.vscode/extensions/vadimcn.vscode-lldb-1.12.2/adapter/codelldb.exe`

Override via `ue.config` key `dap.codelldb_path` (absolute path).

Resolution code: `lua/ue/dap/_common.lua` `find_codelldb()`.

### Adapter wiring (historical, retired)

> This wiring is **retired**. Both the `codelldb.exe` host adapter and the
> `gdbserver --attach` device route are falsified (CONSTRAINTS P16/K31, K56).
> The live route is in **Current Android DAP status** at the top of this file.

```text
nvim-dap
  └─ codelldb.exe          (host, liblldb 22.1.4-codelldb, stdio)
       └─ gdb-remote tcp://127.0.0.1:<dynamic port>
            └─ adb forward
                 └─ run-as <pkg> lldb-server-ndk27 gdbserver --attach <pid>
                      (LLDB 18 inside the app sandbox)
```

- Adapter type was `executable` (stdio), wired in
  `lua/ue/dap/_common.lua` `ensure_adapter()`.
- Configuration `request="launch"` + `targetCreateCommands` +
  `processCreateCommands` — **NOT** `request="custom"` (codelldb 1.12.2
  rejects `custom` with "Malformed message"; see Pitfalls #1).
- `setup_dap` installs a global `dap.terminate` monkey-patch that
  rewrites terminate→`disconnect{terminateDebuggee=false}` for UE
  Android sessions (= ■ button detaches instead of killing the game).
  This part is still live and independent of the adapter choice.

## Android lldb-server (platform route)

- **Required**: NDK 27 LLDB 18.x `lldb-server` for `aarch64-android` for the
  platform server route.
- **Install path glob**:
  `%LOCALAPPDATA%\Android\Sdk\ndk\27.*\toolchains\llvm\prebuilt\*\lib\clang\*\lib\linux\aarch64\lldb-server`
- Resolution: `lua/utils/platform/windows.lua` `default_lldb_server_paths()`
  lists NDK 27 first for platform mode, then other NDK / Android Studio
  fallbacks.
- Staged by `lua/ue/dap/android.lua` in two hops: `adb push` to
  `/data/local/tmp/lldb-server` (transport only), then `run-as` `cat` +
  `chmod 700` into `/data/data/<pkg>/lldb-server`.
- Command on device (app uid, sandbox copy, quoted wildcard):
  `run-as <pkg> sh -c '/data/data/<pkg>/lldb-server platform --server --listen "*:<port>"'`.
  The shell-uid form `cd /data/local/tmp && ./lldb-server platform --server …`
  is falsified — it cannot ptrace the app and dies as
  `attach failed: lost connection` (docs/CONSTRAINTS.md K56).

Do not use `lldb-server gdbserver --attach <pid>` as the production path. That
route has separate historical notes in `docs/CONSTRAINTS.md` K31/K34 and is
retained only as diagnostic background.

### Environment requirements (Android DAP, verified on ANDROID-SERIAL-A)

| Component        | Required                                                        |
| ---------------- | --------------------------------------------------------------- |
| Host adapter     | LLVM 22.1.6+ `lldb-dap.exe` (forward-only)                      |
| Device server    | **NDK 27 LLDB 18.x** `lldb-server` platform server (arm64)      |
| Device           | arm64-v8a, app **DEBUGGABLE**, `run-as <pkg>` usable            |
| Server run uid   | **app uid via `run-as`** — load-bearing, not a convenience (K56) |
| Host symbol .so  | symbol-rich `libUE4.so` (e.g. `.../<Target>_Symbols_v*/<Target>-arm64/libUE4.so`) |
| Validation scope | adb serial `ANDROID-SERIAL-A` only (other devices need their own proof) |

`run-as` is required for two distinct things: staging the sandbox copy, **and**
running the platform server itself. `DEBUGGABLE` alone does not let the shell uid
ptrace the app on a `ro.debuggable=0` build (K56).


## Pitfalls (hard-won)

Things that cost real time. Each line maps to a permanent constraint in
`lua/ue/dap/`. Item 1 belongs to the retired codelldb route; the rest apply to
the current lldb-dap route.

1. *(retired route only)* **`request="custom"` ⇒ codelldb returned
   `Malformed message`.** The current lldb-dap Android config is
   `request="attach"` + `stopOnEntry=true` + `initCommands` /
   `attachCommands` / `postRunCommands`; the `request="launch"` +
   `targetCreateCommands` / `processCreateCommands` shape was codelldb-only.
   See `lldb_dap_attach_config` in `lua/ue/dap/android.lua`.
2. **No automatic module rebase on a remote attach.** You must explicitly emit
   `target modules load --file libUE4.so --slide 0x<base>` for every `.so` you
   want resolvable, and it must run **before** breakpoints are set. `<base>`
   comes from `/proc/<pid>/maps` on the device. On the current route this is
   emitted inside `attachCommands` (see `attach_commands` in
   `lua/ue/dap/android.lua`); breakpoint commands are inserted after it.
   Constraint: `docs/CONSTRAINTS.md` K37.
3. **`process handle SIGSEGV/SIGBUS -p true -s false`** is mandatory.
   UE's `Signal Catcher` thread and Chrome IO threads tickle these
   constantly; without `-s false` every kick freezes the whole app.
4. **`string.format("%x", 0x7594c2a000)` truncates to 32 bits under
   LuaJIT.** Build module-slide hex strings via concatenation, never
   `string.format`.
5. **Don't use `dap.terminate` directly for Android sessions.** The
   default terminate sends `disconnect{terminateDebuggee=true}` which
   SIGKILLs the game on the device. We monkey-patch `dap.terminate` in
   `setup_dap` to route UE Android sessions through
   `disconnect{terminateDebuggee=false}` instead.
6. **dap-repl is a `prompt` buffer.** F-keys MUST be bound in `n`, `i`,
   `t`, and `v` modes — pure normal-mode bindings produce literal
   `<F5>` characters in insert mode. See `lua/config/keymaps.lua`
   `dap_fkeys` table.
7. **Neovide 0.16+ binds F11 to fullscreen by default.** If F11
   (StepIn) is swallowed, either set `vim.g.neovide_fullscreen=false`
   or rebind StepIn elsewhere.
8. **DAP attach repeat-disconnect death loop.** A listener that itself
   sends `disconnect` will re-enter cleanup endlessly. Listeners run
   cleanup state only; they never call `disconnect`/`terminate`.
9. **Windows pipe paths in `nvim --server` need forward slashes**, not
   backslashes — `//./pipe/nvim.<pid>.0`. Backslash form
   silently fails with `exit_code=2` and no output.
10. **Breakpoints are persisted per UE project** under
    `<engine_root>/.cache/nvim-ue/breakpoints/<project>.json`. F9
    routes through `ue.dap._persist_bp` which debounces saves by 250 ms
    and lazy-restores on `BufReadPost`. The module is `setup()`'d
    eagerly from `ue.lua` so persistence works even before nvim-dap is
    lazy-loaded.
