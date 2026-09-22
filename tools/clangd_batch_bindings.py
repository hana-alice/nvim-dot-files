"""Prove shard bindings in their original compiler TUs, never standalone headers.

Run the CLI in an owned subprocess: native libclang failure cannot be recovered
in Python, and parsing temporarily selects the compilation command's cwd.
"""
import argparse
import ctypes as C
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import time
from urllib.parse import unquote, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cdb_argv import normalize_cdb
from build_hot_super_unity_cdb import strip_write_only_flags


class String(C.Structure):
    _fields_ = [('data', C.c_void_p), ('private_flags', C.c_uint)]


class Location(C.Structure):
    _fields_ = [('ptr_data', C.c_void_p * 2), ('int_data', C.c_uint)]


class Cursor(C.Structure):
    _fields_ = [('kind', C.c_uint), ('xdata', C.c_int), ('data', C.c_void_p * 3)]


class Range(C.Structure):
    _fields_ = [('ptr_data', C.c_void_p * 2), ('begin_int_data', C.c_uint), ('end_int_data', C.c_uint)]


class Token(C.Structure):
    _fields_ = [('int_data', C.c_uint * 4), ('ptr_data', C.c_void_p)]


class Type(C.Structure):
    _fields_ = [('kind', C.c_int), ('data', C.c_void_p * 2)]


Visitor = C.CFUNCTYPE(C.c_uint, Cursor, Cursor, C.c_void_p)


class Libclang:
    def __init__(self, path):
        self.lib = C.CDLL(str(path))
        pointer = C.c_void_p
        self.bind('clang_getCString', C.c_char_p, String)
        self.bind('clang_disposeString', None, String)
        self.bind('clang_getClangVersion', String)
        self.bind('clang_createIndex', pointer, C.c_int, C.c_int)
        self.bind('clang_disposeIndex', None, pointer)
        self.bind('clang_parseTranslationUnit2FullArgv', C.c_uint, pointer, C.c_char_p,
                  C.POINTER(C.c_char_p), C.c_int, pointer, C.c_uint, C.c_uint, C.POINTER(pointer))
        self.bind('clang_disposeTranslationUnit', None, pointer)
        self.bind('clang_getFile', pointer, pointer, C.c_char_p)
        self.bind('clang_getLocation', Location, pointer, pointer, C.c_uint, C.c_uint)
        self.bind('clang_getCursor', Cursor, pointer, Location)
        self.bind('clang_getCursorUSR', String, Cursor)
        self.bind('clang_getCursorSpelling', String, Cursor)
        self.bind('clang_getCursorReferenced', Cursor, Cursor)
        self.bind('clang_getCanonicalCursor', Cursor, Cursor)
        self.bind('clang_Cursor_isNull', C.c_uint, Cursor)
        self.bind('clang_isInvalid', C.c_uint, C.c_uint)
        self.bind('clang_isInvalidDeclaration', C.c_uint, Cursor)
        self.bind('clang_isDeclaration', C.c_uint, C.c_uint)
        self.bind('clang_isReference', C.c_uint, C.c_uint)
        self.bind('clang_isExpression', C.c_uint, C.c_uint)
        self.bind('clang_equalCursors', C.c_uint, Cursor, Cursor)
        self.bind('clang_getTranslationUnitCursor', Cursor, pointer)
        self.bind('clang_visitChildren', C.c_uint, Cursor, Visitor, pointer)
        self.bind('clang_getCursorExtent', Range, Cursor)
        self.bind('clang_getRangeStart', Location, Range)
        self.bind('clang_getRangeEnd', Location, Range)
        self.bind('clang_getSpellingLocation', None, Location, C.POINTER(pointer),
                  C.POINTER(C.c_uint), C.POINTER(C.c_uint), C.POINTER(C.c_uint))
        self.bind('clang_File_isEqual', C.c_int, pointer, pointer)
        self.bind('clang_getToken', C.POINTER(Token), pointer, Location)
        self.bind('clang_getTokenKind', C.c_uint, Token)
        self.bind('clang_getTokenSpelling', String, pointer, Token)
        self.bind('clang_getTokenLocation', Location, pointer, Token)
        self.bind('clang_disposeTokens', None, pointer, C.POINTER(Token), C.c_uint)
        self.bind('clang_getNumDiagnostics', C.c_uint, pointer)
        self.bind('clang_getDiagnostic', pointer, pointer, C.c_uint)
        self.bind('clang_getDiagnosticSeverity', C.c_uint, pointer)
        self.bind('clang_formatDiagnostic', String, pointer, C.c_uint)
        self.bind('clang_disposeDiagnostic', None, pointer)

    def bind(self, name, result, *arguments):
        function = getattr(self.lib, name)
        function.restype, function.argtypes = result, list(arguments)

    def string(self, value):
        try:
            raw = self.lib.clang_getCString(value)
            return raw.decode('utf-8', errors='strict') if raw else ''
        finally:
            self.lib.clang_disposeString(value)

    def invalid(self, cursor):
        return (self.lib.clang_Cursor_isNull(cursor)
                or self.lib.clang_isInvalid(cursor.kind)
                or self.lib.clang_isInvalidDeclaration(cursor))


