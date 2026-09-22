"""Describe then validate a frozen batch publication outside Neovim's UI thread."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from cdb_verified_batch import describe_receipts, validate_receipts


def _covers(parent, path):
    return parent == path or parent in path.parents


def _existing(path):
    while not path.is_dir() and path.parent != path:
        path = path.parent
    return path


def _lookup_watches(search_roots, files, recursive_roots):
    """Keep lexical ancestors so junction retargets cannot hide behind resolve()."""
    def lexical(value):
        path = Path(value)
        if not path.is_absolute():
            raise ValueError('invalid-driver-lookup-path')
        return Path(os.path.abspath(path))
    watched = {lexical(path) for path in files}
    requested = {lexical(path) for path in search_roots} | {path.parent for path in watched}
    direct = set()
    for root in requested:
        watched.add(root)
        watched.update(root.parents)
        # Existing parents observe root deletion/rename/retarget; the nearest
        # existing ancestor observes creation of the first missing component.
        for parent in (root, *root.parents):
            if parent.is_dir() and not any(_covers(base, parent) for base in recursive_roots):
                direct.add(parent)
    return sorted(direct, key=str), watched


def _norm(value):
    value = str(value or '').replace('\\', '/')
    unc = value.startswith('//')
    value = re.sub('/+', '/', value)
    if unc:
        value = '/' + value
    return value[:-1] if len(value) > 1 and value.endswith('/') else value


def normalized_cdb_digest(path):
    """Match ue.index._generation canonical_cdb_entry/stable_hash off the UI."""
    def absolute(directory, value):
        value = _norm(value)
        if value and not (value.startswith('/') or re.match(r'^[A-Za-z]:/', value)) and directory:
            return _norm(directory + '/' + value)
        return value
    canonical = []
    for entry in json.loads(path if isinstance(path, bytes) else Path(path).read_bytes()):
        directory = _norm(entry.get('directory'))
        file = absolute(directory, entry.get('file'))
        if not file:
            continue
        arguments = entry.get('arguments', [])
        if not isinstance(arguments, list) or any(not isinstance(value, str) for value in arguments):
            raise ValueError('non-structured-active-command')
        canonical.append(dict(directory=directory, file=file,
            output=absolute(directory, entry.get('output')), arguments=arguments,
            command=entry.get('command', '').strip() if isinstance(entry.get('command', ''), str) else ''))
    canonical.sort(key=lambda entry: (entry['file'], entry['directory'], '\x1f'.join(entry['arguments']),
                                      entry['command'], entry['output']))
    encoded = json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(',', ':'))
    return hashlib.sha256(encoded.encode('utf-8')).hexdigest()


def _native(entry):
    native = {field: entry[field] for field in ('file', 'directory', 'arguments')}
    if 'output' in entry:
        native['output'] = entry['output']
    return native


def _command_key(entry):
    return json.dumps(_native(entry), ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def _coverage(original_bytes, frozen_bytes, receipts):
    original = set()
    for entry in json.loads(original_bytes):
        key = _command_key(entry)
        if key in original:
            raise ValueError('duplicate-original-command')
        original.add(key)
    replacements = {}
    for receipt in receipts:
        key = _command_key(receipt['candidate'])
        if key in replacements and replacements[key] != receipt:
            raise ValueError('conflicting-batch-receipts')
        replacements[key] = receipt
        if key in original:
            raise ValueError('batch-command-aliases-original')
    covered, used = set(), set()
    for entry in json.loads(frozen_bytes):
        key = _command_key(entry)
        receipt = replacements.get(key)
        if receipt is None and key not in original:
            raise ValueError('published-command-is-not-proven')
        if receipt:
            if key in used:
                raise ValueError('published-batch-covered-more-than-once')
            used.add(key)
            if not receipt.get('original_entries'):
                raise ValueError('batch-has-no-original-commands')
        for member in receipt['original_entries'] if receipt else [entry]:
            member_key = _command_key(member)
            if member_key not in original:
                raise ValueError('batch-original-command-changed')
            if member_key in covered:
                raise ValueError('original-command-covered-more-than-once')
            covered.add(member_key)
    if covered != original or used != set(replacements):
        raise ValueError('published-batch-coverage-changed')


def activate(info_path, clangd_path, validate=False, server_profile=None):
    try:
        info_path = Path(info_path).resolve()
        info_bytes = info_path.read_bytes()
        info = json.loads(info_bytes)
        if info.get('schema') != 1 or not info.get('receipts'):
            raise ValueError('no-verified-batches')
        original = Path(info['original_cdb']).resolve()
        frozen = Path(info['verified_cdb']).resolve()
        active = Path(info['active_cdb']).resolve()
        if original == frozen or not original.is_file() or not frozen.is_file():
            raise ValueError('missing-separated-original-cdb')
        receipt_paths = [Path(path).resolve() for path in info['receipts']]
        receipt_hashes = {str(Path(path).resolve()): digest for path, digest in info['receipt_hashes'].items()}
        if set(receipt_hashes) != set(map(str, receipt_paths)):
            raise ValueError('missing-receipt-content-identities')
        result = describe_receipts(list(map(str, receipt_paths)), server_profile=server_profile)
        if not result['ok']:
            return result
        if result.get('server_profile') != server_profile:
            raise ValueError('server-profile-mismatch')
        result['input_roots'] = list(result['watch_roots'])
        result['input_roots'].extend(result.get('query_search_roots', []))
        # Compiler source policy and immutable snapshot files must be watched as
        # well as include lookup roots. Proof output directories are otherwise
        # excluded, so a concurrent proof cannot invalidate an unrelated batch.
        watched = {info_path, active, original, frozen, Path(__file__).resolve(), *receipt_paths}
        receipts = []
        tool_paths = set()
        for path in receipt_paths:
            receipt = json.loads(path.read_text(encoding='utf-8'))
            receipts.append(receipt)
            tool_path = Path(receipt['identities']['tool_path'])
            if not tool_path.is_absolute():
                raise ValueError('non-absolute-certified-clangd')
            tool_paths.add(str(tool_path))
            watched.update(Path(item['path']).resolve() for item in receipt['assets'])
            watched.add(Path(receipt['identities']['tool_path']).resolve())
            if receipt['identities'].get('binding_path'):
                watched.add(Path(receipt['identities']['binding_path']).resolve())
        if len(tool_paths) != 1:
            raise ValueError('conflicting-certified-clangd-paths')
        result['tool_path'] = next(iter(tool_paths))
        watched.update(Path(__file__).resolve().parent / name for name in (
            'cdb_verified_batch.py', 'clangd_batch_runner.py', 'clangd_index_graph.py',
            'clangd_batch_admission.py', 'clangd_batch_bindings.py', 'clangd_query_profile.py',
            'build_hot_super_unity_cdb.py'))
        roots = {Path(root).resolve() for root in result['watch_roots']}
        roots.update(Path(root).resolve() for root in result.get('query_search_roots', []))
        roots.update(path.parent for path in watched)
        bases = [Path(path).resolve() for path in info.get('watch_bases', []) if path]
        collapsed = set()
        for root in roots:
            base = next((base for base in bases if _covers(base, root)), root)
            collapsed.add(_existing(base))
        minimal = []
        for root in sorted(collapsed, key=lambda path: (len(path.parts), str(path))):
            if not any(_covers(parent, root) for parent in minimal):
                minimal.append(root)
        lookup_roots, lookup_files = _lookup_watches(result.get('query_driver_search_roots', []),
            result.get('query_driver_files', []), minimal)
        watched.update(lookup_files)
        # An ancestor rename/delete must revoke its watched descendants too.
        for path in list(watched):
            for parent in path.parents:
                if parent in minimal:
                    break
                watched.add(parent)
        result.update(watch_roots=list(map(str, minimal)), watched_files=sorted(map(str, watched)),
                      lookup_roots=list(map(str, lookup_roots)),
                      verified_cdb=str(frozen), original_cdb=str(original),
                      receipts=list(map(str, receipt_paths)), info_sha256=hashlib.sha256(info_bytes).hexdigest(),
                      generation_id=info['generation_id'])
        result['exclude_roots'] = sorted(set(result['exclude_roots']) | {
            str(frozen.parent / '.cache'), str(original.parent / '.cache'),
            str(frozen.parent.parent.parent / 'frozen-cache')})
        if validate:
            for path in receipt_paths:
                if hashlib.sha256(path.read_bytes()).hexdigest() != receipt_hashes[str(path)]:
                    raise ValueError('published-receipt-changed')
            original_bytes, frozen_bytes = original.read_bytes(), frozen.read_bytes()
            if hashlib.sha256(frozen_bytes).hexdigest() != info['verified_sha256']:
                raise ValueError('published-batch-cdb-changed')
            if hashlib.sha256(original_bytes).hexdigest() != info['original_sha256']:
                raise ValueError('published-original-cdb-changed')
            active_bytes = active.read_bytes()
            active_sha = hashlib.sha256(active_bytes).hexdigest()
            if normalized_cdb_digest(active_bytes) != info['active_digest']:
                raise ValueError('active-build-cdb-changed')
            del active_bytes
            _coverage(original_bytes, frozen_bytes, receipts)
            verdict = validate_receipts(list(map(str, receipt_paths)), clangd_path, server_profile=server_profile)
            if not verdict['ok']:
                result.update(ok=False, reason=verdict.get('reason', 'receipt-validation-failed'))
                return result
            if verdict.get('server_profile') != server_profile:
                raise ValueError('server-profile-mismatch')
            if verdict.get('compiler_environment') != result.get('compiler_environment'):
                raise ValueError('compiler-environment-changed')
            if info_path.read_bytes() != info_bytes:
                raise ValueError('publication-changed-during-validation')
            if hashlib.sha256(frozen.read_bytes()).hexdigest() != info['verified_sha256']:
                raise ValueError('published-batch-cdb-changed-during-validation')
            if hashlib.sha256(original.read_bytes()).hexdigest() != info['original_sha256']:
                raise ValueError('published-original-cdb-changed-during-validation')
            if hashlib.sha256(active.read_bytes()).hexdigest() != active_sha:
                raise ValueError('active-build-cdb-changed-during-validation')
            for path in receipt_paths:
                if hashlib.sha256(path.read_bytes()).hexdigest() != receipt_hashes[str(path)]:
                    raise ValueError('published-receipt-changed-during-validation')
            result.update(reason='publication-and-receipts-current', validation_seconds=verdict['validation_seconds'])
        return result
    except (OSError, ValueError, KeyError, TypeError) as error:
        return {'ok': False, 'reason': str(error), 'watch_roots': [], 'watched_files': []}


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--info', required=True)
    parser.add_argument('--clangd', required=True)
    parser.add_argument('--server-profile', help='Explicit caller server profile JSON; never inferred from receipts')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--describe', action='store_true')
    mode.add_argument('--validate', action='store_true')
    args = parser.parse_args()
    try:
        profile = json.loads(args.server_profile) if args.server_profile is not None else None
    except ValueError as error:
        parser.error(str(error))
    result = activate(args.info, args.clangd, validate=args.validate, server_profile=profile)
    print(json.dumps(result, ensure_ascii=True, separators=(',', ':')))
    raise SystemExit(0 if result['ok'] else 1)
