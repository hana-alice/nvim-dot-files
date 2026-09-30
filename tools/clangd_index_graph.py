"""Read and compare clangd 22.1.5 BackgroundIndex file shards, without LLVM.

The wire layout is pinned to llvmorg-22.1.5/clang-tools-extra/clangd/index/
Serialization.cpp (RIFF version 20), and clangd/RIFF.cpp. This module does
not prove build provenance, dependency freshness, or completeness of a set
of shards; callers must establish those separately before admitting a batch.
"""

import struct
import zlib
from pathlib import Path


VERSION = 20
_MAX_STRING_TABLE = 256 * 1024 * 1024


class _Reader:
    def __init__(self, data):
        self.data = data
        self.pos = 0
        self.ids = {}

    def remaining(self):
        return len(self.data) - self.pos

    def take(self, size):
        if size > self.remaining():
            raise ValueError("truncated clangd index record")
        result = self.data[self.pos:self.pos + size]
        self.pos += size
        return result

    def byte(self):
        if self.pos >= len(self.data):
            raise ValueError("truncated clangd index record")
        value = self.data[self.pos]
        self.pos += 1
        return value

    def symbol_id(self):
        raw = self.take(8)
        value = self.ids.get(raw)
        if value is None:
            value = self.ids[raw] = raw.hex()
        return value

    def u32(self):
        return struct.unpack("<I", self.take(4))[0]

    def var(self):
        result = 0
        for shift in range(0, 35, 7):
            value = self.byte()
            if shift == 28 and value > 15:
                raise ValueError("overflowing clangd uint32 varint")
            result |= (value & 127) << shift
            if not value & 128:
                return result
        raise ValueError("unterminated clangd varint")

    def count(self):
        count = self.var()
        if count > self.remaining():
            raise ValueError("truncated clangd index sequence")
        return count

    def string(self, strings):
        index = self.var()
        if index >= len(strings):
            raise ValueError("invalid clangd string table index")
        return strings[index]

    def location(self, strings):
        return {"uri": self.string(strings),
                "start": [self.var(), self.var()],
                "end": [self.var(), self.var()]}


def _chunks(data):
    reader = _Reader(data)
    if reader.take(4) != b"RIFF":
        raise ValueError("not a RIFF file")
    size = reader.u32()
    if size != reader.remaining() or reader.take(4) != b"CdIx":
        raise ValueError("invalid clangd RIFF size or type")
    chunks = {}
    while reader.remaining():
        tag, size = reader.take(4), reader.u32()
        if tag in chunks:
            raise ValueError("duplicate clangd RIFF chunk")
        chunks[tag] = reader.take(size)
        if size & 1 and reader.take(1) != b"\0":
            raise ValueError("invalid clangd RIFF padding")
    allowed = {b"meta", b"stri", b"symb", b"refs", b"rela", b"srcs", b"cmdl"}
    if chunks.keys() - allowed:
        raise ValueError("unknown clangd RIFF chunk")
    required = {b"meta", b"stri", b"symb", b"refs", b"rela", b"srcs"}
    if required - chunks.keys():
        raise ValueError("missing clangd BackgroundIndex shard chunk")
    if chunks[b"meta"] != struct.pack("<I", VERSION):
        raise ValueError("unsupported clangd index version (expected 20)")
    return chunks


def _strings(data):
    reader = _Reader(data)
    size = reader.u32()
    raw = reader.take(reader.remaining())
    if size > _MAX_STRING_TABLE:
        raise ValueError("clangd shard string table exceeds 256 MiB")
    if size:
        try:
            inflater = zlib.decompressobj()
            raw = inflater.decompress(raw, size + 1)
        except zlib.error as error:
            raise ValueError("invalid compressed clangd string table") from error
        if (len(raw) != size or not inflater.eof or inflater.unused_data
                or inflater.unconsumed_tail):
            raise ValueError("clangd string table size or compression mismatch")
    if not raw.endswith(b"\0"):
        raise ValueError("unterminated clangd string table")
    # LLVM strings are bytes; surrogateescape preserves non-UTF8 comments.
    return [value.decode("utf-8", "surrogateescape") for value in raw[:-1].split(b"\0")]


def _symbol(reader, strings):
    symbol = {"id": reader.symbol_id(), "kind": reader.byte(), "language": reader.byte()}
    for field in ("name", "scope", "template_specialization_args"):
        symbol[field] = reader.string(strings)
    symbol["definition"] = reader.location(strings)
    symbol["canonical_declaration"] = reader.location(strings)
    symbol["references"] = reader.var()
    symbol["flags"] = reader.byte()
    for field in ("signature", "completion_snippet_suffix", "documentation", "return_type", "type"):
        symbol[field] = reader.string(strings)
    includes = []
    for _ in range(reader.count()):
        header, packed = reader.string(strings), reader.var()
        includes.append({"header": header, "references": packed >> 2,
                         "supported_directives": packed & 3})
    symbol["include_headers"] = includes
    return symbol


