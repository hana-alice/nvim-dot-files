#!/usr/bin/env python3
"""Self-test matrix for code-query.

Runs each case, captures (rc, stdout, stderr, wall_time), validates against
expected_rc / expected_backend pattern / json shape, prints a Markdown table
to stdout.

Run with PYTHONHOME= PYTHONPATH= cleared.
"""
import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import List, Optional, Callable

CQ = os.environ.get("CODE_QUERY_BIN", os.path.expanduser("~/bin/code-query"))
UE = os.environ.get("CQ_TEST_UE_ROOT", "")        # required for most cases
UETEMP = os.environ.get("CQ_TEST_NOIDX_ROOT", "") # optional: a tree without csearch.idx
NVIMCFG = os.environ.get("CQ_TEST_NVIM_CFG",
                         os.path.expanduser("~/AppData/Local/nvim"))

if not UE:
    sys.stderr.write(
        "Set CQ_TEST_UE_ROOT to a path with a warm csearch index "
        "(e.g. an Unreal Engine tree where you've run :UEPrepare).\n"
        "Optional: CQ_TEST_NOIDX_ROOT for a tree without an index "
        "(exercises the rg fallback case).\n"
        "Optional: CQ_TEST_CLANGD_FILE / CQ_TEST_CLANGD_LINE /\n"
        "          CQ_TEST_CLANGD_COL / CQ_TEST_CLANGD_SYMBOL\n"
        "  to exercise the clangd live-RPC def/ref upgrade path.\n")
    sys.exit(2)

# Optional clangd test position. Without these, the clangd-upgrade cases
# are skipped (the rest of the matrix still runs).
CLANGD_FILE   = os.environ.get("CQ_TEST_CLANGD_FILE", "")
CLANGD_LINE   = os.environ.get("CQ_TEST_CLANGD_LINE", "")
CLANGD_COL    = os.environ.get("CQ_TEST_CLANGD_COL", "1")
CLANGD_SYMBOL = os.environ.get("CQ_TEST_CLANGD_SYMBOL", "")


@dataclass
class Case:
    name: str
    cwd: str
    args: list
    expected_rc: tuple = (0,)               # acceptable rc set
    expect_backend: Optional[str] = None    # regex pattern in stderr
    expect_min_hits: int = 0                # how many JSONL lines minimum
    expect_max_hits: Optional[int] = None
    json_shape_check: Optional[Callable] = None  # called with list of dicts
    timeout: int = 90


@dataclass
class Result:
    case: Case
    rc: int = 0
    wall: float = 0.0
    stdout: str = ""
    stderr: str = ""
    parsed: list = field(default_factory=list)
    issues: list = field(default_factory=list)


def run(c: Case) -> Result:
    t0 = time.time()
    cp = subprocess.run(
        ["bash", CQ, *c.args],
        cwd=c.cwd, capture_output=True, text=True,
        timeout=c.timeout,
    )
    r = Result(case=c, rc=cp.returncode, wall=time.time() - t0,
               stdout=cp.stdout, stderr=cp.stderr)

    # Parse JSONL when applicable.
    if "--format=plain" not in c.args and c.args[0] not in ("doctor", "ctx"):
        for line in cp.stdout.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                r.parsed.append(json.loads(line))
            except ValueError:
                r.issues.append(f"unparseable JSON line: {line[:80]!r}")

    # Validate.
    if cp.returncode not in c.expected_rc:
        r.issues.append(f"rc={cp.returncode} not in {c.expected_rc}")
    if c.expect_backend and not re.search(c.expect_backend, cp.stderr):
        r.issues.append(f"stderr missing backend pattern {c.expect_backend!r}; got: {cp.stderr.strip()[:120]!r}")

    hits = len(r.parsed) if r.parsed else _count_plain_hits(cp.stdout, c.args)
    if hits < c.expect_min_hits:
        r.issues.append(f"hits={hits} < min {c.expect_min_hits}")
    if c.expect_max_hits is not None and hits > c.expect_max_hits:
        r.issues.append(f"hits={hits} > max {c.expect_max_hits}")

    if c.json_shape_check and r.parsed:
        try:
            c.json_shape_check(r.parsed)
        except AssertionError as e:
            r.issues.append(f"shape: {e}")

    return r


def _count_plain_hits(out: str, args) -> int:
    if args[0] in ("doctor", "ctx"):
        return 0
    return len([ln for ln in out.splitlines() if ln.strip()])


def shape_grep(items):
    for it in items:
        assert "path" in it, "missing path"
        assert "line" in it, "missing line"
        assert "backend" in it, "missing backend"


def shape_loc(items):
    for it in items:
        assert "path" in it, "missing path"
        assert "line" in it, "missing line"
        assert "col" in it, "missing col"


def shape_files_only(items):
    for it in items:
        assert "path" in it, "missing path"
        assert "line" not in it, "files-only should not have line"