def utf16_column_to_byte(text, column):
    """Convert a zero-based UTF-16 column to a one-based UTF-8 byte column."""
    if type(column) is not int or column < 0:
        raise ValueError('invalid UTF-16 column')
    units, size = 0, 0
    for character in text:
        if units == column:
            return size + 1
        units += 2 if ord(character) > 0xffff else 1
        size += len(character.encode('utf-8'))
        if units > column:
            raise ValueError('UTF-16 column splits a surrogate pair')
    if units == column:
        return size + 1
    raise ValueError('UTF-16 column exceeds the line')


def _uri_path(uri):
    parts = urlsplit(uri)
    if parts.scheme != 'file' or parts.query or parts.fragment:
        raise ValueError('request URI must be a local file URI')
    path = unquote(parts.path, encoding='utf-8', errors='strict')
    if parts.netloc and parts.netloc != 'localhost':
        if os.name != 'nt':
            raise ValueError('remote file URI is unsupported on this host')
        path = '//' + parts.netloc + path
    elif os.name == 'nt' and re.match(r'^/[A-Za-z]:/', path):
        path = path[1:]
    return Path(path).resolve(strict=True)


def _resource_directory(libclang_path, version, requested):
    major_match = re.search(r'clang version (\d+)', version)
    if not major_match:
        raise ValueError('cannot identify libclang resource version')
    major = major_match.group(1)
    if requested:
        candidates = [Path(requested)]
    else:
        library_dir = Path(libclang_path).resolve().parent
        candidates = [library_dir.parent / 'lib' / 'clang' / major,
                      library_dir / 'clang' / major]
    for candidate in candidates:
        if candidate.name.split('.')[0] == major and (candidate / 'include').is_dir():
            return candidate.resolve()
    raise ValueError('matching libclang resource directory is unavailable')


def _parse_arguments(entry, resource_dir):
    if not isinstance(entry.get('directory'), str) or not entry['directory']:
        raise ValueError('compile directory is required')
    directory = Path(entry.get('directory', '')).resolve(strict=True)
    if not directory.is_dir():
        raise ValueError('compile directory is not a directory')
    source = Path(entry['file'])
    source = (directory / source).resolve(strict=True)
    if source.suffix.lower() not in {'.c', '.cc', '.cpp', '.cxx', '.m', '.mm'}:
        raise ValueError('context must be an original source TU, not a standalone header')
    original = entry['arguments']
    if (not isinstance(original, list) or not original or not original[0]
            or any(not isinstance(arg, str) or '\0' in arg for arg in original)):
        raise ValueError('invalid compilation arguments')
    options = original[1:]
    if '--' in options:
        terminator = options.index('--')
        inputs = options[terminator + 1:]
        if len(inputs) != 1 or (directory / inputs[0]).resolve() != source:
            raise ValueError('input terminator must be followed by the single original TU')
        # libclang appends source_filename and preprocessing flags itself.
        # Keeping -- would reinterpret those options (or an added VFS option)
        # as filenames. Everything after it was validated as the one TU above.
        options = options[:terminator]
    arguments = [original[0]]
    for arg in strip_write_only_flags(options):
        if arg == '-c':
            continue
        # Source is passed explicitly to libclang. All semantic options retain
        # their original order, including language, macros, includes and target.
        if not arg.startswith('-') and os.path.normcase(str((directory / arg).resolve())) == os.path.normcase(str(source)):
            continue
        arguments.append(arg)
    # FullArgv keeps the effective driver's identity, including its language
    # mode and executable-relative lookup; never replace argv[0] with clang.
    for position, arg in enumerate(arguments):
        if arg == '-resource-dir':
            if position + 1 >= len(arguments) or (directory / arguments[position + 1]).resolve() != resource_dir:
                raise ValueError('compile resource directory differs from the selected libclang')
        elif arg.startswith('-resource-dir=') and (directory / arg.split('=', 1)[1]).resolve() != resource_dir:
            raise ValueError('compile resource directory differs from the selected libclang')
    if not any(a == '-resource-dir' or a.startswith('-resource-dir=') for a in arguments):
        arguments.append('-resource-dir=' + str(resource_dir))
    diagnostic_adjustments = []
    if '-Werror' in arguments:
        # This changes warning severity only. Every remaining error/fatal
        # diagnostic still rejects the entire TU below, even after a zero exit.
        diagnostic_adjustments.append('-Wno-error')
        arguments.extend(diagnostic_adjustments)
    return directory, source, arguments, diagnostic_adjustments


