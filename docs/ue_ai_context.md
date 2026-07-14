# UE AI Context Export

Use the exporter when an AI agent needs the effective Unreal Engine project,
platform, configuration, target, and native commands for a checkout.

```powershell
nvim --headless -l scripts/export_ue_context.lua D:\path\to\UnrealEngine
```

The default output directory is `<engine-root>/.omx/context/`:

- `ue-nvim-context.json`: machine-readable values and argv arrays.
- `ue-nvim-context.md`: agent-readable summary and common key mappings.

An explicit output directory can be passed as the second argument:

```powershell
nvim --headless -l scripts/export_ue_context.lua D:\path\to\UnrealEngine C:\tmp\ue-context
```

## Resolution Contract

The exporter treats the supplied engine directory as authoritative and reads
`<engine-root>/.cache/nvim-ue/state.json` for the selected project. A persisted
`uproject` path is preferred because P4 workspaces can place it below
`<project-root>/Source/Client/`.

Selection precedence matches the live Neovim UE integration:

1. `UE_TARGET_PLATFORM`, `UE_TARGET_CONFIGURATION`, and `UE_BUILD_TARGET`.
2. Persisted `target_platform` and `target_configuration`.
3. Existing automatic defaults and `*.Target.cs` detection.

The generated build argv comes from the same `ue.lua` command builder used by
`:UEBuild`. The install argv uses the same newest-APK search as
`:UEInstallAndroid`.