# ---- The matrix ---------------------------------------------------------
CASES: List[Case] = [
    # --- doctor / ctx ---
    Case("doctor (UE)", UE, ["doctor"], expected_rc=(0, 2)),
    Case("ctx (UE)", UE, ["ctx"]),
    Case("ctx (nvim cfg dir)", NVIMCFG, ["ctx"]),
    Case("ctx (uetemp)", UETEMP, ["ctx"]),

    # --- grep ---
    Case("grep regex (UE)", UE,
         ["--limit", "5", "grep", r"class FRDGBuilder\b"],
         expect_backend=r"backend=csearch", expect_min_hits=1,
         json_shape_check=shape_grep),
    Case("grep --literal (UE)", UE,
         ["--limit", "5", "grep", "--literal", "TRefCountPtr<FShaderCompileJob>"],
         expect_backend=r"backend=csearch", expect_min_hits=1),
    Case("grep -i (UE)", UE,
         ["--limit", "5", "grep", "-i", "frdgbuilder"],
         expect_backend=r"backend=csearch", expect_min_hits=1),
    Case("grep -l files-only (UE)", UE,
         ["--limit", "5", "grep", "-l", "FRDGBuilder"],
         expect_backend=r"backend=csearch", expect_min_hits=1,
         json_shape_check=shape_files_only),
    Case("grep --format=plain (UE)", UE,
         ["--format=plain", "--limit", "3", "grep", "FRDGBuilder"],
         expect_backend=r"backend=csearch", expect_min_hits=1),
    Case("grep 0-hit (UE)", UE,
         ["grep", "ZZZ_NoSuchSymbolNoOneEverWroteThis_QQQ"],
         expected_rc=(1,), expect_max_hits=0),
    Case("grep --limit truncate (UE)", UE,
         ["--limit", "7", "grep", "FRDGBuilder"],
         expect_backend=r"backend=csearch",
         expect_min_hits=1, expect_max_hits=7),
    Case("grep no-csearch -> rg (UE)", UE,
         ["--limit", "3", "grep", "--no-csearch", "FRDGBuilder"],
         expect_backend=r"backend=ripgrep", expect_min_hits=1, timeout=180),
    Case("grep in uetemp (no idx -> rg)", UETEMP,
         ["--limit", "3", "grep", "class FRDGBuilder"],
         expect_backend=r"backend=ripgrep", expect_min_hits=1, timeout=180),

    # --- def ---
    Case("def symbol-only (UE)", UE,
         ["--limit", "5", "def", "FRDGBuilder"],
         expect_backend=r"backend=(gtags|csearch-literal)",
         expect_min_hits=1, json_shape_check=shape_grep),
]

# Clangd-upgrade cases — require a real callsite the user supplies via env.
if CLANGD_FILE and CLANGD_LINE and CLANGD_SYMBOL:
    CASES += [
        Case("def +file/+line/+col -> clangd (UE)", UE,
             ["--limit", "5", "def", CLANGD_SYMBOL,
              "--file", CLANGD_FILE,
              "--line", CLANGD_LINE, "--col", CLANGD_COL],
             expect_backend=r"backend=clangd-(live|headless|lsp)",
             expect_min_hits=1, json_shape_check=shape_loc, timeout=60),
        Case("def --no-clangd (UE)", UE,
             ["--limit", "3", "def", CLANGD_SYMBOL, "--no-clangd",
              "--file", CLANGD_FILE,
              "--line", CLANGD_LINE, "--col", CLANGD_COL],
             expect_backend=r"backend=(gtags|csearch-literal)"),
        Case("ref +pos -> clangd (UE)", UE,
             ["--limit", "10", "ref", CLANGD_SYMBOL,
              "--file", CLANGD_FILE,
              "--line", CLANGD_LINE, "--col", CLANGD_COL],
             expect_backend=r"backend=clangd-(live|headless|lsp)",
             expect_min_hits=1, json_shape_check=shape_loc, timeout=90),
    ]

CASES += [
    Case("ref symbol-only (UE)", UE,
         ["--limit", "5", "ref", "FShaderCompileJob"],
         expect_backend=r"backend=(gtags|csearch-literal)",
         expect_min_hits=1),
]


def main():
    results = [run(c) for c in CASES]

    print("\n# code-query self-test results\n")
    print(f"backend = {CQ}")
    print()
    print("| # | case | rc | wall(s) | hits | status | note |")
    print("|---|------|---:|--------:|-----:|:------:|------|")
    for i, r in enumerate(results, 1):
        hits = len(r.parsed) if r.parsed else _count_plain_hits(r.stdout, r.case.args)
        status = "OK" if not r.issues else "FAIL"
        note = "; ".join(r.issues)[:120] if r.issues else _short_diag(r)
        print(f"| {i} | {r.case.name} | {r.rc} | {r.wall:.2f} | {hits} | {status} | {note} |")

    fails = [r for r in results if r.issues]
    print(f"\n**{len(results)-len(fails)}/{len(results)} pass**.")
    if fails:
        print("\n## Failures (full stderr)\n")
        for r in fails:
            print(f"### {r.case.name}\n```\nargs: {r.case.args}\nrc: {r.rc}\nissues: {r.issues}\nstderr: {r.stderr.strip()[:500]}\n```")
    sys.exit(1 if fails else 0)


def _short_diag(r: Result) -> str:
    m = re.search(r"backend=(\S+)\s+hits=(\d+)", r.stderr)
    if m:
        return f"backend={m.group(1)}"
    if r.case.args[0] in ("doctor", "ctx"):
        try:
            j = json.loads(r.stdout)
            if r.case.args[0] == "ctx":
                return ",".join(sorted(j.keys()))
            if r.case.args[0] == "doctor":
                missing = [k for k, v in j.get("tools", {}).items() if "missing" in v]
                return f"missing={missing}" if missing else "all tools present"
        except Exception:
            pass
    return ""


if __name__ == "__main__":
    main()