def _diagnostics(api, tu):
    errors, warnings, details = 0, 0, []
    for number in range(api.lib.clang_getNumDiagnostics(tu)):
        diagnostic = api.lib.clang_getDiagnostic(tu, number)
        try:
            severity = api.lib.clang_getDiagnosticSeverity(diagnostic)
            errors += severity >= 3
            warnings += severity == 2
            if severity >= 3 and len(details) < 16:
                details.append({'severity': severity,
                                'message': api.string(api.lib.clang_formatDiagnostic(diagnostic, 0))})
        finally:
            api.lib.clang_disposeDiagnostic(diagnostic)
    return {'error_count': errors, 'warning_count': warnings, 'errors': details}


def _spelling_position(api, location):
    source, line, column, offset = C.c_void_p(), C.c_uint(), C.c_uint(), C.c_uint()
    api.lib.clang_getSpellingLocation(location, C.byref(source), C.byref(line),
                                     C.byref(column), C.byref(offset))
    return source, offset.value


def _container(api, tu, selected, location):
    """Locate the selected cursor in its actual AST ancestor chain.

    TypeRef parent getters are null, so query the compiler tree. Extent pruning
    may conservatively fail for cross-file macro nodes; it never guesses owner.
    """
    source, offset = _spelling_position(api, location)
    found = []
    failures = []

    def walk(parent, ancestors):
        @Visitor
        def visit(child, _parent, _data):
            try:
                if api.lib.clang_equalCursors(child, selected):
                    found.append(ancestors[-1] if ancestors else '')
                    return 0
                extent = api.lib.clang_getCursorExtent(child)
                begin_file, begin = _spelling_position(api, api.lib.clang_getRangeStart(extent))
                end_file, end = _spelling_position(api, api.lib.clang_getRangeEnd(extent))
                if (not begin_file or not end_file
                        or not api.lib.clang_File_isEqual(source, begin_file)
                        or not api.lib.clang_File_isEqual(source, end_file)
                        or not begin <= offset < end):
                    return 1
                # FriendDecl is an unnamed syntactic wrapper whose libclang
                # USR can be the bare "c:" prefix; it is not a symbol owner.
                named = api.lib.clang_isDeclaration(child.kind) and api.string(api.lib.clang_getCursorSpelling(child))
                usr = api.string(api.lib.clang_getCursorUSR(child)) if named else ''
                walk(child, ancestors + [usr] if usr else ancestors)
                return 0 if found or failures else 1
            except Exception as error:
                # ctypes cannot propagate callback exceptions across native code.
                failures.append(str(error))
                return 0
        api.lib.clang_visitChildren(parent, visit, None)

    walk(api.lib.clang_getTranslationUnitCursor(tu), [])
    if failures or not found:
        return {'ok': False, 'reason': 'container-unproven'}
    usr = found[0]
    return {'ok': True, 'container_usr': usr,
            'actual_container': hashlib.sha1(usr.encode()).digest()[:8].hex() if usr else '0000000000000000'}


def _reference_metadata(api, tu, request, cursor, referenced, location):
    proof = {}
    if 'kind' in request:
        # Currently admitted additions are Reference | Spelled. Other roles
        # require their own compiler proof and are deliberately fail-closed.
        if request['kind'] != 12 or api.lib.clang_equalCursors(cursor, referenced) or not (
                api.lib.clang_isReference(cursor.kind) or api.lib.clang_isExpression(cursor.kind)):
            return {'ok': False, 'reason': 'reference-role-unproven'}
        token = api.lib.clang_getToken(tu, location)
        if not token:
            return {'ok': False, 'reason': 'spelled-reference-unproven'}
        try:
            token_source, token_offset = _spelling_position(api, api.lib.clang_getTokenLocation(tu, token[0]))
            source, offset = _spelling_position(api, location)
            if (api.lib.clang_getTokenKind(token[0]) != 2 or not token_source or not source
                    or not api.lib.clang_File_isEqual(source, token_source) or offset != token_offset
                    or api.string(api.lib.clang_getTokenSpelling(tu, token[0]))
                    != api.string(api.lib.clang_getCursorSpelling(referenced))):
                return {'ok': False, 'reason': 'spelled-reference-unproven'}
        finally:
            api.lib.clang_disposeTokens(tu, token, 1)
        proof['verified_kind'] = 12
    if 'container' in request:
        container = _container(api, tu, cursor, location)
        if not container['ok']:
            return container
        proof.update(container)
        if container['actual_container'] != request['container'].lower():
            proof.update({'ok': False, 'reason': 'container-mismatch'})
            return proof
    proof.update({'ok': True, 'reason': 'verified'})
    return proof


