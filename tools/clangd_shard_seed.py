"""Fill a frozen clangd shard cache with shards missing from the original cache.

Frozen batch databases retain every original command byte-for-byte except the
proven batch replacements (see clangd_batch_activation._coverage). clangd 22
keys shards by source path and decides staleness only by content digest
(Background.cpp shardIsStale), so shards the original client already built are
valid inputs for the retained commands; batch TUs have new paths, get no shard
and are indexed normally. Without this, the first frozen activation re-indexes
every retained TU into its separate cache (measured: ~33k shards cold).

clangd writes shards via llvm::writeToOutput (temporary file + rename), so a
hard-linked seed never mutates the original cache: a later rewrite replaces
only the frozen directory entry. Cross-volume targets fall back to copies.
Existing target shards are never touched; only absent names are added.
"""
import argparse
import json
import os
from pathlib import Path
import shutil
import sys
import time

sys.dont_write_bytecode = True


def _shards(directory):
    with os.scandir(directory) as entries:
        return [entry for entry in entries
                if entry.name.endswith('.idx') and '.temp-stream-' not in entry.name
                and entry.is_file(follow_symlinks=False)]


def seed(source, target):
    started = time.perf_counter()
    source, target = Path(source), Path(target)
    result = {'ok': False, 'linked': 0, 'copied': 0, 'existing': 0, 'source': str(source), 'target': str(target)}
    try:
        if source.is_symlink() or not source.is_dir():
            result.update(ok=True, reason='source-cache-unavailable')
            return result
        if target.is_symlink() or not target.is_dir():
            result['reason'] = 'target-cache-unavailable'
            return result
        if os.path.samefile(source, target):
            result['reason'] = 'target-is-source'
            return result
        present = {entry.name for entry in _shards(target)}
        result['existing'] = len(present)
        link = True
        for entry in _shards(source):
            if entry.name in present:
                continue
            destination = target / entry.name
            try:
                if link:
                    try:
                        os.link(entry.path, destination)
                        result['linked'] += 1
                        continue
                    except FileExistsError:
                        raise
                    except OSError:
                        link = False  # Cross-volume or unsupported: copy the rest.
                with open(entry.path, 'rb') as reader, open(destination, 'xb') as writer:
                    try:
                        shutil.copyfileobj(reader, writer)
                    except OSError:
                        writer.close()
                        os.unlink(destination)  # Never leave a truncated shard behind.
                        raise
                result['copied'] += 1
            except FileExistsError:
                continue  # A concurrent clangd write owns this name now.
        result.update(ok=True, reason='seeded')
    except OSError as error:
        result['reason'] = 'seed-io-error'
        result['error'] = str(error)
    finally:
        result['seconds'] = round(time.perf_counter() - started, 3)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--source', required=True)
    parser.add_argument('--target', required=True)
    args = parser.parse_args()
    outcome = seed(args.source, args.target)
    print(json.dumps(outcome, ensure_ascii=True, separators=(',', ':')))
    raise SystemExit(0 if outcome['ok'] else 1)
