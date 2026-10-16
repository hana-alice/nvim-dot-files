"""Read-only TEMP proof inventory. This tool has no deletion operation.

Reference roots must be metadata directories, never whole source trees. A proof
invocation is retained as a unit: migration re-collection needs its native run
reports and RIFF shards as well as graph JSON (clangd_receipt_migration._recollect).
Historical worker metrics.proof_directory is provenance, not a live reference.
Reclaimability describes the observed known producers only, not a future lease.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
SKIP_DIRS = {'.cache', '.git', 'graphs', 'snapshots', 'node_modules', 'Binaries',
             'Intermediate', 'Saved', 'DerivedDataCache', 'super_unity_cpps'}
PRODUCERS = ('cdb_verified_batch.py', 'cdb_background_batch.py',
             'clangd_receipt_migration.py', 'clangd_background_index.py')
OPAQUE_PREFIXES = ('graph-', 'template-proof.', 'overlay.', 'overlay.aliases.', 'aliases.', 'canonical.')


def absolute(path):
    # No resolve(): inspecting an inventory must not traverse a junction.
    return Path(os.path.abspath(os.fspath(path)))


def linked(path):
    info = path.lstat()
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, 'st_file_attributes', 0) & 0x400)


def safe_path(path):
    for parent in (path, *path.parents):
        if parent.exists() and linked(parent):
            raise ValueError('reparse-or-symbolic-link: ' + str(parent))


def process_snapshot():
    """Complete relevant process enumeration or an explicit unknown observation."""
    try:
        if os.name == 'nt':
            command = "@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -match '^(python.*|clangd.*|nvim.*)$' } | Select-Object ProcessId,Name,CommandLine) | ConvertTo-Json -Compress"
            result = subprocess.run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Command', command],
                                    capture_output=True, text=True, timeout=20)
            if result.returncode:
                raise ValueError(result.stderr.strip())
            rows = json.loads(result.stdout or '[]')
            rows = rows if isinstance(rows, list) else [rows]
            records = [{'pid': row['ProcessId'], 'name': row['Name'], 'command': row['CommandLine']}
                       for row in rows if row['ProcessId'] != os.getpid()]
        elif Path('/proc').is_dir():
            records = []
            for directory in Path('/proc').iterdir():
                if not directory.name.isdigit() or int(directory.name) == os.getpid():
                    continue
                try:
                    name = (directory / 'comm').read_text().strip()
                    if name.startswith(('python', 'clangd', 'nvim')):
                        command = (directory / 'cmdline').read_bytes().replace(b'\0', b' ').decode(errors='replace')
                        records.append({'pid': int(directory.name), 'name': name, 'command': command or None})
                except FileNotFoundError:
                    continue  # Process exited before observation.
        else:
            raise ValueError('complete-process-enumeration-unavailable')
        return {'ok': True, 'time': time.time(), 'records': records}
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        return {'ok': False, 'time': time.time(), 'reason': str(error), 'records': []}


def process_alive(pid):
    if type(pid) is not int or pid <= 0:
        return None
    if os.name == 'nt':
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False if ctypes.get_last_error() == 87 else None
        code = wintypes.DWORD()
        try:
            return code.value == 259 if kernel.GetExitCodeProcess(handle, ctypes.byref(code)) else None
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except OSError:
        return None


def inventory(work_root, reference_roots, active_roots=(), observe=process_snapshot):
    started = time.monotonic()
    work_root = absolute(work_root)
    roots = [absolute(root) for root in reference_roots]
    active_roots = [absolute(root) for root in active_roots]
    errors, links, references, historical, stores, locks = [], [], [], [], {}, []
    fingerprints, seen, pending = {}, set(), []
    before = observe()

    def store(path):
        path = absolute(path)
        bucket = hashlib.sha256(str(path).encode()).hexdigest()[:24]
        stores.setdefault(bucket, set()).add(str(path))

    def read(path):
        path = absolute(path)
        safe_path(path)
        before_stat = path.stat()
        raw = path.read_bytes()
        after_stat = path.stat()
        signature = (before_stat.st_size, before_stat.st_mtime_ns, before_stat.st_ctime_ns)
        if signature != (after_stat.st_size, after_stat.st_mtime_ns, after_stat.st_ctime_ns):
            raise ValueError('metadata-changed-during-read: ' + str(path))
        fingerprints[str(path)] = signature
        return json.loads(raw)

    def add_reference(value, source, kind):
        if not isinstance(value, str) or not value:
            errors.append({'path': str(source), 'reason': 'invalid-reference-' + kind})
            return
        path = absolute(value)
        references.append({'path': str(path), 'source': str(source), 'kind': kind})
        if (kind not in ('graph_files', 'graphs') and path.suffix == '.json'
                and path.parent.name != 'graphs' and not path.name.startswith(OPAQUE_PREFIXES)):
            # Follow only explicitly referenced proof metadata, not dependency source.
            pending.append(path)

    def record(value, source):
        if isinstance(value, list):
            for child in value:
                record(child, source)
            return
        if not isinstance(value, dict):
            return
        for field in ('store', 'legacy_store', 'output_dir'):
            if isinstance(value.get(field), str):
                store(value[field])
        for field in ('assets', 'graph_files', 'graphs', 'template_argument_proof_assets'):
            if field in value:
                if not isinstance(value[field], list):
                    errors.append({'path': str(source), 'reason': 'invalid-reference-list-' + field})
                else:
                    for item in value[field]:
                        add_reference(item.get('path') if isinstance(item, dict) else item, source, field)
        if 'migration_source' in value:
            child = value['migration_source']
            add_reference(child.get('path') if isinstance(child, dict) else child, source, 'migration_source')
        for field in ('receipts', 'receipt_paths'):
            if field in value:
                if isinstance(value[field], list):
                    for item in value[field]:
                        add_reference(item, source, 'receipt')
                else:
                    errors.append({'path': str(source), 'reason': 'invalid-receipts'})
        for field in ('receipt', 'nvim_ue_batch_receipt', 'cache_path'):
            if field in value:
                add_reference(value[field], source, field)
        if isinstance(value.get('proof_directory'), str):
            historical.append({'path': str(absolute(value['proof_directory'])), 'source': str(source)})
        for field, child in value.items():
            if field not in ('assets', 'graph_files', 'graphs', 'dependencies', 'inventories', 'watch_roots',
                             'query_profiles', 'original_entries', 'effective_entries', 'migration_source'):
                if isinstance(child, (dict, list)):
                    record(child, source)

    def walk_error(error):
        errors.append({'path': str(error.filename), 'reason': str(error)})

    for root in roots:
        try:
            safe_path(root)
            if not root.is_dir():
                raise ValueError('reference-root-not-directory')
            for current, directories, files in os.walk(root, followlinks=False, onerror=walk_error):
                for name in list(directories):
                    path = Path(current) / name
                    if linked(path):
                        links.append(str(path)); directories.remove(name)
                    elif name.endswith('.lock'):
                        locks.append(path); directories.remove(name)
                    elif name in SKIP_DIRS:
                        directories.remove(name)
                if Path(current).name in ('receipts', 'assets', 'originals'):
                    store(Path(current).parent)
                for name in files:
                    if name.endswith('.json') and not name.startswith(('compile_commands', *OPAQUE_PREFIXES)):
                        pending.append(Path(current) / name)
        except (OSError, ValueError) as error:
            errors.append({'path': str(root), 'reason': str(error)})
    while pending:
        path = pending.pop()
        key = str(path)
        if key in seen:
            continue
        seen.add(key)
        try:
            record(read(path), path)
        except (OSError, ValueError, TypeError) as error:
            errors.append({'path': key, 'reason': str(error)})

    def lock_observation():
        rows = []
        for path in locks:
            try:
                safe_path(path)
                owners = [item for item in path.iterdir() if item.name.startswith('owner') and item.suffix == '.json']
                if len(owners) != 1:
                    raise ValueError('owner-record-not-unique')
                value = json.loads(owners[0].read_bytes())
                if not isinstance(value, dict) or not isinstance(value.get('token'), str) or not value['token']:
                    raise ValueError('invalid-owner-record')
                rows.append({'path': str(path), 'pid': value.get('pid'), 'alive': process_alive(value.get('pid'))})
            except FileNotFoundError:
                continue  # Lease was released, no filesystem mutation by us.
            except (OSError, ValueError, TypeError) as error:
                rows.append({'path': str(path), 'alive': None, 'reason': str(error)})
        return rows

    owner_before = lock_observation()
    units = {}
    try:
        safe_path(work_root)
        if not work_root.is_dir():
            raise ValueError('work-root-not-directory')
        for current, directories, files in os.walk(work_root, followlinks=False, onerror=walk_error):
            for name in list(directories):
                path = Path(current) / name
                if linked(path):
                    links.append(str(path)); directories.remove(name)
            for name in files:
                path = Path(current) / name
                if linked(path):
                    links.append(str(path)); continue
                info = path.stat(follow_symlinks=False)
                parts = path.relative_to(work_root).parts
                unit = work_root.joinpath(*parts[:2]) if len(parts) > 2 else path
                row = units.setdefault(str(unit), {'path': str(unit), 'bucket': parts[0], 'logical_bytes': 0,
                                                  'files': 0, 'file_paths': []})
                row['logical_bytes'] += info.st_size
                row['files'] += 1
                row['file_paths'].append(str(path))
    except (OSError, ValueError) as error:
        errors.append({'path': str(work_root), 'reason': str(error)})
    after = observe()
    # Discover leases created since the first metadata pass as well.
    for root in roots:
        try:
            safe_path(root)
            for current, directories, _ in os.walk(root, followlinks=False, onerror=walk_error):
                for name in list(directories):
                    path = Path(current) / name
                    if linked(path) or name in SKIP_DIRS:
                        directories.remove(name)
                    elif name.endswith('.lock'):
                        if path not in locks:
                            locks.append(path)
                        directories.remove(name)
        except (OSError, ValueError) as error:
            errors.append({'path': str(root), 'reason': str(error)})
    owner_after = lock_observation()
    for path, signature in fingerprints.items():
        try:
            info = Path(path).stat()
            if signature != (info.st_size, info.st_mtime_ns, info.st_ctime_ns):
                raise ValueError('metadata-changed-during-inventory')
        except (OSError, ValueError) as error:
            errors.append({'path': path, 'reason': str(error)})
    relevant = []
    for sample in (before, after):
        for process in sample.get('records', []):
            command = process.get('command')
            if command is None or any(name in command.lower() for name in PRODUCERS):
                relevant.append(process)
    activity_known = before.get('ok') and after.get('ok') and not relevant
    owner_active = any(row['alive'] is True for row in owner_before + owner_after)
    owner_unknown = any(row['alive'] is None for row in owner_before + owner_after)

    totals = {name: {'logical_bytes': 0, 'files': 0, 'units': 0} for name in
              ('referenced', 'active', 'unreferenced_reclaimable', 'unknown')}
    def group_sources(sources):
        grouped, ancestors = {}, []
        for item in sources:
            path = Path(item['path'])
            if not path.is_relative_to(work_root):
                if work_root.is_relative_to(path):
                    ancestors.append((path, item))
                continue
            parts = path.relative_to(work_root).parts
            if len(parts) < 2:
                ancestors.append((path, item))
            else:
                key = str(work_root.joinpath(*parts[:2]))
                grouped.setdefault(key, []).append(item)
        return grouped, ancestors

    by_unit, ancestor_refs = group_sources(references)
    historical_by_unit, ancestor_history = group_sources(historical)
    for row in units.values():
        unit = Path(row['path'])
        row['references'] = by_unit.get(str(unit), []) + [ref for path, ref in ancestor_refs if unit.is_relative_to(path)]
        row['historical_sources'] = historical_by_unit.get(str(unit), []) + [ref for path, ref in ancestor_history if unit.is_relative_to(path)]
        row['stores'] = sorted(stores.get(row['bucket'], []))
        explicit_active = any(unit.is_relative_to(root) or root.is_relative_to(unit) for root in active_roots)
        if explicit_active or (row['stores'] and owner_active):
            category, reason = 'active', 'explicit-active-root-or-live-owner'
        elif row['references']:
            category, reason = 'referenced', 'receipt-cache-or-migration-reference'
        elif errors or links or not activity_known or owner_unknown or not row['stores']:
            category, reason = 'unknown', 'incomplete-reference-or-activity-evidence'
        else:
            category, reason = 'unreferenced_reclaimable', 'no-reference-and-known-producers-inactive-at-observation'
        row.update(category=category, reason=reason)
        total = totals[category]
        for field in ('logical_bytes', 'files'):
            total[field] += row[field]
        total['units'] += 1
    return {'schema': 1, 'dry_run': True, 'deletion_supported': False,
            'observed_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'work_root': str(work_root), 'reference_roots': list(map(str, roots)),
            'active_roots': list(map(str, active_roots)), 'totals': totals,
            'logical_bytes': sum(row['logical_bytes'] for row in units.values()),
            'files': sum(row['files'] for row in units.values()), 'metadata_files': len(seen),
            'units': sorted(units.values(), key=lambda row: (-row['logical_bytes'], row['path'])),
            'errors': errors, 'skipped_links': links,
            'activity': {'before': before, 'after': after, 'relevant_or_unknown_processes': relevant,
                         'owners_before': owner_before, 'owners_after': owner_after},
            'limitation': 'Point-in-time dry-run, not permission to delete. Recheck references and acquire writer leases before any later deletion. Unknown buckets are outside the supplied metadata scope.',
            'elapsed_seconds': round(time.monotonic() - started, 6)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--work-root', default=str(Path(tempfile.gettempdir()) / 'nvim-ue-batch-work'))
    parser.add_argument('--reference-root', action='append', required=True)
    parser.add_argument('--active-root', action='append', default=[])
    parser.add_argument('--out', required=True)
    args = parser.parse_args()
    output = absolute(args.out)
    safe_path(output.parent)
    if output.is_relative_to(absolute(args.work_root)) or any(output.is_relative_to(absolute(root)) for root in args.reference_root):
        parser.error('--out must be outside work and reference roots')
    if output.exists():
        parser.error('--out already exists; choose a new report path')
    result = inventory(args.work_root, args.reference_root, args.active_root)
    with output.open('x', encoding='utf-8') as stream:
        json.dump(result, stream, ensure_ascii=False, indent=2)
    print(json.dumps({'dry_run': True, 'out': str(output), 'totals': result['totals'],
                      'logical_bytes': result['logical_bytes'], 'files': result['files'],
                      'errors': len(result['errors']), 'elapsed_seconds': result['elapsed_seconds']}))
    print('inventory elapsed_seconds=' + str(result['elapsed_seconds']), file=sys.stderr)


if __name__ == '__main__':
    main()
