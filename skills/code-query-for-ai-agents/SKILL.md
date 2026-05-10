---
name: code-query-for-ai-agents
description: When an AI coding agent (Claude, Codex, etc.) needs to grep / find-definition / find-references inside a large C++ codebase managed by this nvim config, expose the editor's already-warm indexes (csearch, GNU global, clangd LSP) through a small Python CLI so the agent gets answers in milliseconds instead of running rg from scratch every call.
---

# code-query — turn this nvim config into an AI-agent code analysis platform

## When to use

Use this skill whenever an AI coding agent (Claude Code / Codex / OpenCode /
Hermes-Agent / etc.) is working inside a project that this nvim config has
already indexed, and you want the agent to:

  - search the codebase fast (instead of `rg` from cold cache)
  - jump to a symbol's definition the way `gd` does in nvim
  - find every reference of a symbol the way `<leader>gr` does in nvim
  - know *which* indexes exist for the current path before deciding what to do

Concretely: a UE-sized C++ tree (10k+ TUs) where naive `rg` takes tens of
seconds and is the agent's main bottleneck. The nvim side already pays the
indexing cost once (csearch + global + clangd super-unity CDB); this CLI
just exposes that work over a stable JSONL contract.

## Why this works

The nvim config maintains three layers of index per project root:

  1. **csearch** (Google trigram index) — one `csearch.idx` per engine root,
     sub-second literal/regex grep over millions of LOC. Built by
     `:UEPrepare`. Selected via the `CSEARCHINDEX` env var.
  2. **GNU global / gtags** (with ctags langmap for HLSL/USF/USH) — symbol
     definitions and references including shaders. Per-project DB usually
     sits at `<workspace_root>/GTAGS`.
  3. **clangd LSP** (super-unity CDB) — true semantic def/ref for C++,
     already attached to the running nvim's open buffers.

The CLI is just an *exposer*: it asks nvim what it knows (via msgpack-RPC
into the live instance, falling back to `nvim --headless`), then dispatches
the right backend with sensible defaults.

```
agent → code-query → ctx (live nvim RPC) → ue.csearch_ctx / ue.clangd_root
                  ↘ csearch  (grep, fast)
                  ↘ rg       (grep, fallback when no idx)
                  ↘ global   (def/ref, semantic-lite)
                  ↘ clangd   (def/ref via live nvim, true semantic)
```

## Layout

```
scripts/code-query/
├── code_query.py            # entry point (argparse + dispatch)
├── code-query.cmd           # Windows shim (clears PYTHONHOME/PYTHONPATH)
├── code-query               # bash/MSYS shim
├── ctx.py                   # live-nvim / headless-nvim ctx resolver
└── backends/
    ├── csearch.py           # CSEARCHINDEX env-var driven
    ├── ripgrep.py           # rg --json fallback
    ├── gtags.py             # global -d / -r --result=grep
    └── clangd_lsp.py        # textDocument/{definition,references} via live nvim
```

## Install (one-time per machine)

The CLI lives **inside** the nvim config repo, so a fresh `git pull` ships
it. To make `code-query` callable from any cwd, add a shim somewhere on
your PATH (e.g. `~/bin/`) that points back to the repo:

**bash / MSYS / git-bash** — `~/bin/code-query`:

```bash
#!/usr/bin/env bash
HERE="$HOME/AppData/Local/nvim/scripts/code-query"   # adjust to your repo
PY="$HOME/AppData/Local/Programs/Python/Python312/python.exe"
[ ! -x "$PY" ] && PY="$(command -v python || command -v python3)"
PYTHONPATH= PYTHONHOME= exec "$PY" "$HERE/code_query.py" "$@"
```

**Windows cmd** — `~/bin/code-query.cmd`:

```bat
@echo off
setlocal
set "HERE=%USERPROFILE%\AppData\Local\nvim\scripts\code-query"
set "PYTHONPATH="
set "PYTHONHOME="
"%USERPROFILE%\AppData\Local\Programs\Python\Python312\python.exe" "%HERE%\code_query.py" %*
endlocal
```

Then `chmod +x ~/bin/code-query` and ensure `~/bin` is on PATH.

> Why we strip `PYTHONHOME`/`PYTHONPATH`: on Windows, having `uv`'s managed
> Python on PATH leaks stdlib pointers into a vanilla CPython invocation
> and you get `_sre.MAGIC` mismatch on `import re`. Clearing both env vars
> dodges it.

## Usage

```
code-query [--format jsonl|plain] [--limit N] SUBCOMMAND ARGS
```

**Important**: top-level flags (`--format`, `--limit`) must come *before*
the subcommand, not after.

### grep — fast full-text search

```bash
code-query --format=plain --limit 20 grep 'class FRDGBuilder'
code-query grep --literal -i 'TODO(name)'
code-query --format=jsonl grep -l 'IModularFeature'        # files-only
```

Backend chain: csearch → ripgrep. csearch needs `CSEARCHINDEX` resolvable —
the CLI gets this from `ue.csearch_ctx(bufnr)` via the live-nvim bridge.

### def — go to definition

```bash
# Cheapest: gtags (semantic-lite, works without nvim).
code-query --format=plain def FRDGBuilder

# Strongest: clangd, but you must give it a position.
code-query def FRDGBuilder \
  --file /path/to/SomeFile.cpp --line 90 --col 9
```

Backend chain: clangd-lsp (only if `--file/--line` given) → gtags →
csearch-literal.

### ref — find references

Same flags as `def`, just a different LSP method.

### ctx — what does the editor know about this path?

```bash
$ cd /path/to/project && code-query ctx
{
  "workspace_root": "/path/to/project",
  "clangd_root":    "/path/to/project",
  "gtags_db":       "/path/to/project",
  "csearch_idx":    "/path/to/project/.cache/nvim-ue/csearch/csearch.idx"
}
```

