"""gtags backend — GNU global / gtags symbol lookup.

`global -d SYMBOL` → definitions; `-r SYMBOL` → references.
We use `--result=grep` so the output is `path:line:text`, parseable like rg/csearch.

The DB is selected via the GTAGSDBPATH + GTAGSROOT env vars (global picks them
up even outside a "real" GTAGS dir, which is exactly our case — the DB lives
under the agent's cache dir, not the workspace itself).
"""

from __future__ import annotations

import os
import subprocess
from typing import List, Dict, Optional


def lookup(*, symbol: str, gtags_db: str, workspace_root: str,
           kind: str = "def", limit: int = 200) -> List[Dict]:
    if kind not in ("def", "ref"):
        raise ValueError(f"kind must be def|ref, got {kind!r}")
    if not os.path.isdir(gtags_db):
        raise RuntimeError(f"GTAGS dir not found: {gtags_db!r}")

    cmd = ["global", "--literal", "--result=grep"]
    cmd.append("-r" if kind == "ref" else "-d")
    cmd.append(symbol)

    env = os.environ.copy()
    env["GTAGSROOT"] = workspace_root
    env["GTAGSDBPATH"] = gtags_db

    cp = subprocess.run(cmd, capture_output=True, text=True,
                        encoding="utf-8", errors="replace",
                        env=env, cwd=workspace_root, timeout=60)
    # global exit codes: 0=found, 1=not found, 3+=error
    if cp.returncode not in (0, 1):
        raise RuntimeError(f"global exit={cp.returncode}: {cp.stderr.strip()[:200]}")

    matches: List[Dict] = []
    for raw in (cp.stdout or "").splitlines():
        if not raw:
            continue
        # path:line:text  — Windows drive letter colon trap (same as csearch).
        start = 2 if len(raw) > 2 and raw[1] == ":" else 0
        path_end = raw.find(":", start)
        if path_end < 0:
            continue
        rest = raw[path_end + 1:]
        line_end = rest.find(":")
        if line_end < 0:
            continue
        try:
            line = int(rest[:line_end])
        except ValueError:
            continue
        text = rest[line_end + 1:]
        matches.append({
            "path": _rel(raw[:path_end], workspace_root),
            "line": line,
            "text": text,
            "backend": f"gtags-{kind}",
        })
        if len(matches) >= limit:
            break
    return matches


def _rel(p: str, root: str) -> str:
    p = p.replace("\\", "/")
    r = root.replace("\\", "/").rstrip("/")
    if p.startswith(r + "/"):
        return p[len(r) + 1:]
    return p
