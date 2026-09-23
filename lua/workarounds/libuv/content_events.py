"""Windows source/input notifications; companion to libuv.content_events.lua.

Parent-bound native waits, no source reads or tree scans. The single source
watch excludes access/attribute/security/creation subscriptions; grouped frozen
inputs exclude only last access. See Microsoft's ReadDirectoryChangesW,
GetOverlappedResult and CancelIoEx contracts.
"""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
import stat
import struct
import sys
import threading

FILTER = 0x1B  # FILE_NAME | DIR_NAME | SIZE | LAST_WRITE
INPUT_FILTER = 0x15F  # All libuv input categories except LAST_ACCESS (0x20).
INPUT_STREAMS = {'metadata': 0x147, 'write': 0x18}
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


def watch(root, parent_pid, *, capacity=CAPACITY, output=emit, recursive=True, notification_filter=FILTER):
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
        native.checked(native.ReadDirectoryChangesW(directory, buffer, capacity, recursive, notification_filter,
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


def ordinary_directory_identity(path):
    """No following links/reparse points, and no timestamp-based identity."""
    try:
        info = os.lstat(path)
        attributes = info.st_file_attributes
        if (not stat.S_ISDIR(info.st_mode) or attributes & 0x400
                or not info.st_dev or not info.st_ino):
            return None
        return info.st_dev, info.st_ino, attributes
    except (OSError, AttributeError):
        return None


def input_event(root, stream, event, directories):
    """Annotate only; consumers must independently decide what can be ignored."""
    event = dict(event)
    if stream == 'write' and event.get('action') == 3 and event.get('directory') is True:
        path = os.path.normcase(os.path.abspath(os.path.join(root, event['path'])))
        baseline = directories.get(path)
        if baseline is not None and ordinary_directory_identity(path) == baseline:
            event['stable_directory_write'] = True
    return event


def watch_group(parent_pid):
    """One bounded input group; each thread owns its overlapped I/O buffers."""
    raw = sys.stdin.buffer.readline(1024 * 1024 + 1)
    if len(raw) > 1024 * 1024 or not raw.endswith(b'\n'):
        raise ValueError('invalid group configuration frame')
    config = json.loads(raw)
    roots = config.get('roots') if isinstance(config, dict) and config.get('v') == 1 else None
    if not isinstance(roots, list) or not 1 <= len(roots) <= 288:
        raise ValueError('invalid group roots')
    recursive_count = direct_count = 0
    seen = set()
    for position, root in enumerate(roots, 1):
        if (not isinstance(root, dict) or root.get('id') != position
                or not isinstance(root.get('path'), str) or not os.path.isabs(root['path'])
                or any(c in root['path'] for c in '\0\r\n') or type(root.get('recursive')) is not bool):
            raise ValueError('invalid group root')
        key = (os.path.normcase(os.path.abspath(root['path'])), root['recursive'])
        if key in seen:
            raise ValueError('duplicate group root')
        seen.add(key)
        recursive_count += root['recursive']
        direct_count += not root['recursive']
    if recursive_count > 32 or direct_count > 256:
        raise ValueError('group root budget exceeded')
    # Only the bounded configured roots can receive the annotation. No tree
    # scanning, following junctions or inferring stability from timestamps.
    directories = {os.path.normcase(os.path.abspath(root['path'])):
                   ordinary_directory_identity(root['path']) for root in roots}
    output_lock = threading.Lock()
    armed = {root['id']: set() for root in roots}

    def output(root, stream, record):
        with output_lock:
            if record['kind'] == 'ready':
                armed[root['id']].add(stream)
                if len(armed[root['id']]) == len(INPUT_STREAMS):
                    emit({'kind': 'ready', 'root_id': root['id'], 'streams': list(INPUT_STREAMS)})
                return
            if record['kind'] == 'events':
                record = dict(record, events=[input_event(root['path'], stream, event, directories)
                                              for event in record['events']])
            emit(dict(record, root_id=root['id'], stream=stream))

    def run(root, stream, mask):
        try:
            watch(root['path'], parent_pid, recursive=root['recursive'], notification_filter=mask,
                  output=lambda record: output(root, stream, record))
            raise RuntimeError('input watch unexpectedly returned')
        except BaseException as error:
            try:
                output(root, stream, {'kind': 'error', 'error': str(error)})
            finally:
                os._exit(2)

    def input_closed():
        # No second command is supported. EOF or unexpected input ends the
        # process, letting the OS cancel all outstanding requests atomically.
        sys.stdin.buffer.read(1)
        os._exit(2)

    threading.Thread(target=input_closed, daemon=True).start()
    for root in roots:
        for stream, mask in INPUT_STREAMS.items():
            threading.Thread(target=run, args=(root, stream, mask), daemon=True).start()
    threading.Event().wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', nargs='?')
    parser.add_argument('parent_pid', type=int, nargs='?')
    parser.add_argument('--group', type=int, metavar='PARENT_PID')
    args = parser.parse_args()
    try:
        if args.group is not None:
            if args.root is not None or args.parent_pid is not None:
                raise ValueError('group mode does not accept positional roots')
            watch_group(args.group)
        else:
            if args.root is None or args.parent_pid is None:
                raise ValueError('root and parent_pid required')
            watch(args.root, args.parent_pid)
    except Exception as error:
        try:
            emit({'kind': 'error', 'error': str(error), 'winerror': getattr(error, 'winerror', None)})
        except (BrokenPipeError, OSError):
            os._exit(2)
        if args.group is not None:
            # A thread-start/configuration failure may occur after other
            # subscriptions were armed. Do not tear down Python buffers while
            # the kernel still owns pending requests; terminate the group.
            os._exit(2)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
