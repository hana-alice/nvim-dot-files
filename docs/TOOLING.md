# Tooling Requirements

External binaries and version constraints for this Neovim configuration.

This file is **English-only** (this repo is mirrored to a public GitHub
remote). Keep notes here factual and reproducible.

> **Status (2026-05-13): the `lldb-dap 21.1.8 side-load` route below is
> superseded.** The active Android / Win64 DAP adapter is **codelldb
> 1.12.2** (see *Active adapter (codelldb 1.12.2)* at the bottom of this
> file). The 21.1.8 section is retained verbatim because the
> `STATUS_STACK_BUFFER_OVERRUN` analysis is still useful reference for
> anyone who later tries to revisit a stock LLVM-shipped `lldb-dap.exe`
> on Windows.

## clangd / clang (C++ LSP + indexer)

- **Required**: LLVM **22.1.x** (22.1.5 verified)
- **Source**: `winget install LLVM.LLVM`
- **Install path** (Windows): `C:\Program Files\LLVM\bin\`
- Used by: clangd LSP, custom `clangd-indexer` super-unity pipeline.

Do **not** downgrade clang/clangd to 21.x — the super-unity CDB pipeline
and `.idx` format depend on 22.x behavior.

## lldb-dap (DAP debugger adapter, Windows)

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

## Active adapter (codelldb 1.12.2)

> Added 2026-05-13. This is the route the editor actually uses today —
> the 21.1.8 section above is kept as historical reference.

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

## Android lldb-server (current)

- **Required**: NDK **27** `lldb-server` for `aarch64-android` (LLDB 18)
- **Install path glob**: `%LOCALAPPDATA%\Android\Sdk\ndk\27.*\toolchains\llvm\prebuilt\windows-x86_64\lib\clang\18\lib\linux\aarch64\lldb-server`
- Pushed to device by `lua/ue/dap/android.lua`:
  - host:                                  `<NDK>/.../lldb-server`
  - device staging:                        `/data/local/tmp/lldb-server-ndk27`
  - app sandbox (via `run-as`):            `/data/data/<pkg>/lldb-server-ndk27`
- Command on device: `lldb-server-ndk27 gdbserver --attach <pid> 127.0.0.1:<port>`

Why **NDK 27**, not NDK 21 (the version that built libUE4.so):

- `gdbserver --attach` does NOT use the `qLaunchGDBServer` handshake;
  the LLDB-version-mismatch deadlock that motivated NDK-21-pinning in
  the old lldb-dap+platform-mode route does not apply here.
- NDK 21's lldb-server is too old to attach reliably under Android 12+.
- Cross-major gdb-remote (host LLDB 22 ↔ device LLDB 18) is empirically
  stable; verified against UE 5.x `libUnreal.so`.

The platform driver's `default_lldb_server_paths()` glob list still
contains NDK 21 entries — those are for the *retired* lldb-dap route
and are kept for backwards compatibility. `ue.dap.android` resolves
**all** matches and picks the highest NDK version.

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
