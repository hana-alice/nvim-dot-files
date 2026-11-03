"""Conservative lexical conflict screening and global index-superset policy.

Screening never certifies C++ compatibility: preprocessing, overload resolution and
all constructs not understood here remain subject to the real compilation gate.
No native process or source rewrite is performed by these helpers.
"""
import collections
import json
import re


def _key(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


# Tokenize before inspecting scopes: comments, ordinary/raw strings and character
# literals must not introduce fake braces or declarations. Conditional branches
# are deliberately all screened (false positives split groups, not lose sources).
_TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|R"([^ ()\\\t\r\n]{0,16})\(.*?\)\1"|'
                     r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|::|[^\s]', re.S)
_IDENT = re.compile(r'^[A-Za-z_]\w*$')


def file_definitions(text):
    tokens = [m.group() for m in _TOKENS.finditer(text)
              if not m.group().startswith(('//', '/*', '"', "'", 'R"'))]
    names, scopes, statement = set(), [], []

    def namespace_scope():
        return all(kind == 'namespace' for kind, _ in scopes)

    def record(name):
        prefix = [name for kind, name in scopes if kind == 'namespace' and name]
        names.add('::'.join(prefix + [name]))

    def declaration(part, brace=False):
        if not namespace_scope() or not part:
            return
        tags = [i for i, token in enumerate(part) if token in ('struct', 'class')]
        # A function body brace (`class T* F::G() {`) has a parameter list; an
        # elaborated type in its return type or parameters is not a class
        # definition. Only a tag outside any parentheses can start a definition.
        tags = [i for i in tags if '(' not in part[:i] and '(' not in part[i:]]
        if tags and brace:
            # Skip API/attribute macros: the class name is the last identifier
            # before an optional `final` and base-clause `:`.
            head = part[tags[-1] + 1:]
            stop = next((i for i, token in enumerate(head) if token in (':', 'final')), len(head))
            identifiers = [token for token in head[:stop] if _IDENT.match(token)]
            if identifiers:
                record(identifiers[-1])
        if 'DEFINE_LOG_CATEGORY_STATIC' in part:
            at = part.index('DEFINE_LOG_CATEGORY_STATIC')
            if part[at + 1:at + 2] == ['('] and at + 2 < len(part):
                record(part[at + 2])
        if 'static' in part:
            # Static functions: name directly before the first parameter list.
            # Static objects: declarator immediately before initializer/end.
            end = next((i for i, token in enumerate(part) if token in ('(', '=', '[')), len(part))
            identifiers = [token for token in part[:end] if _IDENT.match(token)]
            if len(identifiers) >= 3:
                record(identifiers[-1])
        elif any(kind == 'namespace' and not name for kind, name in scopes):
            end = next((i for i, token in enumerate(part) if token in ('(', '=', '[')), len(part))
            identifiers = [token for token in part[:end] if _IDENT.match(token)]
            if len(identifiers) >= 2 and part[0] not in ('using', 'typedef', 'namespace'):
                record(identifiers[-1])

    for token in tokens:
        if token == '{':
            declaration(statement, brace=True)
            if namespace_scope() and 'namespace' in statement and '=' not in statement:
                at = statement.index('namespace')
                name = ''.join(statement[at + 1:])
                scopes.append(('namespace', name))
            else:
                scopes.append(('other', ''))
            statement = []
        elif token == '}':
            if scopes:
                scopes.pop()
            statement = []
        elif token == ';':
            declaration(statement)
            statement = []
        else:
            statement.append(token)
    return names


def graph_superset(originals, candidate, ignore_files=(), macro_sites=None):
    """Global SymbolID preservation, per-own-file source/ref/relation superset.

    Approved differences: include multiplicity, additional symbols/relations,
    reference targets at an existing (kind,range) and canonical declaration at
    another declaration site already present in A. No signature/name/definition
    remapping, missing friend reference or counter/typedef ID folding is allowed.
    """
    ignored = set(ignore_files)
    macro_sites = macro_sites or {}
    originals = [{u: r for u, r in g.items() if u not in ignored} for g in originals]
    candidate = {u: r for u, r in candidate.items() if u not in ignored}
    bad = []
    expected_uris = set().union(*(set(g) for g in originals)) if originals else set()
    if not originals or set(candidate) != expected_uris:
        bad.append('own-file-set-mismatch')

    def table(graphs):
        symbols, declarations = collections.defaultdict(list), collections.defaultdict(set)
        for graph in graphs:
            for record in graph.values():
                for symbol in record['symbols']:
                    symbols[symbol['id']].append(symbol)
                for ref in record['refs']:
                    if ref['kind'] & 1:
                        declarations[ref['symbol_id']].add(_key(ref['location']))
        return symbols, declarations

    old_symbols, declarations = table(originals)
    new_symbols, _ = table([candidate])
    fields = ('name', 'scope', 'signature', 'kind')
    for identity, rows in old_symbols.items():
        available = new_symbols.get(identity, [])
        if not available:
            bad.append('symbol-missing:' + identity)
            continue
        declaration_ok = False
        for old in rows:
            matched = [s for s in available if all(s.get(f) == old.get(f) for f in fields)]
            if not matched:
                bad.append('symbol-fields:' + identity)
                continue
            definition = old.get('definition')
            if definition and definition.get('uri'):
                matched = [s for s in matched if s.get('definition') == definition]
            if not matched:
                bad.append('definition-missing:' + identity)
                continue
            # One SymbolID can have several A rows (forward declarations in other
            # shards); the merged TU keeps one. Judge the identity, not each row.
            declaration_ok = declaration_ok or any(
                s.get('canonical_declaration') == old.get('canonical_declaration')
                or _key(s.get('canonical_declaration')) in declarations[identity] for s in available)
        if not declaration_ok:
            bad.append('canonical-declaration:' + identity)
    for graph in originals:
        for uri, old in graph.items():
            new = candidate.get(uri)
            if new is None:
                continue
            a, b = old['source'], new['source']
            if (a['digest'] != b['digest'] or a['flags'] != b['flags']
                    or set(a['direct_includes']) != set(b['direct_includes'])):
                bad.append('source-node:' + uri)
            sites = collections.defaultdict(set)
            for ref in new['refs']:
                sites[(_key(ref['location']), ref['kind'])].add(ref['symbol_id'])
            for ref in old['refs']:
                alternatives = sites.get((_key(ref['location']), ref['kind']))
                if not alternatives:
                    bad.append('ref-location-missing:' + uri)
                    break
                # A replacement target must exist, not be an arbitrary unknown ID.
                macro = macro_sites.get(ref['symbol_id'], set())
                if not any(identity == ref['symbol_id'] or identity in new_symbols
                           or (len(macro) == 1 and macro == macro_sites.get(identity, set())) for identity in alternatives):
                    bad.append('ref-target-unresolved:' + uri)
                    break
            if collections.Counter(map(_key, old['relations'])) - collections.Counter(map(_key, new['relations'])):
                bad.append('relation-missing:' + uri)
    return {'ok': not bad, 'reason': 'global-superset' if not bad else bad[0],
            'violations': bad[:100], 'violation_count': len(bad)}
