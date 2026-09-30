"""Carry compiler-authored unity evidence through a successful CDB pipeline.

``begin`` admits only origins (or previously sealed receipts) matching the
current exact commands. ``seal`` records the successful pipeline's commands
without changing its original compiler dependencies. The caller owns the
writer lease and a unique pending path, and must never seal a failed pipeline.
Consumers still check complete unity membership and equal member contexts.
"""
import argparse
import hashlib
import json
import os
import sys
import tempfile


def canonical_path(path):
    return os.path.normcase(os.path.normpath(path))


def entry_hash(entry):
    """Hash UTF-8 byte-length framed cwd/source/argv; ignore output metadata."""
    if not isinstance(entry, dict):
        raise ValueError('compile entry must be an object')
    arguments = entry.get('arguments')
    if not isinstance(arguments, list) or not arguments:
        raise ValueError('compile entry must have nonempty arguments')
    fields = [entry.get('directory'), entry.get('file')] + arguments
    if any(not isinstance(value, str) or '\0' in value for value in fields):
        raise ValueError('compile entry fields must be strings without NUL')
    if not fields[0] or not fields[1] or not arguments[0]:
        raise ValueError('compile entry must identify cwd, source and compiler')
    framed = b''.join(str(len(value.encode('utf-8'))).encode('ascii') + b':'
                      + value.encode('utf-8') for value in fields)
    return hashlib.sha256(framed).hexdigest()


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('duplicate JSON object key')
        result[key] = value
    return result


def _read_json(path):
    with open(path, encoding='utf-8-sig') as stream:
        return json.load(stream, object_pairs_hook=_unique_object)


def _document(path):
    data = _read_json(path)
    if (not isinstance(data, dict) or type(data.get('schema')) is not int
            or data['schema'] != 1 or not isinstance(data.get('groups'), list)):
        raise ValueError('expected a schema 1 unity receipt')
    return data


def _absolute_path(path):
    return isinstance(path, str) and '\0' not in path and os.path.isabs(path)


def _digest(value):
    return (isinstance(value, str) and len(value) == 64
            and all(char in '0123456789abcdef' for char in value))


def _path_hashes(value):
    if not isinstance(value, dict) or not value:
        return None
    result = {}
    for path, digest in value.items():
        if not _absolute_path(path) or not _digest(digest):
            return None
        key = canonical_path(path)
        if key in result:
            return None
        result[key] = (path, digest)
    return result


def _commands(cdb, shader_commands=None):
    if isinstance(cdb, (str, os.PathLike)):
        cdb = _read_json(cdb)
    if not isinstance(cdb, list):
        raise ValueError('compile database must be an array')
    commands = {}
    for entry in cdb:
        if not isinstance(entry, dict):
            continue
        directory, source = entry.get('directory'), entry.get('file')
        if (not _absolute_path(directory) or not isinstance(source, str)
                or not source or '\0' in source):
            continue
        key = canonical_path(os.path.join(directory, source))
        if key in commands:
            commands[key] = None  # Ambiguous, even if both commands are identical.
            if shader_commands is not None:
                shader_commands.pop(key, None)
            continue
        try:
            commands[key] = entry_hash(entry)
            if shader_commands is not None:
                shader_commands[key] = {'file': os.path.join(directory, source),
                                        'directory': directory, 'command_hash': commands[key]}
        except (ValueError, UnicodeError):
            commands[key] = None
    return commands


def _shader_records(document):
    records = document.get('synthetic_shaders', [])
    if not isinstance(records, list):
        return {}
    result, seen = {}, set()
    for record in records:
        if (not isinstance(record, dict) or not _absolute_path(record.get('file'))
                or not _absolute_path(record.get('directory')) or not _digest(record.get('command_hash'))):
            return {}
        key = canonical_path(record['file'])
        if key in seen:
            return {}  # Conflicting or repeated provenance is not exclusion authority.
        seen.add(key)
        result[key] = record
    return result


