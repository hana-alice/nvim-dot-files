#!/usr/bin/env python
"""Expand UE-style compile_commands.json `command` entries that use
@response-files into a flat `arguments` array suitable for clangd and
the rest of the ue-pipeline (prebuild_pch / unify / prune).

Why:
  UnrealBuildTool emits CDB entries like:
      "command": "\"clang-cl.exe\" @relative/path/Foo.cpp.obj.response"
  No -I, no -D — everything lives in the .response file. Downstream
  scripts (prune_include_dirs.py etc.) read e['arguments'] and crash or
  silently no-op. Expanding once at the top of the pipeline fixes them
  all and also lets clangd start without paying the response read on
  every TU.

What it does (idempotent):
  1. For every entry, if `arguments` already populated → skip.
  2. Tokenize `command` (handles quoted args / @files).
  3. Recursively expand @response files (resolved relative to entry
     directory).
  4. Convert MSVC-style /I (with or without space) to clang -I so
     downstream scripts that grep for -I work. Other /flags are left
     alone — clangd uses clang-cl driver and consumes them fine.
  5. Drop the bare source-file path that UE puts as the first token of
     the .response (entry already has `file`).
  6. Strip /Fo /Fp /sourceDependencies (and their args) — they confuse
     clangd preamble cache (different .pch path per TU defeats reuse).
  7. Replace `command` with the driver alone, write `arguments` array.

Safe to re-run: detects already-expanded entries and skips.
"""

import json
import os
import re
import shlex
import sys
import time

# /flags that take a following positional argument (space-separated form)
CL_FLAGS_WITH_SPACE_ARG = {
    '/I', '/FI', '/Yu', '/Yc', '/Fp', '/Fo', '/Fd', '/Fa',
    '/sourceDependencies', '/Tc', '/Tp',
}

# /flags whose argument may also be glued on (e.g. /I"path" or /Idir)
CL_FLAGS_GLUED_OR_SPACE = {'/I', '/FI', '/Yu', '/Yc', '/Fp', '/Fo', '/Fd', '/sourceDependencies'}

# Drop these entirely (with their argument) — they break clangd preamble
# cache because they encode per-TU .obj/.pch paths.
CL_FLAGS_DROP_WITH_ARG = {'/Fo', '/Fp', '/Fd', '/Fa', '/sourceDependencies'}


# Fast tokenizer: regex-based. UE .response uses simple format —
# whitespace-separated tokens with optional "..." quoting (no escapes,
# no nested quotes). 50-100x faster than shlex on 14k entries.
_TOK_RE = re.compile(r'"([^"]*)"|(\S+)')

def tokenize_response(text):
    """Tokenize a response file. Handles "quoted strings" and bare tokens.
    Backslashes preserved as-is (Windows paths)."""
    return [m.group(1) if m.group(1) is not None else m.group(2)
            for m in _TOK_RE.finditer(text)]


def expand_response_file(path, base_dir, seen):
    """Read .response at `path` (resolved against base_dir if relative),
    return token list with any nested @response files inlined."""
    full = path
    if not os.path.isabs(full):
        full = os.path.normpath(os.path.join(base_dir, full))

    # WSL bridge: D:\ → /mnt/d/ when running under WSL
    full_read = full
    if sys.platform.startswith('linux') and re.match(r'^[A-Za-z]:', full_read):
        drive = full_read[0].lower()
        rest = full_read[2:].replace('\\', '/')
        full_read = f'/mnt/{drive}{rest}'

    real = os.path.realpath(full_read)
    if real in seen:
        return []
    seen.add(real)

    if not os.path.exists(full_read):
        return None  # signal: missing (caller decides)

    with open(full_read, 'r', encoding='utf-8', errors='replace') as f:
        text = f.read()

    tokens = tokenize_response(text)
    out = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if t.startswith('@'):
            nested = expand_response_file(t[1:], base_dir, seen)
            if nested:
                out.extend(nested)
            i += 1
        else:
            out.append(t)
            i += 1
    return out


