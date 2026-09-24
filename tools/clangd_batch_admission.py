"""Admit a batch against independently collected original-TU index graphs.

This is a semantic preservation gate, not byte-graph equivalence. Inputs come
from clangd_index_graph.canonical_file_graph. Compiler/snapshot freshness and
complete original-TU collection are obligations of the caller. No shared
BackgroundIndex cache may substitute for those independent original graphs.
"""

from copy import deepcopy
from pathlib import PurePosixPath
from urllib.parse import unquote, urlparse

from clangd_index_graph import _location_key, _record_key


_IDENTITY = ("name", "scope", "kind", "template_specialization_args")
_COMPLETION = ("type", "signature", "return_type", "completion_snippet_suffix")
_HAS_DOC_COMMENT = 1 << 4  # LLVM 22.1.5 index/Symbol.h.


def _locations(symbols, field):
    return {_location_key(symbol[field]) for symbol in symbols if symbol[field]["uri"]}


def _headers(symbols):
    # Merge.cpp:255-259,287-299 keeps the definition-bearing record's header
    # suggestions when folding a bare declaration into it. Other declarations
    # may still contribute SupportedDirectives to already shared suggestions.
    definitions = [symbol for symbol in symbols if symbol["definition"]["uri"]]
    allowed = {header["header"] for symbol in definitions or symbols
               for header in symbol["include_headers"]}
    headers = {}
    for symbol in symbols:
        for header in symbol["include_headers"]:
            name = header["header"]
            if name in allowed:
                headers[name] = headers.get(name, 0) | header["supported_directives"]
    return headers


def _flags(symbols):
    result = 0
    for symbol in symbols:
        result |= symbol["flags"] & ~_HAS_DOC_COMMENT
    return result


def _provider_evidence(graphs, wanted):
    evidence = []
    for graph in graphs:
        locations = {}
        for entry in graph.values() if wanted else ():
            for symbol in entry["symbols"]:
                if symbol["id"] in wanted:
                    decls, defs = locations.setdefault(symbol["id"], (set(), set()))
                    decls.add(symbol["canonical_declaration"]["uri"])
                    defs.add(symbol["definition"]["uri"])
            for ref in entry["refs"]:
                if ref["symbol_id"] in wanted and ref["kind"] & 3:
                    decls, defs = locations.setdefault(ref["symbol_id"], (set(), set()))
                    decls.add(ref["location"]["uri"])
                    if ref["kind"] & 2:
                        defs.add(ref["location"]["uri"])
        evidence.append({sid: (decls | defs, defs) for sid, (decls, defs) in locations.items()})
    return evidence


def _valid_providers(original, candidate, graphs, reachable, evidence):
    old, new = _headers(original), _headers(candidate)
    if old == new:
        return True
    if (not new or set(old.values()) != set(new.values())
            or any(urlparse(header).scheme != "file" for header in old)):
        return False
    def exposes(index, header, body=False):
        locations = evidence[index].get(original[0]["id"])
        return locations and closure(index, header) & locations[bool(body)]

    def closure(index, uri):
        key = (index, uri)
        if key not in reachable:
            seen, pending, graph = set(), [uri], graphs[index]
            while pending:
                path = pending.pop()
                if path in seen or path not in graph:
                    continue
                seen.add(path)
                pending.extend(graph[path]["source"]["direct_includes"])
            reachable[key] = seen
        return reachable[key]

    need_body = any(exposes(i, header, True) for header in old
                    for i, graph in enumerate(graphs) if header in graph)
    for header, directives in new.items():
        if header in old:
            if old[header] != directives:
                return False
            continue
        uri = urlparse(header)
        # Changed literal include spellings need compiler search-path proof;
        # basename/suffix matching alone cannot resolve an include safely.
        if uri.scheme != "file" or PurePosixPath(unquote(uri.path)).suffix.lower() not in {
                "", ".h", ".hh", ".hpp", ".hxx", ".inc", ".inl", ".ipp", ".tcc", ".def", ".cuh"}:
            return False
        if not any(header in graph and exposes(i, header, need_body) for i, graph in enumerate(graphs)):
            return False
    return True


