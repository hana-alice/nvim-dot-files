#!/usr/bin/env python3
"""build_hot_super_unity_cdb.py — compiler-authored UBT unity wrappers plus
exact per-file fallback for controlled BackgroundIndex.

The full/current/hot pipelines feed this script exact per-file compile commands.
It discovers unity membership only from wrappers and response files emitted by
the active UBT build, then copies each proven member set into nvim's cache.

Output: a controlled BackgroundIndex CDB whose entries reference wrapper
SuperUnity.*.cpp files in <stage_dir>/super_unity_cpps/ when active-build UBT
unity evidence proves either a matching compiler response file or an exact
Apple active-argv reuse path, and exact per-file entries otherwise. The
resulting CDB keeps active source coverage complete without guessing new unity
groupings.

INPUT  : per-file CDB (after prebuild_pch_v2 / resolve_cdb_paths /
         unify_include_dirs / prune_include_dirs), already inject'd with -D
         from Definitions.<Mod>.h by inject_definitions_to_cdb.py.
OUTPUT : <out_cdb> controlled BackgroundIndex CDB.

USAGE  : python build_hot_super_unity_cdb.py <per_file_cdb> <out_cdb>
                  [--max-mods N] [--super-dir <dir>]

DESIGN NOTES
  - A group is accepted only when a current-build UBT unity wrapper includes
    exact active-CDB members and either its matching `.o.rsp` reconstructs one
    exact compiler context or an Apple active argv can be reused exactly after
    replacing the source and stripping write-only outputs. No synthetic
    cross-module argument union is allowed.
  - `--max-mods` is retained for CLI compatibility only; this script preserves
    compiler-authored membership and does not rechunk accepted unity groups.
  - Sources without valid unity evidence retain their original file, cwd, and
    argv as exact per-file fallbacks, so coverage is complete without guessing.
  - Portable member/module metadata lets the semantic sidecar select subject
    module contexts without writing private workspace roots into manifests.

PITFALLS HANDLED
  - module metadata from per-file paths tolerates edge cases:
        .../Source/Runtime/<Mod>/Private/...    (most common)
        .../Source/Runtime/<Mod>/Public/...     (Public/Classes counted as same module)
        .../Source/Developer/<Mod>/Private/...
        .../Source/Editor/<Mod>/Private/...
        .../Plugins/.../Source/<Mod>/Private/...
    All resolve to <Mod> (the directory containing Private/Public/Classes).
  - Files outside that conventional layout are assigned to a deterministic
    path bucket. They are never dropped: controlled background indexing must
    preserve the input CDB's complete source set.
"""

import argparse
import ctypes
import glob
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time
from collections import defaultdict
# Emit UTF-8 regardless of the host ANSI code page (cp1252 on CI runners).
# At import time so callers that import this module and call main() are covered.
for _stream in (sys.stdout, sys.stderr):
    if hasattr(_stream, "reconfigure"):
        _stream.reconfigure(encoding="utf-8", errors="backslashreplace")

# Also importable when the CLI is started with Python's isolated (-I) mode.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cdb_unity_receipt import load_verified_groups


# ---- path helpers ----------------------------------------------------------

