import atexit
import ctypes
import ctypes.wintypes as wintypes
import os
import sys
import traceback


user32 = ctypes.WinDLL("user32", use_last_error=True)
kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)

WH_KEYBOARD_LL = 13
WM_KEYDOWN = 0x0100
WM_KEYUP = 0x0101
WM_SYSKEYDOWN = 0x0104
WM_SYSKEYUP = 0x0105
VK_CAPITAL = 0x14
VK_ESCAPE = 0x1B
KEYEVENTF_KEYUP = 0x0002
LLKHF_INJECTED = 0x0010
MUTEX_NAME = "Local\\CapsLockToEscRemap"


ULONG_PTR = wintypes.WPARAM
LRESULT = wintypes.LPARAM


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [
        ("vkCode", wintypes.DWORD),
        ("scanCode", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class KEYBDINPUT(ctypes.Structure):
    _fields_ = [
        ("wVk", wintypes.WORD),
        ("wScan", wintypes.WORD),
        ("dwFlags", wintypes.DWORD),
        ("time", wintypes.DWORD),
        ("dwExtraInfo", ULONG_PTR),
    ]


class _INPUT_UNION(ctypes.Union):
    _fields_ = [
        ("ki", KEYBDINPUT),
    ]


class INPUT(ctypes.Structure):
    _anonymous_ = ("union",)
    _fields_ = [
        ("type", wintypes.DWORD),
        ("union", _INPUT_UNION),
    ]


LowLevelKeyboardProc = ctypes.WINFUNCTYPE(
    LRESULT,
    ctypes.c_int,
    wintypes.WPARAM,
    wintypes.LPARAM,
)

user32.SetWindowsHookExW.argtypes = [ctypes.c_int, LowLevelKeyboardProc, wintypes.HINSTANCE, wintypes.DWORD]
user32.SetWindowsHookExW.restype = wintypes.HANDLE
user32.UnhookWindowsHookEx.argtypes = [wintypes.HANDLE]
user32.UnhookWindowsHookEx.restype = wintypes.BOOL
user32.CallNextHookEx.argtypes = [wintypes.HANDLE, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM]
user32.CallNextHookEx.restype = LRESULT
user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
user32.SendInput.restype = wintypes.UINT
user32.GetMessageW.argtypes = [ctypes.POINTER(wintypes.MSG), wintypes.HWND, wintypes.UINT, wintypes.UINT]
user32.GetMessageW.restype = wintypes.BOOL
kernel32.CreateMutexW.argtypes = [wintypes.LPVOID, wintypes.BOOL, wintypes.LPCWSTR]
kernel32.CreateMutexW.restype = wintypes.HANDLE
kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
kernel32.CloseHandle.restype = wintypes.BOOL


hook_handle = None
proc_ref = None
mutex_handle = None
log_path = os.path.join(os.path.dirname(__file__), "capslock_to_esc.log")


def log(message):
    try:
        with open(log_path, "a", encoding="utf-8") as handle:
            handle.write(message + "\n")
    except OSError:
        pass


def send_escape():
    inputs = (INPUT * 2)()
    inputs[0].type = 1
    inputs[0].ki = KEYBDINPUT(VK_ESCAPE, 0, 0, 0, 0)
    inputs[1].type = 1
    inputs[1].ki = KEYBDINPUT(VK_ESCAPE, 0, KEYEVENTF_KEYUP, 0, 0)
    user32.SendInput(len(inputs), ctypes.byref(inputs), ctypes.sizeof(INPUT))


def keyboard_proc(code, wparam, lparam):
    if code >= 0:
        event = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
        if event.vkCode == VK_CAPITAL and (event.flags & LLKHF_INJECTED) == 0:
            if wparam in (WM_KEYDOWN, WM_SYSKEYDOWN):
                send_escape()
            if wparam in (WM_KEYDOWN, WM_KEYUP, WM_SYSKEYDOWN, WM_SYSKEYUP):
                return 1
    return user32.CallNextHookEx(hook_handle, code, wparam, lparam)


def cleanup():
    global hook_handle, mutex_handle
    if hook_handle:
        user32.UnhookWindowsHookEx(hook_handle)
        hook_handle = None
    if mutex_handle:
        kernel32.CloseHandle(mutex_handle)
        mutex_handle = None


def ensure_single_instance():
    global mutex_handle
    mutex_handle = kernel32.CreateMutexW(None, False, MUTEX_NAME)
    if not mutex_handle:
        log("CreateMutexW failed")
        return False
    ERROR_ALREADY_EXISTS = 183
    if kernel32.GetLastError() == ERROR_ALREADY_EXISTS:
        log("Another instance already exists")
        return False
    return True


def install_hook():
    global hook_handle, proc_ref
    proc_ref = LowLevelKeyboardProc(keyboard_proc)
    hook_handle = user32.SetWindowsHookExW(WH_KEYBOARD_LL, proc_ref, None, 0)
    if not hook_handle:
        log(f"SetWindowsHookExW failed: {ctypes.get_last_error()}")
    return bool(hook_handle)


def message_loop():
    msg = wintypes.MSG()
    while user32.GetMessageW(ctypes.byref(msg), None, 0, 0) != 0:
        user32.TranslateMessage(ctypes.byref(msg))
        user32.DispatchMessageW(ctypes.byref(msg))


def main():
    log("Starting CapsLockToEsc")
    if not ensure_single_instance():
        return 0
    if not install_hook():
        cleanup()
        return 1
    log("Hook installed")
    atexit.register(cleanup)
    message_loop()
    log("Message loop exited")
    cleanup()
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception:
        log(traceback.format_exc())
        raise
