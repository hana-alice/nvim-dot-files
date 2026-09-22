"""Windows content/name notifications; companion to libuv.content_events.lua.

One parent-bound process, no source reads or tree scans. ReadDirectoryChangesW
excludes libuv's last-access/attribute/security subscriptions. See Microsoft's
ReadDirectoryChangesW, GetOverlappedResult and CancelIoEx contracts.
"""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
import struct
import sys

FILTER = 0x1B  # FILE_NAME | DIR_NAME | SIZE | LAST_WRITE
CAPACITY = 64 * 1024  # DWORD aligned; also within the documented SMB limit.


class Overlapped(ctypes.Structure):
    _fields_ = [('Internal', ctypes.c_size_t), ('InternalHigh', ctypes.c_size_t),
                ('Offset', wintypes.DWORD), ('OffsetHigh', wintypes.DWORD), ('hEvent', wintypes.HANDLE)]


def decode_records(raw):
    records, offset = [], 0
    while True:
        if len(raw) - offset < 12:
            raise ValueError('truncated notification')
        following, action, size = struct.unpack_from('<III', raw, offset)
        if size % 2 or offset + 12 + size > len(raw):
            raise ValueError('invalid notification filename length')
        name = raw[offset + 12:offset + 12 + size].decode('utf-16-le')
        if not name or action not in (1, 2, 3, 4, 5):
            raise ValueError('invalid notification action or filename')
        records.append({'path': name, 'action': action})
        if not following:
            return records
        if following % 4 or following < 12 + size or offset + following >= len(raw):
            raise ValueError('invalid notification offset')
        offset += following


class Native:
    def __init__(self):
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        h, d, b, p = wintypes.HANDLE, wintypes.DWORD, wintypes.BOOL, ctypes.c_void_p
        ov = ctypes.POINTER(Overlapped)
        signatures = {
            'CreateFileW': ([wintypes.LPCWSTR, d, d, p, d, d, h], h),
            'OpenProcess': ([d, b, d], h), 'CloseHandle': ([h], b),
            'CreateEventW': ([p, b, b, wintypes.LPCWSTR], h), 'ResetEvent': ([h], b),
            'ReadDirectoryChangesW': ([h, p, d, b, d, p, ov, p], b),
            'GetOverlappedResult': ([h, ov, ctypes.POINTER(d), b], b),
            'WaitForMultipleObjects': ([d, ctypes.POINTER(h), b, d], d),
            'WaitForSingleObject': ([h, d], d), 'CancelIoEx': ([h, ov], b),
        }
        for name, (arguments, result) in signatures.items():
            method = getattr(self.kernel, name)
            method.argtypes, method.restype = arguments, result
            setattr(self, name, method)

    @staticmethod
    def checked(value):
        if not value or value == ctypes.c_void_p(-1).value:
            raise ctypes.WinError(ctypes.get_last_error())
        return value


def emit(record):
    print(json.dumps(dict(v=1, **record), ensure_ascii=True, separators=(',', ':')), flush=True)


def watch(root, parent_pid, *, capacity=CAPACITY, output=emit):
    native = Native()
    root = os.path.abspath(root)
    if not os.path.isdir(root):
        raise NotADirectoryError(root)
    if not 16 <= capacity <= CAPACITY or capacity % 4:
        raise ValueError('invalid notification buffer size')
    native_root = root if root.startswith('\\\\?\\') else (
        '\\\\?\\UNC\\' + root[2:] if root.startswith('\\\\') else '\\\\?\\' + root)
    parent = directory = signal = None
    pending = False
    overlapped = Overlapped()
    buffer = (wintypes.DWORD * (capacity // 4))()

    def arm():
        nonlocal pending
        native.checked(native.ResetEvent(signal))
        ctypes.memset(ctypes.byref(overlapped), 0, ctypes.sizeof(overlapped))
        overlapped.hEvent = signal
        native.checked(native.ReadDirectoryChangesW(directory, buffer, capacity, True, FILTER,
                                                    None, ctypes.byref(overlapped), None))
        pending = True

    try:
        parent = native.checked(native.OpenProcess(0x00100000, False, parent_pid))  # SYNCHRONIZE
        directory = native.checked(native.CreateFileW(native_root, 1, 7, None, 3, 0x42000000, None))
        signal = native.checked(native.CreateEventW(None, True, False, None))
        handles = (wintypes.HANDLE * 2)(parent, signal)
        arm()
        output({'kind': 'ready'})
        while True:
            completed = native.WaitForMultipleObjects(2, handles, False, 0xFFFFFFFF)
            if completed == 0:
                # Never release Python buffers while a kernel request owns them.
                # Process teardown cancels its I/O and closes its handles.
                os._exit(0)
            if completed != 1:
                raise ctypes.WinError(ctypes.get_last_error())
            count = wintypes.DWORD()
            ok = native.GetOverlappedResult(directory, ctypes.byref(overlapped), ctypes.byref(count), False)
            error = ctypes.get_last_error() if not ok else 0
            if error == 996:  # ERROR_IO_INCOMPLETE
                continue
            pending = False
            if error and error != 1022:  # ERROR_NOTIFY_ENUM_DIR is lost detail, not silence.
                raise ctypes.WinError(error)
            raw = ctypes.string_at(buffer, count.value) if ok else b''
            arm()
            if not raw:
                output({'kind': 'overflow', 'winerror': error})
                continue
            records = decode_records(raw)
            for record in records:
                # A deleted/renamed old name may no longer exist; the Lua owner
                # conservatively invalidates unclassified namespace changes.
                record['directory'] = os.path.isdir(os.path.join(root, record['path']))
            output({'kind': 'events', 'events': records})
    finally:
        if pending:
            native.CancelIoEx(directory, ctypes.byref(overlapped))
            if native.WaitForSingleObject(signal, 2000) != 0:
                os._exit(2)
            count = wintypes.DWORD()
            native.GetOverlappedResult(directory, ctypes.byref(overlapped), ctypes.byref(count), False)
        for handle in (directory, signal, parent):
            if handle:
                native.CloseHandle(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root')
    parser.add_argument('parent_pid', type=int)
    args = parser.parse_args()
    try:
        watch(args.root, args.parent_pid)
    except Exception as error:
        try:
            emit({'kind': 'error', 'error': str(error), 'winerror': getattr(error, 'winerror', None)})
        except (BrokenPipeError, OSError):
            os._exit(2)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
