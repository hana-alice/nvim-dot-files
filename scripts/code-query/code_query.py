#!/usr/bin/env python3
"""code-query — unified search/definition/reference CLI for AI agents.

Backed by the indexes this nvim config maintains:
  - csearch (Google codesearch, trigram)  → grep
  - ripgrep                                → grep fallback
  - GNU global / gtags                     → def / ref fallback
  - clangd LSP via headless nvim RPC bridge → def / ref (strong)

Output is JSONL on stdout (one match per line) by default. Use --format=plain
for a human-readable view. Stderr carries diagnostics + which backend served
the query — never mix into stdout.

Subcommands:
  grep   PATTERN [PATH]   regex/literal search across an indexed root
  def    SYMBOL  [PATH]   "go to definition" of a symbol
  ref    SYMBOL  [PATH]   "find references" of a symbol
  ctx    [PATH]           dump the index context (roots/idx paths) for PATH
  doctor                  probe which backends are reachable

Exit codes:
  0   ok (matches found OR ctx/doctor ran)
  1   no matches
  2   bad arguments / backend not configured
  3   backend execution error
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from typing import Optional

# Make the backends/ subpackage importable when invoked directly.
HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from backends import csearch as be_csearch  # noqa: E402
from backends import ripgrep as be_rg  # noqa: E402
from backends import gtags as be_gtags  # noqa: E402
from backends import clangd_lsp as be_clangd  # noqa: E402
import ctx as ctxmod  # noqa: E402


def _eprint(*a, **kw):
    print(*a, file=sys.stderr, **kw)


def _emit(matches, fmt: str):
    if fmt == "jsonl":
        for m in matches:
            sys.stdout.write(json.dumps(m, ensure_ascii=False) + "\n")
    elif fmt == "plain":
        for m in matches:
            line = m.get("line", "?")
            col = m.get("col")
            path = m.get("path", "?")
            text = (m.get("text") or "").rstrip()
            loc = f"{path}:{line}" + (f":{col}" if col else "")
            sys.stdout.write(f"{loc}\t{text}\n")
    else:
        _eprint(f"[code-query] unknown --format: {fmt}")
        sys.exit(2)


def _resolve_path(p: Optional[str]) -> str:
    if not p:
        return os.getcwd()
    return os.path.abspath(os.path.expanduser(p))


# ---------- subcommand: grep ----------
def cmd_grep(args) -> int:
    cwd = _resolve_path(args.path)
    ctx = ctxmod.resolve(cwd, want="csearch")

    matches = []
    used = None
    err = None

    # Tier 1: csearch
    if not args.no_csearch and ctx and ctx.get("csearch_idx"):
        used = "csearch"
        try:
            matches = be_csearch.grep(
                pattern=args.pattern,
                idx=ctx["csearch_idx"],
                workspace_root=ctx.get("workspace_root"),
                limit=args.limit,
                literal=args.literal,
                ignore_case=args.ignore_case,
                files_only=args.files_only,
            )
        except Exception as e:
            err = f"csearch failed: {e}"
            matches = []

    # Tier 2: ripgrep
    if not matches and not args.no_rg:
        used = "ripgrep"
        try:
            matches = be_rg.grep(
                pattern=args.pattern,
                root=cwd,
                limit=args.limit,
                literal=args.literal,
                ignore_case=args.ignore_case,
                files_only=args.files_only,
            )
        except Exception as e:
            err = f"{err+'; ' if err else ''}rg failed: {e}"

    _eprint(f"[code-query] backend={used}  hits={len(matches)}"
            + (f"  err={err}" if err else ""))
    _emit(matches, args.format)
    return 0 if matches else 1


# ---------- subcommand: def ----------
def cmd_def(args) -> int:
    cwd = _resolve_path(args.path)
    return _resolve_symbol(args, cwd, kind="def")


# ---------- subcommand: ref ----------
def cmd_ref(args) -> int:
    cwd = _resolve_path(args.path)
    return _resolve_symbol(args, cwd, kind="ref")


def _resolve_symbol(args, cwd: str, kind: str) -> int:
    ctx = ctxmod.resolve(cwd, want="all")
    matches = []
    used = None
    errs = []

    # Tier 1: clangd via headless nvim — strongest semantic answer for C/C++.
    # Requires a file path (LSP requests are file/position based). When the
    # user passes --file/--line, use those; otherwise we cannot ask clangd.
    if not args.no_clangd and args.file and args.line is not None:
        try:
            used = "clangd-lsp"
            matches = be_clangd.lookup(
                file=os.path.abspath(args.file),
                line=args.line,
                col=args.col or 1,
                kind=kind,
                workspace_root=(ctx or {}).get("clangd_root") or cwd,
                timeout=args.timeout,
            )
        except Exception as e:
            errs.append(f"clangd: {e}")
            matches = []

    # Tier 2: GNU global / gtags
    if not matches and not args.no_gtags and ctx and ctx.get("gtags_db"):
        try:
            used = "gtags"
            matches = be_gtags.lookup(
                symbol=args.symbol,
                gtags_db=ctx["gtags_db"],
                workspace_root=ctx.get("workspace_root") or cwd,
                kind=kind,
                limit=args.limit,
            )
        except Exception as e:
            errs.append(f"gtags: {e}")

    # Tier 3: csearch literal fallback (last resort — text not semantic)
    if not matches and not args.no_csearch and ctx and ctx.get("csearch_idx"):
        try:
            used = "csearch-literal"
            matches = be_csearch.grep(
                pattern=args.symbol,
                idx=ctx["csearch_idx"],
                workspace_root=ctx.get("workspace_root"),
                limit=args.limit,
                literal=True,
                ignore_case=False,
                files_only=False,
            )
        except Exception as e:
            errs.append(f"csearch: {e}")

    _eprint(f"[code-query] kind={kind} backend={used} hits={len(matches)}"
            + (f"  errs={'; '.join(errs)}" if errs else ""))
    _emit(matches, args.format)
    return 0 if matches else 1


# ---------- subcommand: ctx ----------
def cmd_ctx(args) -> int:
    cwd = _resolve_path(args.path)
    ctx = ctxmod.resolve(cwd, want="all") or {}
    sys.stdout.write(json.dumps(ctx, indent=2, ensure_ascii=False) + "\n")
    return 0


# ---------- subcommand: doctor ----------
def cmd_doctor(args) -> int:
    rows = []
    for name, exe in [
        ("csearch", "csearch"),
        ("cindex", "cindex"),
        ("global", "global"),
        ("gtags", "gtags"),
        ("rg", "rg"),
        ("nvim", "nvim"),
    ]:
        path = shutil.which(exe)
        rows.append((name, path or "(missing)"))

    cwd = _resolve_path(args.path)
    ctx = ctxmod.resolve(cwd, want="all") or {}
    out = {
        "tools": {n: p for n, p in rows},
        "context_for_cwd": {"cwd": cwd, "ctx": ctx},
    }
    sys.stdout.write(json.dumps(out, indent=2, ensure_ascii=False) + "\n")
    missing = [n for n, p in rows if p == "(missing)"]
    return 2 if missing else 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="code-query",
                                description="AI-agent-friendly code search/def/ref CLI")
    p.add_argument("--format", choices=["jsonl", "plain"], default="jsonl",
                   help="output format (default: jsonl)")
    p.add_argument("--limit", type=int, default=200, help="max matches (default: 200)")

    sub = p.add_subparsers(dest="cmd", required=True)

    g = sub.add_parser("grep", help="full-text search")
    g.add_argument("pattern")
    g.add_argument("path", nargs="?")
    g.add_argument("--literal", action="store_true",
                   help="treat PATTERN as a literal string, not regex")
    g.add_argument("-i", "--ignore-case", action="store_true")
    g.add_argument("-l", "--files-only", action="store_true",
                   help="emit only file paths, no line text")
    g.add_argument("--no-csearch", action="store_true")
    g.add_argument("--no-rg", action="store_true")
    g.set_defaults(func=cmd_grep)

    for name, fn in [("def", cmd_def), ("ref", cmd_ref)]:
        s = sub.add_parser(name, help=f"find {name} of SYMBOL")
        s.add_argument("symbol")
        s.add_argument("path", nargs="?")
        s.add_argument("--file", help="for clangd: source file the symbol appears in")
        s.add_argument("--line", type=int, help="for clangd: 1-based line number")
        s.add_argument("--col", type=int, help="for clangd: 1-based column (default 1)")
        s.add_argument("--timeout", type=int, default=30,
                       help="clangd request timeout seconds (default 30)")
        s.add_argument("--no-clangd", action="store_true")
        s.add_argument("--no-gtags", action="store_true")
        s.add_argument("--no-csearch", action="store_true")
        s.set_defaults(func=fn)

    c = sub.add_parser("ctx", help="dump index context for PATH")
    c.add_argument("path", nargs="?")
    c.set_defaults(func=cmd_ctx)

    d = sub.add_parser("doctor", help="probe backends + context")
    d.add_argument("path", nargs="?")
    d.set_defaults(func=cmd_doctor)

    args = p.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
