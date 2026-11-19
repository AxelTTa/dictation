"""Paste step for Windows: Handy runs this with the transcript (its "external script" paste method).

It asks the helper (dictation_helper.py) for the better text and the window you started in, then pastes there:
same window, plain Ctrl+V; another window, brings the start window forward, pastes, and goes back to where you are.
The words stay on the clipboard afterwards, so a paste that missed is one Ctrl+V away.

Never hangs Handy (Handy waits for this program with no time limit): the helper gets 2.5 s, and after 6 s in all the
words go on the clipboard and this exits. If anything fails, Handy's own text is pasted where you are.

    dictation-paste "text"        what Handy runs
    DICTATION_DRY=1 dictation-paste "text"   prints what it would paste and where, touches nothing
"""
import ctypes
import json
import os
import socket
import sys
import threading
import time

HOME = os.environ.get("DICTATION_HOME") or os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")), "dictation")
STATE = os.path.join(HOME, "helper.json")
LOG = os.path.join(HOME, "logs", "paste.log")
DRY = os.environ.get("DICTATION_DRY") == "1"
HELPER_WAIT = float(os.environ.get("DICTATION_HELPER_WAIT", 2.5))  # tests on slow machines wait longer
DEADLINE = HELPER_WAIT + 3.5


def log(line):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        if os.path.exists(LOG) and os.path.getsize(LOG) > 1_000_000:
            os.replace(LOG, LOG + ".old")
        with open(LOG, "a", encoding="utf-8") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%S ") + line + "\n")
    except OSError:
        pass


if sys.platform == "win32":
    from ctypes import wintypes
    user32 = ctypes.WinDLL("user32", use_last_error=True)
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    user32.GetForegroundWindow.restype = wintypes.HWND
    user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
    user32.GetWindowThreadProcessId.restype = wintypes.DWORD
    user32.SetForegroundWindow.argtypes = [wintypes.HWND]
    user32.BringWindowToTop.argtypes = [wintypes.HWND]
    user32.IsWindow.argtypes = [wintypes.HWND]
    user32.IsWindowVisible.argtypes = [wintypes.HWND]
    user32.IsIconic.argtypes = [wintypes.HWND]
    user32.ShowWindow.argtypes = [wintypes.HWND, ctypes.c_int]
    user32.OpenClipboard.argtypes = [wintypes.HWND]
    user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    user32.SetClipboardData.restype = wintypes.HANDLE
    kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalLock.restype = wintypes.LPVOID
    kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]
    kernel32.GlobalFree.argtypes = [wintypes.HGLOBAL]

    ULONG_PTR = ctypes.c_size_t

    class KEYBDINPUT(ctypes.Structure):
        _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                    ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]

    class MOUSEINPUT(ctypes.Structure):
        _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                    ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]

    class HARDWAREINPUT(ctypes.Structure):
        _fields_ = [("uMsg", wintypes.DWORD), ("wParamL", wintypes.WORD), ("wParamH", wintypes.WORD)]

    class _INPUTUNION(ctypes.Union):
        _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT), ("hi", HARDWAREINPUT)]

    class INPUT(ctypes.Structure):
        _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]

    user32.SendInput.argtypes = [wintypes.UINT, ctypes.POINTER(INPUT), ctypes.c_int]
    user32.AttachThreadInput.argtypes = [wintypes.DWORD, wintypes.DWORD, wintypes.BOOL]


def set_clipboard(text):
    data = (text + "\0").encode("utf-16-le")
    for _ in range(20):  # another program may hold the clipboard for a moment
        if user32.OpenClipboard(None):
            break
        time.sleep(0.025)
    else:
        return False
    try:
        user32.EmptyClipboard()
        handle = kernel32.GlobalAlloc(0x0002, len(data))  # GMEM_MOVEABLE
        pointer = kernel32.GlobalLock(handle)
        ctypes.memmove(pointer, data, len(data))
        kernel32.GlobalUnlock(handle)
        if not user32.SetClipboardData(13, handle):  # CF_UNICODETEXT; the clipboard owns it now
            kernel32.GlobalFree(handle)
            return False
        return True
    finally:
        user32.CloseClipboard()


def key(vk, up=False):
    i = INPUT(type=1)  # INPUT_KEYBOARD
    i.u.ki = KEYBDINPUT(wVk=vk, wScan=0, dwFlags=0x0002 if up else 0, time=0, dwExtraInfo=0)
    return i