def read_shard(path):
    """Return lossless decoded records from a v20 RIFF file, or raise ValueError.

    Keys: version, symbols, refs (flat records including symbol_id), relations,
    sources (URI -> flags/digest/direct_includes), command (directory/arguments
    or None). File I/O failures retain their usual OSError type. Digest is the
    eight on-disk bytes as hex, not an integer or a SHA hash.
    """
    chunks = _chunks(Path(path).read_bytes())
    strings = _strings(chunks[b"stri"])
    result = {"version": VERSION, "symbols": [], "refs": [], "relations": [],
              "sources": {}, "command": None}
    reader = _Reader(chunks[b"symb"])
    while reader.remaining():
        result["symbols"].append(_symbol(reader, strings))
    reader = _Reader(chunks[b"refs"])
    while reader.remaining():
        symbol_id = reader.symbol_id()
        for _ in range(reader.count()):
            result["refs"].append({"symbol_id": symbol_id, "kind": reader.byte(),
                                   "location": reader.location(strings),
                                   "container": reader.symbol_id()})
    reader = _Reader(chunks[b"rela"])
    while reader.remaining():
        result["relations"].append({"subject": reader.symbol_id(),
                                    "predicate": reader.byte(),
                                    "object": reader.symbol_id()})
    reader = _Reader(chunks[b"srcs"])
    while reader.remaining():
        flags, uri, digest = reader.byte(), reader.string(strings), reader.take(8).hex()
        includes = [reader.string(strings) for _ in range(reader.count())]
        if uri in result["sources"]:
            raise ValueError("duplicate clangd include graph node")
        result["sources"][uri] = {"flags": flags, "digest": digest, "direct_includes": includes}
    if b"cmdl" in chunks:
        reader = _Reader(chunks[b"cmdl"])
        directory = reader.string(strings)
        arguments = [reader.string(strings) for _ in range(reader.count())]
        if reader.remaining():
            raise ValueError("trailing clangd command bytes")
        result["command"] = {"directory": directory, "arguments": arguments}
    return result


_REF_FIELDS = ("container", "kind", "location", "symbol_id")
_LOCATION_FIELDS = ("end", "start", "uri")
_SYMBOL_FIELDS = ("canonical_declaration", "completion_snippet_suffix", "definition", "documentation",
                  "flags", "id", "include_headers", "kind", "language", "name", "references",
                  "return_type", "scope", "signature", "template_specialization_args", "type")
_REF_FIELD_SET = frozenset(_REF_FIELDS)
_LOCATION_FIELD_SET = frozenset(_LOCATION_FIELDS)
_SYMBOL_FIELD_SET = frozenset(_SYMBOL_FIELDS)


def _location_key(location):
    if location.keys() == _LOCATION_FIELD_SET:
        end, start = location["end"], location["start"]
        return (_LOCATION_FIELDS, len(end), *end, len(start), *start, location["uri"])
    return _record_key(location)


def _value_key(value):
    if isinstance(value, dict):
        return _record_key(value)
    if isinstance(value, list):
        return tuple(_value_key(item) for item in value)
    return value


def _record_key(record):
    # Collision-free structural keys retain scalar values by reference. The
    # common ref/location schemas avoid allocating copies of long URI strings.
    if record.keys() == _REF_FIELD_SET:
        return (_REF_FIELDS, record["container"], record["kind"],
                _location_key(record["location"]), record["symbol_id"])
    if record.keys() == _SYMBOL_FIELD_SET:
        return (_SYMBOL_FIELDS, _location_key(record["canonical_declaration"]),
                record["completion_snippet_suffix"], _location_key(record["definition"]),
                record["documentation"], record["flags"], record["id"],
                tuple(_record_key(header) for header in record["include_headers"]),
                record["kind"], record["language"], record["name"], record["references"],
                record["return_type"], record["scope"], record["signature"],
                record["template_specialization_args"], record["type"])
    if record.keys() == _LOCATION_FIELD_SET:
        return _location_key(record)
    fields = tuple(sorted(record))
    return (fields, *(_value_key(record[field]) for field in fields))


def canonical_file_graph(shards, ignore_files=()):
    """Canonicalize an iterable of read_shard results into a per-URI graph.

    A BackgroundIndex disk shard has one nonzero-digest own node; other source
    nodes are zero-digest edge placeholders. Missing dependency shards remain
    the caller's responsibility. Identical duplicate shards are allowed, but
    differing records for the same URI are rejected, never silently merged.

    Explicitly ignored URIs must have no symbols, refs or relations. Edges in
    real files are retained, including any pointing at an ignored file. Command
    provenance is deliberately separate from observable file graph equality.
    Records use deterministic structural ordering (numeric coordinates sort
    numerically), not the old JSON-text ordering; serialized cache hashes change.
    """
    graph = {}
    for shard in shards:
        if shard["version"] != VERSION:
            raise ValueError("unsupported clangd graph version")
        own = [(uri, node) for uri, node in shard["sources"].items()
               if node["digest"] != "0000000000000000"]
        if len(own) != 1:
            raise ValueError("expected one own source node per clangd file shard")
        uri, source = own[0]
        symbols = []
        for symbol in shard["symbols"]:
            symbol = dict(symbol)
            symbol["include_headers"] = sorted(symbol["include_headers"], key=_record_key)
            symbols.append(symbol)
        entry = {"symbols": sorted(symbols, key=_record_key),
                 "refs": sorted(shard["refs"], key=_record_key),
                 "relations": sorted(shard["relations"], key=_record_key),
                 "source": dict(source, direct_includes=sorted(source["direct_includes"]))}
        if uri in graph and graph[uri] != entry:
            raise ValueError("conflicting clangd file shards for " + uri)
        graph[uri] = entry
    for uri in ignore_files:
        if uri not in graph:
            continue
        if any(graph[uri][field] for field in ("symbols", "refs", "relations")):
            raise ValueError("cannot ignore nonempty clangd file graph: " + uri)
        del graph[uri]
    return dict(sorted(graph.items()))
