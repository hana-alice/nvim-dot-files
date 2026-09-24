"""Expand only response files explicitly referenced by active CDB arguments.

The historical filename is retained for pipeline compatibility. Source-tree
location cannot prove which build produced a sibling .Shared.rsp: never replace
an exact include list with discovered Win64 Editor intermediates. Explicit
@response references are expanded in place, retaining flag order and values.
Incomplete response evidence leaves the entire original entry unchanged.
"""
import json
import os
import sys
from pathlib import Path

TOOLS_DIR = str(Path(__file__).resolve().parent)
if TOOLS_DIR not in sys.path:
    sys.path.insert(0, TOOLS_DIR)

from cdb_argv import split_command_line


def winpath_local(path):
    if sys.platform.startswith('linux') and len(path) >= 2 and path[1] == ':' and os.path.isdir('/mnt/c'):
        return f'/mnt/{path[0].lower()}/' + path[2:].replace('\\', '/').lstrip('/')
    return path


def expand_arguments(arguments, directory, entry, stack=()):
    expanded = []
    for arg in arguments:
        if not arg.startswith('@'):
            expanded.append(arg)
            continue
        path = winpath_local(arg[1:].strip('"'))
        if not os.path.isabs(path):
            path = os.path.join(directory, path)
        path = os.path.realpath(path)
        if path in stack or len(stack) >= 32:
            raise ValueError('cyclic or excessively nested response file')
        with open(path, encoding='utf-8-sig') as stream:
            text = ' '.join(stream.read().splitlines())
        tokens = split_command_line(text, entry)
        # Nested compiler response references use the compile command's cwd.
        expanded.extend(expand_arguments(tokens, directory, entry, stack + (path,)))
    return expanded


def main():
    if len(sys.argv) != 2:
        print('usage: replace_i_with_rsp.py <cdb.json>')
        return 1
    path = winpath_local(sys.argv[1])
    with open(path, encoding='utf-8') as stream:
        cdb = json.load(stream)
    changed = 0
    for entry in cdb:
        arguments = entry.get('arguments')
        if not arguments or not any(arg.startswith('@') for arg in arguments):
            continue
        directory = entry.get('directory')
        if not directory or not os.path.isabs(winpath_local(directory)):
            continue
        try:
            expanded = expand_arguments(arguments, winpath_local(directory), entry)
        except (OSError, ValueError, UnicodeError) as error:
            print(f'WARN: retaining exact command for {entry.get("file")}: {error}', file=sys.stderr)
            continue
        if expanded != arguments:
            entry['arguments'] = expanded
            entry.pop('command', None)
            changed += 1
    if changed:
        temporary = path + f'.tmp.{os.getpid()}'
        with open(temporary, 'w', encoding='utf-8', newline='\n') as stream:
            json.dump(cdb, stream, ensure_ascii=False)
        os.replace(temporary, path)
    print(f'Expanded explicit response files in {changed} entries; other active commands retained')
    return 0


if __name__ == '__main__':
    sys.exit(main())
