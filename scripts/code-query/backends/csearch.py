"""csearch backend — Google codesearch trigram index.

We invoke `csearch` with `-n` (line numbers) and parse `path:line:text`.
Optionally `-l` for files-only.

The index is selected via the CSEARCHINDEX env var (csearch reads only that;
no -f flag exists in upstream codesearch). We set it per-call so multiple
indexes (one per UE engine root) coexist without collision.
"""

from __future__ import annotations

import os
import subprocess
from typing import List, Dict, Optional


def _run(cmd: List[str], env_extra: Optional[Dict[str, str]] = None,
         timeout: int = 60) -> subprocess.CompletedProcess:
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
        timeout=timeout,
    )


def grep(*, pattern: str, idx: str, workspace_root: Optional[str] = None,
         limit: int = 200, literal: bool = False, ignore_case: bool = False,
         files_only: bool = False) -> List[Dict]:
    """Run csearch and return list of match dicts.

    Match dict shape:
      {path, line, col, text, backend: "csearch"}
    For files_only mode: {path, backend}
    """
    if not idx or not os.path.exists(idx):
        raise RuntimeError(f"csearch index not found: {idx!r}")

    cmd = ["csearch"]
    if files_only:
        cmd.append("-l")
    else:
        cmd.append("-n")
    if ignore_case:
        cmd.append("-i")
    if literal:
        # codesearch interprets pattern as regex by default; escape for literal
        # mode. Re module isn't appropriate (it's PCRE-flavored vs RE2), do a
        # conservative escape of regex metachars.
        pattern = _escape_re2(pattern)
    cmd.append(pattern)

    cp = _run(cmd, env_extra={"CSEARCHINDEX": idx})
    if cp.returncode not in (0, 1):  # 1 = no matches in grep tradition
        raise RuntimeError(f"csearch exit={cp.returncode}: {cp.stderr.strip()[:200]}")

    matches: List[Dict] = []
    for raw in (cp.stdout or "").splitlines():
        if not raw:
            continue
        if files_only:
            matches.append({"path": _norm(raw, workspace_root), "backend": "csearch"})
            if len(matches) >= limit:
                break
            continue
        # path:line:text  — note path on Windows starts with `C:` so the first
        # `:` is part of the drive letter. Split on the FIRST `:` after the
        # 2nd character.
        path_end = _find_path_end(raw)
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
            "path": _norm(raw[:path_end], workspace_root),
            "line": line,
            "text": text,
            "backend": "csearch",
        })
        if len(matches) >= limit:
            break
    return matches


def _find_path_end(s: str) -> int:
    # Skip any drive-letter colon (`C:`) at position 1.
    start = 2 if len(s) > 2 and s[1] == ":" else 0
    return s.find(":", start)


def _norm(p: str, workspace_root: Optional[str]) -> str:
    p = p.replace("\\", "/")
    if workspace_root:
        wr = workspace_root.replace("\\", "/").rstrip("/")
        if p.startswith(wr + "/"):
            return p[len(wr) + 1:]
    return p


_RE2_META = r".\\+*?()|[]{}^$"


def _escape_re2(s: str) -> str:
    return "".join("\\" + c if c in _RE2_META else c for c in s)
