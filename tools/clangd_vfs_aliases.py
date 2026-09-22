"""Collect compiler-proven Windows include aliases for a closed VFS snapshot.

LLVM 22.1.5 RedirectingFileSystem selects dot-normalization style from the first
separator. Mixed Windows paths can therefore lose the wrong parent component.
The caller must validate alias targets against frozen dependencies and layer the
aliases over a closed snapshot; these records never authorize filesystem fallback.
Run in an owned subprocess, since libclang parses are native and select the cwd.
"""
import argparse
import ctypes as C
import json
import ntpath
import os
from pathlib import Path
import posixpath
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from clangd_batch_bindings import (
    Cursor, Libclang, Location, String, Visitor, _diagnostics,
    _parse_arguments, _resource_directory,
)


def _include_alias(including, spelling, included):
    """Reproduce VFS's mixed-slash parent lookup, with a compiler-selected target."""
    if ntpath.isabs(spelling) or '..' not in spelling.replace('\\', '/').split('/'):
        return None
    lookup = ntpath.dirname(including) + '/' + spelling
    separators = [position for position in (lookup.find('/'), lookup.find('\\')) if position >= 0]
    if not separators or lookup[min(separators)] != '/':
        return None
    alias = ntpath.normpath(posixpath.normpath(lookup))
    target_path = Path(included).resolve(strict=True)
    if not target_path.is_file() or not ntpath.isabs(alias):
        raise ValueError('invalid-include-alias-target')
    target = str(target_path)
    if ntpath.normcase(alias) == ntpath.normcase(target):
        return None
    # A normalization workaround must never shadow another physical header.
    if Path(alias).exists() and Path(alias).resolve(strict=True) != target_path:
        raise ValueError('alias-collides-with-physical-file: ' + alias)
    return {'alias': alias, 'target': target}