def press_ctrl_v():
    events = (INPUT * 4)(key(0x11), key(0x56), key(0x56, up=True), key(0x11, up=True))  # Ctrl down, V, Ctrl up
    user32.SendInput(4, events, ctypes.sizeof(INPUT))


def front():
    return user32.GetForegroundWindow() or None


def bring_forward(hwnd):
    """Windows lets only the program you are using pick the front window, so borrow its input queue for the call."""
    if not hwnd or not user32.IsWindow(hwnd) or not user32.IsWindowVisible(hwnd):
        return False
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    for attempt in range(2):
        current = front()
        me = kernel32.GetCurrentThreadId()
        theirs = user32.GetWindowThreadProcessId(current, None) if current else 0
        attached = bool(theirs and theirs != me and user32.AttachThreadInput(me, theirs, True))
        try:
            if attempt:  # an input event of our own also unlocks it: a mouse move of zero
                move = INPUT(type=0)
                move.u.mi = MOUSEINPUT(dx=0, dy=0, mouseData=0, dwFlags=0x0001, time=0, dwExtraInfo=0)
                user32.SendInput(1, ctypes.byref(move), ctypes.sizeof(INPUT))
            user32.BringWindowToTop(hwnd)
            user32.SetForegroundWindow(hwnd)
        finally:
            if attached:
                user32.AttachThreadInput(me, theirs, False)
        for _ in range(20):
            if front() == hwnd:
                return True
            time.sleep(0.02)
    return False


def ask_helper(text):
    """(text, start window, where the words came from). Handy's own text if the helper is not there or slow."""
    try:
        with open(STATE, encoding="utf-8") as f:
            state = json.load(f)
        conn = socket.create_connection(("127.0.0.1", int(state["port"])), timeout=0.5)
    except (OSError, ValueError, KeyError):
        return text, None, "Handy's text: helper not running"
    deadline = time.time() + HELPER_WAIT
    try:
        with conn:
            conn.sendall((json.dumps({"token": state.get("token"), "handy": text}) + "\n").encode("utf-8"))
            data = b""
            while True:
                conn.settimeout(max(0.05, deadline - time.time()))
                chunk = conn.recv(65536)
                if not chunk:
                    break
                data += chunk
        reply = json.loads(data.decode("utf-8"))
    except (OSError, ValueError):
        return text, None, "Handy's text: helper too slow"
    better = reply.get("text") or ""
    if not better.strip():
        return text, reply.get("start"), "Handy's text"
    source = reply.get("source", "?") + (", punctuation added" if reply.get("punctuated") else "")
    return better, reply.get("start"), source


def main():
    text = " ".join(sys.argv[1:])
    if not text.strip():
        return
    began = time.time()

    def give_up():  # Handy must never wait forever on us
        log(f"TIMED OUT after {DEADLINE:.0f}s; kept {len(text)} chars on the clipboard")
        if not DRY:
            set_clipboard(text)
        os._exit(0)

    timer = threading.Timer(DEADLINE, give_up)
    timer.daemon = True
    timer.start()

    final, start, source = ask_helper(text)
    current = front() if sys.platform == "win32" else None
    target = start.get("hwnd") if start else None
    route = bool(target and current and target != current and sys.platform == "win32" and user32.IsWindow(target))
    if DRY:
        print(("route to " + start.get("name", "?") if route else "here") + " | " + final + " | " + source)
        return
    if not set_clipboard(final):
        log("could not open the clipboard; nothing pasted")
        return
    if route and bring_forward(target):
        time.sleep(0.15)  # let the window put focus back in its text box
        press_ctrl_v()
        time.sleep(0.2)   # the paste reads the clipboard before we leave
        back = bring_forward(current)
        log(f"pasted {len(final)} chars ({source}) into {start.get('name', '?')}, back to where you were"
            f"{'' if back else ' FAILED'}, in {int((time.time() - began) * 1000)}ms")
    else:
        press_ctrl_v()
        where = "where you are" + (f" (could not bring {start.get('name', '?')} forward)" if route else "")
        log(f"pasted {len(final)} chars ({source}) {where}, in {int((time.time() - began) * 1000)}ms")
    time.sleep(0.05)


def run():
    """The program's entry point: never leaves Handy with an error and no words."""
    try:
        main()
    except Exception as error:
        log(f"failed: {error!r}")
        if len(sys.argv) > 1 and not DRY and sys.platform == "win32":
            set_clipboard(" ".join(sys.argv[1:]))
    return 0


if __name__ == "__main__":
    sys.exit(run())
