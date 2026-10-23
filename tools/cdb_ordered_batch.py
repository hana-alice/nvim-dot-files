"""Explicit generated-only ordered recipe for strict original-TU qualification.

This module constructs candidates and stores bounded graphs. It never grants
admission, changes Tier 1 discovery, or issues a receipt by itself.
"""
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import stat
import tempfile

import cdb_ordered_unity as ordered

RECIPE = 'ordered-generated-original-tu-union-v1'
GRAPH_FORMAT = 'canonical-json-gzip-v1'
_OVERLAY_TOKEN = '-nvim-owned-overlay-operand'
_CODE_FILES = ('cdb_ordered_batch.py', 'cdb_ordered_unity.py')
_MiB = 1024 * 1024


def _require(condition, reason):
    if not condition:
        raise ValueError(reason)


def _stamp(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def _sha(raw):
    return hashlib.sha256(raw).hexdigest()


def code_assets():
    """Recipe-local identities, in addition to the shared strict policy identity."""
    result = []
    for name in _CODE_FILES:
        path = Path(__file__).resolve().parent / name
        before = path.stat()
        _require(before.st_size <= _MiB, 'ordered-recipe-code-size')
        raw = path.read_bytes()
        _require(_stamp(before) == _stamp(path.stat()), 'ordered-recipe-code-drift')
        result.append({'path': str(path), 'sha256': _sha(raw)})
    return result


def descriptor(recipe):
    _require(recipe == RECIPE, 'unsupported-strict-recipe')
    current = code_assets()
    _require(current == _IMPORTED_RECIPE_ASSETS, 'ordered-recipe-code-changed-since-import')
    return {'name': RECIPE, 'code_assets': current}


def validate_group(entries, indexes, max_group, max_sources, verified):
    """Validate explicit whole owners without weakening the ordinary group gate."""
    _require(type(max_group) is int and max_group >= 2 and type(max_sources) is int
             and max_sources > 0, 'ordered-group-limits-invalid')
    _require(isinstance(entries, (list, tuple)) and isinstance(indexes, (list, tuple))
             and 2 <= len(indexes) <= max_group
             and all(type(i) is int and 0 <= i < len(entries) for i in indexes)
             and list(indexes) == sorted(set(indexes)), 'ordered-group-indexes-invalid')
    group = [entries[i] for i in indexes]
    _require(all(isinstance(entry, dict) and verified._is_ubt(entry)
                 and isinstance(entry.get('arguments'), list) and entry['arguments']
                 and all(isinstance(arg, str) and arg for arg in entry['arguments'])
                 and all(isinstance(entry.get(k), str) and os.path.isabs(entry[k])
                         for k in ('file', 'directory')) for entry in group),
             'ordered-original-ubt-required')
    _require(len({ordered._key(entry['file']) for entry in group}) == len(group),
             'ordered-original-path-collision')
    membership, keys, physical = {}, set(), set()
    with verified.tier1_overlay_scope():
        for entry in group:
            members = verified._validate_ubt(entry)
            _require(members and all(path.lower().endswith('.gen.cpp') for path in members),
                     'ordered-generated-only-required')
            for path in members:
                key = ordered._key(path)
                info = Path(path).stat()
                ident = (info.st_dev, info.st_ino)
                _require(stat.S_ISREG(info.st_mode) and info.st_ino != 0,
                         'ordered-member-physical-identity-required')
                _require(key not in keys and ident not in physical,
                         'ordered-member-overlap-or-alias')
                keys.add(key)
                physical.add(ident)
            membership[entry['file']] = members
    _require(len(keys) <= max_sources, 'ordered-member-budget-exceeded')
    return list(indexes), membership


def owned_overlay(group, verified):
    """Accept only the same currently validated literal two-token owned overlay."""
    literal = None
    for entry in group:
        args = entry['arguments']
        positions = [i for i, arg in enumerate(args) if arg == '-ivfsoverlay']
        _require(not any(arg.startswith('-ivfsoverlay=') for arg in args),
                 'ordered-joined-overlay-rejected')
        if not positions:
            _require(literal is None, 'ordered-overlay-context-mismatch')
            continue
        _require(len(positions) == 1, 'ordered-one-overlay-required')
        i = positions[0]
        _require(i > 0 and i + 1 < len(args) and os.path.isabs(args[i + 1])
                 and args[i - 1] not in ('-Xclang', '-Xpreprocessor'),
                 'ordered-overlay-operand-invalid')
        _require(literal is None or literal == args[i + 1], 'ordered-overlay-context-mismatch')
        literal = args[i + 1]
    if literal is None:
        return None
    _require(all('-ivfsoverlay' in entry['arguments'] for entry in group),
             'ordered-overlay-context-mismatch')
    before = Path(literal).stat()
    with verified.tier1_overlay_scope():
        overlays = verified._owned_overlays(group[0])
    _require(_stamp(before) == _stamp(Path(literal).stat()) and len(overlays) == 1
             and overlays[0]['mapping'] and Path(overlays[0]['path']).resolve() == Path(literal).resolve(),
             'ordered-owned-overlay-validation-failed')
    return {'path': literal, 'sha256': overlays[0]['sha256']}


def parse_entry(entry, overlay):
    """Preserve the exact owned flag/operand while reusing the ordered parser."""
    if overlay is None:
        return ordered._parse(entry)
    args = list(entry['arguments'])
    positions = [i for i, arg in enumerate(args) if arg == '-ivfsoverlay']
    _require(len(positions) == 1 and not any(arg.startswith('-ivfsoverlay=') for arg in args)
             and _OVERLAY_TOKEN not in args, 'ordered-overlay-parser-shape')
    i = positions[0]
    _require(i > 0 and i + 1 < len(args) and args[i + 1] == overlay['path']
             and args[i - 1] not in ('-Xclang', '-Xpreprocessor'), 'ordered-overlay-parser-binding')
    args[i] = _OVERLAY_TOKEN
    common, search, definitions = ordered._parse(dict(entry, arguments=args))
    _require(common.count(_OVERLAY_TOKEN) == 1, 'ordered-overlay-parser-lost-flag')
    position = common.index(_OVERLAY_TOKEN)
    _require(common[position + 1] == overlay['path'], 'ordered-overlay-parser-moved-operand')
    common[position] = '-ivfsoverlay'
    return common, search, definitions


def prepare(group, directory, verified, *, max_group=8, max_sources=80):
    """Construct one explicit candidate; strict proof still owns all admission."""
    _, membership = validate_group(group, list(range(len(group))), max_group, max_sources, verified)
    overlay = owned_overlay(group, verified)
    result = ordered.build_candidates(group, membership, directory, max_originals=max_group,
        max_sources=max_sources, parse_entry=lambda entry: parse_entry(entry, overlay))
    _require(not result['rejections'] and not result['retained_entries']
             and len(result['candidates']) == len(result['groups']) == 1,
             'ordered-recipe-incompatible-group')
    built = result['groups'][0]
    _require(built['original_entries'] == group and built['original_indexes'] == list(range(len(group)))
             and built['members'] == [p for entry in group for p in membership[entry['file']]],
             'ordered-whole-owner-construction-changed')
    candidate = result['candidates'][0]
    path = Path(candidate['file'])
    _require(path.stat().st_size <= 8 * _MiB, 'ordered-body-size-limit')
    raw = path.read_bytes()
    return {'recipe': descriptor(RECIPE), 'candidate': candidate, 'body': raw.decode('utf-8'),
            'body_sha256': _sha(raw), 'original_entries': group, 'membership': membership,
            'definitions': built['definitions'], 'definition_sha256': built['definition_sha256'],
            'owned_overlay': overlay, 'admitted': False}


def validate_prepared(prepared, group):
    _require(prepared.get('recipe') == descriptor(RECIPE) and prepared.get('original_entries') == group
             and prepared.get('admitted') is False, 'ordered-prepared-identity-changed')
    raw = prepared['body'].encode('utf-8')
    _require(_sha(raw) == prepared['body_sha256']
             and Path(prepared['candidate']['file']).read_bytes() == raw,
             'ordered-prepared-body-changed')
    _require(all(_sha(Path(path).read_bytes()) == digest
                 for path, digest in prepared['definition_sha256'].items()),
             'ordered-prepared-definitions-changed')
    overlay = prepared.get('owned_overlay')
    _require(overlay is None or _sha(Path(overlay['path']).read_bytes()) == overlay['sha256'],
             'ordered-prepared-overlay-changed')
    return prepared


class _PhysicalWriter:
    def __init__(self, stream, limit):
        self.stream, self.limit = stream, limit
        self.size, self.digest = 0, hashlib.sha256()

    def write(self, raw):
        _require(self.size + len(raw) <= self.limit, 'ordered-graph-physical-byte-limit')
        written = self.stream.write(raw)
        _require(written == len(raw), 'ordered-graph-short-write')
        self.digest.update(raw)
        self.size += len(raw)
        return written

    def flush(self):
        self.stream.flush()


def save_graph(directory, value, *, logical_limit=256 * _MiB, physical_limit=256 * _MiB):
    """Stream canonical JSON to content-addressed gzip, retaining both identities."""
    _require(type(logical_limit) is int and logical_limit > 0
             and type(physical_limit) is int and physical_limit > 0, 'ordered-graph-invalid-limit')
    directory = Path(directory).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix='ordered-graph-', suffix='.tmp', dir=directory)
    temporary = Path(temporary)
    logical_size, logical_digest = 0, hashlib.sha256()
    try:
        with os.fdopen(fd, 'wb') as stream:
            sink = _PhysicalWriter(stream, physical_limit)
            with gzip.GzipFile(filename='', mode='wb', fileobj=sink, mtime=0) as compressed:
                pieces, buffered = [], 0
                def emit():
                    nonlocal logical_size
                    raw = ''.join(pieces).encode('ascii')
                    _require(logical_size + len(raw) <= logical_limit, 'ordered-graph-logical-byte-limit')
                    logical_size += len(raw)
                    logical_digest.update(raw)
                    compressed.write(raw)
                for piece in json.JSONEncoder(sort_keys=True, ensure_ascii=True, separators=(',', ':')).iterencode(value):
                    pieces.append(piece)
                    buffered += len(piece)
                    if buffered >= 128 * 1024:
                        emit()
                        pieces, buffered = [], 0
                if pieces:
                    emit()
            sink.flush()
        digest = sink.digest.hexdigest()
        path = directory / (digest + '.json.gz')
        if path.exists():
            _require(path.stat().st_size == sink.size and _sha(path.read_bytes()) == digest,
                     'ordered-content-addressed-graph-changed')
        else:
            os.replace(temporary, path)
        return {'path': str(path), 'format': GRAPH_FORMAT, 'sha256': digest, 'size': sink.size,
                'logical_sha256': logical_digest.hexdigest(), 'logical_size': logical_size}
    finally:
        if temporary.exists():
            temporary.unlink()


def read_graph(asset, *, logical_limit=256 * _MiB, physical_limit=256 * _MiB):
    """Read one saved graph, verify physical and logical pins, then decode once."""
    _require(asset.get('format') == GRAPH_FORMAT and type(asset.get('size')) is int
             and 0 < asset['size'] <= physical_limit and type(asset.get('logical_size')) is int
             and 0 < asset['logical_size'] <= logical_limit, 'ordered-graph-record-or-budget')
    path = Path(asset['path'])
    before = path.stat()
    _require(before.st_size == asset['size'], 'ordered-graph-physical-size')
    raw = path.read_bytes()
    _require(_stamp(before) == _stamp(path.stat()) and _sha(raw) == asset['sha256'],
             'ordered-graph-physical-identity')
    with gzip.GzipFile(fileobj=io.BytesIO(raw), mode='rb') as stream:
        logical = stream.read(asset['logical_size'] + 1)
    _require(len(logical) == asset['logical_size'] and _sha(logical) == asset['logical_sha256'],
             'ordered-graph-logical-identity')
    del raw
    return json.loads(logical)


_IMPORTED_RECIPE_ASSETS = code_assets()
