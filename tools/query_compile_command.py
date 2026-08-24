#!/usr/bin/env python3
"""Return one exact clangd CompileCommand from a JSON compilation database.

The result is NDJSON-safe JSON on stdout. Ambiguous duplicate commands are
rejected: callers must never choose a C++ build context by array order.
"""

import argparse
import ctypes
import json
import os
import shlex
import sys


def canonical_path(path):
    return os.path.normcase(os.path.realpath(os.path.abspath(path)))


def absolute_file(entry):
    path = entry.get("file", "")
    if not os.path.isabs(path):
        path = os.path.join(entry.get("directory", ""), path)
    return canonical_path(path)


def split_command(command):
    if os.name != "nt":
        return shlex.split(command)
    argc = ctypes.c_int()
    split = ctypes.windll.shell32.CommandLineToArgvW
    split.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
    split.restype = ctypes.POINTER(ctypes.c_wchar_p)
    argv = split(command, ctypes.byref(argc))
    if not argv:
        raise ValueError("CommandLineToArgvW failed")
    try:
        return [argv[index] for index in range(argc.value)]
    finally:
        ctypes.windll.kernel32.LocalFree(ctypes.cast(argv, ctypes.c_void_p))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("compile_commands")
    parser.add_argument("source_file")
    parser.add_argument("--subject", default=None,
                        help="Associate the donor command with this subject path")
    args = parser.parse_args()

    wanted = canonical_path(args.source_file)
    with open(args.compile_commands, "r", encoding="utf-8") as handle:
        database = json.load(handle)

    matches = []
    seen = set()
    for entry in database:
        if absolute_file(entry) != wanted:
            continue
        command = entry.get("arguments")
        if not isinstance(command, list):
            raw = entry.get("command")
            if not isinstance(raw, str) or not raw:
                continue
            command = split_command(raw)
        command = [str(value) for value in command]
        directory = os.path.abspath(entry.get("directory") or os.path.dirname(wanted))
        if args.subject:
            subject = os.path.abspath(args.subject)
            rewritten = []
            for value in command:
                candidate = value
                if not os.path.isabs(candidate):
                    candidate = os.path.join(directory, candidate)
                if canonical_path(candidate) == wanted:
                    value = subject
                rewritten.append(value)
            command = rewritten
        fingerprint = (canonical_path(directory), tuple(command))
        if fingerprint not in seen:
            seen.add(fingerprint)
            matches.append({
                "workingDirectory": directory,
                "compilationCommand": command,
            })

    if len(matches) != 1:
        print(json.dumps({
            "state": "unavailable",
            "reason": "compile-command-missing" if not matches else "compile-command-ambiguous",
            "candidate_count": len(matches),
        }, separators=(",", ":")))
        return 2

    print(json.dumps({"state": "resolved", "command": matches[0]}, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main())