def _collect(graphs, ignored):
    sources, symbols, refs, relations, contexts = {}, {}, {}, set(), {}
    for index, graph in enumerate(graphs):
        if not graph:
            raise ValueError("empty original/candidate graph")
        for uri, entry in graph.items():
            if entry["source"]["flags"] & 2:
                raise ValueError("uncompilable source graph: " + uri)
            if uri in ignored:
                if any(entry[field] for field in ("symbols", "refs", "relations")):
                    raise ValueError("cannot ignore nonempty wrapper: " + uri)
                continue
            node = entry["source"]
            source = (node["digest"], node["flags"], frozenset(node["direct_includes"]))
            if uri in sources:
                previous = sources[uri]
                if previous[:2] != source[:2]:
                    raise ValueError("conflicting original source graph: " + uri)
                source = (*source[:2], previous[2] | source[2])
            sources[uri] = source
            contexts.setdefault(uri, set()).add(index)
            for symbol in entry["symbols"]:
                symbols.setdefault(symbol["id"], {})[_record_key(symbol)] = symbol
            for ref in entry["refs"]:
                if ref["location"]["uri"] != uri:
                    raise ValueError("reference stored under wrong source URI")
                refs[_record_key(ref)] = ref
            relations.update(_record_key(relation) for relation in entry["relations"])
    if not sources:
        raise ValueError("no original/candidate real files")
    return sources, symbols, refs, relations, contexts


def _template_requests(wanted, graphs, candidates):
    requests = {sid: {'symbol_id': sid, 'originals': [],
                     'candidate': [candidates[sid][key] for key in sorted(candidates[sid])]}
                for sid in sorted(wanted)}
    for index, graph in enumerate(graphs):
        found = {}
        for node in graph.values():
            for symbol in node['symbols']:
                sid = symbol['id']
                if sid in requests:
                    found.setdefault(sid, {})[_record_key(symbol)] = symbol
        for sid, records in found.items():
            requests[sid]['originals'].append({'index': index,
                'symbols': [records[key] for key in sorted(records)]})
    # Compiler callbacks must not be able to mutate the graphs being certified.
    return deepcopy(list(requests.values()))


