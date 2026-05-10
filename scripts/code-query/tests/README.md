# code-query test matrix

End-to-end self-test for the `code-query` CLI. Validates each subcommand
× backend × scenario × edge-case combination, reports pass/fail with
wall-clock timings, and exits non-zero on any regression.

## Run

Configure via env vars (none have hard-coded paths — bring your own tree):

```bash
export CQ_TEST_UE_ROOT=/path/to/your/UnrealEngine    # required: a tree with a warm csearch.idx
export CQ_TEST_NOIDX_ROOT=/path/to/some/no-idx-tree  # optional: exercises rg fallback
export CQ_TEST_NVIM_CFG=$HOME/AppData/Local/nvim     # optional: defaults to this

# Optional: exercise the clangd live-RPC upgrade path. Pick any real
# C++ file in your UE tree where SYMBOL appears at LINE:COL.
export CQ_TEST_CLANGD_FILE=$CQ_TEST_UE_ROOT/Engine/.../SomeFile.cpp
export CQ_TEST_CLANGD_LINE=90
export CQ_TEST_CLANGD_COL=9
export CQ_TEST_CLANGD_SYMBOL=FRDGBuilder

# Then:
PYTHONPATH= PYTHONHOME= python run_matrix.py
```

`CODE_QUERY_BIN` overrides where the test harness looks for the
`code-query` shim (default: `~/bin/code-query`).

## What it covers

- **doctor** — every external tool reachable
- **ctx** — across multiple cwd shapes (with idx / without idx)
- **grep** — regex / literal / case-insensitive / files-only / plain
  output / `--limit` truncation / `--no-csearch` fallback / 0-hit rc
- **def / ref** — symbol-only (gtags or csearch-literal fallback) and
  the clangd live-RPC upgrade path (only when env vars provided)

## Output

Markdown table on stdout: case name, rc, wall time, hit count, status.
Failed cases get full stderr dumped at the end. Exit 0 if all pass,
1 otherwise.
