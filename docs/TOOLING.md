# Tooling Requirements

External binaries and version constraints for this Neovim configuration.

> **Regression tests:** run `nvim --headless -l tests/run.lua` (or
> `pwsh -File scripts/run_regression.ps1` on Windows) after any change.
> Full guide: [`testing-regression.md`](testing-regression.md).

This file is **English-only** (this repo is mirrored to a public GitHub
remote). Keep notes here factual and reproducible.

## Current Android DAP status

As of 2026-06-15, the active Android route in `lua/ue/dap/android.lua` is:

```text
nvim-dap
  -> LLVM 22.1.6+ lldb-dap.exe
    -> lldb-server platform --server --listen *:<port>
      -> platform connect connect://[<adb-serial>]:<port>
      -> process attach --pid <pid>
```

Hard constraints:

- Use serial-form `platform connect connect://[<serial>]:<port>`.
- Do not use `platform connect connect://localhost:<port>` or
  `connect://127.0.0.1:<port>` for Android.
- Do not use `lldb-server gdbserver --attach <pid>` as the production route.
- Stage `lldb-server` under `/data/local/tmp/lldb-server`; platform mode does
  not require the binary inside the app sandbox.
- Prefer the NDK 27 LLDB 18.x `lldb-server` for the platform server path, as
  ordered by `lua/utils/platform/windows.lua`.

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

> **Historical sections below:** the older lldb-dap 21.1.8 side-load and
> codelldb 1.12.2 notes are retained because their crash analyses remain useful
> reference. For current Android behavior, follow **Current Android DAP status**
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
  personal path. The production `:UEDAPAttach` / `:UEDAPLaunch` handler uses the
  same validated legacy route and fails closed on a different backend.

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
`ios-deploy --nolldb` exposes the pre-iOS17 Xcode DeveloperDiskImage/debugserver
loopback bridge, while Xcode `lldb-dap` owns target creation, attach/launch,
breakpoints and expression evaluation. It is never a Mac-process fallback.

## Historical lldb-dap 21 side-load (DAP debugger adapter, Windows)

- **Required**: LLVM **21.1.8** — **NOT 22.x**
- **Install path**: `C:\tools\lldb-21\bin\` (private side-load, not on PATH)

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

### Known limitation: no Python bindings

LLVM 21.1.8 ships a **nopython** build of `liblldb`. `import lldb` from
inside lldb scripts will fail with `ModuleNotFoundError: No module named
'lldb'`. Effects:

- ✅ Attach / launch / breakpoints / step / variables / memory: **work**.
- ❌ `UE4DataFormatters_2ByteChars.py` (UE FString / TArray / TMap
  pretty-printers): import fails harmlessly. UE strings will display as
  raw `TCHAR*` arrays instead of decoded text.

If pretty-printers are needed urgently, the only options are (a) wait
for 22.1.6+ with the backported fix, or (b) build LLVM 22 main HEAD
locally (~1.5h compile).

### Adapter wiring

- Resolution lives in `lua/utils/platform/windows.lua`
  `default_lldb_dap_paths()` — `C:/tools/lldb-21/bin/lldb-dap.exe` is
  the top-priority candidate.
- Adapter type is **stdio** (`type='executable'`), wired in
  `lua/ue/dap/_common.lua` `ensure_adapter()`.
- We previously used `type='server'` + `--connection listen://` as a
  TCP workaround for the 22.x crash. With the 21.1.8 side-load that
  workaround is no longer needed; stdio is the default.

## lldb-server (Android remote debugging)

- **Required**: NDK 27 ships LLDB 18.x `lldb-server` for `aarch64-android`
- **Install path**: `%LOCALAPPDATA%\Android\Sdk\ndk\27.*\toolchains\llvm\prebuilt\windows-x86_64\lib\clang\18\lib\linux\aarch64\lldb-server`
- Pushed to device under `/data/local/tmp/lldb-server` by
  `lua/ue/dap/android.lua`.

