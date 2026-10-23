"""Read only ownership metadata from candidate clangd v20 RIFF shards.

Input is one JSON object on stdin: {"paths": [absolute shard paths]}.
Each output item preserves its input path and contains either one own URI or
an error. Symbols, references, relations and commands are never decoded or
read. This helper does not decide physical identity and never deletes files.
"""

import json
import os
from pathlib import Path
import struct
import sys
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
from clangd_index_graph import VERSION, _Reader, _strings


_ALLOWED = {b"meta", b"stri", b"symb", b"refs", b"rela", b"srcs", b"cmdl"}
_REQUIRED = _ALLOWED - {b"cmdl"}
_METADATA = {b"meta", b"stri", b"srcs"}
_MAX_METADATA_CHUNK = 256 * 1024 * 1024


def read_owner(path):
    """Return a conservative per-path result; malformed input retains no URI."""
    result = {"path": path, "bytes_read": 0}
    started = time.perf_counter()
    try:
        if not isinstance(path, str) or not os.path.isabs(path):
            raise ValueError("shard path must be an absolute string")
        # Unbuffered reads must not prefetch the skipped symbol/ref payloads.
        with open(path, "rb", buffering=0) as stream:
            before = os.fstat(stream.fileno())

            def take(size):
                raw = stream.read(size)
                result["bytes_read"] += len(raw)
                if len(raw) != size:
                    raise ValueError("truncated clangd RIFF file")
                return raw

            header = take(12)
            if (header[:4] != b"RIFF" or header[8:] != b"CdIx"
                    or struct.unpack("<I", header[4:8])[0] != before.st_size - 8):
                raise ValueError("invalid clangd RIFF size or type")
            chunks, seen = {}, set()
            while stream.tell() < before.st_size:
                if before.st_size - stream.tell() < 8:
                    raise ValueError("truncated clangd RIFF chunk header")
                tag, size = struct.unpack("<4sI", take(8))
                if tag not in _ALLOWED:
                    raise ValueError("unknown clangd RIFF chunk")
                if tag in seen:
                    raise ValueError("duplicate clangd RIFF chunk")
                seen.add(tag)
                if size + (size & 1) > before.st_size - stream.tell():
                    raise ValueError("truncated clangd RIFF chunk")
                if tag in _METADATA:
                    if size > _MAX_METADATA_CHUNK:
                        raise ValueError("clangd ownership metadata chunk exceeds 256 MiB")
                    chunks[tag] = take(size)
                else:
                    stream.seek(size, os.SEEK_CUR)
                if size & 1 and take(1) != b"\0":
                    raise ValueError("invalid clangd RIFF padding")
            after = os.fstat(stream.fileno())
            if (before.st_size, before.st_mtime_ns, before.st_ino) != (
                    after.st_size, after.st_mtime_ns, after.st_ino):
                raise ValueError("clangd shard changed while reading")
        if _REQUIRED - seen:
            raise ValueError("missing clangd BackgroundIndex shard chunk")
        if chunks[b"meta"] != struct.pack("<I", VERSION):
            raise ValueError("unsupported clangd index version (expected 20)")
        strings = _strings(chunks[b"stri"])
        reader, uris, own = _Reader(chunks[b"srcs"]), set(), []
        while reader.remaining():
            reader.byte()  # Source flags do not identify ownership.
            uri, digest = reader.string(strings), reader.take(8)
            if not uri or uri in uris:
                raise ValueError("empty or duplicate clangd include graph URI")
            uris.add(uri)
            for _ in range(reader.count()):
                reader.string(strings)
            if digest != b"\0" * 8:
                own.append(uri)
        if len(own) != 1:
            raise ValueError("expected exactly one clangd shard own node")
        result["own_uris"] = own
    except (OSError, ValueError, struct.error) as error:
        result["error"] = str(error)
    result["read_ms"] = (time.perf_counter() - started) * 1000
    return result


def main():
    started = time.perf_counter()
    try:
        request = json.load(sys.stdin)
        if not isinstance(request, dict) or not isinstance(request.get("paths"), list):
            raise ValueError("expected an object containing a paths array")
        items = [read_owner(path) for path in request["paths"]]
        response = {"items": items, "bytes_read": sum(item["bytes_read"] for item in items),
                    "read_ms": (time.perf_counter() - started) * 1000}
    except (ValueError, OSError) as error:
        print(json.dumps({"error": str(error)}))
        return 2
    print(json.dumps(response, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