def compare_graphs(original_graphs, candidate_graph, ignore_files=(), resolve_original=None,
                   resolve_template_arguments=None):
    """Return {accepted, reason, added_refs}, with details on rejection.

    Added refs require resolve_original(uri, line, column, symbol_id, indices)
    to return exactly True. Coordinates are clangd's zero-based index ranges;
    indices are zero-based original_graphs entries containing that URI. The
    callback must prove the requested identity in EVERY supplied original TU.
    It must not resolve in the merged TU or accept a single matching context.

    Printed template_specialization_args may differ only when the separate
    resolve_template_arguments(request) callback proves the complete typed
    arguments in every declaring original context and in the candidate. Its
    request contains the exact raw symbol records and original graph indices;
    absence, exceptions and anything other than True reject. Unrepairable graph
    changes are checked first. Neither callback may rewrite the raw graphs.

    Missing/removed references, symbols, definitions, relation changes and
    novel completion semantics cannot be excused by this callback. Only docs,
    usage counts, HasDocComment and include-header counts are ignored. Header
    suggestions follow clangd's definition preference. Changed URI providers
    must expose the proven declaration/body through an original TU's include
    graph; this does not prove standalone-header compilability. Other flags
    retain their original union.
    """
    added = []

    def verdict(reason, **details):
        return dict(accepted=False, reason=reason, added_refs=added, **details)

    try:
        if not isinstance(original_graphs, list) or not original_graphs:
            return verdict("missing-original-tu-graphs")
        ignored = set(ignore_files)
        before = _collect(original_graphs, ignored)
        after = _collect([candidate_graph], ignored)
        old_sources, old_symbols, old_refs, old_relations, contexts = before
        sources, symbols, refs, relations, _ = after
        if old_sources.keys() != sources.keys():
            return verdict("file-coverage-changed", missing=sorted(old_sources.keys() - sources.keys()),
                           added=sorted(sources.keys() - old_sources.keys()))
        for uri in sorted(sources):
            if sources[uri] != old_sources[uri]:
                return verdict("source-dependencies-changed", uri=uri)
        if old_symbols.keys() != symbols.keys():
            return verdict("symbol-identities-changed",
                           missing=sorted(old_symbols.keys() - symbols.keys()),
                           added=sorted(symbols.keys() - old_symbols.keys()))
        declaration_refs, definition_refs, reachable = {}, {}, {}
        for ref in old_refs.values():
            sid, location = ref["symbol_id"], _location_key(ref["location"])
            if ref["kind"] & 3:
                declaration_refs.setdefault(sid, set()).add(location)
            if ref["kind"] & 2:
                definition_refs.setdefault(sid, set()).add(location)
        changed_providers = {sid for sid in symbols
                             if _headers(list(old_symbols[sid].values())) != _headers(list(symbols[sid].values()))}
        provider_evidence = _provider_evidence(original_graphs, changed_providers)
        changed_templates = set()
        for sid in sorted(symbols):
            original, candidate = list(old_symbols[sid].values()), list(symbols[sid].values())
            for field in _IDENTITY:
                if {s[field] for s in original} != {s[field] for s in candidate}:
                    if field == 'template_specialization_args':
                        changed_templates.add(sid)
                    else:
                        return verdict("symbol-identity-fields-changed", symbol_id=sid, field=field)
            # clangd Merge.cpp prefers a record whose TU saw the definition.
            # IndexSymbol.cpp labels a forward struct C until isCLike() can see
            # its C++ body. Preserve the existing definition's classification;
            # this is not permission to introduce a language absent from it.
            preferred = [s for s in original if s["definition"]["uri"]] or original
            if {s["language"] for s in preferred} != {s["language"] for s in candidate}:
                return verdict("symbol-identity-fields-changed", symbol_id=sid, field="language")
            for field in _COMPLETION:
                if {s[field] for s in original if s[field]} != {s[field] for s in candidate if s[field]}:
                    return verdict("symbol-completion-changed", symbol_id=sid, field=field)
            if _flags(original) != _flags(candidate):
                return verdict("symbol-flags-changed", symbol_id=sid)
            if not _valid_providers(original, candidate, original_graphs, reachable, provider_evidence):
                return verdict("symbol-include-headers-changed", symbol_id=sid)
            old_defs = _locations(original, "definition")
            new_defs = _locations(candidate, "definition")
            if not old_defs <= new_defs or not new_defs <= old_defs | definition_refs.get(sid, set()):
                return verdict("symbol-definitions-changed", symbol_id=sid)
            old_decls = _locations(original, "canonical_declaration")
            new_decls = _locations(candidate, "canonical_declaration")
            if ((old_decls and not new_decls)
                    or not new_decls <= old_decls | declaration_refs.get(sid, set())):
                return verdict("symbol-declarations-changed", symbol_id=sid)
        if old_relations != relations:
            return verdict("relations-changed")
        removed = old_refs.keys() - refs.keys()
        if removed:
            return verdict("references-removed-or-retargeted", removed_refs=[old_refs[k] for k in sorted(removed)])
        for key in sorted(refs.keys() - old_refs.keys()):
            ref = refs[key]
            added.append(dict(ref, original_graph_indices=sorted(contexts[ref["location"]["uri"]])))
        template_requests = _template_requests(changed_templates, original_graphs, symbols) if changed_templates else []
        if template_requests and resolve_template_arguments is None:
            return verdict('template-arguments-require-compiler-proof', template_arguments=template_requests)
        for request in template_requests:
            try:
                proven = resolve_template_arguments(deepcopy(request))
            except Exception as error:
                return verdict('template-argument-proof-failed', error=str(error))
            if proven is not True:
                return verdict('template-argument-identity-unproven', template_argument=request)
        if added and resolve_original is None:
            return verdict("added-references-require-original-proof")
        for ref in added:
            location = ref["location"]
            try:
                proven = resolve_original(location["uri"], *location["start"], ref["symbol_id"],
                                          ref["original_graph_indices"])
            except Exception as error:
                return verdict("original-reference-proof-failed", error=str(error))
            if proven is not True:
                return verdict("original-reference-identity-unproven", reference=ref)
        result = {"accepted": True, "reason": "compatible-original-tu-union", "added_refs": added}
        if template_requests:
            result['proven_template_arguments'] = template_requests
        return result
    except (KeyError, TypeError, ValueError, IndexError) as error:
        return verdict("invalid-original-or-candidate-graph", error=str(error))