def collect_aliases(entries, libclang_path, resource_dir=None):
    """Parse original whole TUs and return aliases plus compiler evidence.

    Every error rejects the whole collection and returns an empty aliases list.
    The builder remains responsible for frozen-dependency membership and collisions
    with its existing snapshot map, which this function does not receive.
    ``aliases`` are file redirects; ``directory_aliases`` are same-native-name
    directory-remap entries for the proven includer directories. Both require an
    outer VFS whose external filesystem is the closed snapshot, never the host FS.
    """
    started = time.monotonic()
    evidence = {'translation_units': [], 'include_records': []}
    aliases, directory_aliases = {}, {}

    def finish(ok, reason):
        evidence['seconds'] = round(time.monotonic() - started, 6)
        return {'ok': ok, 'reason': reason,
                'aliases': [aliases[key] for key in sorted(aliases)] if ok else [],
                'directory_aliases': [directory_aliases[key] for key in sorted(directory_aliases)] if ok else [],
                'evidence': evidence}

    if not isinstance(entries, list) or not entries:
        return finish(False, 'invalid-entries')
    if os.name != 'nt':
        return finish(True, 'no-windows-aliases')
    try:
        api = Libclang(libclang_path)
        version = api.string(api.lib.clang_getClangVersion())
        resource = _resource_directory(libclang_path, version, resource_dir)
        api.bind('clang_getCursorLocation', Location, Cursor)
        api.bind('clang_getFileName', String, C.c_void_p)
        api.bind('clang_getIncludedFile', C.c_void_p, Cursor)
        evidence['toolchain'] = {'version': version, 'resource_dir': str(resource),
                                 'libclang_path': str(Path(libclang_path).resolve())}
    except (AttributeError, OSError, ValueError, TypeError) as error:
        evidence['error'] = str(error)
        return finish(False, 'libclang-unavailable')
    index = api.lib.clang_createIndex(0, 0)
    if not index:
        return finish(False, 'libclang-index-unavailable')
    previous_cwd = Path.cwd()
    try:
        for number, entry in enumerate(entries):
            tu = C.c_void_p()
            unit = {'entry_index': number}
            evidence['translation_units'].append(unit)
            try:
                directory, source, arguments, adjustments = _parse_arguments(entry, resource)
                unit.update(file=str(source), diagnostic_adjustments=adjustments)
                argv = (C.c_char_p * len(arguments))(*(arg.encode('utf-8') for arg in arguments))
                os.chdir(directory)
                parse_started = time.monotonic()
                code = api.lib.clang_parseTranslationUnit2FullArgv(index, str(source).encode('utf-8'),
                    argv, len(arguments), None, 0, 0x201, C.byref(tu))
                unit.update(parse_code=code, parse_seconds=round(time.monotonic()-parse_started, 6))
                unit['diagnostics'] = _diagnostics(api, tu) if tu else {'error_count': 0}
                if code or not tu or unit['diagnostics']['error_count']:
                    return finish(False, 'tu-parse-error')
                callback_errors = []

                @Visitor
                def visit(cursor, parent, data):
                    # Inclusion directives are top-level detailed preprocessing records.
                    if cursor.kind != 503:  # CXCursor_InclusionDirective
                        return 1
                    try:
                        spelling = api.string(api.lib.clang_getCursorSpelling(cursor))
                        if '..' not in spelling.replace('\\', '/').split('/'):
                            return 1
                        source_file, line, column, offset = C.c_void_p(), C.c_uint(), C.c_uint(), C.c_uint()
                        api.lib.clang_getSpellingLocation(api.lib.clang_getCursorLocation(cursor),
                            C.byref(source_file), C.byref(line), C.byref(column), C.byref(offset))
                        included_file = api.lib.clang_getIncludedFile(cursor)
                        if not source_file or not included_file:
                            raise ValueError('include-target-unavailable')
                        including = api.string(api.lib.clang_getFileName(source_file))
                        included = api.string(api.lib.clang_getFileName(included_file))
                        record = {'entry_index': number, 'including': including,
                                  'line': line.value, 'spelling': spelling, 'included': included}
                        evidence['include_records'].append(record)
                        alias = _include_alias(including, spelling, included)
                        if alias:
                            key = ntpath.normcase(alias['alias'])
                            previous = aliases.get(key)
                            if previous and ntpath.normcase(previous['target']) != ntpath.normcase(alias['target']):
                                raise ValueError('alias-target-collision: ' + alias['alias'])
                            aliases[key] = alias
                            record['alias'] = alias
                            # Native directory remapping also handles a '\\..'
                            # component left unnormalized by POSIX lookup. Its
                            # external FS must be the closed snapshot layer.
                            parent_path = Path(including).resolve(strict=True).parent
                            parent_name = str(parent_path)
                            directory_aliases[ntpath.normcase(parent_name)] = {
                                'alias': parent_name, 'target': parent_name}
                        return 1
                    except (AttributeError, OSError, ValueError, TypeError) as error:
                        callback_errors.append(str(error))
                        return 0

                api.lib.clang_visitChildren(api.lib.clang_getTranslationUnitCursor(tu), visit, None)
                if callback_errors:
                    unit['errors'] = callback_errors
                    return finish(False, 'include-alias-unproven')
            except (AttributeError, KeyError, TypeError, ValueError, OSError) as error:
                unit['error'] = str(error)
                return finish(False, 'invalid-compilation-context')
            finally:
                if tu:
                    api.lib.clang_disposeTranslationUnit(tu)
                os.chdir(previous_cwd)
    finally:
        api.lib.clang_disposeIndex(index)
        os.chdir(previous_cwd)
    return finish(True, 'collected' if aliases else 'no-aliases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    try:
        request = json.loads(args.request.read_text(encoding='utf-8-sig'))
        result = collect_aliases(request['entries'], request['libclang_path'], request.get('resource_dir'))
    except (KeyError, TypeError, ValueError, OSError) as error:
        result = {'ok': False, 'aliases': [], 'directory_aliases': [],
                  'reason': 'invalid-request', 'evidence': {'error': str(error)}}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
