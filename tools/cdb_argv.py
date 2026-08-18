"""Canonical compile_commands command-string to structured argv conversion."""

import ctypes
import os
import shlex


def split_command_line(command):
    """Split one compile_commands `command` using the current host's rules."""
    if os.name != "nt":
        return shlex.split(command, posix=True)
    argc = ctypes.c_int()
    split = ctypes.windll.shell32.CommandLineToArgvW
    split.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_int)]
    split.restype = ctypes.POINTER(ctypes.c_wchar_p)
    argv = split(command, ctypes.byref(argc))
    if not argv:
        raise OSError("CommandLineToArgvW failed")
    try:
        return [argv[index] for index in range(argc.value)]
    finally:
        ctypes.windll.kernel32.LocalFree(ctypes.cast(argv, ctypes.c_void_p))


def normalize_cdb(entries):
    """Return unambiguous structured entries for downstream CDB stages."""
    normalized = []
    converted = 0
    for index, entry in enumerate(entries):
        file_path = entry.get("file")
        arguments = entry.get("arguments")
        if not isinstance(arguments, list):
            command = entry.get("command")
            if not isinstance(command, str) or not command.strip():
                raise ValueError(f"entry {index} lacks arguments/command")
            arguments = split_command_line(command)
            converted += 1
        if not file_path or not arguments:
            raise ValueError(f"entry {index} lacks file/arguments")
        structured = dict(entry)
        structured["arguments"] = list(arguments)
        structured.pop("command", None)
        normalized.append(structured)
    return normalized, converted
