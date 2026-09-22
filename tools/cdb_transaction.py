"""Stage and content-aware publish a prepare CDB while its caller holds the lease.

The physical workspace is outside watched live roots. Tools receive the logical
CDB separately so compiler/PCH identities never include temporary paths. Large
copies, JSON, and hashing run in this child, never on Neovim's UI thread.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cdb_argv import normalize_cdb
from cdb_unity_receipt import entry_hash

SIDECARS = ('.unity-origin.json', '.unity-receipt.json', '.pipeline-result.json')


class RecoveryRequired(RuntimeError):
    def __init__(self, cause, recovery):
        paths = ', '.join(item['backup'] or item['destination'] for item in recovery)
        super().__init__(f'publish failed: {cause}; rollback incomplete; recovery files retained: {paths}')
        self.recovery = recovery


def read_json(path):
    with open(path, encoding='utf-8-sig') as stream:
        return json.load(stream)


def digest(path):
    entries = read_json(path)
    if not isinstance(entries, list) or not entries:
        raise ValueError('final CDB must be a nonempty array')
    entries, _ = normalize_cdb(entries)
    return hashlib.sha256(''.join(sorted(entry_hash(row) for row in entries))
                          .encode('ascii')).hexdigest()


def payload(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True) + '\n').encode('utf-8')


def prepare(config):
    stage, active = Path(config['stage']), Path(config['active'])
    # No hardlinks: pipeline tools may mutate their physical input in place.
    for suffix in ('',) + SIDECARS:
        source = Path(str(active) + suffix)
        if source.is_file():
            shutil.copy2(source, str(stage) + suffix)
    source = Path(config['shards'])
    if source.is_dir():
        shutil.copytree(source, config['stage_shards'], dirs_exist_ok=True)
    return {'ok': True}


def equivalent_json(path, value, ignored=()):
    try:
        old = read_json(path)
    except (OSError, ValueError):
        return False
    if ignored and isinstance(old, dict) and isinstance(value, dict):
        old, value = dict(old), dict(value)
        for field in ignored:
            old.pop(field, None)
            value.pop(field, None)
    return old == value


def commit(config):
    stage, active = Path(config['stage']), Path(config['active'])
    final_digest = digest(stage)
    try:
        previous_digest = digest(active)
    except (OSError, ValueError, TypeError):
        previous_digest = None
    changed = final_digest != previous_digest
    replacements = []

    def add_file(source, destination, json_value=None, ignored=()):
        source, destination = Path(source), Path(destination)
        if json_value is not None:
            if equivalent_json(destination, json_value, ignored):
                return
            replacements.append((None, destination, payload(json_value)))
        elif source.is_file():
            # JSON key order and formatting are not reasons to rewrite evidence.
            if source.suffix == '.json' and equivalent_json(destination, read_json(source)):
                return
            if source.suffix != '.json' and destination.is_file() and source.read_bytes() == destination.read_bytes():
                return
            replacements.append((source, destination, None))

    for suffix in SIDECARS[:2]:
        source = Path(str(stage) + suffix)
        if source.is_file():
            add_file(source, str(active) + suffix)
    # Do not oscillate a persisted changed flag on identical final commands.
    result_path = str(active) + SIDECARS[2]
    add_file(stage, result_path, {'schema': 1, 'digest': final_digest, 'changed': changed}, ('changed',))

    stage_shards, shards = Path(config['stage_shards']), Path(config['shards'])
    if stage_shards.is_dir():
        for source in sorted(stage_shards.glob('*.json')):
            value = read_json(source)
            destination = shards / source.name
            if source.name == 'manifest.json':
                # Timestamps describe changed shard bytes, not the prepare run.
                try:
                    old = read_json(destination)
                except (OSError, ValueError):
                    old = {}
                for name, metadata in value.get('shards', {}).items():
                    previous = old.get('shards', {}).get(name, {})
                    # Source roots are a set collected from Lua pairs(). Keep
                    # historical ordering when only process hash order changed.
                    if sorted(metadata.get('source_roots', [])) == sorted(previous.get('source_roots', [])):
                        metadata['source_roots'] = previous.get('source_roots', [])
                    if equivalent_json(shards / (name + '.json'), read_json(stage_shards / (name + '.json'))):
                        for field in ('mtime', 'updated_at'):
                            if field in previous:
                                metadata[field] = previous[field]
                add_file(source, destination, value)
            else:
                add_file(source, destination)

    stage_manifest = Path(config['stage_manifest'])
    if stage_manifest.is_file():
        manifest = read_json(stage_manifest)
        manifest['source'] = str(active)
        # The staged pre-partition backup is an implementation detail, not a
        # durable public artifact; never publish a path removed at cleanup.
        manifest.pop('base_backup', None)
        if 'out_dir' in manifest:
            manifest['out_dir'] = config['partition_dir']
        for group in manifest.get('groups', []):
            source = Path(group['file'])
            destination = Path(config['partition_dir']) / source.name
            add_file(source, destination)
            group['file'] = str(destination)
        add_file(stage_manifest, config['manifest'], manifest, ('generated_at', 'base_backup'))

    # PCH recipes contain logical published paths, but are generated physically
    # outside all live watcher roots. Unchanged recipes do not emit live events.
    if config.get('stage_pch'):
        for source in sorted(Path(config['stage_pch']).glob('*')):
            if source.is_file() and (source.suffix == '.rsp' or source.name.endswith('.stub.cpp')
                                     or source.name == 'build_pch.bat'):
                add_file(source, Path(config['pch_dir']) / source.name)

    # Evidence and auxiliary shards first; the active command database is the
    # final commit point. Readers observing a partial pair fail closed.
    for target in config['targets']:
        try:
            same = digest(target) == final_digest
        except (OSError, ValueError, TypeError):
            same = False
        if not same:
            replacements.append((stage, Path(target), None))

    prepared, published, recovery = [], [], []
    try:
        for source, destination, data in replacements:
            destination.parent.mkdir(parents=True, exist_ok=True)
            fd, temporary = tempfile.mkstemp(prefix='.cdb-commit-', dir=destination.parent)
            os.close(fd)
            backup = None
            if data is None:
                shutil.copy2(source, temporary)
            else:
                Path(temporary).write_bytes(data)
            if destination.exists():
                fd, backup = tempfile.mkstemp(prefix='.cdb-rollback-', dir=destination.parent)
                os.close(fd)
                shutil.copy2(destination, backup)
            prepared.append((temporary, destination, backup))
        for temporary, destination, backup in prepared:
            os.replace(temporary, destination)
            published.append((destination, backup))
    except BaseException as error:
        for destination, backup in reversed(published):
            try:
                if backup:
                    os.replace(backup, destination)
                else:
                    destination.unlink(missing_ok=True)
            except OSError as restore_error:
                recovery.append({'destination': str(destination), 'backup': backup, 'reason': str(restore_error)})
        if recovery:
            raise RecoveryRequired(error, recovery) from error
        raise
    finally:
        for temporary, _, backup in prepared:
            Path(temporary).unlink(missing_ok=True)
            if backup and not any(item['backup'] == backup for item in recovery):
                Path(backup).unlink(missing_ok=True)
    result = {'ok': True, 'changed': changed, 'digest': final_digest,
              'published': [str(destination) for _, destination, _ in prepared]}
    # Migration belongs after the real commit point, outside rollback. Its
    # durable backup/marker remains available if this post-commit repair fails.
    if config.get('header_path_case_cache_dir'):
        try:
            sys.path.insert(0, str(Path(__file__).absolute().parents[1] / 'lua/workarounds/clangd'))
            from header_path_case_cache import migrate
            result['cache_migration'] = migrate(active, config['semantic_cdb'], config['header_path_case_cache_dir'])
            if result['cache_migration'].get('deferred'):
                result.update(ok=False, committed=True,
                              reason='CDB committed; header cache migration deferred: ' + result['cache_migration']['reason'])
        except Exception as error:
            result.update(ok=False, committed=True,
                          reason='CDB committed; header cache migration failed: ' + str(error),
                          cache_migration={'ok': False, 'manifest': getattr(error, 'manifest', None)})
    return result


def cleanup(config):
    stage, work = Path(config['stage']).resolve(), Path(config['work']).resolve()
    # The owner names both paths. Refuse broad removal or a foreign directory.
    active = Path(config['active']).resolve()
    if (stage.parent != work or stage.name != 'compile_commands.json'
            or not work.name.endswith('-ue-cdb-prepare') or active.is_relative_to(work)
            or Path(config['config']).resolve() != work / 'transaction.json'):
        raise ValueError('invalid owned transaction paths')
    if work.is_dir():
        shutil.rmtree(work)
    return {'ok': True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'commit', 'cleanup'))
    parser.add_argument('config')
    args = parser.parse_args()
    try:
        config = read_json(args.config)
        result = globals()[args.operation](config)
    except Exception as error:
        print(json.dumps({'ok': False, 'reason': str(error), 'recovery': getattr(error, 'recovery', [])}))
        return 1
    print(json.dumps(result))
    return 0 if result.get('ok') else 1


if __name__ == '__main__':
    raise SystemExit(main())
