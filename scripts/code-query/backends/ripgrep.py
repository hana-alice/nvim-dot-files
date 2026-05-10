"""ripgrep backend — fallback when no csearch index is built.

We invoke `rg` with --json so we don't have to parse the human-friendly
output (which is locale/colour dependent). Each JSON event with type='match'
yields one or more sub-matches.
"""

from __future__ import annotations

import json
import os
import subprocess
from typing import List, Dict, Optional


def grep(*, pattern: str, root: str, limit: int = 200,
         literal: bool = False, ignore_case: bool = False,
         files_only: bool = False) -> List[Dict]:
    if not os.path.isdir(root):
        raise RuntimeError(f"rg root not a directory: {root!r}")

    cmd = ["rg", "--json"]
    if literal:
        cmd.append("-F")
    if ignore_case:
        cmd.append("-i")
    if files_only:
        cmd.append("-l")
    # Cap to avoid blowing the agent's context with megabyte answers.
    cmd += ["-m", str(max(limit * 2, 100))]
    cmd += ["--", pattern, root]

    cp = subprocess.run(cmd, capture_output=True, text=True,
                        encoding="utf-8", errors="replace", timeout=120)
    if cp.returncode not in (0, 1):
        raise RuntimeError(f"rg exit={cp.returncode}: {cp.stderr.strip()[:200]}")

    matches: List[Dict] = []
    if files_only:
        # rg -l --json emits {type:"begin", data:{path:{text:...}}}
        for raw in (cp.stdout or "").splitlines():
            if not raw:
                continue
            try:
                ev = json.loads(raw)
            except ValueError:
                continue
            if ev.get("type") == "begin":
                p = (ev.get("data", {}).get("path", {}) or {}).get("text")
                if p:
                    matches.append({"path": _rel(p, root), "backend": "ripgrep"})
                    if len(matches) >= limit:
                        break
        return matches

    for raw in (cp.stdout or "").splitlines():
        if not raw:
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if ev.get("type") != "match":
            continue
        d = ev.get("data") or {}
        path = (d.get("path", {}) or {}).get("text")
        line = d.get("line_number")
        text = (d.get("lines", {}) or {}).get("text", "")
        if not path or line is None:
            continue
        for sub in d.get("submatches", []) or [{"start": 0}]:
            matches.append({
                "path": _rel(path, root),
                "line": int(line),
                "col": int(sub.get("start", 0)) + 1,
                "text": text.rstrip("\n"),
                "backend": "ripgrep",
            })
            if len(matches) >= limit:
                return matches
    return matches


def _rel(p: str, root: str) -> str:
    p = p.replace("\\", "/")
    r = root.replace("\\", "/").rstrip("/")
    if p.startswith(r + "/"):
        return p[len(r) + 1:]
    return p