def normalize_args(tokens, source_file):
    """Apply cl→clang fixups, drop noise, drop bare source-file token.

    Returns the cleaned argument list (without the driver — caller
    prepends it).
    """
    # The first non-flag token in a UE .response is usually the .cpp
    # path. Drop any leading tokens that don't start with / or - and
    # equal (basename of) source_file. We do an aggressive match: any
    # token that ends in .cpp/.c/.cc/.cxx and refers to source_file.
    src_base = os.path.basename(source_file).lower() if source_file else ''
    src_exts = ('.cpp', '.cc', '.cxx', '.c', '.c++', '.m', '.mm')

    cleaned = []
    i = 0
    while i < len(tokens):
        t = tokens[i]
        if not t:
            i += 1
            continue

        # Drop bare source-file token (no flag prefix, ends with src ext)
        if not t.startswith(('/', '-', '@')) and t.lower().endswith(src_exts):
            # Even if not exactly matching source_file, this is a TU
            # input — clangd uses entry.file, not this.
            i += 1
            continue

        # Handle /I dir  →  -I dir
        if t == '/I' and i + 1 < len(tokens):
            cleaned.append('-I')
            cleaned.append(tokens[i + 1])
            i += 2
            continue
        # Handle /I"dir" or /Idir → -Idir
        if t.startswith('/I') and len(t) > 2:
            cleaned.append('-I' + t[2:])
            i += 1
            continue

        # Drop /Fo /Fp /Fd /sourceDependencies and their argument
        if t in CL_FLAGS_DROP_WITH_ARG:
            # consume next token as its arg
            i += 2
            continue
        # Glued form: /Fo"path", /Fp"path", /sourceDependenciespath
        dropped = False
        for flag in CL_FLAGS_DROP_WITH_ARG:
            if t.startswith(flag) and len(t) > len(flag):
                dropped = True
                break
        if dropped:
            i += 1
            continue

        # Everything else (including /FI /Yu /Yc /D /wd /we /std:c++17 etc.)
        # → keep verbatim. clang-cl understands them.
        cleaned.append(t)
        i += 1

    return cleaned


def needs_expand(entry):
    """True if entry must be expanded (no arguments, command has @rsp)."""
    if entry.get('arguments'):
        return False
    cmd = entry.get('command', '')
    return '@' in cmd


def parse_command_for_driver_and_rsp(cmd):
    """Split `command` string into (driver_path, [rsp_paths], extra_tokens).
    Returns None if no @response found."""
    toks = [m.group(1) if m.group(1) is not None else m.group(2)
            for m in _TOK_RE.finditer(cmd)]
    if not toks:
        return None
    driver = toks[0]
    rsps = []
    extras = []
    for t in toks[1:]:
        if t.startswith('@'):
            rsps.append(t[1:])
        else:
            extras.append(t)
    if not rsps:
        return None
    return driver, rsps, extras


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    cdb_path = sys.argv[1]
    dry_run = '--dry-run' in sys.argv

    t0 = time.time()
    with open(cdb_path, 'r', encoding='utf-8') as f:
        cdb = json.load(f)

    n_total = len(cdb)
    n_already = 0
    n_expanded = 0
    n_missing_rsp = 0
    n_no_rsp = 0
    n_kept_as_is = 0

    new_cdb = []
    for entry in cdb:
        if entry.get('arguments'):
            n_already += 1
            new_cdb.append(entry)
            continue

        cmd = entry.get('command', '')
        if not cmd:
            n_kept_as_is += 1
            new_cdb.append(entry)
            continue

        parsed = parse_command_for_driver_and_rsp(cmd)
        if not parsed:
            n_no_rsp += 1
            new_cdb.append(entry)
            continue

        driver, rsps, extras = parsed
        base_dir = entry.get('directory', '').replace('\\', '/')
        source_file = entry.get('file', '')

        all_tokens = list(extras)
        all_missing = True
        for rsp in rsps:
            seen = set()
            toks = expand_response_file(rsp, base_dir, seen)
            if toks is None:
                continue  # missing file
            all_missing = False
            all_tokens.extend(toks)

        if all_missing:
            # No usable .response — leave entry untouched (clangd will
            # also fail, but at least pipeline does not silently strip
            # the original command).
            n_missing_rsp += 1
            new_cdb.append(entry)
            continue

        cleaned = normalize_args(all_tokens, source_file)
        new_entry = {
            'directory': entry.get('directory', ''),
            'file': source_file,
            'arguments': [driver] + cleaned,
        }
        if 'output' in entry:
            new_entry['output'] = entry['output']
        new_cdb.append(new_entry)
        n_expanded += 1

    dt = time.time() - t0
    print(f"expand_response_cdb: total={n_total} expanded={n_expanded} "
          f"already_args={n_already} missing_rsp={n_missing_rsp} "
          f"no_rsp_in_cmd={n_no_rsp} no_command={n_kept_as_is} ({dt:.1f}s)")

    if n_expanded == 0:
        print("expand_response_cdb: nothing to expand, leaving file untouched")
        return

    if dry_run:
        print("[DRY RUN] no write")
        return

    with open(cdb_path, 'w', encoding='utf-8') as f:
        json.dump(new_cdb, f, indent=2)
    print(f"expand_response_cdb: wrote {cdb_path}")


if __name__ == '__main__':
    main()