Use this *first* in any agent script — it tells you which downstream
backends are even worth trying.

### doctor — backend reachability

```bash
$ code-query doctor
```

Reports presence of `csearch`, `cindex`, `global`, `gtags`, `rg`, `nvim`,
plus the same `ctx` block. Exit code 2 if any tool is missing.

## Output contract

JSONL (default) — one match per line, stable schema:

```
{"path": "Engine/Source/.../X.h", "line": 42, "col": 9, "backend": "csearch"}
```

Paths are relative to `workspace_root` when known, absolute otherwise.
`backend` always tells you which layer answered, so the agent can decide
how much to trust the result (`clangd-live-def` ≫ `gtags-def` ≫
`csearch-literal`).

stderr always carries one diagnostic line `[code-query] backend=… hits=…`
plus any per-backend errors. Never mixed into stdout.

Exit codes: `0` matches found, `1` no matches, `2` bad args / no backend,
`3` backend execution error.

## How the live-nvim bridge works (and why it's fast)

The cheap path: `nvim --server //./pipe/nvim.PID.0 --remote-send` against
the user's running nvim, executing `:luafile <tmp.lua>`. The lua file
calls into the user's already-loaded `ue.lua` and writes the answer to a
JSON tempfile that the CLI then reads.

Two reasons this is dramatically faster than spawning headless nvim:

  1. The user's nvim already has `ue.lua` resolved, project context
     warmed, and (for clangd) the relevant buffer attached to a clangd
     server with the index in RAM.
  2. RPC dispatch is local IPC, ~50 ms round-trip. Spawning
     `nvim --headless` to load LazyVim + ue.lua + treesitter is 1–3 s
     just for startup.

If no live nvim is reachable (no Neovide / nvim TUI running), it falls
back to spawning `nvim --headless` — correctness preserved, latency
degraded. Surfaced via `[clangd] no live nvim reachable; spawning
headless (slow)` on stderr.

## Pitfalls (real ones — these all bit me)

1. **Windows named pipe URI form**. nvim listens on
   `\\.\pipe\nvim.PID.0`. From bash that path is unusable; you must use
   the forward-slash form `//./pipe/nvim.PID.0`. PowerShell enumerates
   the back-slash form, so the CLI normalizes.

2. **PowerShell pwd traps `\\.\pipe\` resolution**. When PS is invoked
   with cwd on a non-`C:` drive, `[System.IO.Directory]::EnumerateFiles('\\.\pipe\')`
   may resolve `\` against that drive (e.g. `D:\pipe`) and 404. The CLI
   passes the path with doubled backslashes and an explicit drive-free
   anchor; do not try to "simplify" that escape.

3. **Drive-letter colon in `path:line:text` parsing**. csearch/global
   output starts `C:/Users/...:42:text`. Splitting on the first `:`
   chops the drive letter. Always start the search for the path-end
   colon at index 2.

4. **uv-installed Python leaks into vanilla CPython** (Windows). If
   `uv` is on PATH, its `PYTHONHOME` can leak into a normal `python.exe`
   invocation and you get `_sre.MAGIC == MAGIC AssertionError` on
   `import re`. The shim sets `PYTHONPATH=` and `PYTHONHOME=` empty.

5. **argparse top-level flags vs subcommand position**. `--format` and
   `--limit` are on the top-level parser, so they must precede the
   subcommand. `code-query grep --format=plain ...` will fail.

6. **GTAGS DB can silently corrupt** ("`global: GTAGS seems corrupted`")
   — the CLI doesn't fail; it returns 0 hits and the next backend takes
   over. To rebuild: from inside nvim, `:UEPrepare` re-runs `gtags`.

7. **Clangd `def` of a symbol with no `--file`/`--line` cannot use
   clangd** (LSP is position-based). It silently falls through to gtags
   then csearch-literal. If the agent has a known callsite (e.g. from a
   prior `grep` answer), feed `--file/--line/--col` to upgrade the
   query to true semantic def.

8. **Multiple clangd clients per nvim** (multi-engine setups) cause
   duplicate hits. The CLI dedups by `(path, line, col)` after merging
   server responses.

## How an agent should use this

A typical agent loop on a UE-sized codebase:

```bash
# 1. Check what's available.
code-query ctx                    # know if csearch_idx / gtags_db exist
code-query doctor                 # know if external tools are on PATH

# 2. Find candidate sites with grep (cheap, very fast).
code-query --format=jsonl --limit 10 grep 'class FNiagaraSystem'

# 3. For the most promising hit, upgrade to real semantic def via clangd.
code-query def FNiagaraSystem \
  --file Engine/Source/.../NiagaraComponent.cpp --line 1234 --col 12

# 4. Walk references the same way.
code-query ref FNiagaraSystem \
  --file Engine/Source/.../NiagaraComponent.cpp --line 1234 --col 12
```

Performance budget on UE-sized tree (~14k cpp, csearch warm, live nvim
attached to the project):

  - `grep`  ≈ 1.5–2.5 s end-to-end (csearch ~50 ms, ctx-bridge ~1 s,
    Python startup ~0.3 s)
  - `def`/`ref` via clangd live ≈ 2–4 s (RPC + LSP request)
  - rg fallback for the same `grep`: ≈ 30–60 s (NTFS+anti-virus)
    — *order of magnitude slower*

## Skill maintenance

If you add a new backend (e.g. zoekt, cscope), keep the same JSONL
contract and add it to the `Backend chain` order in this skill. If the
shim placement changes, update the **Install** section. If you discover
a new pitfall while debugging, append it to the Pitfalls list — that
section earned its keep through real failures.
