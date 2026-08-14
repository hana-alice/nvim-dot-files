# Neovim Core Functionality Health Audit

This audit answers a narrower question than the regression suite: whether the
current machine can execute the real startup, editing, syntax, search and
compiler-semantic capabilities declared by this configuration.

It is read-only with respect to the configuration, plugins, parsers, UE
workspace, indexes, devices and signing state. Writable probes use a unique
temporary directory and remove it before exit.

## Run it

Inside Neovim:

```vim
:NvimCoreHealth
:NvimCoreHealth! " add explicitly supplied live evidence
:NvimCoreHealth syntax
```

From a shell:

```sh
nvim --headless -l scripts/nvim_core_health.lua
nvim --headless -l scripts/nvim_core_health.lua --json
nvim --headless -l scripts/nvim_core_health.lua --filter syntax
nvim --headless -l scripts/nvim_core_health.lua --live
```

The default deterministic audit uses only fixtures and temporary files. Live
mode may read an already configured UE context and existing CDB/index
provenance, but it never builds, prepares, repairs, installs or launches
anything.

For live workspace evidence, point `NVIM_CORE_HEALTH_LIVE_SPEC` at a JSON file
(or set it to equivalent inline JSON). The required read-only fields are
`tuple.target`, `tuple.platform`, `tuple.configuration`, `cdb`, `index` and
`provenance`. The provenance JSON must expose the same tuple at `tuple`,
`active_tuple`, `context`, or its top level. The semantic index must not be
older than the CDB. Optional `workspace_root`, `csearch_index`, `query` and
`expected_hits` fields enable a bounded query against an existing csearch
index; the audit never rebuilds that index. `UE_CPP_SEMANTIC_SMOKE_SPEC` enables
the existing live C++ semantic smoke as a separate check.

## Status model

| Status | Meaning |
|---|---|
| `PASS` | The check executed and produced the expected evidence. |
| `FAIL` | A deterministic required capability executed incorrectly. |
| `BLOCKED` | An external prerequisite such as csearch or clangd 22.1.x is unavailable. |
| `SKIP` | An optional/live check was not requested or has no supplied context. |

Overall `FAIL` means at least one deterministic check failed. `DEGRADED` means
the editor core works but one or more optional/external capabilities are
blocked. A missing csearch binary therefore does not masquerade as a broken
buffer editor, while it also cannot disappear behind a fully green result.

## Capability groups

- `startup`: real `init.lua` startup with Lazy installation/update behavior
  disabled for the probe.
- `editor`: temporary create/open/edit/write/reopen transaction.
- `syntax`: real `c`, `cpp` and `hlsl` Tree-sitter trees without error or
  missing nodes in the fixture range.
- `search`: real ripgrep fallback; real temporary cindex/csearch round trip
  when both tools are already installed.
- `compiler`: actual clangd path/version plus deterministic CDB evidence.
- `ue`: target registry and pure plan checks; optional read-only live context.
- `cleanup`: probe deadlines, process completion and temporary cleanup.

Tree-sitter syntax and clangd compiler semantics are deliberately separate. A
valid syntax tree remains `PASS` when clangd or a CDB is unavailable.

## Safety boundaries

The runner must not execute plugin/parser installation, Lazy sync/update,
Mason installation, UE Build/Prepare/Cook/Package/Deploy/Install/Launch, DAP or
device writes. Reports redact the home/config/temp roots and caller-supplied
sensitive identities before rendering JSON or text.

This audit complements rather than replaces:

```sh
nvim --headless -l tests/run.lua
```