def _query(api, tu, request, path, byte_column):
    source = api.lib.clang_getFile(tu, str(path).encode('utf-8'))
    if not source:
        return {'ok': False, 'reason': 'file-not-in-tu'}
    location = api.lib.clang_getLocation(tu, source, request['line'] + 1, byte_column)
    cursor = api.lib.clang_getCursor(tu, location)
    if api.invalid(cursor):
        return {'ok': False, 'reason': 'invalid-cursor'}
    if cursor.kind == 49:  # CXCursor_OverloadedDeclRef, defined by clang-c/Index.h.
        return {'ok': False, 'reason': 'ambiguous-cursor'}
    referenced = api.lib.clang_getCursorReferenced(cursor)
    if api.invalid(referenced) or referenced.kind == 49:
        return {'ok': False, 'reason': 'invalid-referenced-cursor'}
    canonical = api.lib.clang_getCanonicalCursor(referenced)
    if api.invalid(canonical):
        return {'ok': False, 'reason': 'invalid-canonical-cursor'}
    usr = api.string(api.lib.clang_getCursorUSR(canonical))
    actual = hashlib.sha1(usr.encode('utf-8')).digest()[:8].hex() if usr else ''
    matches = bool(usr) and actual == request['symbol_id'].lower()
    proof = {'ok': matches, 'reason': 'verified' if matches else 'symbol-id-mismatch',
            'usr': usr, 'actual_symbol_id': actual, 'cursor_kind': cursor.kind,
            'canonical_kind': canonical.kind, 'line': request['line'] + 1,
            'byte_column': byte_column}
    if matches:
        proof.update(_reference_metadata(api, tu, request, cursor, referenced, location))
    return proof