def winpath_local(p):
    """Translate D:\foo or D:/foo into /mnt/d/foo when running under WSL."""
    if sys.platform.startswith('linux') and len(p) >= 2 and p[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{p[0].lower()}/' + p[2:].replace('\\', '/').lstrip('/')
    return p


def winpath_from_local(p):
    """/mnt/d/foo -> D:/foo. Identity for native Windows paths."""
    if p.startswith('/mnt/') and len(p) > 6 and p[6] == '/':
        drive = p[5].upper()
        return f'{drive}:{p[6:]}'
    return p


# ---- portable module metadata ---------------------------------------------

# Common UE source layout markers; the module name is the directory IMMEDIATELY
# above one of these subdirectories.
_MODULE_MARKER_DIRS = ('Private', 'Public', 'Classes', 'Internal')


def _portable_parts(file_path):
    normalized = file_path.replace('\\', '/').strip('/')
    return [part for part in normalized.split('/') if part]


def portable_member_path(file_path):
    """Return a suffix-stable member path without workspace-specific roots."""
    parts = _portable_parts(file_path)
    for index in range(len(parts) - 1, -1, -1):
        if parts[index] == 'Source' and index + 1 < len(parts):
            return '/'.join(parts[index:])
    marker = next((i for i, part in enumerate(parts) if part in _MODULE_MARKER_DIRS), None)
    if marker is not None and marker >= 1:
        return '/'.join(parts[marker - 1:])
    if len(parts) <= 3:
        return '/'.join(parts)
    return '/'.join(parts[-3:])


def portable_module_root(file_path):
    """Infer the module root from UE markers without absolute workspace paths."""
    parts = _portable_parts(file_path)
    for index, segment in enumerate(parts):
        if segment in _MODULE_MARKER_DIRS and index >= 1:
            for source_index in range(index - 1, -1, -1):
                if parts[source_index] == 'Source':
                    return '/'.join(parts[source_index:index])
            return parts[index - 1]
    member_path = portable_member_path(file_path)
    parent = os.path.dirname(member_path.replace('\\', '/')).replace('\\', '/')
    return parent.strip('/')


WRITE_ONLY_FLAGS = frozenset({
    '-MD', '-MMD', '-MP', '-MV',
})
WRITE_ONLY_FLAGS_WITH_VALUE = frozenset({
    '-o', '-MF', '-MT', '-MQ', '-MJ',
    '-dependency-file', '-serialize-diagnostics', '--serialize-diagnostics',
})
WRITE_ONLY_PREFIXES = (
    '-MF', '-MT', '-MQ', '-MJ',
    '-dependency-file=', '-serialize-diagnostics=', '--serialize-diagnostics=',
)


def strip_write_only_flags(args):
    stripped = []
    index = 0
    while index < len(args):
        arg = str(args[index])
        if arg in WRITE_ONLY_FLAGS_WITH_VALUE:
            index += 2 if index + 1 < len(args) else 1
            continue
        if arg in WRITE_ONLY_FLAGS:
            index += 1
            continue
        if arg.startswith(WRITE_ONLY_PREFIXES):
            index += 1
            continue
        stripped.append(args[index])
        index += 1
    return stripped


def compile_context_key(entry):
    """Fingerprint every semantic compile input, ignoring per-file writes.

    Entries with different command lines must not share an AST. Keeping this
    key exact is intentionally conservative: less compression is acceptable;
    silently combining incompatible macro/include environments is not.
    """
    source = os.path.normcase(entry.get('file', '').replace('\\', '/'))
    normalized = []
    for arg in strip_write_only_flags(entry.get('arguments', [])):
        candidate = os.path.normcase(str(arg).replace('\\', '/'))
        normalized.append('<SOURCE>' if candidate == source else arg)
    payload = json.dumps({
        'directory': entry.get('directory', ''),
        'arguments': normalized,
    }, ensure_ascii=False, separators=(',', ':'))
    return hashlib.sha256(payload.encode('utf-8')).hexdigest()[:16]


def _member_stems(members):
    sources, generated = set(), set()
    for member in members:
        name = member.replace('\\', '/').rsplit('/', 1)[-1].casefold()
        if name.endswith('.gen.cpp'):
            generated.add(name[:-8])
        else:
            stem, suffix = os.path.splitext(name)
            if suffix in ('.cpp', '.cc', '.cxx'):
                sources.add(stem)
    return sources, generated


def secondary_unity_chunks(entries, max_sources=None, max_unities=8,
                           budget_factor=None, diagnostics=None, split_member_classes=True,
                           avoid_same_stem_pairs=False):
    """Plan same-context SuperUnity chunks without modifying original commands.

    Each chunk is bounded by budget_factor * UBT's 384 KiB member-source budget.
    max_sources is an optional additional limit for existing strict callers.
    Original UBT groups remain indivisible; unknown source sizes conservatively
    exceed the budget. Same-stem exclusion is an optional planning constraint;
    Tier 1 normally retries failed cross-class candidates by member class.
    These are candidates, not admission receipts.
    """
    if not isinstance(split_member_classes, bool):
        raise ValueError('SuperUnity member-class split must be boolean')
    if budget_factor is None:
        budget_factor = int(os.environ.get('NVIM_UE_SUPER_UNITY_BUDGET_FACTOR', '8'))
    if (not isinstance(budget_factor, int) or isinstance(budget_factor, bool)
            or budget_factor < 1 or not isinstance(max_unities, int)
            or isinstance(max_unities, bool) or max_unities < 1
            or (max_sources is not None and (not isinstance(max_sources, int)
                or isinstance(max_sources, bool) or max_sources < 1))):
        raise ValueError('SuperUnity chunk budgets must be positive')
    byte_budget = budget_factor * 393216
    buckets = defaultdict(list)
    for index, entry in enumerate(entries):
        members = entry.get('nvim_ue_members')
        module = entry.get('nvim_ue_module_root')
        name = entry.get('file', '').replace('\\', '/').rsplit('/', 1)[-1]
        if name.startswith('SuperUnity.UBT.') and members and module:
            generated = [member.lower().endswith('.gen.cpp') for member in members]
            member_class = 'gen' if all(generated) else 'mixed' if any(generated) else 'src'
            buckets[(module, compile_context_key(entry),
                     member_class if split_member_classes else None)].append(index)

    def member_bytes(index):
        entry = entries[index]
        wrapper = winpath_local(entry['file'])
        if not os.path.isabs(wrapper):
            wrapper = os.path.join(winpath_local(entry.get('directory', '')), wrapper)
        member = None
        try:
            with open(wrapper, encoding='utf-8') as source:
                paths = [match.group(1) for line in source
                         if (match := UNITY_INCLUDE_RE.match(line))]
            if [portable_member_path(path) for path in paths] != entry['nvim_ue_members']:
                raise ValueError('wrapper-membership-mismatch')
            size = 0
            for member in paths:
                path = winpath_local(member)
                if not os.path.isabs(path):
                    path = os.path.join(os.path.dirname(wrapper), path)
                size += os.stat(path).st_size
            return size
        except (OSError, UnicodeError, ValueError) as error:
            detail = {'entry_index': index, 'file': entry['file'], 'member': member,
                      'reason': 'member-size-unavailable', 'detail': str(error),
                      'assumed_bytes': byte_budget + 1}
            if diagnostics is not None:
                diagnostics.append(detail)
            else:
                print('[hot-super] ' + json.dumps(detail, ensure_ascii=True), file=sys.stderr)
            return byte_budget + 1

    chunks = []
    for indexes in buckets.values():
        chunk, size, count = [], 0, 0
        chunk_sources, chunk_generated = set(), set()
        for index in indexes:
            source_bytes = member_bytes(index)
            sources = len(entries[index]['nvim_ue_members'])
            source_stems, generated_stems = (set(), set())
            if not split_member_classes and avoid_same_stem_pairs:
                source_stems, generated_stems = _member_stems(entries[index]['nvim_ue_members'])
            if chunk and (size + source_bytes > byte_budget or len(chunk) >= max_unities
                    or (max_sources is not None and count + sources > max_sources)
                    or source_stems.intersection(chunk_generated)
                    or generated_stems.intersection(chunk_sources)):
                if len(chunk) > 1:
                    chunks.append(chunk)
                chunk, size, count = [], 0, 0
                chunk_sources, chunk_generated = set(), set()
            if source_bytes > byte_budget or (max_sources is not None and sources > max_sources):
                # An oversized original is retained, not split or omitted.
                continue
            chunk.append(index)
            size += source_bytes
            count += sources
            chunk_sources.update(source_stems)
            chunk_generated.update(generated_stems)
        if len(chunk) > 1:
            chunks.append(chunk)
    return sorted(chunks, key=lambda chunk: chunk[0])


def _tier2_path(path, directory):
    path = winpath_local(str(path))
    if not os.path.isabs(path):
        path = os.path.join(winpath_local(directory), path)
    return os.path.normpath(os.path.abspath(path))


def _tier2_entry(entry):
    """Read one compiler-authored owner; never write or grant admission."""
    directory = _tier2_path(entry.get('directory', ''), os.getcwd())
    source = _tier2_path(entry['file'], directory)
    args = strip_write_only_flags(entry['arguments'])
    residual, includes, forced, context = [], [], [], []
    index = 1
    while index < len(args):
        arg = str(args[index])
        if arg in ('-I', '-include'):
            if index + 1 >= len(args):
                raise ValueError('missing operand: ' + arg)
            value = str(args[index + 1])
            (includes if arg == '-I' else forced).append(_tier2_path(value, directory))
            if arg == '-include' and not os.path.basename(value.replace('\\', '/')).startswith('Definitions.'):
                context.extend((arg, value))
            index += 2
            continue
        if arg.startswith('-I') and len(arg) > 2:
            includes.append(_tier2_path(arg[2:], directory))
        elif arg.startswith('-include='):
            value = arg[len('-include='):]
            forced.append(_tier2_path(value, directory))
            if not os.path.basename(value.replace('\\', '/')).startswith('Definitions.'):
                context.append(arg)
        elif arg != '-c' and os.path.normcase(_tier2_path(arg, directory)) != os.path.normcase(source):
            residual.append(arg)
            context.append(arg)
        elif arg == '-c':
            context.append(arg)
        index += 1
    definitions = [path for path in forced
                   if os.path.basename(path).startswith('Definitions.')]
    shared = [path for path in forced if 'sharedpch' in os.path.basename(path).casefold()]
    if len(definitions) != 1 or len(shared) != 1:
        raise ValueError('expected one Definitions header and one SharedPCH header')
    with open(definitions[0], encoding='utf-8-sig') as stream:
        definition_text = stream.read()
    engine = re.findall(r'^\s*#\s*define\s+UE_IS_ENGINE_MODULE\s+([^\r\n]+)',
                        definition_text, re.MULTILINE)
    if len(engine) != 1:
        raise ValueError('expected one UE_IS_ENGINE_MODULE definition')
    with open(source, encoding='utf-8-sig') as stream:
        members = [_tier2_path(match.group(1), os.path.dirname(source))
                   for line in stream if (match := UNITY_INCLUDE_RE.match(line))]
    if not members or [portable_member_path(path) for path in members] != entry.get('nvim_ue_members'):
        raise ValueError('wrapper-membership-mismatch')
    prefix = [path for path in forced if path not in definitions]
    # Preserve forced includes at their original argv positions in the key.
    key = (os.path.normcase(directory), str(args[0]), os.path.normcase(shared[0]),
           engine[0].strip(), tuple(context))
    return {'directory': directory, 'source': source, 'driver': args[0],
            'residual': residual, 'includes': includes, 'forced': forced,
            'definitions': definitions[0], 'definition_text': definition_text,
            'members': members, 'prefix': prefix, 'key': key}


def tier2_unity_chunks(entries, max_unities=8, budget_factor=8, diagnostics=None):
    """Plan whole-module, ordered cross-module candidates without writing files.

    Incompatible or oversized complete modules remain available to Tier 1.
    Reading compiler-owned wrappers and member sizes does not grant qualification.
    """
    if any(not isinstance(value, int) or isinstance(value, bool) or value < 1
           for value in (max_unities, budget_factor)):
        raise ValueError('Tier 2 budgets must be positive integers')
    budget = budget_factor * 393216
    modules = defaultdict(list)
    for index, entry in enumerate(entries):
        if (os.path.basename(entry.get('file', '').replace('\\', '/')).startswith('SuperUnity.UBT.')
                and entry.get('nvim_ue_members') and entry.get('nvim_ue_module_root')):
            modules[entry['nvim_ue_module_root']].append(index)
    buckets = defaultdict(list)
    for module, indexes in modules.items():
        try:
            infos = [_tier2_entry(entries[index]) for index in indexes]
            if len({compile_context_key(entries[index]) for index in indexes}) != 1:
                raise ValueError('module has multiple compiler contexts')
            if len({info['key'] for info in infos}) != 1:
                raise ValueError('module has incompatible Tier 2 contexts')
            size = sum(os.stat(member).st_size for info in infos for member in info['members'])
            if size > budget or len(indexes) > max_unities:
                raise ValueError('whole module exceeds Tier 2 budget')
            buckets[infos[0]['key']].append((indexes, size))
        except (OSError, UnicodeError, ValueError, KeyError) as error:
            if diagnostics is not None:
                diagnostics.append({'module': module, 'entry_indexes': indexes, 'reason': str(error)})
    chunks = []
    for modules_in_bucket in buckets.values():
        chunk, size, module_count = [], 0, 0
        for indexes, module_size in modules_in_bucket:
            if chunk and (len(chunk) + len(indexes) > max_unities or size + module_size > budget):
                if module_count > 1:
                    chunks.append(sorted(chunk))
                chunk, size, module_count = [], 0, 0
            chunk.extend(indexes)
            size += module_size
            module_count += 1
        if module_count > 1:
            chunks.append(sorted(chunk))
    return sorted(chunks, key=lambda chunk: chunk[0])


def tier2_candidate_spec(group, wrapper_path):
    """Return an explicit cross-module candidate and wrapper text; do not write."""
    if not group:
        raise ValueError('empty Tier 2 group')
    infos = [_tier2_entry(entry) for entry in group]
    if len({info['key'] for info in infos}) != 1:
        raise ValueError('incompatible Tier 2 group')
    modules = defaultdict(list)
    for entry, info in zip(group, infos):
        modules[entry['nvim_ue_module_root']].append(info)
    for module in modules:
        if len({compile_context_key(entry) for entry in group
                if entry['nvim_ue_module_root'] == module}) != 1:
            raise ValueError('module has multiple compiler contexts')
    if len(modules) < 2:
        raise ValueError('Tier 2 requires multiple modules')
    lines = ['// Explicit Tier 2 candidate; qualification required.']
    lines.extend('#include "' + path.replace('\\', '/') + '"' for path in infos[0]['prefix'])
    for module_infos in modules.values():
        if len({info['definitions'] for info in module_infos}) != 1:
            raise ValueError('module has multiple Definitions headers')
        macros = list(dict.fromkeys(re.findall(r'^\s*#\s*define\s+([A-Za-z_]\w*)',
                    module_infos[0]['definition_text'], re.MULTILINE)))
        for macro in macros:
            lines.extend(['#pragma push_macro("' + macro + '")', '#undef ' + macro])
        lines.append('#include "' + module_infos[0]['definitions'].replace('\\', '/') + '"')
        lines.extend('#include "' + member.replace('\\', '/') + '"'
                     for info in module_infos for member in info['members'])
        lines.extend('#pragma pop_macro("' + macro + '")' for macro in reversed(macros))
    includes = list(dict.fromkeys(path for info in infos for path in info['includes']))
    source = _tier2_path(wrapper_path, infos[0]['directory'])
    candidate = dict(group[0])
    candidate.update(file=source, arguments=[infos[0]['driver'], *infos[0]['residual'],
                     *('-I' + path for path in includes), '-c', source],
                     nvim_ue_members=[member for entry in group for member in entry['nvim_ue_members']],
                     nvim_ue_tier=2,
                     nvim_ue_tier2_modules=list(modules))
    return candidate, '\n'.join(lines) + '\n'


def _tier2_dependency_paths(text):
    """Decode Make dependency escaping without consuming Windows separators."""
    paths, token, index = [], [], 0
    while index < len(text):
        char = text[index]
        if char == '\\' and index + 1 < len(text):
            following = text[index + 1]
            if following.isspace() or following in '#$:' or (following == '\\' and os.name != 'nt'):
                token.append(following)
                index += 2
                continue
        if char.isspace():
            if token:
                paths.append(''.join(token).replace('$$', '$'))
                token = []
        else:
            token.append(char)
        index += 1
    if token:
        paths.append(''.join(token).replace('$$', '$'))
    return paths


def tier2_include_gate(group, work_dir, clang_path, timeout=10):
    """Compare actual preprocessing dependencies; sequential and private only."""
    started = time.monotonic()
    result = {'ok': False, 'reason': '', 'seconds': 0.0, 'commands': [],
              'only_tier1': [], 'only_tier2': []}
    try:
        work_dir = os.path.realpath(os.path.abspath(work_dir))
        if '/.cache/nvim-ue/' in (work_dir.replace('\\', '/').casefold().rstrip('/') + '/'):
            raise ValueError('include gate work directory must be private')
        os.makedirs(work_dir, exist_ok=True)
        wrapper = os.path.join(work_dir, 'Tier2.include-gate.cpp')
        candidate, body = tier2_candidate_spec(group, wrapper)
        with open(wrapper, 'w', encoding='utf-8', newline='\n') as stream:
            stream.write(body)
        modules = defaultdict(list)
        for entry in group:
            modules[entry['nvim_ue_module_root']].append(entry)
        commands = []
        for number, module_entries in enumerate(modules.values()):
            infos = [_tier2_entry(entry) for entry in module_entries]
            info = infos[0]
            original_wrapper = os.path.join(work_dir, 'Tier1.include-gate.' + str(number) + '.cpp')
            with open(original_wrapper, 'w', encoding='utf-8', newline='\n') as stream:
                stream.write(''.join('#include "' + member.replace('\\', '/') + '"\n'
                                    for item in infos for member in item['members']))
            original_args = strip_write_only_flags(module_entries[0]['arguments'])[1:]
            original_args = [arg for arg in original_args if arg != '-c' and
                os.path.normcase(_tier2_path(arg, info['directory'])) != os.path.normcase(info['source'])]
            commands.append(('tier1', info['directory'], [*original_args, original_wrapper], original_wrapper))
        commands.append(('tier2', candidate['directory'],
                         [arg for arg in candidate['arguments'][1:] if arg != '-c'], wrapper))
        generated = {os.path.normcase(os.path.realpath(item[3])) for item in commands}
        dependencies = {'tier1': set(), 'tier2': set()}
        for number, (kind, directory, args, _source) in enumerate(commands):
            remaining = timeout - (time.monotonic() - started)
            if remaining <= 0:
                raise subprocess.TimeoutExpired('include-gate', timeout)
            depfile = os.path.join(work_dir, str(number) + '.d')
            argv = [str(clang_path), *args, '-E', '-M', '-MF', depfile, '-MT', 'tier2_gate']
            command_started = time.monotonic()
            try:
                completed = subprocess.run(argv, cwd=directory, capture_output=True, text=True,
                    encoding='utf-8', errors='replace', timeout=remaining,
                    creationflags=getattr(subprocess, 'BELOW_NORMAL_PRIORITY_CLASS', 0) if os.name == 'nt' else 0)
            except subprocess.TimeoutExpired:
                result['commands'].append({'kind': kind, 'argv': argv, 'returncode': None,
                    'seconds': round(time.monotonic() - command_started, 6), 'timeout': True})
                raise
            result['commands'].append({'kind': kind, 'argv': argv, 'returncode': completed.returncode,
                'seconds': round(time.monotonic() - command_started, 6), 'stderr': completed.stderr[-6000:]})
            if completed.returncode:
                raise ValueError(kind + ' preprocessing failed')
            with open(depfile, encoding='utf-8') as stream:
                text = stream.read().replace('\\\n', ' ').replace('\\\r\n', ' ')
            if not text.startswith('tier2_gate:'):
                raise ValueError('unexpected dependency target')
            for path in _tier2_dependency_paths(text[len('tier2_gate:'):]):
                normalized = os.path.normcase(os.path.realpath(_tier2_path(path, directory)))
                if normalized not in generated:
                    dependencies[kind].add(normalized)
        result['only_tier1'] = sorted(dependencies['tier1'] - dependencies['tier2'])
        result['only_tier2'] = sorted(dependencies['tier2'] - dependencies['tier1'])
        result['dependency_counts'] = {key: len(value) for key, value in dependencies.items()}
        result['ok'] = not result['only_tier1'] and not result['only_tier2']
        result['reason'] = 'equal' if result['ok'] else 'dependency-set-mismatch'
    except (OSError, UnicodeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
        result['reason'] = str(error)
    result['seconds'] = round(time.monotonic() - started, 6)
    return result


def strict_unity_chunks(entries, max_sources=None, max_unities=8,
                        budget_factor=None, diagnostics=None):
    """Keep same-class candidates first, then pack unclaimed strict candidates.

    Removing chunks can make remaining same-class originals fit together, so
    settle those first. Each final cross-class group then replans as one group.
    The residual pass may cross member classes, but preserves module/context,
    original entry order and all budgets. Every result still needs strict proof.
    """
    chunks, available = [], list(range(len(entries)))
    split_member_classes = True
    while True:
        residual_diagnostics = []
        residual = secondary_unity_chunks([entries[index] for index in available],
            max_sources=max_sources, max_unities=max_unities, budget_factor=budget_factor,
            diagnostics=residual_diagnostics, split_member_classes=split_member_classes,
            avoid_same_stem_pairs=False)
        for detail in residual_diagnostics:
            detail['entry_index'] = available[detail['entry_index']]
            if diagnostics is not None:
                diagnostics.append(detail)
            else:
                print('[hot-super] ' + json.dumps(detail, ensure_ascii=True), file=sys.stderr)
        chunks.extend([available[index] for index in chunk] for chunk in residual)
        if not split_member_classes:
            return chunks
        if residual:
            claimed = {index for chunk in residual for index in chunk}
            available = [index for position, index in enumerate(available) if position not in claimed]
        else:
            split_member_classes = False


def compiler_authored_module_roots(cdb, groups):
    """Keep generated and ordinary sources under their actual UBT module.

    An Inc/Module path is a build output, not a separate module. Only groups
    from the same compiler-owned module directory and exact context may share
    a source root; ambiguous or generated-only owners keep their existing root.
    """
    owners, source_roots = {}, defaultdict(set)
    for unity, members, _kind, _args in groups:
        key = (os.path.normcase(os.path.normpath(os.path.dirname(unity))),
               compile_context_key(cdb[members[0]]))
        owners[unity] = key
        for member in members:
            path = cdb[member]['file']
            parts = _portable_parts(path)
            if ('intermediate' not in [part.casefold() for part in parts]
                    and any(part in _MODULE_MARKER_DIRS for part in parts)):
                source_roots[key].add(portable_module_root(path))
    roots = {}
    for unity, members, _kind, _args in groups:
        candidates = source_roots[owners[unity]]
        roots[unity] = (next(iter(candidates)) if len(candidates) == 1
                        else portable_module_root(cdb[members[0]]['file']))
    return roots


# ---- compiler-authored unity discovery ------------------------------------

UNITY_ROOT_RE = re.compile(
    r'((?:(?:[A-Za-z]:|/mnt/[A-Za-z])[/\\]|/).*?[/\\]Intermediate[/\\]Build[/\\].*?'
    r'[/\\](?:DebugGame|Development|Shipping|Debug|Test))(?=[/\\])',
    re.IGNORECASE,
)
UNITY_INCLUDE_RE = re.compile(r'^\s*#\s*include\s+"([^"]+\.cpp)"', re.IGNORECASE)


def discover_active_unity_root(cdb):
    """Return the build-intermediate root proven by active command args.

    We deliberately do not scan hard-coded platform/configuration paths. The
    only candidates are roots literally present in this CDB's compiler-owned
    arguments; repeated references provide a deterministic evidence score.
    """
    evidence = defaultdict(int)
    for entry in cdb:
        for arg in entry.get('arguments', []):
            for match in UNITY_ROOT_RE.finditer(str(arg)):
                root = match.group(1).replace('\\', '/')
                local = winpath_local(root)
                if os.path.isdir(local):
                    evidence[root] += 1
    if not evidence:
        return None, 0
    return sorted(evidence.items(), key=lambda item: (-item[1], item[0].casefold()))[0]


def source_suffix_lookup(cdb):
    """Build an exact suffix lookup for compiler-generated unity includes."""
    lookup = defaultdict(list)
    for index, entry in enumerate(cdb):
        path = entry.get('file', '').replace('\\', '/').strip('/')
        parts = path.split('/')
        for start in range(max(0, len(parts) - 12), len(parts) - 1):
            lookup['/'.join(parts[start:]).casefold()].append(index)
        lookup[path.casefold()].append(index)
    return lookup


def resolve_unity_member(include_path, lookup):
    key = include_path.replace('\\', '/').lstrip('./').casefold()
    matches = sorted(set(lookup.get(key, [])))
    return matches[0] if len(matches) == 1 else None


def split_response_file(text):
    if os.name != 'nt':
        return shlex.split(text, posix=True)
    argc = ctypes.c_int()
    split = ctypes.windll.shell32.CommandLineToArgvW
    split.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
    split.restype = ctypes.POINTER(ctypes.c_wchar_p)
    # RSPs contain arguments, not argv[0]. A dummy driver avoids Windows'
    # special first-token parsing (including its leading-whitespace empty arg).
    argv = split('clang ' + text.replace('\r', ' ').replace('\n', ' '), ctypes.byref(argc))
    if not argv:
        raise OSError('CommandLineToArgvW failed')
    try:
        return [argv[index] for index in range(1, argc.value)]
    finally:
        ctypes.windll.kernel32.LocalFree(ctypes.cast(argv, ctypes.c_void_p))


def option_value(args, prefix):
    for index, arg in enumerate(args):
        if arg.startswith(prefix + '='):
            return arg[len(prefix) + 1:]
        if arg == prefix and index + 1 < len(args):
            return args[index + 1]
    return None


def looks_like_apple_platform(args):
    target = option_value(args, '--target') or option_value(args, '-target')
    if target and 'apple' in target.casefold():
        return True
    for index, raw_arg in enumerate(args):
        arg = str(raw_arg)
        if arg == '-isysroot' and index + 1 < len(args):
            sysroot = str(args[index + 1]).replace('\\', '/').casefold()
        elif arg.startswith('--sysroot='):
            sysroot = arg.split('=', 1)[1].replace('\\', '/').casefold()
        else:
            continue
        if any(token in sysroot for token in (
            'macosx', 'iphoneos', 'iphonesimulator', 'appletvos',
            'watchos', 'xros', '.platform/developer/sdks/',
        )):
            return True
    return False


def unity_response_args(unity_path, template):
    """Return compatible response args and whether responses are proven absent."""
    template_args = template.get('arguments', [])
    template_target = option_value(template_args, '--target')
    template_std = next((arg for arg in template_args if arg.startswith('-std=')), None)
    unity_normalized = os.path.normcase(unity_path.replace('\\', '/'))
    try:
        unity_name = os.path.normcase(os.path.basename(unity_path))
        with os.scandir(os.path.dirname(unity_path)) as entries:
            candidates = [entry.path for entry in entries
                          if os.path.normcase(entry.name).startswith(unity_name)
                          and os.path.normcase(entry.name).endswith('.o.rsp')]
        candidates.sort(key=lambda path: (-os.path.getmtime(path), path.casefold()))
    except OSError:
        return None, False
    for rsp_path in candidates:
        try:
            with open(rsp_path, encoding='utf-8', errors='replace') as stream:
                rsp_args = split_response_file(stream.read())
        except (OSError, ValueError):
            continue
        rsp_target = option_value(rsp_args, '--target')
        rsp_std = next((arg for arg in rsp_args if arg.startswith('-std=')), None)
        if template_target and rsp_target != template_target:
            continue
        if template_std and rsp_std != template_std:
            continue
        if not any(
            os.path.normcase(str(arg).replace('\\', '/')) == unity_normalized
            for arg in rsp_args
        ):
            continue
        response_entry = {
            'directory': template.get('directory', ''),
            'file': unity_path,
            'arguments': [template_args[0]] + rsp_args,
        }
        # Member agreement and matching target/std do not prove that this
        # response belongs to their context. Compare all semantic flags in
        # order, including defines, includes and PCH inputs.
        if compile_context_key(response_entry) != compile_context_key(template):
            continue
        return rsp_args, False
    return None, not candidates


def compiler_authored_unity_groups(cdb, root, receipts=None):
    """Map active UBT unity manifests to exact CDB entries.

    A group is accepted only when every include maps uniquely into the active
    CDB and every member has the same exact compile-context fingerprint.
    Anything not proven this way remains an original per-file entry.
    """
    receipts = receipts or {}
    if not root and not receipts:
        return []
    root_local = winpath_local(root) if root else ''
    lookup = source_suffix_lookup(cdb)
    groups = []
    claimed = set()
    patterns = (
        os.path.join(root_local, '*', 'Module.*.cpp'),
        os.path.join(root_local, '*', '*', 'Module.*.cpp'),
    )
    unity_files = [group['unity'] for group in receipts.values()]
    if root:
        for pattern in patterns:
            unity_files.extend(glob.glob(pattern))
    for unity_path in sorted(set(unity_files), key=str.casefold):
        try:
            with open(unity_path, encoding='utf-8', errors='replace') as stream:
                includes = [
                    match.group(1)
                    for line in stream
                    for match in [UNITY_INCLUDE_RE.match(line)]
                    if match
                ]
        except OSError:
            continue
        members = [resolve_unity_member(include, lookup) for include in includes]
        if not members or any(member is None for member in members):
            continue
        if len(set(members)) != len(members) or any(member in claimed for member in members):
            continue
        directories = {cdb[member].get('directory', '') for member in members}
        if len(directories) != 1:
            continue
        contexts = {compile_context_key(cdb[member]) for member in members}
        if len(contexts) != 1:
            continue
        template = cdb[members[0]]
        receipt = receipts.get(os.path.normcase(os.path.normpath(unity_path)))
        if receipt and [os.path.normcase(os.path.normpath(cdb[i]['file'])) for i in members] == [
            os.path.normcase(os.path.normpath(path)) for path in receipt['members']
        ]:
            # The actual prepare pipeline attested the complete transformation
            # from this compiler RSP to these exact active commands. Both ends
            # and every input are revalidated; no flags are ignored here.
            groups.append((unity_path, members, 'exact', list(template['arguments'])))
            claimed.update(members)
            continue
        rsp_args, no_rsp = unity_response_args(unity_path, template)
        if rsp_args:
            groups.append((unity_path, members, 'rsp', rsp_args))
            claimed.update(members)
            continue
        # A present but unusable response cannot prove Apple's no-RSP case.
        if not no_rsp or not looks_like_apple_platform(template.get('arguments', [])):
            continue
        exact_args = rewritten_arguments(template, unity_path)
        if not exact_args:
            continue
        groups.append((unity_path, members, 'exact', list(template.get('arguments', []))))
        claimed.update(members)
    groups.sort(key=lambda group: min(group[1]))
    return groups


def rewritten_arguments(entry, new_source):
    args = strip_write_only_flags(list(entry.get('arguments', [])))
    old_source = os.path.normcase(entry.get('file', '').replace('\\', '/'))
    replaced = False
    for index, arg in enumerate(args):
        normalized = os.path.normcase(str(arg).replace('\\', '/'))
        if normalized == old_source:
            args[index] = new_source
            replaced = True
    return args if replaced else None


def rewritten_response_arguments(template, unity_path, rsp_args, new_source):
    """Build a clangd command from proven response flags without write outputs."""
    driver = template.get('arguments', [None])[0]
    if not driver:
        return None
    unity_normalized = os.path.normcase(unity_path.replace('\\', '/'))
    args = [driver]
    replaced = False
    index = 0
    filtered_rsp_args = strip_write_only_flags(rsp_args)
    while index < len(filtered_rsp_args):
        arg = filtered_rsp_args[index]
        if os.path.normcase(str(arg).replace('\\', '/')) == unity_normalized:
            args.append(new_source)
            replaced = True
        else:
            args.append(arg)
        index += 1
    return args if replaced else None


# ---- main ------------------------------------------------------------------

def write_if_changed(path, content):
    """Keep existing output timestamps; publish changed bytes atomically."""
    data = content.encode('utf-8')
    try:
        with open(path, 'rb') as stream:
            if stream.read() == data:
                return False
    except FileNotFoundError:
        pass
    temporary = f'{path}.{os.getpid()}.tmp'
    try:
        with open(temporary, 'wb') as stream:
            stream.write(data)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.remove(temporary)
    return True


def write_outputs_if_changed(outputs):
    """Stage a CDB/marker pair before publishing; restore it on local I/O errors.

    This is not crash-atomic across files. Persisted manifest hashes still
    reject an interrupted process before a mixed pair can become authoritative.
    """
    import shutil

    prepared = []
    seen = set()
    try:
        for path, content in outputs:
            key = os.path.normcase(os.path.abspath(path))
            if key in seen:
                raise ValueError('duplicate transaction output')
            seen.add(key)
            os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
            existed = os.path.exists(path)
            if existed:
                with open(path, 'rb') as stream:
                    if stream.read() == content.encode('utf-8'):
                        continue
            item = {'path': path, 'pending': f'{path}.{os.getpid()}.pending',
                    'backup': f'{path}.{os.getpid()}.rollback',
                    'existed': existed, 'replaced': False}
            prepared.append(item)
            write_if_changed(item['pending'], content)
            if existed:
                shutil.copy2(path, item['backup'])
        for item in prepared:
            os.replace(item['pending'], item['path'])
            item['replaced'] = True
    except OSError:
        for item in reversed(prepared):
            if item['replaced']:
                if item['existed']:
                    os.replace(item['backup'], item['path'])
                else:
                    os.remove(item['path'])
        raise
    finally:
        for item in prepared:
            for key in ('pending', 'backup'):
                # Leave recovery evidence if restoring an already-published
                # output itself failed; do not delete its last saved baseline.
                if key == 'backup' and item['replaced'] and os.path.exists(item[key]):
                    continue
                if os.path.exists(item[key]):
                    os.remove(item[key])
    # Successful commits no longer need the previous generation's backup.
    for item in prepared:
        if os.path.exists(item['backup']):
            os.remove(item['backup'])
    return bool(prepared)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src', help='per-file CDB (hot.json)')
    ap.add_argument('out', help='output controlled BackgroundIndex CDB path')
    ap.add_argument('--max-mods', type=int, default=80,
                    help='max member .cpps per wrapper TU (default 80)')
    ap.add_argument('--super-dir', default=None,
                    help='where to write SuperUnity.*.cpp (default: <out_dir>/super_unity_cpps)')
    ap.add_argument('--unity-receipt', help='verified prepare pipeline provenance sidecar')
    args = ap.parse_args()

    src_local = winpath_local(args.src)
    out_local = winpath_local(args.out)
    with open(src_local, encoding='utf-8') as f:
        cdb = json.load(f)

    print(f'[hot-super] input: {len(cdb)} per-file TUs', file=sys.stderr)
    if not cdb:
        print('[hot-super] empty CDB, nothing to do', file=sys.stderr)
        return 0

    for index, entry in enumerate(cdb):
        if not isinstance(entry.get('arguments'), list) or not entry.get('file'):
            print(f'ERROR: entry {index} lacks structured arguments/file', file=sys.stderr)
            return 1

    # Output dir for SuperUnity.*.cpp
    out_dir = os.path.dirname(out_local) or '.'
    os.makedirs(out_dir, exist_ok=True)
    super_dir = args.super_dir or os.path.join(out_dir, 'super_unity_cpps')
    super_dir_local = winpath_local(super_dir)
    os.makedirs(super_dir_local, exist_ok=True)
    # Existing wrappers may still be consumed by a published CDB. Their
    # content-addressed names let generations coexist until cache cleanup.

    active_root, root_evidence = discover_active_unity_root(cdb)
    receipts = load_verified_groups(args.unity_receipt, cdb) if args.unity_receipt else {}
    groups = compiler_authored_unity_groups(cdb, active_root, receipts)
    module_roots = compiler_authored_module_roots(cdb, groups)
    claimed = {member for _unity, members, _kind, _args in groups for member in members}
    new_cdb = []

    for unity_path, members, group_kind, group_args in groups:
        template = cdb[members[0]]
        member_paths = [cdb[index]['file'].replace('\\', '/') for index in members]
        digest = hashlib.sha256(
            (
                '\0'.join(member_paths)
                + '\0' + compile_context_key(template)
                + '\0' + group_kind
                + '\0' + json.dumps(group_args, ensure_ascii=False, separators=(',', ':'))
            ).encode('utf-8')
        ).hexdigest()[:20]
        wrapper_local = os.path.join(super_dir_local, f'SuperUnity.UBT.{digest}.cpp')
        wrapper = winpath_from_local(wrapper_local)
        if len(wrapper) >= 2 and wrapper[1] == ':':
            wrapper = wrapper.replace('/', '\\')
        else:
            wrapper = wrapper.replace('\\', '/')
        write_if_changed(wrapper_local,
            '// Compiler-authored UBT unity membership; copied into nvim cache.\n'
            + ''.join(f'#include "{member_path}"\n' for member_path in member_paths))
        if group_kind == 'rsp':
            command = rewritten_response_arguments(template, unity_path, group_args, wrapper)
        else:
            command = rewritten_arguments(template, wrapper)
        if not command:
            print('ERROR: accepted unity group no longer rewrites its source', file=sys.stderr)
            return 1
        new_cdb.append({
            'directory': template.get('directory', ''),
            'arguments': command,
            'file': wrapper,
            'nvim_ue_members': [portable_member_path(member_path) for member_path in member_paths],
            'nvim_ue_module_root': module_roots[unity_path],
        })

    # A source without current-build UBT unity evidence stays an exact original
    # TU. This is slower but semantics-preserving and makes coverage complete.
    for index, entry in enumerate(cdb):
        if index not in claimed:
            fallback_entry = {
                'directory': entry.get('directory', ''),
                'arguments': list(entry.get('arguments', [])),
                'file': entry.get('file', ''),
                'nvim_ue_members': [portable_member_path(entry.get('file', ''))],
                'nvim_ue_module_root': portable_module_root(entry.get('file', '')),
            }
            new_cdb.append(fallback_entry)

    covered = len(claimed) + (len(cdb) - len(claimed))
    if covered != len(cdb):
        print(f'ERROR: source coverage mismatch: input={len(cdb)} covered={covered}',
              file=sys.stderr)
        return 1

    print(
        f'[hot-super] active unity root evidence: {root_evidence}; '
        f'proven groups: {len(groups)}; grouped sources: {len(claimed)}; '
        f'exact per-file fallback: {len(cdb) - len(claimed)}',
        file=sys.stderr,
    )
    print(f'[hot-super] background TUs: {len(new_cdb)} '
          f'(compression {len(cdb)/max(len(new_cdb),1):.1f}x)', file=sys.stderr)

    changed = write_if_changed(out_local, json.dumps(new_cdb))
    print(f'[hot-super] {"wrote" if changed else "unchanged"}: {out_local}', file=sys.stderr)
    return 0


if __name__ == '__main__':
    sys.exit(main())
