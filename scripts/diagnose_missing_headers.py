"""
Diagnose: for each missing header, find which -I dir would contain it.
Compare pre-prune (baseline) vs post-prune CDB to see if prune wrongly stripped them.
"""
import json
import os
import re
import sys

BASELINE = r'<PROJ_DRIVE>\UnrealEngine\compile_commands.pre-prune.bak'
PRUNED = r'<PROJ_DRIVE>\UnrealEngine\compile_commands.json'
LOG = r'<PROJ_DRIVE>\UnrealEngine\smoke100.indexer.log'

# Parse missing header names from log
missing_set = set()
re_miss = re.compile(r"'([^']+\.h)' file not found")
with open(LOG, 'r', encoding='utf-8', errors='replace') as f:
    for line in f:
        m = re_miss.search(line)
        if m:
            missing_set.add(m.group(1).replace('\\', '/'))

print(f"Missing unique: {len(missing_set)}")

# Index baseline -I dirs as a flat set
def i_dirs(args):
    out = set()
    i = 0
    while i < len(args):
        if args[i] == '-I' and i + 1 < len(args):
            out.add(args[i + 1].replace('\\', '/'))
            i += 2
        elif args[i].startswith('-I') and len(args[i]) > 2:
            out.add(args[i][2:].replace('\\', '/'))
            i += 1
        else:
            i += 1
    return out

print("\nLoading pre-prune baseline (this is large)...")
with open(BASELINE, 'r', encoding='utf-8') as f:
    baseline = json.load(f)
print(f"  entries: {len(baseline)}")
baseline_dirs = set()
for e in baseline:
    baseline_dirs.update(i_dirs(e.get('arguments') or []))
print(f"  unique -I dirs: {len(baseline_dirs)}")

print("\nLoading pruned CDB...")
with open(PRUNED, 'r', encoding='utf-8') as f:
    pruned = json.load(f)
pruned_dirs = set()
for e in pruned:
    pruned_dirs.update(i_dirs(e.get('arguments') or []))
print(f"  unique -I dirs after prune: {len(pruned_dirs)}")

# For each missing header, look for it in baseline_dirs
print("\n=== Header location lookup (baseline) ===")
prune_victims = []
truly_missing = []
for h in sorted(missing_set):
    # Try to find a baseline dir where dir/h exists on disk
    found_in = []
    for d in baseline_dirs:
        candidate = os.path.normpath(os.path.join(d, h))
        if os.path.isfile(candidate):
            found_in.append(d)
            if len(found_in) >= 3:
                break
    if found_in:
        # Check if pruned still has any
        kept = [d for d in found_in if d.replace('\\', '/') in pruned_dirs]
        if kept:
            print(f"  [STILL OK] {h}: kept {kept[0]}")
        else:
            prune_victims.append((h, found_in[0]))
            print(f"  [PRUNE VICTIM] {h}: was in {found_in[0]}, all stripped")
    else:
        truly_missing.append(h)

print(f"\n=== Summary ===")
print(f"  Missing total: {len(missing_set)}")
print(f"  Prune victims (dir existed but stripped): {len(prune_victims)}")
print(f"  Truly missing (dir not in any baseline -I): {len(truly_missing)}")
print(f"\nFirst 10 truly-missing:")
for h in truly_missing[:10]:
    print(f"  {h}")

# Aggregate prune victims by parent dir patterns
print("\n=== Prune victim dir patterns ===")
victim_dirs = {}
for h, d in prune_victims:
    victim_dirs.setdefault(d, []).append(h)
for d, hs in sorted(victim_dirs.items(), key=lambda kv: -len(kv[1])):
    print(f"  {d}: {len(hs)} headers")
    for h in hs[:3]:
        print(f"      {h}")
    if len(hs) > 3:
        print(f"      ... and {len(hs)-3} more")