LLDB 21.1.8 client ↔ LLDB 18.x server on device: gdbremote protocol is
backward-compatible; verified working for `platform select remote-android`
+ `platform connect connect://localhost:5039` + `process attach -p <pid>`.

## adb

- **Required**: any recent Android Platform-Tools (35.x+ verified)
- **Install path**: `%LOCALAPPDATA%\Android\Sdk\platform-tools\adb.exe`

## Neovim

- **Required**: 0.10+ (uses `vim.uv`, `vim.system`, `vim.api.nvim__redraw`)
- **Install path**: `C:\Program Files\Neovim\bin\nvim.exe`

---

## Historical adapter route (codelldb 1.12.2)

> Added 2026-05-13. Retained as historical reference; current Android DAP
> behavior is documented in **Current Android DAP status**.

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

### Adapter wiring (current)

```text
nvim-dap
  └─ codelldb.exe          (host, liblldb 22.1.4-codelldb, stdio)
       └─ gdb-remote tcp://127.0.0.1:<dynamic port>
            └─ adb forward
                 └─ run-as <pkg> lldb-server-ndk27 gdbserver --attach <pid>
                      (LLDB 18 inside the app sandbox)
```

- Adapter type: `executable` (stdio), wired in
  `lua/ue/dap/_common.lua` `ensure_adapter()`.
- Configuration `request="launch"` + `targetCreateCommands` +
  `processCreateCommands` — **NOT** `request="custom"` (codelldb 1.12.2
  rejects `custom` with "Malformed message"; see Pitfalls #1).
- `setup_dap` installs a global `dap.terminate` monkey-patch that
  rewrites terminate→`disconnect{terminateDebuggee=false}` for UE
  Android sessions (= ■ button detaches instead of killing the game).

## Android lldb-server (platform route)

- **Required**: NDK 27 LLDB 18.x `lldb-server` for `aarch64-android` for the
  platform server route.
- **Install path glob**:
  `%LOCALAPPDATA%\Android\Sdk\ndk\27.*\toolchains\llvm\prebuilt\*\lib\clang\*\lib\linux\aarch64\lldb-server`
- Resolution: `lua/utils/platform/windows.lua` `default_lldb_server_paths()`
  lists NDK 27 first for platform mode, then other NDK / Android Studio
  fallbacks.
- Pushed to device by `lua/ue/dap/android.lua` as `/data/local/tmp/lldb-server`.
- Command on device:
  `cd /data/local/tmp && ./lldb-server platform --server --listen *:<port>`.

Do not use `lldb-server gdbserver --attach <pid>` as the production path. That
route has separate historical notes in `docs/CONSTRAINTS.md` K31/K34 and is
retained only as diagnostic background.

### Environment requirements (Android DAP, verified on ANDROID-SERIAL-A)

| Component        | Required                                                        |
| ---------------- | --------------------------------------------------------------- |
| Host adapter     | LLVM 22.1.6+ `lldb-dap.exe` (forward-only)                      |
| Device server    | **NDK 27 LLDB 18.x** `lldb-server` platform server (arm64)      |
| Device           | arm64-v8a, app **DEBUGGABLE**, `run-as <pkg>` usable            |
| Host symbol .so  | symbol-rich `libUE4.so` (e.g. `.../<Target>_Symbols_v*/<Target>-arm64/libUE4.so`) |
| Validation scope | adb serial `ANDROID-SERIAL-A` only (other devices need their own proof) |


## Pitfalls (codelldb route, hard-won)

Things that cost real time. Each line maps to a permanent constraint in
`lua/ue/dap/`.

1. **`request="custom"` ⇒ codelldb returns `Malformed message`.**
   Use `request="launch"` with `targetCreateCommands` +
   `processCreateCommands` arrays. See `bootstrap_session` in
   `lua/ue/dap/android.lua`.
2. **No automatic module rebase across gdb-remote.** After
   `processCreateCommands` you must explicitly emit
   `target modules load --file libUE4.so --slide 0x<base>` for every
   `.so` you want resolvable. `<base>` comes from
   `cat /proc/<pid>/maps` on the device.
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
