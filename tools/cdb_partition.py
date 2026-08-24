#!/usr/bin/env python3
"""
cdb_partition.py — split a multi-config compile_commands.json into per-(plat,cfg)
files and pick one as the "active" base.

Background
----------
UE's `compile_commands.json` accumulates entries from multiple build configs
(Test / Development / Shipping) and platforms (Android / Win64 / ...) across
:UEPrepare runs because UBT's CDB writer is config-agnostic — a Test
:UEPrepare leaves stale Editor-only Win64 entries and earlier Android-Dev
entries from the previous build. clangd then resolves header `#define`s
(notably `UE_BUILD_DEVELOPMENT`) against whichever config-specific
`Definitions.<Module>.h` is reachable in the CDB, so `gd UE_BUILD_DEVELOPMENT`
jumps into the wrong config's generated header.

This tool partitions a single base CDB into:

  <repo>/.cache/nvim-ue/cdb/active/compile_commands.<plat>-<cfg>.json   per-group full copies
  <repo>/compile_commands.json                                          active group (overwritten)
  <repo>/compile_commands.partition.json                                manifest

Active selection
----------------
By default `--active auto` picks the most-frequent (plat, cfg) group with both
fields known. Override with `--active Android/Test`.

Unclassified shaders (.usf/.hlsl/.ush/.glsl etc.) carry no Intermediate path
so they cannot be grouped — they are appended to the active base file so
shader-related entries remain reachable.

Failure modes
-------------
- base CDB missing / unparseable / empty → exit 2 (caller should fall back to
  leaving CDB untouched).
- no classifiable groups → exit 3 (likely a single-config CDB already; emit
  manifest with active=null and leave base untouched).
- single classifiable group → no-op rewrite (but still emit manifest so the
  caller can confirm); exit 0.

Idempotency
-----------
Running twice on the same base CDB produces the same per-group files and the
same active base content. The .bak file is timestamped so reruns accumulate
backups (deliberate — small price for restore safety on a 200 MB CDB).
"""
from __future__ import annotations

import argparse
import collections
import json
import os
import re
import shutil
import sys
import time
from typing import Any

PLATFORMS = {
    "Win64", "Win32", "Linux", "LinuxAArch64", "Mac",
    "Android", "IOS", "TVOS", "HoloLens",
    "PS4", "PS5", "XSX", "XB1", "Switch",
}
KNOWN_CFG = {"Development", "Test", "Shipping", "DebugGame", "Debug"}

PLAT_RE = re.compile(r"[Ii]ntermediate/[Bb]uild/([^/]+)/([^/]+)(?:/([^/]+))?")


def _platform_canonical(name: str) -> str | None:
    for p in PLATFORMS:
        if p.lower() == name.lower():
            return p
    return None


