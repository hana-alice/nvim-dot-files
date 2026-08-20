"""Canonical compile_commands command-string to structured argv conversion."""

import ctypes
import os
import shlex
from typing import Any


POSIX_HINTS = {
    "posix",
    "sh",
    "bash",
    "zsh",
    "darwin",
    "macos",
    "linux",
}

WINDOWS_HINTS = {
    "windows",
    "win32",
    "windows_nt",
    "nt",
    "cmd",
    "powershell",
    "pwsh",
}


def split_posix_command_line(command):
    return shlex.split(command, posix=True)


def split_windows_command_line_native(command):
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


def _split_windows_argument(command):
    """Port Go's os.CommandLineToArgv rules without requiring Win32 APIs."""
    value = []
    in_quotes = False
    backslashes = 0
    index = 0
    while index < len(command):
        char = command[index]
        if char in {" ", "\t"} and not in_quotes:
            value.append("\\" * backslashes)
            return "".join(value), command[index + 1 :]
        if char == '"':
            value.append("\\" * (backslashes // 2))
            if backslashes % 2 == 0:
                if in_quotes and index + 1 < len(command) and command[index + 1] == '"':
                    value.append('"')
                    index += 1
                in_quotes = not in_quotes
            else:
                value.append('"')
            backslashes = 0
            index += 1
            continue
        if char == "\\":
            backslashes += 1
            index += 1
            continue
        value.append("\\" * backslashes)
        backslashes = 0
        value.append(char)
        index += 1
    value.append("\\" * backslashes)
    return "".join(value), ""


def split_windows_command_line(command):
    arguments = []
    rest = command
    while rest:
        if rest[0] in {" ", "\t"}:
            rest = rest[1:]
            continue
        argument, rest = _split_windows_argument(rest)
        arguments.append(argument)
    return arguments


def _normalize_hint(value: Any) -> str | None:
    if value is None:
        return None
    hint = str(value).strip().lower()
    return hint or None


def _syntax_from_provenance(entry):
    if not isinstance(entry, dict):
        return None
    for key in ("command_syntax", "nvim_ue_command_syntax", "shell_kind", "host_os"):
        hint = _normalize_hint(entry.get(key))
        if hint in POSIX_HINTS:
            return "posix"
        if hint in WINDOWS_HINTS:
            return "windows"
    provenance = entry.get("provenance")
    if isinstance(provenance, dict):
        for key in ("command_syntax", "shell_kind", "host_os"):
            hint = _normalize_hint(provenance.get(key))
            if hint in POSIX_HINTS:
                return "posix"
            if hint in WINDOWS_HINTS:
                return "windows"
    return None


def _looks_posix_quoted(command):
    in_double = False
    escaped = False
    for index, ch in enumerate(command):
        if escaped:
            escaped = False
            continue
        if ch == "\\":
            nxt = command[index + 1] if index + 1 < len(command) else ""
            if not in_double and (nxt.isspace() or nxt in {"'", '"', "\\", "$"}):
                return True
            escaped = in_double and nxt in {'"', "\\", "$", "`"}
            continue
        if ch == '"':
            in_double = not in_double
            continue
        if ch == "'" and not in_double:
            return True
    return False


def command_syntax(entry, command):
    syntax = _syntax_from_provenance(entry)
    if syntax:
        return syntax
    if _looks_posix_quoted(command):
        return "posix"
    return "windows" if os.name == "nt" else "posix"


def split_command_line(command, entry=None):
    """Split one compile_commands `command` using producer syntax evidence."""
    syntax = command_syntax(entry, command)
    if syntax == "posix":
        return split_posix_command_line(command)
    return split_windows_command_line(command)


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
            arguments = split_command_line(command, entry)
            converted += 1
        if not file_path or not arguments:
            raise ValueError(f"entry {index} lacks file/arguments")
        structured = dict(entry)
        structured["arguments"] = list(arguments)
        structured.pop("command", None)
        normalized.append(structured)
    return normalized, converted
