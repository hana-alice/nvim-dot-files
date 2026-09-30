"""Produce ordered secondary Unity candidates, without admitting or activating them.

The caller must supply compiler-authored entries and verified, ordered membership.
Returned candidates are not evidence of equivalent C++ semantics or index coverage.
Exact/shader entries absent from membership, unsupported inputs and oversized units
remain in retained_entries. No compiler, receipt, publisher or runtime is invoked.
"""
import collections
import hashlib
import json
import os
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from build_hot_super_unity_cdb import strip_write_only_flags, write_if_changed

_SEARCH = ('-I', '-isystem', '-iquote', '-idirafter', '-F', '-iframework')
_FORCED = ('-include-pch', '-include', '-imacros')
_API = re.compile(r'\w+_API\Z')
_MACRO = re.compile(r'^\s*#\s*(define|undef)\s+([A-Za-z_]\w*)\b(.*)$')
_COMMENTS = re.compile(r'("(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\')|/\*.*?\*/|//[^\n]*', re.S)


def _key(path):
    return os.path.normcase(os.path.abspath(os.path.normpath(path)))


def _json(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, separators=(',', ':'))


def _include_path(path):
    value = str(path).replace('\\', '/')
    if any(char in value for char in ('"', '\r', '\n', '\0')):
        raise ValueError('unsupported include path')
    return value


def _parse(entry):
    directory = entry['directory']
    args = strip_write_only_flags(entry['arguments'])
    source = _key(os.path.join(directory, entry['file']))
    common, search, definitions = [], [], []
    index, source_count = 0, 0
    while index < len(args):
        arg = args[index]
        if arg.startswith('@') or arg in ('--config', '-ivfsoverlay') or arg.startswith(('--config=', '-ivfsoverlay=')):
            raise ValueError('unsupported indirect compiler input')
        if _key(os.path.join(directory, arg)) == source:
            common.append('<SOURCE>')
            source_count += 1
            index += 1
            continue
        if arg in _SEARCH:
            if index + 1 >= len(args):
                raise ValueError('missing include search operand')
            search.append(args[index:index + 2])
            index += 2
            continue
        if ((arg.startswith(('-I', '-F')) and len(arg) > 2)
                or any(arg.startswith(flag + '=') for flag in _SEARCH[1:])):
            search.append([arg])
            index += 1
            continue
        flag = next((flag for flag in _FORCED if arg == flag or arg.startswith(flag + '=')), None)
        if flag:
            if arg == flag:
                if index + 1 >= len(args):
                    raise ValueError('missing forced include operand')
                path, tokens = args[index + 1], args[index:index + 2]
                index += 2
            else:
                path, tokens = arg.split('=', 1)[1], [arg]
                index += 1
            path = Path(os.path.abspath(os.path.join(directory, path)))
            if (flag == '-include' and path.name.startswith(('Definitions.', 'SharedDefinitions.'))
                    and path.suffix == '.h'):
                definitions.append(_include_path(path))
            else:
                if definitions:
                    raise ValueError('Definitions precedes another forced input')
                common.extend(tokens)
            continue
        common.append(arg)
        index += 1
    if source_count != 1:
        raise ValueError('expected one original source operand')
    return common, search, definitions


def _definitions(path):
    raw = Path(path).read_bytes()
    text = raw.decode('utf-8-sig').replace('\\\r\n', '').replace('\\\n', '')
    text = _COMMENTS.sub(lambda match: match.group(1) or ' ', text)
    state = {}
    for line in text.splitlines():
        match = _MACRO.match(line)
        if match:
            action, name, body = match.groups()
            if action == 'undef':
                if body.strip():
                    raise ValueError('unsupported undef directive')
                state[name] = None
            else:
                state[name] = {'function': body.startswith('('), 'replacement': body.strip()}
        elif line.lstrip().startswith('#'):
            # Include guards, pragma once and indirect inputs cannot be replayed
            # faithfully by this deliberately narrow candidate producer.
            raise ValueError('unsupported Definitions directive: ' + line.strip())
        elif line.strip():
            raise ValueError('unsupported non-directive Definitions content')
    return state, hashlib.sha256(raw).hexdigest()


def _context(entry, common, state):
    # Absence differs from explicit undef. Empty object-like API definitions
    # alone may vary: the per-member scope restores those exact macro states.
    semantic = {name: value for name, value in state.items()
                if not _API.fullmatch(name) or value is None or value['function'] or value['replacement']}
    return _json([entry['directory'], common, semantic])