def verify_bindings(entries, requests, libclang_path, resource_dir=None):
    """Require every requested 0-based entry context to prove the expected ID.

    Each original source TU is parsed once and disposed before the next one.
    No header-only AST, heuristic name match, or partial success is accepted.
    """
    started = time.monotonic()
    evidence = {'requests': [], 'translation_units': [], 'toolchain': {}}

    def finish(ok, reason):
        evidence['wall_seconds'] = round(time.monotonic() - started, 6)
        return {'ok': ok, 'reason': reason, 'evidence': evidence}

    prepared, grouped, file_lines = [], {}, {}
    try:
        if not isinstance(entries, list) or not isinstance(requests, list):
            raise ValueError('entries and requests must be arrays')
        if any(not isinstance(entry, dict) for entry in entries):
            raise ValueError('compilation entries must be objects')
        entries, _ = normalize_cdb(entries)
        for number, request in enumerate(requests):
            if not isinstance(request, dict):
                raise ValueError('request must be an object')
            contexts = request.get('contexts')
            if not isinstance(contexts, list) or not contexts or any(
                    type(index) is not int or index < 0 or index >= len(entries) for index in contexts):
                raise ValueError('request contexts must contain valid original entry indices')
            if type(request.get('line')) is not int or request['line'] < 0:
                raise ValueError('request line must be a zero-based nonnegative integer')
            if not isinstance(request.get('symbol_id'), str) or not re.fullmatch(r'[0-9a-fA-F]{16}', request['symbol_id']):
                raise ValueError('expected SymbolID must contain 16 hexadecimal digits')
            if not isinstance(request.get('uri'), str):
                raise ValueError('request URI must be a string')
            if 'kind' in request and type(request['kind']) is not int:
                raise ValueError('reference kind must be an integer')
            if 'container' in request and (not isinstance(request['container'], str)
                    or not re.fullmatch(r'[0-9a-fA-F]{16}', request['container'])):
                raise ValueError('container SymbolID must contain 16 hexadecimal digits')
            path = _uri_path(request['uri'])
            if path not in file_lines:
                file_lines[path] = path.read_bytes().split(b'\n')
            lines = file_lines[path]
            if request['line'] >= len(lines):
                raise ValueError('request line exceeds the file')
            text = lines[request['line']].rstrip(b'\r').decode('utf-8', errors='strict')
            byte_column = utf16_column_to_byte(text, request['column'])
            prepared.append((request, path, byte_column))
            evidence['requests'].append({key: request[key] for key in ('uri', 'line', 'column', 'symbol_id')})
            evidence['requests'][-1].update({'request_index': number, 'ok': False,
                                             'reason': 'not-verified', 'contexts': []})
            evidence['requests'][-1].update({key: request[key] for key in ('kind', 'container') if key in request})
            for index in sorted(set(contexts)):
                grouped.setdefault(index, []).append(number)
    except (KeyError, TypeError, ValueError, OSError) as error:
        evidence['error'] = str(error)
        return finish(False, 'invalid-request')
    if not requests:
        return finish(True, 'no-bindings-requested')
    try:
        api = Libclang(libclang_path)
        version = api.string(api.lib.clang_getClangVersion())
        resource = _resource_directory(libclang_path, version, resource_dir)
        evidence['toolchain'] = {'libclang_path': str(Path(libclang_path).resolve()),
                                 'version': version, 'resource_dir': str(resource)}
    except (AttributeError, OSError, ValueError, TypeError) as error:
        evidence['error'] = str(error)
        return finish(False, 'libclang-unavailable')
    index_handle = api.lib.clang_createIndex(0, 0)
    if not index_handle:
        return finish(False, 'libclang-index-unavailable')
    previous_cwd = Path.cwd()
    try:
        for entry_index, numbers in sorted(grouped.items()):
            unit = {'entry_index': entry_index, 'file': entries[entry_index]['file'], 'ok': False}
            evidence['translation_units'].append(unit)
            tu = C.c_void_p()
            try:
                directory, source, arguments, adjustments = _parse_arguments(entries[entry_index], resource)
                unit.update({'file': str(source), 'directory': str(directory),
                             'arguments_sha256': hashlib.sha256(json.dumps(arguments).encode()).hexdigest(),
                             'diagnostic_adjustments': adjustments})
                encoded = [arg.encode('utf-8') for arg in arguments]
                argv = (C.c_char_p * len(encoded))(*encoded)
                os.chdir(directory)
                parse_started = time.monotonic()
                code = api.lib.clang_parseTranslationUnit2FullArgv(index_handle, str(source).encode('utf-8'),
                    argv, len(encoded), None, 0, 0x201, C.byref(tu))
                unit.update({'parse_code': code, 'parse_seconds': round(time.monotonic() - parse_started, 6)})
                unit['diagnostics'] = _diagnostics(api, tu) if tu else {'error_count': 0}
                if code or not tu or unit['diagnostics']['error_count']:
                    unit['reason'] = 'tu-parse-error'
                else:
                    unit.update({'ok': True, 'reason': 'parsed'})
                for number in numbers:
                    proof = _query(api, tu, *prepared[number]) if unit['ok'] else {'ok': False, 'reason': unit['reason']}
                    proof['entry_index'] = entry_index
                    evidence['requests'][number]['contexts'].append(proof)
            except (KeyError, TypeError, ValueError, OSError) as error:
                unit.update({'reason': 'invalid-compilation-context', 'error': str(error)})
                for number in numbers:
                    evidence['requests'][number]['contexts'].append({
                        'entry_index': entry_index, 'ok': False, 'reason': unit['reason']})
            finally:
                if tu:
                    api.lib.clang_disposeTranslationUnit(tu)
                os.chdir(previous_cwd)
    finally:
        api.lib.clang_disposeIndex(index_handle)
        os.chdir(previous_cwd)
    for proof in evidence['requests']:
        proof['ok'] = bool(proof['contexts']) and all(item['ok'] for item in proof['contexts'])
        proof['reason'] = 'verified' if proof['ok'] else next(
            (item['reason'] for item in proof['contexts'] if not item['ok']), 'missing-context')
    return finish(all(proof['ok'] for proof in evidence['requests']),
                  'verified' if all(proof['ok'] for proof in evidence['requests']) else 'binding-verification-failed')