def _verified_synthetic_shaders(document, shader_commands, match_commands=True):
    verified = {}
    for key, record in _shader_records(document).items():
        actual = shader_commands.get(key)
        if actual is None:
            continue
        if match_commands and (record['command_hash'] != actual['command_hash']
                               or record['directory'] != actual['directory']):
            continue
        verified[key] = actual
    return verified


def load_verified_synthetic_shaders(receipt_path, cdb):
    """Return exact final entry hashes of proven augmentation inserts only.

    Missing/legacy/corrupt provenance and ambiguous or modified commands never
    authorize removing a C++ background-index input. No suffix heuristics.
    """
    try:
        document = _document(receipt_path)
        if not _shader_records(document):
            return set()
        identities = {}
        _commands(cdb, identities)
        verified = _verified_synthetic_shaders(document, identities)
        return {record['command_hash'] for record in verified.values()}
    except (OSError, TypeError, ValueError, UnicodeError, RecursionError):
        return set()


def _verified_groups(document, commands, dependency_cache, match_commands=True):
    groups = {}
    seen_unities = set()
    for group in document['groups']:
        if not isinstance(group, dict) or not _absolute_path(group.get('unity')):
            continue
        unity_key = canonical_path(group['unity'])
        if unity_key in seen_unities:
            groups.pop(unity_key, None)
            continue
        seen_unities.add(unity_key)
        members = group.get('members')
        if not isinstance(members, list) or not members or not all(map(_absolute_path, members)):
            continue
        member_keys = [canonical_path(member) for member in members]
        if len(set(member_keys)) != len(member_keys):
            continue
        expected = _path_hashes(group.get('commands'))
        dependencies = _path_hashes(group.get('dependencies'))
        if (expected is None or set(expected) != set(member_keys)
                or dependencies is None or unity_key not in dependencies):
            continue
        if any(commands.get(key) is None for key in member_keys):
            continue
        if match_commands and any(commands[key] != expected[key][1] for key in member_keys):
            continue
        valid = True
        for key, (path, digest) in dependencies.items():
            if key not in dependency_cache:
                try:
                    with open(path, 'rb') as stream:
                        dependency_cache[key] = hashlib.sha256(stream.read()).hexdigest()
                except OSError:
                    dependency_cache[key] = None
            if dependency_cache[key] != digest:
                valid = False
                break
        if valid:
            groups[unity_key] = {
                'unity': group['unity'],
                'members': list(members),
                'dependencies': dict(group['dependencies']),
                'commands': {member: commands[key] for member, key in zip(members, member_keys)},
            }
    return groups


def load_verified_groups(receipt_path, cdb):
    """Return only groups with current exact commands and byte-level evidence."""
    try:
        return _verified_groups(_document(receipt_path), _commands(cdb), {})
    except (OSError, TypeError, ValueError, UnicodeError, RecursionError):
        return {}


