#!/usr/bin/env python3
"""
resolve_cdb_paths.py - Resolve relative -I paths to absolute in compile_commands.json

ROOT CAUSE: When PCH files are precompiled with absolute -I paths (via prebuild_pch_v2.py),
but compile_commands.json contains relative -I paths, clang cannot match the PCH's
included headers with the CDB's include search paths. This causes clang to re-parse
ALL headers from scratch instead of reusing the PCH cache.

IMPACT: Preamble build time drops from 12-15s to 0.03-2.4s per file (5-400x speedup).
PCH cache hit rate goes from 0% to near 100%.

Must run AFTER slim + pch steps, BEFORE or AFTER unify/prune.

Usage:
    python resolve_cdb_paths.py <PROJ_DRIVE>/UEProj/Engine/compile_commands.json

The script modifies compile_commands.json in-place. Skips write if no changes needed.
"""

import json
import os
import sys
import time


def resolve_paths(cdb_path: str) -> dict:
    """Resolve relative -I/-isystem paths to absolute in CDB entries.
    
    Returns dict with stats: {total, resolved, skipped, unchanged}
    """
    cdb_path = os.path.abspath(cdb_path)
    
    with open(cdb_path, 'r', encoding='utf-8') as f:
        data = json.load(f)
    
    total_resolved = 0
    total_entries = len(data)
    unchanged_entries = 0
    
    for entry in data:
        directory = entry.get('directory', '')
        if not directory:
            unchanged_entries += 1
            continue
        
        args = entry.get('arguments', [])
        if not args:
            unchanged_entries += 1
            continue
        
        modified = False
        new_args = list(args)
        
        i = 0
        while i < len(new_args):
            arg = new_args[i]
            
            # Handle -I<path> (combined form)
            if arg.startswith('-I') and len(arg) > 2 and arg != '-include-pch' and arg != '-include':
                rel_path = arg[2:]
                if not os.path.isabs(rel_path) and not rel_path.startswith('D:') and not rel_path.startswith('C:'):
                    abs_path = os.path.normpath(os.path.join(directory, rel_path)).replace('\\', '/')
                    new_args[i] = f'-I{abs_path}'
                    total_resolved += 1
                    modified = True
            
            # Handle -I <path> (separate form)
            elif arg == '-I' and i + 1 < len(new_args):
                next_arg = new_args[i + 1]
                if not os.path.isabs(next_arg) and not next_arg.startswith('D:') and not next_arg.startswith('C:'):
                    abs_path = os.path.normpath(os.path.join(directory, next_arg)).replace('\\', '/')
                    new_args[i + 1] = abs_path
                    total_resolved += 1
                    modified = True
                i += 1  # skip the path argument
            
            # Handle -isystem <path> (always separate form in our CDBs)
            elif arg == '-isystem' and i + 1 < len(new_args):
                next_arg = new_args[i + 1].strip('"')
                if not os.path.isabs(next_arg) and not next_arg.startswith('D:') and not next_arg.startswith('C:'):
                    abs_path = os.path.normpath(os.path.join(directory, next_arg)).replace('\\', '/')
                    new_args[i + 1] = abs_path
                    total_resolved += 1
                    modified = True
                i += 1  # skip the path argument
            
            # Handle -iquote <path>
            elif arg == '-iquote' and i + 1 < len(new_args):
                next_arg = new_args[i + 1]
                if not os.path.isabs(next_arg) and not next_arg.startswith('D:') and not next_arg.startswith('C:'):
                    abs_path = os.path.normpath(os.path.join(directory, next_arg)).replace('\\', '/')
                    new_args[i + 1] = abs_path
                    total_resolved += 1
                    modified = True
                i += 1
            
            i += 1
        
        if modified:
            entry['arguments'] = new_args
        else:
            unchanged_entries += 1
    
    stats = {
        'total': total_entries,
        'resolved': total_resolved,
        'unchanged': unchanged_entries,
    }
    
    if total_resolved == 0:
        print(f"resolve_cdb_paths: no relative paths found, skipping write")
        return stats
    
    # Write back
    with open(cdb_path, 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
    
    print(f"resolve_cdb_paths: resolved {total_resolved} relative paths "
          f"across {total_entries - unchanged_entries} entries "
          f"({unchanged_entries} unchanged)")
    
    return stats


def main():
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <compile_commands.json>")
        sys.exit(1)
    
    cdb_path = sys.argv[1]
    if not os.path.exists(cdb_path):
        print(f"Error: {cdb_path} not found")
        sys.exit(1)
    
    t0 = time.time()
    stats = resolve_paths(cdb_path)
    elapsed = time.time() - t0
    
    print(f"  Time: {elapsed:.1f}s")
    print(f"  Entries: {stats['total']}")
    print(f"  Paths resolved: {stats['resolved']}")


if __name__ == '__main__':
    main()