def build_candidates(entries, membership, output_dir, *, max_originals=50, max_sources=2000):
    """Return candidates, original fallbacks and separate ownership metadata.

    membership maps absolute original-TU paths to ordered absolute member paths.
    Generated-only and implementation originals form separate groups; mixed
    originals stay unchanged. Bounds never split an original Unity. Callers
    must perform semantic admission before using candidates.
    """
    if type(max_originals) is not int or max_originals < 2 or type(max_sources) is not int or max_sources < 1:
        raise ValueError('candidate budgets must allow at least two originals and one source')
    mapped = {}
    for path, values in membership.items():
        ident = _key(path)
        if ident in mapped:
            raise ValueError('ambiguous membership key')
        mapped[ident] = list(values)
    source_keys = [_key(os.path.join(entry['directory'], entry['file'])) for entry in entries]
    source_counts = collections.Counter(source_keys)
    member_counts = collections.Counter(_key(path) for ident in source_keys for path in mapped.get(ident, []))
    headers, groups, retained, rejections = {}, {}, set(), []
    for index, (entry, ident) in enumerate(zip(entries, source_keys)):
        if ident not in mapped:
            retained.add(index)
            continue
        try:
            members = mapped[ident]
            if not members or source_counts[ident] != 1 or any(member_counts[_key(p)] != 1 for p in members):
                raise ValueError('ambiguous or overlapping original membership')
            if not os.path.isabs(entry['directory']) or not os.path.isfile(ident):
                raise ValueError('original compiler directory or Unity file is unavailable')
            if any(not os.path.isabs(path) for path in members):
                raise ValueError('member paths must be absolute')
            if len(members) > max_sources:
                raise ValueError('original Unity exceeds member source budget')
            common, search, definitions = _parse(entry)
            state = {}
            for path in definitions:
                if path not in headers:
                    headers[path] = _definitions(path)
                state.update(headers[path][0])
            generated = sum(str(path).lower().endswith('.gen.cpp') for path in members)
            if 0 < generated < len(members):
                raise ValueError('mixed generated/implementation original retained')
            source_class = 'generated-only' if generated else 'implementation'
            item = {'index': index, 'entry': entry,
                    'source': _include_path(os.path.abspath(os.path.join(entry['directory'], entry['file']))),
                    'members': members, 'common': common, 'search': search, 'definitions': definitions,
                    'source_class': source_class}
            # A generated specialization can silently rebind an implementation
            # call even when generated-first order compiles without errors.
            groups.setdefault((source_class, _context(entry, common, state)), []).append(item)
        except (OSError, UnicodeError, ValueError) as error:
            retained.add(index)
            rejections.append({'entry_index': index, 'file': entry['file'], 'reason': str(error)})

    chunks = []
    for group in groups.values():
        chunk, count = [], 0
        for item in group:
            size = len(item['members'])
            if chunk and (len(chunk) >= max_originals or count + size > max_sources):
                chunks.append(chunk)
                chunk, count = [], 0
            chunk.append(item)
            count += size
        if chunk:
            chunks.append(chunk)

    output = Path(output_dir).resolve()
    candidates, records = [], []
    for original_order in chunks:
        if len(original_order) == 1:
            retained.add(original_order[0]['index'])
            continue
        ordered = original_order
        touched = sorted({name for item in ordered for path in item['definitions'] for name in headers[path][0]})
        search, seen = [], set()
        for item in original_order:
            for option in item['search']:
                if tuple(option) not in seen:
                    search.extend(option)
                    seen.add(tuple(option))
        lines = ['// Ordered Unity candidate only; semantic admission is required.']
        for item in ordered:
            lines.append('// Original Unity: ' + item['source'])
            lines.extend('#pragma push_macro("' + name + '")' for name in touched)
            lines.extend('#include "' + path + '"' for path in item['definitions'])
            lines.append('#include "' + item['source'] + '"')
            lines.extend('#pragma pop_macro("' + name + '")' for name in reversed(touched))
        body = '\n'.join(lines) + '\n'
        common = original_order[0]['common']
        definition_hashes = {path: headers[path][1] for item in ordered for path in item['definitions']}
        identity = hashlib.sha256(_json([body, common, search, definition_hashes,
            [item['members'] for item in ordered], original_order[0]['entry']['directory']]).encode('utf-8')).hexdigest()
        path = output / ('SuperUnity.Ordered.' + identity + '.cpp')
        output.mkdir(parents=True, exist_ok=True)
        write_if_changed(str(path), body)
        args = [str(path) if arg == '<SOURCE>' else arg for arg in common]
        args = args[:1] + search + args[1:]
        candidate = {'directory': original_order[0]['entry']['directory'], 'file': str(path), 'arguments': args}
        candidates.append(candidate)
        records.append({'candidate': candidate, 'original_entries': [item['entry'] for item in ordered],
                        'original_indexes': [item['index'] for item in ordered],
                        'members': [path for item in ordered for path in item['members']],
                        'definitions': [item['definitions'] for item in ordered],
                        'definition_sha256': definition_hashes,
                        'source_class': ordered[0]['source_class'], 'mixed_originals': []})
    return {'classification': 'candidate-only', 'admitted': False, 'candidates': candidates,
            'retained_entries': [entry for index, entry in enumerate(entries) if index in retained],
            'groups': records, 'rejections': rejections}