def _write_if_changed(path, groups, synthetic_shaders=None):
    document = {'schema': 1, 'groups': [groups[key] for key in sorted(groups)]}
    if synthetic_shaders:
        document['synthetic_shaders'] = [synthetic_shaders[key] for key in sorted(synthetic_shaders)]
    payload = json.dumps(document,
                         ensure_ascii=False, sort_keys=True, indent=2).encode('utf-8') + b'\n'
    try:
        with open(path, 'rb') as stream:
            if stream.read() == payload:
                return False
    except FileNotFoundError:
        pass
    directory = os.path.dirname(os.path.abspath(path))
    handle, temporary = tempfile.mkstemp(prefix='.unity-receipt-', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(handle, 'wb') as stream:
            stream.write(payload)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return True


def begin(cdb_path, pending_path):
    identities = {}
    commands = _commands(cdb_path, identities)
    groups, dependency_cache, synthetic_shaders = {}, {}, {}
    origin_path = cdb_path + '.unity-origin.json'
    # A fresh producer's empty list is negative provenance: an original/native
    # command must not inherit an earlier donor label just because argv agrees.
    allowed = None
    if os.path.exists(origin_path):
        try:
            allowed = set(_shader_records(_document(origin_path)))
        except (OSError, ValueError, UnicodeError, RecursionError):
            allowed = set()
    # A matching sealed receipt can carry a previous successful transformation.
    # Neither source is allowed to bless arbitrary edits to the active command.
    for suffix in ('.unity-receipt.json', '.unity-origin.json'):
        try:
            document = _document(cdb_path + suffix)
            verified = _verified_groups(document, commands, dependency_cache)
            groups.update(verified)
            synthetic_shaders.update({key: record for key, record in
                                      _verified_synthetic_shaders(document, identities).items()
                                      if allowed is None or key in allowed})
        except (OSError, ValueError, UnicodeError, RecursionError):
            continue
    _write_if_changed(pending_path, groups, synthetic_shaders)
    return len(groups)


def seal(cdb_path, pending_path):
    # A missing or malformed pending file is not pipeline authorization.
    pending = _document(pending_path)
    identities = {}
    groups = _verified_groups(pending, _commands(cdb_path, identities), {}, match_commands=False)
    synthetic_shaders = _verified_synthetic_shaders(pending, identities, match_commands=False)
    _write_if_changed(cdb_path + '.unity-receipt.json', groups, synthetic_shaders)
    return len(groups)


def complete(cdb_path):
    """Compare successful final commands, independent of row/JSON key order."""
    cdb = _read_json(cdb_path)
    if not isinstance(cdb, list) or any(not isinstance(entry, dict) for entry in cdb):
        raise ValueError('compile database must be an array of objects')
    tools_dir = os.path.dirname(os.path.abspath(__file__))
    if tools_dir not in sys.path:
        sys.path.insert(0, tools_dir)
    from cdb_argv import normalize_cdb
    cdb, _ = normalize_cdb(cdb)
    # Fixed-width entry hashes retain duplicates while ignoring row order.
    digest = hashlib.sha256(''.join(sorted(entry_hash(entry) for entry in cdb))
                            .encode('ascii')).hexdigest()
    result_path = cdb_path + '.pipeline-result.json'
    try:
        previous = _read_json(result_path)
    except (OSError, ValueError, UnicodeError, RecursionError):
        previous = None
    unchanged = (isinstance(previous, dict) and type(previous.get('schema')) is int
                 and previous['schema'] == 1 and previous.get('digest') == digest)
    result = {'schema': 1, 'digest': digest, 'changed': not unchanged}
    if previous == result:
        return result
    payload = json.dumps(result, sort_keys=True).encode('utf-8') + b'\n'
    directory = os.path.dirname(os.path.abspath(result_path))
    handle, temporary = tempfile.mkstemp(prefix='.pipeline-result-', suffix='.tmp', dir=directory)
    try:
        with os.fdopen(handle, 'wb') as stream:
            stream.write(payload)
        os.replace(temporary, result_path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('begin', 'seal', 'complete'))
    parser.add_argument('cdb')
    parser.add_argument('pending', nargs='?')
    args = parser.parse_args()
    if args.operation != 'complete' and not args.pending:
        parser.error('begin/seal require the pending receipt path')
    try:
        if args.operation == 'complete':
            result = complete(args.cdb)
        else:
            count = (begin if args.operation == 'begin' else seal)(args.cdb, args.pending)
    except (OSError, ValueError, UnicodeError, RecursionError) as error:
        print(f'unity receipt {args.operation} failed: {error}', file=sys.stderr)
        return 1
    if args.operation == 'complete':
        print('pipeline complete: ' + json.dumps(result, sort_keys=True))
    else:
        print(f'unity receipt {args.operation}: {count} verified groups')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