def _template_api(api):
    """Additional CIndex APIs; existing binding proof keeps its original path."""
    for name in ('clang_getCursorSemanticParent', 'clang_getSpecializedCursorTemplate'):
        api.bind(name, Cursor, Cursor)
    for name in ('clang_getCursorDisplayName',):
        api.bind(name, String, Cursor)
    api.bind('clang_getCursorType', Type, Cursor)
    api.bind('clang_getCanonicalType', Type, Type)
    api.bind('clang_Type_getSizeOf', C.c_longlong, Type)
    api.bind('clang_equalTypes', C.c_uint, Type, Type)
    api.bind('clang_Cursor_getNumTemplateArguments', C.c_int, Cursor)
    api.bind('clang_Cursor_getTemplateArgumentKind', C.c_uint, Cursor, C.c_uint)
    api.bind('clang_Cursor_getTemplateArgumentType', Type, Cursor, C.c_uint)
    api.bind('clang_Cursor_getTemplateArgumentValue', C.c_longlong, Cursor, C.c_uint)
    api.bind('clang_getCursorLocation', Location, Cursor)
    api.bind('clang_getFileName', String, C.c_void_p)
    api.bind('clang_getTokenExtent', Range, C.c_void_p, Token)
    api.bind('clang_getExpansionLocation', None, Location, C.POINTER(C.c_void_p),
             C.POINTER(C.c_uint), C.POINTER(C.c_uint), C.POINTER(C.c_uint))


def _template_position(api, location, expansion=False):
    file, line, column, offset = C.c_void_p(), C.c_uint(), C.c_uint(), C.c_uint()
    function = api.lib.clang_getExpansionLocation if expansion else api.lib.clang_getSpellingLocation
    function(location, C.byref(file), C.byref(line), C.byref(column), C.byref(offset))
    if not file or not line.value or not column.value:
        raise ValueError('template-source-location-unproven')
    return {'file': api.string(api.lib.clang_getFileName(file)), 'line': line.value,
            'column': column.value, 'offset': offset.value}


def _template_children(api, cursor):
    children = []
    @Visitor
    def collect(child, _parent, _data):
        children.append(child)
        return 1
    api.lib.clang_visitChildren(cursor, collect, None)
    return children


def _template_fact(api, tu, cursor, symbols):
    """Only the proven (int integral, own type parameter) partial shape."""
    lib = api.lib
    usr = api.string(lib.clang_getCursorUSR(cursor))
    primary = lib.clang_getSpecializedCursorTemplate(cursor)
    owner = lib.clang_getCursorSemanticParent(cursor)
    primary_usr, owner_usr = (api.string(lib.clang_getCursorUSR(item)) for item in (primary, owner))
    if primary.kind != 31 or not primary_usr or not owner_usr:
        raise ValueError('template-primary-or-owner-unproven')
    parameters = [p for p in _template_children(api, primary) if p.kind in (27, 28, 29)]
    children = _template_children(api, cursor)
    own = [p for p in children if p.kind in (27, 28, 29)]
    if (lib.clang_Cursor_getNumTemplateArguments(cursor) != 2
            or [p.kind for p in parameters] != [28, 27] or [p.kind for p in own] != [27]
            or [lib.clang_Cursor_getTemplateArgumentKind(cursor, i) for i in range(2)] != [4, 1]):
        raise ValueError('unsupported-template-argument-shape')
    integer = lib.clang_getCursorType(parameters[0])
    width = lib.clang_Type_getSizeOf(integer) * 8
    # Check before the APInt getter: values wider than 64 bits can assert.
    if integer.kind != 17 or not 0 < width <= 64:  # CXType_Int only.
        raise ValueError('unsupported-integral-parameter-type')
    argument = lib.clang_Cursor_getTemplateArgumentType(cursor, 1)
    if (not lib.clang_equalTypes(lib.clang_getCanonicalType(argument),
                                lib.clang_getCanonicalType(lib.clang_getCursorType(own[0])))
            or not any(child.kind == 43 and lib.clang_equalCursors(
                lib.clang_getCursorReferenced(child), own[0]) for child in children)):
        raise ValueError('template-type-parameter-binding-unproven')
    parameter_usr = api.string(lib.clang_getCursorUSR(parameters[0]))
    type_usr = api.string(lib.clang_getCursorUSR(own[0]))
    if not parameter_usr or not type_usr:
        raise ValueError('template-parameter-identity-unproven')
    spelling = _template_position(api, lib.clang_getCursorLocation(cursor))
    expansion = _template_position(api, lib.clang_getCursorLocation(cursor), True)
    file = lib.clang_getFile(tu, spelling['file'].encode('utf-8'))
    token = lib.clang_getToken(tu, lib.clang_getLocation(tu, file, spelling['line'], spelling['column']))
    if not token:
        raise ValueError('template-name-token-unproven')
    try:
        name = api.string(lib.clang_getCursorSpelling(cursor))
        if lib.clang_getTokenKind(token[0]) != 2 or api.string(lib.clang_getTokenSpelling(tu, token[0])) != name:
            raise ValueError('template-name-token-unproven')
        end = _template_position(api, lib.clang_getRangeEnd(lib.clang_getTokenExtent(tu, token[0])))
    finally:
        lib.clang_disposeTokens(tu, token, 1)
    display = api.string(lib.clang_getCursorDisplayName(cursor))
    for symbol in symbols:
        if display != symbol['name'] + symbol['template_specialization_args']:
            raise ValueError('template-printed-arguments-mismatch')
        declaration = symbol['canonical_declaration']
        path = _uri_path(declaration['uri'])
        lines = path.read_bytes().split(b'\n')
        for key, position in (('start', spelling), ('end', end)):
            line, column = declaration[key]
            if (not os.path.samefile(path, position['file']) or position['line'] != line + 1
                    or position['column'] != utf16_column_to_byte(lines[line].decode('utf-8'), column)):
                raise ValueError('template-canonical-declaration-mismatch')
    return {'usr': usr, 'primary_usr': primary_usr, 'owner_usr': owner_usr,
            'spelling_location': spelling, 'expansion_location': expansion, 'display_name': display,
            'arguments': [{'index': 0, 'kind': 'Integral', 'parameter_usr': parameter_usr,
                           'type_kind': 17, 'width_bits': width, 'signed': True,
                           'value': str(lib.clang_Cursor_getTemplateArgumentValue(cursor, 0))},
                          {'index': 1, 'kind': 'Type', 'parameter_usr': type_usr,
                           'owner_usr': usr, 'parameter_index': 0}]}