def classify(entry: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    """Vote-based classification — most-common (plat,proj,cfg) across all args.

    Vote rather than first-hit because a single TU cmd often references many
    Intermediate paths (one per module via -I), and an Editor-only h-injected
    .h cmd may have its primary platform out-voted by a single stray cross-platform
    include if we pick first-hit.
    """
    plat_votes: collections.Counter = collections.Counter()
    proj_votes: collections.Counter = collections.Counter()
    cfg_votes: collections.Counter = collections.Counter()

    args = entry.get("arguments") or []
    for a in args:
        if "ntermediate" not in a:  # cheap pre-filter (case-insensitive 'I')
            continue
        norm = a.replace("\\", "/")
        for m in PLAT_RE.finditer(norm):
            p, pr, c = m.group(1), m.group(2), m.group(3)
            P = _platform_canonical(p)
            if P:
                plat_votes[P] += 1
                proj_votes[pr] += 1
                if c and c in KNOWN_CFG:
                    cfg_votes[c] += 1

    # target= fallback when no Intermediate paths matched (rare: third-party .c
    # without Definitions, e.g. SQLite/minizip).
    if not plat_votes:
        for a in args:
            if a.startswith("--target="):
                t = a.split("=", 1)[1].lower()
                if "android" in t:
                    plat_votes["Android"] = 1
                elif "win" in t or "msvc" in t:
                    plat_votes["Win64"] = 1
                elif "linux" in t:
                    plat_votes["Linux"] = 1
                break

    plat = plat_votes.most_common(1)[0][0] if plat_votes else None
    proj = proj_votes.most_common(1)[0][0] if proj_votes else None
    cfg = cfg_votes.most_common(1)[0][0] if cfg_votes else None
    return (plat, proj, cfg)


def group_key_label(group: tuple[str | None, str | None, str | None]) -> str:
    p, pr, c = group
    return f"{p or 'unknown'}-{pr or 'unknown'}-{c or 'unknown'}"


def group_filename(group: tuple[str | None, str | None, str | None],
                   needs_project: bool = False) -> str:
    """Active-dir file name: <plat>-<cfg>.json normally, <plat>-<proj>-<cfg>.json
    when needs_project=True (called when two groups would otherwise collide on
    plat+cfg, typically Client vs UE4 leftover from a UE4-UE5 migration)."""
    p, pr, c = group
    if needs_project:
        return f"compile_commands.{p or 'unknown'}-{pr or 'unknown'}-{c or 'unknown'}.json"
    return f"compile_commands.{p or 'unknown'}-{c or 'unknown'}.json"


def pick_active_auto(groups: dict[tuple, list]) -> tuple | None:
    """Most-frequent group with both plat and cfg known."""
    candidates = {k: v for k, v in groups.items() if k[0] and k[2]}
    if not candidates:
        # fall back to most-frequent with plat known
        candidates = {k: v for k, v in groups.items() if k[0]}
    if not candidates:
        return None
    return max(candidates.items(), key=lambda kv: len(kv[1]))[0]


def parse_active_arg(s: str, groups: dict[tuple, list]) -> tuple | None:
    """Parse '--active Android/Test' or 'Android/Client/Test'. Project segment optional."""
    parts = s.split("/")
    if len(parts) == 2:
        plat, cfg = parts
        for k in groups:
            if k[0] == plat and k[2] == cfg:
                return k
        return None
    if len(parts) == 3:
        plat, proj, cfg = parts
        k = (plat, proj, cfg)
        return k if k in groups else None
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("base_cdb", help="path to base compile_commands.json")
    ap.add_argument("--active", default="auto",
                    help="auto | <Platform>/<Config> | <Platform>/<Project>/<Config>")
    ap.add_argument("--out-dir", default=None,
                    help="directory for per-group files (default: <base_cdb_dir>/.cache/nvim-ue/cdb/active)")
    ap.add_argument("--manifest", default=None,
                    help="manifest path (default: <base_cdb_dir>/compile_commands.partition.json)")
    ap.add_argument("--no-rewrite-base", action="store_true",
                    help="emit per-group files + manifest but do NOT overwrite base CDB")
    ap.add_argument("--quiet", "-q", action="store_true")
    args = ap.parse_args()

    base = os.path.abspath(args.base_cdb)
    if not os.path.isfile(base):
        print(f"ERROR: base CDB not found: {base}", file=sys.stderr)
        return 2

    try:
        with open(base, "r", encoding="utf-8") as f:
            data = json.load(f)
    except Exception as e:
        print(f"ERROR: failed to parse base CDB: {e}", file=sys.stderr)
        return 2

    if not isinstance(data, list) or not data:
        print(f"ERROR: base CDB is empty or not a list", file=sys.stderr)
        return 2

    base_dir = os.path.dirname(base)
    out_dir = args.out_dir or os.path.join(base_dir, ".cache", "nvim-ue", "cdb", "active")
    manifest_path = args.manifest or os.path.join(base_dir, "compile_commands.partition.json")
    os.makedirs(out_dir, exist_ok=True)

    # group
    groups: dict[tuple, list] = collections.defaultdict(list)
    for e in data:
        groups[classify(e)].append(e)

    unclassified = groups.pop((None, None, None), [])

    if not args.quiet:
        print(f"[partition] total={len(data)} unclassified-shaders={len(unclassified)} groups={len(groups)}")
        for k, v in sorted(groups.items(), key=lambda x: -len(x[1])):
            print(f"  {len(v):6d}  {k}")

    if not groups:
        # no classifiable groups — probably a CDB with only shaders/third-party.
        # Write a manifest with active=null and leave base alone.
        manifest = {
            "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "source": base,
            "active": None,
            "unclassified_count": len(unclassified),
            "groups": [],
            "note": "no classifiable (plat,proj,cfg) groups; base untouched",
        }
        with open(manifest_path, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)
        if not args.quiet:
            print(f"[partition] no classifiable groups — manifest only: {manifest_path}")
        return 3

    # pick active
    if args.active == "auto":
        active = pick_active_auto(groups)
    else:
        active = parse_active_arg(args.active, groups)
        if active is None:
            print(f"ERROR: --active {args.active!r} matches no group. Available: "
                  + ", ".join(group_key_label(k) for k in groups), file=sys.stderr)
            return 4

    if not args.quiet:
        print(f"[partition] active={active} ({len(groups[active])} cmds)")

    # write per-group files (including the active group, for symmetry / debugging).
    # Detect (plat, cfg) collisions across different projects (e.g. Client vs UE4
    # leftover from UE4->UE5 migration) and add project segment to those names so
    # we don't overwrite one with the other.
    plat_cfg_counts: collections.Counter = collections.Counter()
    for k in groups:
        plat_cfg_counts[(k[0], k[2])] += 1
    collided = {pc for pc, n in plat_cfg_counts.items() if n > 1}

    group_files: list[dict[str, Any]] = []
    for k, entries in sorted(groups.items(), key=lambda x: -len(x[1])):
        fn = os.path.join(out_dir, group_filename(k, needs_project=(k[0], k[2]) in collided))
        with open(fn, "w", encoding="utf-8") as f:
            json.dump(entries, f, indent=2)
        group_files.append({
            "platform": k[0], "project": k[1], "config": k[2],
            "cmd_count": len(entries),
            "file": fn,
            "active": (k == active),
        })
        if not args.quiet:
            print(f"  -> {fn}  ({len(entries)} cmds, {os.path.getsize(fn)/1024:.0f} KB)")

    # rewrite base = active group + unclassified shaders
    if not args.no_rewrite_base:
        new_base = list(groups[active]) + unclassified
        bak = base + f".bak-{time.strftime('%Y%m%d-%H%M%S')}"
        shutil.copy2(base, bak)
        with open(base, "w", encoding="utf-8") as f:
            json.dump(new_base, f, indent=2)
        if not args.quiet:
            print(f"[partition] base rewritten: {len(new_base)} cmds  backup={bak}")
    else:
        bak = None

    manifest = {
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "source": base,
        "base_backup": bak,
        "active": {
            "platform": active[0], "project": active[1], "config": active[2],
            "cmd_count": len(groups[active]),
        },
        "unclassified_in_base": len(unclassified),
        "groups": group_files,
        "out_dir": out_dir,
    }
    with open(manifest_path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, indent=2)
    if not args.quiet:
        print(f"[partition] manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