def _template_cursors(api, tu, targets):
    found, failures = {sid: [] for sid in targets}, []
    @Visitor
    def visit(cursor, _parent, _data):
        try:
            if cursor.kind == 32:  # CXCursor_ClassTemplatePartialSpecialization.
                usr = api.string(api.lib.clang_getCursorUSR(cursor))
                sid = hashlib.sha1(usr.encode('utf-8')).digest()[:8].hex()
                if sid in found:
                    found[sid].append(cursor)
                return 1
            # The supported declarations are class members, never local types.
            return 1 if cursor.kind in (8, 21, 24, 25, 26) else 2
        except Exception as error:
            failures.append(str(error))
            return 0
    api.lib.clang_visitChildren(api.lib.clang_getTranslationUnitCursor(tu), visit, None)
    if failures:
        raise ValueError(failures[0])
    return found


def verify_template_arguments(entries, requests, libclang_path, resource_dir=None):
    """Prove raw printed records against every declared original and candidate.

    Candidate is entries[-1]. The caller binds the exact original context set
    to its independent graphs; this function never treats missing facts as equal.
    """
    started = time.monotonic()
    evidence = {'entries': entries, 'requests': [], 'translation_units': [], 'toolchain': {}}
    def finish(ok, reason):
        evidence['wall_seconds'] = round(time.monotonic() - started, 6)
        return {'ok': ok, 'reason': reason, 'evidence': evidence}
    grouped = {}
    try:
        if not isinstance(entries, list) or len(entries) < 2 or not isinstance(requests, list) or not requests:
            raise ValueError('original entries, candidate entry and requests are required')
        for number, request in enumerate(requests):
            sid = request['symbol_id']
            if not isinstance(sid, str) or not re.fullmatch('[0-9a-f]{16}', sid) or not request['originals']:
                raise ValueError('invalid template symbol or original contexts')
            contexts = [(o['index'], 'original', o['symbols']) for o in request['originals']]
            contexts.append((len(entries) - 1, 'candidate', request['candidate']))
            if len({index for index, _, _ in contexts}) != len(contexts):
                raise ValueError('duplicate template context')
            for index, role, symbols in contexts:
                if type(index) is not int or not 0 <= index < len(entries) - (role == 'original'):
                    raise ValueError('invalid template context index')
                if not isinstance(symbols, list) or not symbols:
                    raise ValueError('missing template records')
                for symbol in symbols:
                    if (symbol['id'] != sid or not symbol['name']
                            or not isinstance(symbol['template_specialization_args'], str)):
                        raise ValueError('invalid template record identity')
                    declaration = symbol['canonical_declaration']
                    _uri_path(declaration['uri'])
                    for key in ('start', 'end'):
                        if len(declaration[key]) != 2 or any(type(n) is not int or n < 0 for n in declaration[key]):
                            raise ValueError('invalid template declaration location')
                grouped.setdefault(index, []).append((number, role, symbols))
            evidence['requests'].append({'request': request, 'ok': False, 'contexts': []})
    except (KeyError, IndexError, TypeError, ValueError, OSError) as error:
        evidence['error'] = str(error)
        return finish(False, 'invalid-request')
    try:
        api = Libclang(libclang_path)
        _template_api(api)
        version = api.string(api.lib.clang_getClangVersion())
        if not re.search(r'clang version 22\.1\.5(?:\s|$)', version):
            raise ValueError('template printing proof requires libclang 22.1.5')
        resource = _resource_directory(libclang_path, version, resource_dir)
        evidence['toolchain'] = {'libclang_path': str(Path(libclang_path).resolve()),
                                'version': version, 'resource_dir': str(resource)}
    except (AttributeError, OSError, ValueError, TypeError) as error:
        evidence['error'] = str(error)
        return finish(False, 'libclang-unavailable')
    handle, previous_cwd = api.lib.clang_createIndex(0, 0), Path.cwd()
    if not handle:
        return finish(False, 'libclang-index-unavailable')
    try:
        for index, pending in sorted(grouped.items()):
            unit, tu = {'entry_index': index, 'ok': False}, C.c_void_p()
            evidence['translation_units'].append(unit)
            try:
                directory, source, arguments, adjustments = _parse_arguments(entries[index], resource)
                unit.update(file=str(source), directory=str(directory), arguments=arguments,
                            diagnostic_adjustments=adjustments)
                argv = (C.c_char_p * len(arguments))(*(a.encode('utf-8') for a in arguments))
                os.chdir(directory)
                unit['parse_code'] = api.lib.clang_parseTranslationUnit2FullArgv(handle, str(source).encode('utf-8'),
                    argv, len(arguments), None, 0, 0x201, C.byref(tu))
                unit['diagnostics'] = _diagnostics(api, tu) if tu else {'error_count': 0}
                if unit['parse_code'] or not tu or unit['diagnostics']['error_count']:
                    raise ValueError('tu-parse-error')
                found = _template_cursors(api, tu, {requests[n]['symbol_id'] for n, _, _ in pending})
                unit['ok'] = True
                for number, role, symbols in pending:
                    proof = {'index': index, 'role': role, 'ok': False}
                    evidence['requests'][number]['contexts'].append(proof)
                    try:
                        cursors = found[requests[number]['symbol_id']]
                        if len(cursors) != 1:
                            raise ValueError('template-declaration-missing-or-ambiguous')
                        proof['fact'] = _template_fact(api, tu, cursors[0], symbols)
                        proof.update(ok=True, reason='verified')
                    except (KeyError, IndexError, TypeError, ValueError, OSError) as error:
                        proof['reason'] = str(error)
            except (KeyError, TypeError, ValueError, OSError) as error:
                unit['reason'] = str(error)
                for number, role, _ in pending:
                    evidence['requests'][number]['contexts'].append({'index': index, 'role': role,
                        'ok': False, 'reason': unit['reason']})
            finally:
                if tu:
                    api.lib.clang_disposeTranslationUnit(tu)
                os.chdir(previous_cwd)
    finally:
        api.lib.clang_disposeIndex(handle)
    for proof in evidence['requests']:
        try:
            if not all(context['ok'] for context in proof['contexts']):
                raise ValueError(next(c['reason'] for c in proof['contexts'] if not c['ok']))
            baseline = proof['contexts'][0]['fact']
            for context in proof['contexts'][1:]:
                fact = context['fact']
                if any(fact[key] != baseline[key] for key in ('usr', 'primary_usr', 'owner_usr', 'arguments')):
                    raise ValueError('template-canonical-facts-differ')
                for key in ('spelling_location', 'expansion_location'):
                    a, b = fact[key], baseline[key]
                    if (not os.path.samefile(a['file'], b['file'])
                            or any(a[k] != b[k] for k in ('line', 'column', 'offset'))):
                        raise ValueError('template-source-identity-differs')
            proof.update(ok=True, reason='verified')
        except (ValueError, OSError) as error:
            proof['reason'] = str(error)
    passed = all(proof['ok'] for proof in evidence['requests'])
    return finish(passed, 'verified' if passed else 'template-argument-verification-failed')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--request', required=True, type=Path)
    parser.add_argument('--out', required=True, type=Path)
    options = parser.parse_args()
    try:
        request = json.loads(options.request.read_text(encoding='utf-8-sig'))
        action = request.get('action', 'bindings')
        if action not in ('bindings', 'template-arguments'):
            raise ValueError('unknown verification action')
        verify = verify_template_arguments if action == 'template-arguments' else verify_bindings
        result = verify(request['entries'], request['requests'], request['libclang_path'], request.get('resource_dir'))
    except (KeyError, TypeError, ValueError, OSError) as error:
        result = {'ok': False, 'reason': 'invalid-request', 'evidence': {'error': str(error)}}
    options.out.parent.mkdir(parents=True, exist_ok=True)
    options.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    return 0 if result['ok'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
